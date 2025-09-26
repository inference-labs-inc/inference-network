import json

from common.constants import ROOT_DIR


def load_abi(file_name):
    with open(ROOT_DIR / "abis" / file_name) as f:
        return json.loads(f.read())


SERVICE_MANAGER_ABI = load_abi("SertnServiceManager.abi.json")

TASK_MANAGER_ABI = load_abi("SertnTaskManager.abi.json")

STRATEGY_ABI = load_abi("StrategyBase.abi.json")

ERC20_MOCK_ABI = load_abi("ERC20Mock.abi.json")

ERC20_ABI = load_abi("ERC20.abi.json")

DELEGATION_MANAGER_ABI = load_abi("DelegationManager.abi.json")

STRATEGY_MANAGER_ABI = load_abi("StrategyManager.abi.json")

ALLOCATION_MANAGER_ABI = load_abi("AllocationManager.abi.json")

MODEL_REGISTRY_ABI = load_abi("ModelRegistry.abi.json")

REWARDS_COORDINATOR_ABI = load_abi("RewardsCoordinator.abi.json")

SERTN_NODES_MANAGER_ABI = load_abi("SertnNodesManager.abi.json")
