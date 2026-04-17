from web3 import Web3
from web3.eth import Eth

from common.config import GasStrategy
from common.logging import get_logger

logger = get_logger("common")


def get_gas_config(
    w3_eth: Eth, strategy: GasStrategy = GasStrategy.STANDARD
) -> tuple[int | None, int | None]:
    """Get recommended gas configuration based on strategy.

    Args:
        w3_eth: Web3.eth instance for blockchain interaction.
        strategy: Gas strategy - SLOW, STANDARD, FAST, or PRIORITY.

    Returns:
        Tuple of (max_priority_fee_per_gas, max_fee_per_gas).
        Returns (None, None) if gas estimation fails.
    """
    try:
        latest_block = w3_eth.get_block("latest")
        if (
            hasattr(latest_block, "baseFeePerGas")
            and latest_block.baseFeePerGas is not None
        ):
            # EIP-1559 network
            base_fee = latest_block.baseFeePerGas

            strategies = {
                GasStrategy.SLOW: (
                    Web3.to_wei("1", "gwei"),  # max_priority_fee_per_gas
                    int(base_fee * 1.1) + Web3.to_wei("1", "gwei"),  # max_fee_per_gas
                ),
                GasStrategy.STANDARD: (
                    Web3.to_wei("2", "gwei"),  # max_priority_fee_per_gas
                    int(base_fee * 1.5) + Web3.to_wei("2", "gwei"),  # max_fee_per_gas
                ),
                GasStrategy.FAST: (
                    Web3.to_wei("3", "gwei"),  # max_priority_fee_per_gas
                    int(base_fee * 2) + Web3.to_wei("3", "gwei"),  # max_fee_per_gas
                ),
                GasStrategy.PRIORITY: (
                    Web3.to_wei("5", "gwei"),  # max_priority_fee_per_gas
                    int(base_fee * 3) + Web3.to_wei("5", "gwei"),  # max_fee_per_gas
                ),
            }
            # Use enum as key instead of string to avoid KeyError
            return strategies.get(strategy, strategies[GasStrategy.STANDARD])
        else:
            # Legacy network
            gas_price = w3_eth.gas_price
            multipliers = {
                GasStrategy.SLOW: 1.0,
                GasStrategy.STANDARD: 1.1,
                GasStrategy.FAST: 1.25,
                GasStrategy.PRIORITY: 1.5,
            }
            return (
                None,  # max_priority_fee_per_gas
                int(gas_price * multipliers.get(strategy, 1.1)),  # max_fee_per_gas
            )

    except Exception as e:
        logger.error(f"Failed to get gas config: {e}")
        return (None, None)  # Default to None if error occurs
