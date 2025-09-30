#!/bin/bash
# filepath: /Users/olegbondarenko/workspace/InferenceLabs/inference-avs/contracts/anvil/stop-anvil.sh

# Load environment variables
source contracts/anvil/load-env.sh

echo "Stopping Anvil..."

# Check if PID file exists
if [ -f "$ANVIL_PID_FILE" ]; then
    ANVIL_PID=$(cat $ANVIL_PID_FILE)

    # Check if process is running
    if kill -0 $ANVIL_PID 2>/dev/null; then
        echo "Stopping Anvil with PID $ANVIL_PID"
        kill $ANVIL_PID

        # Wait for process to stop gracefully
        sleep 2

        # Check if it's still running and force kill if necessary
        if kill -0 $ANVIL_PID 2>/dev/null; then
            echo "Force killing Anvil with PID $ANVIL_PID"
            kill -9 $ANVIL_PID
        fi

        echo "Anvil stopped successfully"
    else
        echo "Anvil process with PID $ANVIL_PID is not running"
    fi

    # Remove PID file
    rm -f $PID_FILE
    echo "PID file removed"

    echo "Anvil shutdown complete"
else
    echo "PID file '$ANVIL_PID_FILE' not found."
fi
