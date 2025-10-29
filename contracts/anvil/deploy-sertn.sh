#!/usr/bin/env bash

# Load environment variables
source contracts/anvil/load-env.sh

# cd to the directory of this script so that this can be run from anywhere
parent_path=$(
    cd "$(dirname "${BASH_SOURCE[0]}")"
    pwd -P
)
cd "$parent_path"

cd ../

forge script script/SertnDeployer.s.sol --rpc-url $RPC_HOST:$RPC_PORT --broadcast

# Format sertnDeployment_*.json files
shopt -s nullglob
json_files=(deployments/sertnDeployment_*.json)

if [ ${#json_files[@]} -eq 0 ]; then
    echo "No sertnDeployment_*.json files found in contracts/deployments/"
else
    for json_file in "${json_files[@]}"; do
        python3 -c "
import json
with open('$json_file', 'r') as f:
    data = json.load(f)
with open('$json_file', 'w') as f:
    json.dump(data, f, indent=4)
"
        echo "Formatted contracts/$json_file"
    done
fi
