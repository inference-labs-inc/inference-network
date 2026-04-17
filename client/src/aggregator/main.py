import os
import random
import threading
import time

import eth_abi
from eth_account import Account
from eth_account.messages import encode_defunct
from web3 import Web3
from web3.contract import Contract

from aggregator.errors import InvalidProofError
from aggregator.server import AggregatorServer
from common.abis import ERC20_ABI, STRATEGY_ABI
from common.auto_update import AutoUpdate
from common.config import AggregatorConfig
from common.constants import (
    RESOLVE_BLOCKS_DELAY,
)
from common.contract_constants import (
    ContractVerificationStrategy,
    TaskStateMap,
    TaskStructMap,
)
from common.eth import EthereumClient, load_ecdsa_private_key
from common.logging import get_logger
from models.execution_layer.model_registry import load_circuit_input_class
from models.proof.ezkl_handler import EZKLHandler

logger = get_logger("aggregator")


def run_aggregator(config: AggregatorConfig) -> None:
    """Start the Inference Aggregator with the given configuration.

    Args:
        config: Validated aggregator configuration object.
    """
    logger.info("Starting Inference Aggregator...")
    aggregator = Aggregator(config=config)
    threading.Thread(target=aggregator.start_sending_new_tasks, args=[]).start()
    threading.Thread(target=aggregator.listen_for_events, args=[]).start()
    threading.Thread(target=aggregator.check_pending_tasks, args=[]).start()
    aggregator.start_server()


class Aggregator:
    def __init__(self, config: AggregatorConfig) -> None:
        self.config = config
        self.eth_client = EthereumClient(
            eth_rpc_url=self.config.eth_rpc_url, gas_strategy=self.config.gas_strategy
        )
        self.private_key = load_ecdsa_private_key(
            keystore_path=str(self.config.ecdsa_private_key_store_path),
            password=os.environ.get("AGGREGATOR_ECDSA_KEY_PASSWORD", ""),
        )
        # the aggregator gonna request proofs for some responses randomly, so probability:
        self.proof_req_probability = self.config.proof_request_probability
        self.aggregator_address = Account.from_key(self.private_key).address

        self.auto_update = AutoUpdate()

        # HTTP server
        self.server = AggregatorServer(self)

    def start_server(self) -> None:
        """
        Runs and blocks the current thread.
        """
        self.server.start()

    def start_sending_new_tasks(self, loop_running: bool = True) -> None:
        """
        Runs in a separate thread and sends new tasks to the task manager.

        Args:
            loop_running: If True, continuously send tasks. If False, send one and stop.
        """
        i = 0
        while True:
            logger.debug("Sending new task")
            self.send_new_task(i)
            if not loop_running:
                logger.debug("Stopping sending new tasks")
                break
            time.sleep(60)
            if self.config.auto_update:
                self.auto_update.try_update()
            i += 1

    def send_new_task(self, i: int) -> int | None:
        """Send a new task to the task manager.

        Args:
            i: Task nonce/counter value.

        Returns:
            Task ID if successful, None if task could not be sent.
        """
        model_id, model_name = self.get_model_id()
        if model_id is None:
            logger.info(
                "No models found in the model registry, cannot send a new task",
            )
            return None

        operator_address = self.get_random_operator(model_id)
        if operator_address is None:
            logger.warning("No operators found, cannot send a new task")
            return None

        model_input_class = load_circuit_input_class(model_name)
        if model_input_class is None:
            logger.warning(f"No valid input class found for model {model_name}")
            return None

        inputs = " ".join([str(x) for x in model_input_class.generate()])

        # Define the _task struct, the dict should correspond to the struct in the contract
        task = {
            "startBlock": self.eth_client.w3.eth.block_number,  # uint256 - Current block number
            "startTimestamp": self.eth_client.w3.eth.get_block("latest")[
                "timestamp"
            ],  # uint256 - Current timestamp
            "modelId": model_id,  # uint256
            "inputs": inputs.encode(),  # bytes - actual input data
            "proofHash": b"\x00" * 32,  # bytes32 - Hash of the proof, empty for now
            "user": self.aggregator_address,  # at the moment the aggregator is the end user
            "nonce": i,  # uint256 - Nonce for the task, can be any number
            "operator": operator_address,  # address - Operator address, can be any address
            "state": TaskStateMap.CREATED.value,  # uint8 - gonna be changed by the contract anyway
            "output": b"",  # bytes - Output of the task, empty for now
            "fee": self.get_model_cost(
                model_id
            ),  # uint256 - Fee for the task, can be any number
        }

        token = self.get_token(task)

        print(f"Approving funds for the task - {task['fee']} tokens")
        self.eth_client.execute_transaction(
            token,
            "approve",
            self.private_key,
            [
                self.eth_client.service_manager.address,  # Approve the task manager to spend tokens
                task["fee"],  # Approve the fee amount
            ],
        )

        # XXX: Approve funds for the task?
        receipt = self.eth_client.execute_transaction(
            self.eth_client.task_manager, "sendTask", self.private_key, [task]
        )

        logger.debug(f"New task sent!")

        # also `TaskCreated` event is emitted, do we need it?
        event = self.eth_client.task_manager.events.TaskAssigned().process_log(
            receipt["logs"][-1]
        )

        task_index = event["args"]["taskId"]
        logger.info(f"Successfully sent the new task {task_index}")

        return task_index

    def get_random_operator(self, model_id: int) -> str | None:
        """Get a random operator address from the allocation manager.

        Args:
            model_id: The model ID to find operators for.

        Returns:
            Random operator address or None if no operators found.
        """
        fucus: int = self.get_model_fucus(model_id)
        operators = (
            self.eth_client.nodes_manager.functions.getAvailableOperatorsForModel(
                model_id, fucus
            ).call()
        )[0]
        if operators:
            return random.choice(operators)
        else:
            logger.error("No operators found in the allocation manager")
            return None

    def get_model_id(self) -> tuple[int | None, str | None]:
        """Get a model ID from the model registry.

        Returns:
            Tuple of (model_id, model_name) or (None, None) if no models found.
        """
        models_count = self.eth_client.model_registry.functions.modelIndex().call() - 1
        # `modelIndex` is an index for future new model.
        # So `modelIndex == 1` means there is no model registered.
        if models_count < 1:
            logger.error("No models found in the model registry")
            return None, None

        # Prefer on-chain random active model selection for efficiency
        try:
            seed = random.randint(0, 2**256 - 1)
            model_id = self.eth_client.model_registry.functions.getRandomActiveModel(
                seed
            ).call()
        except Exception:
            logger.error("No active model found")
            return None, None

        model_name = self.eth_client.model_registry.functions.modelName(model_id).call()
        return model_id, model_name

    def get_model_cost(self, model_id: int) -> int:
        """
        Get the compute cost for a model by its ID.
        This is just a placeholder function, you might want to implement a more sophisticated logic.
        """
        cost: int = self.eth_client.model_registry.functions.computeCost(
            model_id
        ).call()
        if not cost:
            logger.error(f"Model {model_id} has zero cost!!!")
            cost = 0
        return cost

    def get_model_fucus(self, model_id: int) -> int:
        fucus: int = self.eth_client.model_registry.functions.requiredFUCUs(
            model_id
        ).call()
        if not fucus:
            logger.error(f"Model {model_id} has zero fucus!!!")
            fucus = 0
        return fucus

    def get_token(self, task: dict) -> Contract | None:
        """Get the token contract used for task fees.

        Args:
            task: Task dictionary containing operator address.

        Returns:
            ERC20 token contract or None if not found.
        """
        allocated_sets = self.eth_client.allocation_manager.functions.getAllocatedSets(
            task["operator"]
        ).call()
        print(
            f"Got {len(allocated_sets)} allocated sets for operator {task['operator']}"
        )
        if not allocated_sets:
            logger.error(f"No allocated sets for operator {task['operator']}")
            return None
        strategy_addresses = (
            self.eth_client.allocation_manager.functions.getAllocatedStrategies(
                task["operator"], allocated_sets[0]
            ).call()
        )
        print(
            f"Got {len(strategy_addresses)} allocated strategies for operator {task['operator']}"
        )
        if not strategy_addresses:
            logger.error(f"No allocated strategies for operator {task['operator']}")
            return None

        strategy = self.eth_client.w3.eth.contract(
            address=strategy_addresses[0],
            abi=STRATEGY_ABI,
        )
        print(f"Got strategy {strategy.address} for operator {task['operator']}")

        token_address = strategy.functions.underlyingToken().call()
        print(f"Got token {token_address} for strategy {strategy.address}")

        return self.eth_client.w3.eth.contract(
            address=token_address,
            abi=ERC20_ABI,
        )

    def listen_for_events(self, loop_running: bool = True) -> int | None:
        """
        Listen for task manager events in a separate thread.
        """
        logger.debug("Listening for task manager events...")
        task_completed_events = (
            self.eth_client.task_manager.events.TaskCompleted.create_filter(
                from_block="latest"
            )
        )
        processed_count: int = 0
        while True:
            for event in task_completed_events.get_new_entries():
                logger.debug("Some task has been completed. Processing...")
                self.process_completed_task(event)
                processed_count += 1

            if not loop_running:
                logger.debug("Stopping event listener...")
                return processed_count

            time.sleep(3)

    def process_completed_task(self, event: dict) -> None:
        """Process a completed task event.

        Called when a task is completed and the TaskCompleted event is emitted.
        Checks the task state and either resolves the task or challenges it for a proof.

        Args:
            event: Event dictionary containing task information.
        """
        task_id = event["args"]["taskId"]
        logger.info(f"Processing completed task #{task_id}")
        # get task details from the contract
        task = self.eth_client.task_manager.functions.getTask(task_id).call()
        task_state = task[TaskStructMap.STATE]  # TaskStateMap
        if task_state != TaskStateMap.COMPLETED.value:
            logger.info(
                f"Task {task_id} has invalid state, current state: {task_state}",
            )
            return
        # no we are going to mark the task resolved or challenge it, requesting a proof
        # that's gonna be random. With configurable probability of proof requests
        if random.random() < self.proof_req_probability:
            # gonna request a proof
            self.challenge_task(task_id)
        else:
            # here we have a winner, gonna just resolve the task
            self.resolve_task(task_id=task_id, resolved=True)

    def challenge_task(self, task_id: int) -> None:
        """Challenge a task by its ID.

        Two cases of using this function:
        1. The task is not completed for a long time (300 blocks or something). So we are slashing the operator.
        2. The task is completed, but we want to get a proof from the operator.

        Args:
            task_id: ID of the task to challenge.
        """
        self.eth_client.execute_transaction(
            self.eth_client.task_manager, "challengeTask", self.private_key, [task_id]
        )

    def process_submitted_proof(self, task_id: int, proof: str, signature: str) -> bool:
        """Process a submitted proof for verification.

        Args:
            task_id: ID of the task.
            proof: Proof data as string.
            signature: Signature from the operator.

        Returns:
            True if proof is verified successfully.

        Raises:
            InvalidProofError: If proof verification fails.
        """
        logger.info(
            f"Processing proof submitted for the task #{task_id}...",
        )
        task: tuple = self.eth_client.task_manager.functions.getTask(task_id).call()
        operator_address: str = task[TaskStructMap.OPERATOR]

        # check the signature (the origin operator submitted us the data)
        encoded = eth_abi.encode(
            ["uint256", "bytes", "address"],
            [task_id, proof.encode(), operator_address],
        )
        message = encode_defunct(primitive=encoded)
        recovered_address = Account.recover_message(
            message, signature=bytes.fromhex(signature)
        )
        if recovered_address != operator_address:
            logger.info(
                f"Signature verification failed: {recovered_address} != {operator_address}",
            )
            raise InvalidProofError("Signature verification failed")

        # check the task state
        state: int = task[TaskStructMap.STATE]
        if state in (TaskStateMap.RESOLVED.value, TaskStateMap.REJECTED.value):
            logger.error(
                f"The task #{task_id} is already {TaskStateMap.from_int(state)}, skipping..."
            )
            raise InvalidProofError("The task is already resolved")
        if state != TaskStateMap.CHALLENGED.value:
            logger.error(
                f"The task #{task_id} isn't challenged. State is {TaskStateMap.from_int(state)}, skipping..."
            )
            raise InvalidProofError("The task isn't challenged")

        # check the task verification strategy
        model_id = task[TaskStructMap.MODEL_ID]
        verification_strategy: str = (
            self.eth_client.model_registry.functions.verificationStrategy(
                model_id
            ).call()
        )
        if verification_strategy != ContractVerificationStrategy.OFFCHAIN:
            logger.info(
                f"The task #{task_id} is not offchain verifiable...",
            )
            raise InvalidProofError("Not verifiable")
        model_name = self.eth_client.model_registry.functions.modelName(model_id).call()
        if not model_name:
            logger.info(
                f"The model {model_id} has no name, cannot verify the proof...",
            )
            raise InvalidProofError("Model name is empty")

        inputs: bytes = task[TaskStructMap.INPUTS]
        output: bytes = task[TaskStructMap.OUTPUT]
        proof_hash: bytes = task[TaskStructMap.PROOF_HASH]

        # check the task hash (is the same one submitted to the chain?)
        if proof_hash != Web3.keccak(proof.encode()):
            logger.error(
                "Proof hashes mismatch! Proof, submitted to the aggregator differs from"
                f" one submitted to the chain. Task #{task_id} Rejecting..."
            )
            self.resolve_task(task_id=task_id, resolved=False)  # slash the operator
            raise InvalidProofError("Invalid proof hash")

        # OK, we are good to verify the task
        validator_input = [float(i) for i in inputs.decode().split(" ")]
        proof_generator = EZKLHandler(
            model_id=model_name,
            task_id=str(task_id),
            inputs=validator_input,
        )
        verified: bool = proof_generator.verify_proof(
            validator_inputs=[validator_input], proof=proof
        )
        if verified:
            # cool, the operator might receive the reward
            logger.info(f"The task #{task_id} is verified!")
            self.resolve_task(task_id=task_id, resolved=True)
            return True
        else:
            # not good... the proof is not verified
            logger.error(f"The proof for task #{task_id} is invalid!")
            self.resolve_task(task_id=task_id, resolved=False)
            raise InvalidProofError("Proof is not verified")

    def resolve_task(self, task_id: int, resolved: bool) -> None:
        """Resolve a task by its ID.

        Args:
            task_id: ID of the task to resolve.
            resolved: If True, resolve as completed. If False, resolve as rejected (slash operator).
        """
        self.eth_client.execute_transaction(
            self.eth_client.task_manager,
            "resolveTask",
            self.private_key,
            [task_id, resolved],
        )

    def check_pending_tasks(self) -> None:
        """Check for pending tasks that are not completed for a long time.

        Intended to run in a separate thread. Challenges tasks that have been
        assigned or challenged for too long.
        """
        while True:
            pending_ids: list[int] = (
                self.eth_client.task_manager.functions.getPendingTasksIds().call()
            )
            current_block: int = self.eth_client.w3.eth.block_number
            for task_id in pending_ids:
                logger.debug(f"Checking pending task #{task_id}...")
                task: tuple = self.eth_client.task_manager.functions.getTask(
                    task_id
                ).call()
                task_state: int = task[TaskStructMap.STATE]
                start_block: int = task[TaskStructMap.START_BLOCK]
                if (
                    task_state == TaskStateMap.ASSIGNED.value
                    and start_block + RESOLVE_BLOCKS_DELAY < current_block
                ):
                    # the task is assigned, but not completed for a long time
                    # we are going to challenge it and slash the operator
                    logger.info(
                        f"Task #{task_id} is assigned, but not completed for a long time. Challenging...",
                    )
                    self.challenge_task(task_id)
                elif (
                    task_state == TaskStateMap.CHALLENGED.value
                    and start_block + RESOLVE_BLOCKS_DELAY * 2 < current_block
                ):
                    # the task is challenged, but not completed for a long time
                    # we are going to resolve it as rejected and slash the operator
                    logger.info(
                        f"Task #{task_id} is challenged, but a proof is not completed for a long time. "
                        "Challenging again... Contract will slash the operator.",
                    )
                    self.challenge_task(task_id=task_id)
            time.sleep(60)
