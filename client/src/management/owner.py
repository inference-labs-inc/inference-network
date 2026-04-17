from eth_account import Account

from common.eth import EthereumClient
from common.config import GasStrategy
from common.logging import get_logger
from models.execution_layer.model_registry import ModelValidationError

logger = get_logger("owner")


class AvsOwner:
    """Owner of the AVS with management capabilities."""

    def __init__(
        self,
        private_key: str,
        eth_rpc_url: str,
        gas_strategy: GasStrategy = GasStrategy.STANDARD,
    ) -> None:
        """Initialize the AVS Owner.

        Args:
            private_key: ECDSA private key for signing transactions.
            eth_rpc_url: Ethereum RPC endpoint URL.
            gas_strategy: Gas pricing strategy to use.
        """
        self.private_key = private_key
        self.owner_address: str = Account.from_key(self.private_key).address
        self.gas_strategy = gas_strategy
        self.eth_rpc_url = eth_rpc_url
        self.eth_client = EthereumClient(
            eth_rpc_url=eth_rpc_url, gas_strategy=gas_strategy
        )

    def submit_rewards_for_interval(
        self, current_interval: int, **gas_kwargs: int | float
    ) -> None:
        """Submit rewards for the current interval.

        This function is called by the owner of the aggregator.

        Args:
            current_interval: The interval for which to submit rewards.
            **gas_kwargs: Optional gas parameters (gas_limit, gas_multiplier).
        """
        self.eth_client.execute_transaction(
            self.eth_client.service_manager,
            "submitRewardsForInterval",
            self.private_key,
            [current_interval],
            **gas_kwargs,
        )
