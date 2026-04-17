import json

from eth_account import Account
from eth_account.datastructures import SignedTransaction
from web3 import Web3
from web3.contract import Contract
from web3.types import TxReceipt

from common.abis import (
    ALLOCATION_MANAGER_ABI,
    DELEGATION_MANAGER_ABI,
    MODEL_REGISTRY_ABI,
    REWARDS_COORDINATOR_ABI,
    INFERENCE_NODES_MANAGER_ABI,
    SERVICE_MANAGER_ABI,
    STRATEGY_MANAGER_ABI,
    TASK_MANAGER_ABI,
)
from common.config import GasStrategy
from common.logging import get_logger
from common.constants import (
    ALLOCATION_MANAGER_ADDRESS,
    SERVICE_MANAGER_ADDRESS,
    TASK_MANAGER_ADDRESS,
)
from common.gas_strategy import get_gas_config

logger = get_logger("common")


def load_ecdsa_private_key(keystore_path: str, password: str) -> str:
    """Load ECDSA private key from keystore file.

    Args:
        keystore_path: Path to the keystore JSON file.
        password: Password to decrypt the keystore.

    Returns:
        Hex-encoded private key string.

    Raises:
        FileNotFoundError: If keystore file doesn't exist.
        ValueError: If password is incorrect or keystore is invalid.
    """
    if not password:
        logger.info(
            "ECDSA key password is not set. using empty string.",
        )

    try:
        with open(keystore_path, "r") as f:
            keystore = json.load(f)
    except FileNotFoundError:
        raise FileNotFoundError(f"Keystore file not found: {keystore_path}")
    except json.JSONDecodeError as e:
        raise ValueError(f"Invalid keystore JSON in {keystore_path}: {e}")

    try:
        return Account.decrypt(keystore, password).hex()
    except Exception as e:
        raise ValueError(f"Failed to decrypt keystore: {e}")


class EthereumClient:
    """Ethereum client wrapper for blockchain interactions.

    Note: This class is implemented as a singleton. Consider refactoring
    to use a proper singleton pattern if multiple instances are needed.
    """

    def __init__(
        self,
        eth_rpc_url: str,
        gas_strategy: GasStrategy,
    ) -> None:
        """Initialize the Ethereum client.

        Args:
            eth_rpc_url: Ethereum RPC endpoint URL.
            gas_strategy: Gas pricing strategy to use.

        Raises:
            ConnectionError: If unable to connect to the Ethereum node.
        """
        self.w3 = Web3(Web3.HTTPProvider(eth_rpc_url))
        if not self.is_connected():
            raise ConnectionError("Failed to connect to Ethereum node")
        self.service_manager = None
        self.task_manager = None
        self.delegation_manager = None
        self.strategy_manager = None
        self.init_contracts()
        self.max_priority_fee_per_gas, self.max_fee_per_gas = get_gas_config(
            self.w3.eth, gas_strategy
        )

    def init_contracts(self) -> None:
        """
        Initialize contracts
        """
        # Service manager
        self.check_contract_deployed(SERVICE_MANAGER_ADDRESS)
        self.service_manager = self.w3.eth.contract(
            address=SERVICE_MANAGER_ADDRESS, abi=SERVICE_MANAGER_ABI
        )
        # Task manager
        self.check_contract_deployed(TASK_MANAGER_ADDRESS)
        self.task_manager = self.w3.eth.contract(
            address=TASK_MANAGER_ADDRESS, abi=TASK_MANAGER_ABI
        )
        # Delegation manager
        delegation_manager_address = (
            self.service_manager.functions.delegationManager().call()
        )
        self.check_contract_deployed(delegation_manager_address)
        self.delegation_manager = self.w3.eth.contract(
            address=delegation_manager_address,
            abi=DELEGATION_MANAGER_ABI,
        )
        # Strategy manager
        strategy_manager_address = (
            self.delegation_manager.functions.strategyManager().call()
        )
        self.check_contract_deployed(strategy_manager_address)
        self.strategy_manager = self.w3.eth.contract(
            address=strategy_manager_address,
            abi=STRATEGY_MANAGER_ABI,
        )
        # allocation manager
        self.check_contract_deployed(ALLOCATION_MANAGER_ADDRESS)
        self.allocation_manager = self.w3.eth.contract(
            address=ALLOCATION_MANAGER_ADDRESS,
            abi=ALLOCATION_MANAGER_ABI,
        )
        # Model registry
        self.model_registry = self.w3.eth.contract(
            address=self.task_manager.functions.modelRegistry().call(),
            abi=MODEL_REGISTRY_ABI,
        )
        self.check_contract_deployed(self.model_registry.address)
        # Rewards coordinator
        self.rewards_coordinator = self.w3.eth.contract(
            address=self.service_manager.functions.rewardsCoordinator().call(),
            abi=REWARDS_COORDINATOR_ABI,
        )
        self.check_contract_deployed(self.rewards_coordinator.address)
        # Inference nodes manager
        self.nodes_manager = self.w3.eth.contract(
            address=self.task_manager.functions.inferenceNodesManager().call(),
            abi=INFERENCE_NODES_MANAGER_ABI,
        )
        self.check_contract_deployed(self.nodes_manager.address)

    def is_connected(self) -> bool:
        return self.w3.is_connected()

    def get_chain_id(self) -> int:
        return self.w3.eth.chain_id

    def check_contract_deployed(self, address: str) -> None:
        """Check if a contract is deployed at the given address.

        Args:
            address: Ethereum address to check.

        Raises:
            ValueError: If no contract bytecode is found at the address.
        """
        code = self.w3.eth.get_code(address)
        if code in (b"", b"0x"):
            raise ValueError(f"Address {address} is not a contract. Code: {code}")

    def execute_transaction(
        self,
        contract_obj: Contract,
        function_name: str,
        private_key: str,
        args: list,
        gas_limit: int | None = None,
        gas_multiplier: float = 1.1,
    ) -> TxReceipt:
        """Execute a transaction on the Ethereum network with dynamic gas pricing.

        Args:
            contract_obj: Contract object to call.
            function_name: Name of the contract function to call.
            private_key: Private key to sign the transaction.
            args: Arguments to pass to the contract function.
            gas_limit: Optional gas limit override. If None, will estimate and add buffer.
            gas_multiplier: Multiplier for gas estimation buffer (default 1.1 = 10% buffer).

        Returns:
            Transaction receipt.

        Raises:
            RuntimeError: If the transaction execution fails.
        """
        account = Account.from_key(private_key)

        # Build base transaction for estimation
        base_tx = getattr(contract_obj.functions, function_name)(
            *args
        ).build_transaction(
            {
                "from": account.address,
                "nonce": self.w3.eth.get_transaction_count(account.address),
                "chainId": self.w3.eth.chain_id,
            }
        )

        tx_params = self.update_tx_params(
            base_tx,
            gas_limit=gas_limit,
            gas_multiplier=gas_multiplier,
        )

        signed_tx: SignedTransaction = self.w3.eth.account.sign_transaction(
            tx_params, private_key=private_key
        )
        tx_hash = self.w3.eth.send_raw_transaction(signed_tx.raw_transaction)
        receipt = self.w3.eth.wait_for_transaction_receipt(tx_hash)

        msg = f"{function_name} in the contract {contract_obj.address}"
        if receipt.status != 1:
            logger.error(f"Failed to execute {msg}")
            raise RuntimeError(f"Failed to execute {msg}")

        logger.info(f"Successfully executed {msg}")

        return receipt

    def update_tx_params(
        self,
        base_tx: dict,
        gas_limit: int | None = None,
        gas_multiplier: float = 1.1,
    ) -> dict:
        # Estimate gas limit if not provided
        if gas_limit is None:
            try:
                estimated_gas = self.w3.eth.estimate_gas(base_tx)
                gas_limit = int(estimated_gas * gas_multiplier)
                logger.info(
                    f"Estimated gas: {estimated_gas}, using: {gas_limit}",
                )
            except Exception as e:
                logger.info(f"Gas estimation failed: {e}, using default 2M")
                gas_limit = 2000000

        tx_params = base_tx.copy()
        tx_params.update({"gas": gas_limit})
        if self.max_fee_per_gas is not None:
            tx_params["maxFeePerGas"] = self.max_fee_per_gas
        if self.max_priority_fee_per_gas is not None:
            tx_params["maxPriorityFeePerGas"] = self.max_priority_fee_per_gas
        return tx_params
