#!/bin/bash

# Load environment variables
source contracts/anvil/load-env.sh

@chmod +x contracts/anvil/start-anvil.sh
contracts/anvil/start-anvil.sh true

sleep 3

cp .env.example .env

echo "Building contracts"
make build-contracts

echo "Deploying EigenLayer contracts."
make deploy-eigenlayer-contracts

echo "Deploying Inference contracts."
make deploy-inference-contracts

# Kill Anvil using the PID from the file
if [ -f $PID_FILE ]; then
    ANVIL_PID=$(cat $ANVIL_PID_FILE)
    echo "Killing Anvil with PID $ANVIL_PID"
    kill $ANVIL_PID
    rm $PID_FILE
else
    echo "Anvil PID file not found. Skipping termination."
fi
