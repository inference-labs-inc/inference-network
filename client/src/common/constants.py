import os
import json
from pathlib import Path

ROOT_DIR = Path(__file__).parent.parent.parent.parent
CLIENT_PATH = ROOT_DIR / "client"
CLIENT_SRC_PATH = CLIENT_PATH / "src"
CONTRACTS_DIR = ROOT_DIR / "contracts"
MODELS_DATA_DIR = CLIENT_SRC_PATH / "models" / "models_data"
TEMP_FOLDER = CLIENT_SRC_PATH / "models" / "temp"
PROOFS_FOLDER = CLIENT_SRC_PATH / "models" / "generated_proofs"
MODELS_FOLDER = CLIENT_SRC_PATH / "models" / "models"

LOCAL_EZKL_PATH = Path(
    os.environ.get("LOCAL_EZKL_PATH", str(Path.home() / ".ezkl" / "ezkl"))
)

MODELS_DATA_DIR.mkdir(parents=True, exist_ok=True)
TEMP_FOLDER.mkdir(parents=True, exist_ok=True)
PROOFS_FOLDER.mkdir(parents=True, exist_ok=True)

# contracts addresses:
with open(CONTRACTS_DIR / "deployments" / "sertnDeployment.json") as f:
    deployment_info = json.load(f)
    TASK_MANAGER_ADDRESS = deployment_info["sertnTaskManager"]
    SERVICE_MANAGER_ADDRESS = deployment_info["sertnServiceManager"]
    ALLOCATION_MANAGER_ADDRESS = deployment_info["allocationManager"]
    STRATEGIES_ADDRESSES = [
        deployment_info["strategy_0"],
        deployment_info["strategy_1"],
        deployment_info["strategy_2"],
    ]
    ETH_STRATEGY_ADDRESSES = [
        deployment_info["eth_strategy_0"],
        deployment_info["eth_strategy_1"],
    ]

IGNORED_MODEL_HASHES = []

# Queue size limits
MAX_EVALUATION_ITEMS = 1024

# how many blocks are we going to wait for an operator response before rejecting the task?
# TODO: share this constant with contracts (we need that there too)
RESOLVE_BLOCKS_DELAY = 300

# Default proof size when we're unable to determine the actual size
DEFAULT_PROOF_SIZE = 5000
# Size in percent of the sample to be used for the maximum score median
MAXIMUM_SCORE_MEDIAN_SAMPLE = 0.05
# The maximum timespan allowed for miners to process through a circuit
CIRCUIT_TIMEOUT_SECONDS = 60

# Operator set ID
OPERATOR_SET_ID = 0
