#!/usr/bin/env bash

# cd to the directory of this script so that this can be run from anywhere
parent_path=$(
    cd "$(dirname "${BASH_SOURCE[0]}")"
    pwd -P
)

# Load environment variables from the script's directory
source "$parent_path/load-env.sh"

cd "$parent_path/../"

forge script script/DeployEigenLayerCore.s.sol --rpc-url $RPC_HOST:$RPC_PORT --broadcast