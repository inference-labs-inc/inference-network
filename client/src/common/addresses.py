import json
from typing import Callable, Optional

from common.constants import CONTRACTS_DIR


def address_property(attr_name: str):
    def decorator(func: Callable) -> property:
        def getter(self) -> any:
            self._check_initialized()
            return getattr(self, attr_name)

        return property(getter)

    return decorator


class AddressManager:
    """Singleton manager for contract addresses."""

    _instance: Optional["AddressManager"] = None

    def __new__(cls):
        if cls._instance is None:
            cls._instance = super().__new__(cls)
            cls._instance._initialized = False
        return cls._instance

    def __init__(self):
        self.task_manager: Optional[str] = None
        self.service_manager: Optional[str] = None
        self.allocation_manager: Optional[str] = None
        self.strategies: Optional[list[str]] = None
        self.eth_strategies: Optional[list[str]] = None

    def init_addresses(self, chain_id: int) -> None:
        """Initialize contract addresses based on the given chain ID."""
        deployment_file = (
            CONTRACTS_DIR / "deployments" / f"sertnDeployment_{chain_id}.json"
        )

        try:
            with open(deployment_file) as f:
                deployment_info = json.load(f)
                self.task_manager = deployment_info["sertnTaskManager"]
                self.service_manager = deployment_info["sertnServiceManager"]
                self.allocation_manager = deployment_info["allocationManager"]
                self.strategies = [
                    deployment_info["strategy_0"],
                    deployment_info["strategy_1"],
                    deployment_info["strategy_2"],
                ]
                self.eth_strategies = [
                    deployment_info["eth_strategy_0"],
                    deployment_info["eth_strategy_1"],
                ]
                self._initialized = True
        except FileNotFoundError:
            raise FileNotFoundError(
                f"Deployment file for chain ID {chain_id} not found: {deployment_file}. "
                "Did you forget to deploy?"
            )
        except KeyError as e:
            raise KeyError(
                f"Missing expected key in deployment file for chain ID {chain_id}: {e}"
            )

    def _check_initialized(self):
        if not self._initialized:
            raise RuntimeError(
                "AddressManager not initialized. Call addresses.init(chain_id) first."
            )

    @address_property("task_manager")
    def TASK_MANAGER_ADDRESS(self) -> str:
        pass

    @address_property("service_manager")
    def SERVICE_MANAGER_ADDRESS(self) -> str:
        pass

    @address_property("allocation_manager")
    def ALLOCATION_MANAGER_ADDRESS(self) -> str:
        pass

    @address_property("strategies")
    def STRATEGIES_ADDRESSES(self) -> list[str]:
        pass

    @address_property("eth_strategies")
    def ETH_STRATEGY_ADDRESSES(self) -> list[str]:
        pass


# Global singleton instance
addresses = AddressManager()
