#!/usr/bin/env bash

# cd to the directory of this script so that this can be run from anywhere
parent_path=$(
    cd "$(dirname "${BASH_SOURCE[0]}")"
    pwd -P
)

# Load environment variables from the script's directory
source "$parent_path/load-env.sh"

cd "$parent_path/../"

forge script script/InferenceDeployer.s.sol --rpc-url $RPC_HOST:$RPC_PORT --broadcast

# Format the JSON file using Python
if [ -f deployments/inferenceDeployment.json ]; then
    python3 -c "
import json
with open('deployments/inferenceDeployment.json', 'r') as f:
    data = json.load(f)
with open('deployments/inferenceDeployment.json', 'w') as f:
    json.dump(data, f, indent=4)
"
    echo "Formatted deployments/inferenceDeployment.json"
else
    echo "deployments/inferenceDeployment.json not found!"
fi
