import json
import os
import time
from typing import Optional

import eth_abi
import requests
from eth_account import Account
from eth_account.datastructures import SignedMessage, SignedTransaction
from eth_account.messages import encode_defunct
from tqdm import tqdm
from web3 import Web3

from avs_operator.nodes import OperatorNodesManager
from common.auto_update import AutoUpdate
from common.config import OperatorConfig
from common.logging import get_logger
from common.contract_constants import TaskStructMap
from common.eth import EthereumClient, load_ecdsa_private_key
from models.onnx_run import run_onnx
from models.proof.ezkl_handler import EZKLHandler

logger = get_logger("operator")


def run_operator(config: OperatorConfig) -> None:
    logger.info("Starting Sertn Operator...")

    with tqdm(total=100, desc="Initializing operator") as pbar:
        task_operator = TaskOperator(config)
        pbar.update(25)
        task_operator.nodes_manager.sync_nodes()
        task_operator.nodes_manager.print_nodes()
        # task_operator.register()
        pbar.update(100)
    task_operator.listen_for_events()


class TaskOperator:
    def __init__(self, config: OperatorConfig):
        self.config = config
        self.eth_client = EthereumClient(
            eth_rpc_url=self.config.eth_rpc_url, gas_strategy=self.config.gas_strategy
        )
        self.private_key = load_ecdsa_private_key(
            keystore_path=str(self.config.ecdsa_private_key_store_path),
            password=os.environ.get("OPERATOR_ECDSA_KEY_PASSWORD", ""),
        )
        self.operator_address = Account.from_key(self.private_key).address

        self.nodes_manager = OperatorNodesManager(
            private_key=self.private_key,
            operator_address=self.operator_address,
            eth_client=self.eth_client,
            nodes_config=self.config.nodes,
        )
        self.auto_update = AutoUpdate()

    def listen_for_events(self, loop_running: bool = True) -> int | None:
        logger.info("Starting Operator...")
        task_assigned_events = (
            self.eth_client.task_manager.events.TaskAssigned.create_filter(
                from_block="latest"
            )
        )
        task_challenged_events = (
            self.eth_client.task_manager.events.TaskChallenged.create_filter(
                from_block="latest"
            )
        )
        processed_count: int = 0
        while True:
            for event in task_assigned_events.get_new_entries():
                logger.info(f"New assignedTask received. Processing...")
                self.process_assigned_task(
                    event["args"]["taskId"], event["args"]["operator"]
                )
                processed_count += 1
            for event in task_challenged_events.get_new_entries():
                logger.info(f"Challenged received. Processing...")
                self.process_challenged_task(event["args"]["taskId"])
                processed_count += 1
            if not loop_running:
                logger.info("Stopping Operator...")
                return processed_count
            if self.config.auto_update:
                self.auto_update.try_update()
            time.sleep(3)

    def process_assigned_task(self, task_id: int, operator_address: bytes):
        """Process assigned task by task ID and operator address."""

        if operator_address != self.operator_address:
            logger.info(
                f"Operator address {operator_address} does not match "
                f"the operator address {self.operator_address}, skipping...",
            )
            return

        # get task details, `struct ISertnTaskManager.Task`
        task = self.eth_client.task_manager.functions.tasks(task_id).call()
        model_id: int = task[TaskStructMap.MODEL_ID]  # uint256 modelId
        inputs: bytes = task[TaskStructMap.INPUTS]  # bytes inputs
        operator_address: str = task[TaskStructMap.OPERATOR]  # address operator

        model_name: str = self.eth_client.model_registry.functions.modelName(
            model_id
        ).call()
        input_data = [float(i) for i in inputs.decode().split(" ") if i]
        output = run_onnx(
            model_id=model_name,
            input_data=input_data,
        )
        output_bytes: bytes = json.dumps(output).encode()

        # post task output to the task manager contract
        self.eth_client.execute_transaction(
            self.eth_client.task_manager,
            "submitTaskOutput",
            self.private_key,
            [task_id, output_bytes],
        )

    def process_challenged_task(self, task_id: int):
        # get task details, `struct ISertnTaskManager.Task`
        task = self.eth_client.task_manager.functions.tasks(task_id).call()

        starting_block: int = task[TaskStructMap.START_BLOCK]  # uint256 startBlock
        model_id: int = task[TaskStructMap.MODEL_ID]  # uint256 modelId
        inputs: bytes = task[TaskStructMap.INPUTS]  # bytes inputs
        operator_address: str = task[TaskStructMap.OPERATOR]  # address operator

        if operator_address != self.operator_address:
            logger.info(
                f"Operator address {operator_address} does not match "
                f"the operator address {self.operator_address}, skipping...",
            )
            return

        # generate proof for the task
        proof = self.generate_proof_for_task(inputs, task_id, model_id)
        proof_encoded = proof.encode()

        # submit proof to the task manager contract
        self.eth_client.execute_transaction(
            self.eth_client.task_manager,
            "submitProofForTask",
            self.private_key,
            [task_id, proof_encoded],
        )

        # sign the proof
        encoded = eth_abi.encode(
            ["uint256", "bytes", "address"],
            [task_id, proof_encoded, operator_address],
        )
        message = encode_defunct(primitive=encoded)
        signed_message: SignedMessage = Account.sign_message(
            message, private_key=self.private_key
        )
        signature = signed_message.signature.hex()
        logger.info(
            f"Signature generated, task_id: {task_id}, model: {model_id}, "
            f"signature: {signature}",
        )

        # send the proof and signature to the aggregator server
        try:
            resp = requests.post(
                f"http://{self.config.aggregator_server_ip_port_address}/proof",
                json={
                    "task_id": task_id,
                    "proof": proof,
                    "signature": signature,
                },
            )
            resp.raise_for_status()
            logger.info(
                f"Successfully posted a proof for the {task_id} task",
            )
        except requests.RequestException as e:
            err_text = e.response.text if getattr(e, "response", None) else str(e)
            logger.warning(
                f"Failed to post a proof for the {task_id} task: {err_text}",
            )

    def generate_proof_for_task(
        self, inputs: bytes, task_id: int, model_id: int
    ) -> Optional[str]:
        """
        Generate proof for the task with the given task_id.
        """
        # generate proof for the task
        model_name: str = self.eth_client.model_registry.functions.modelName(
            model_id
        ).call()
        proof_generator = EZKLHandler(
            model_id=model_name,
            task_id=str(task_id),
            inputs=[float(i) for i in inputs.decode().split(" ")],
        )
        proof_generator.gen_input_file()
        proof_result = proof_generator.gen_proof()
        if not proof_result or len(proof_result) == 0:
            return None
        proof: str = proof_result[0]
        return proof

    def post_task_output(
        self,
        task_id: int,
        output: bytes,
    ):
        """
        Post task output to the task manager contract.
        """
        self.eth_client.execute_transaction(
            self.eth_client.task_manager,
            "submitTaskOutput",
            self.private_key,
            [task_id, output],
        )
        logger.info(
            f"Successfully posted an output to the {task_id} task",
        )
