import asyncio
import json
import os
import shutil
import sys
import tempfile
import threading
import time
from pathlib import Path

import pytest
import requests
import uvicorn
from dotenv import load_dotenv
from eth_account import Account
from web3 import Web3

from aggregator.main import Aggregator
from avs_operator.main import TaskOperator
from common.config import AggregatorConfig, OperatorConfig
from common.constants import CLIENT_SRC_PATH, ROOT_DIR
from management.owner import AvsOwner

sys.path.insert(0, str(CLIENT_SRC_PATH))
load_dotenv(ROOT_DIR / ".env")  # Load environment variables

OPERATOR_NODES = [
    {
        "node_name": "node1",
        "metadata": "optional metadata",
        "total_fucus": 500,
        "is_active": True,
        "models": [
            {"model_name": "model_0", "allocated_fucus": 500},
            # {"model_name": "model_1", "allocated_fucus": 50},
        ],
    },
    {
        "node_name": "node2",
        "metadata": "optional metadata",
        "total_fucus": 900,
        "is_active": True,
        "models": [
            {"model_name": "model_0", "allocated_fucus": 900},
            # {"model_name": "model_1", "allocated_fucus": 10},
        ],
    },
]


@pytest.fixture(scope="session")
def owner():
    return AvsOwner(
        private_key=os.getenv("PRIVATE_KEY"),
        eth_rpc_url="http://localhost:8545",
    )


@pytest.fixture(scope="session")
def aggregator():
    config = AggregatorConfig(
        eth_rpc_url="http://localhost:8545",
        aggregator_server_ip_port_address="localhost:8090",
        ecdsa_private_key_store_path="tests/keys/aggregator.ecdsa.key.json",
        proof_request_probability=1.0,  # challenge every task
        auto_update=False,
    )
    return Aggregator(config)


@pytest.fixture(scope="session")
def aggregator_server(aggregator: Aggregator):
    """Start aggregator server in a separate thread and provide cleanup."""
    server = None
    server_thread = None

    def start_server():
        nonlocal server
        config = uvicorn.Config(
            app=aggregator.server.app, host="0.0.0.0", port=8090, log_level="info"
        )
        server = uvicorn.Server(config)

        # Run server until stop event is set
        loop = asyncio.new_event_loop()
        asyncio.set_event_loop(loop)

        try:
            loop.run_until_complete(server.serve())
        except asyncio.CancelledError:
            pass
        finally:
            loop.close()

    # Start server in a separate thread
    server_thread = threading.Thread(target=start_server)
    server_thread.start()
    time.sleep(5)  # Wait for server to start

    yield aggregator

    # Cleanup - stop server
    if server:
        server.should_exit = True

    if server_thread:
        server_thread.join(timeout=5)  # Wait up to 5 seconds


@pytest.fixture(scope="function")
def operator():
    config = OperatorConfig(
        eth_rpc_url="http://localhost:8545",
        aggregator_server_ip_port_address="localhost:8090",
        ecdsa_private_key_store_path="tests/keys/operator.ecdsa.key.json",
        auto_update=False,
        nodes=OPERATOR_NODES,
    )
    operator = TaskOperator(config)
    operator.nodes_manager.sync_nodes()
    operator.nodes_manager.print_nodes()
    return operator


@pytest.fixture(scope="function")
def init_environment(aggregator: Aggregator):
    """Ensure the Anvil node is running and has the correct state"""
    # Fast-forward the blockchain to 400 blocks,
    # because current block number must be greater than MIN_WITHDRAWAL_DELAY_BLOCKS
    try:
        requests.post(
            "http://localhost:8545",
            json={
                "jsonrpc": "2.0",
                "method": "anvil_mine",
                "params": ["0x190"],
                "id": 1,
            },
            headers={"Content-Type": "application/json"},
            timeout=60,  # Set a timeout for the request
        )
    except requests.exceptions.ReadTimeout:
        # Mining 400 blocks can take time, timeout is expected
        print("Warning: Mining request timed out, but blocks may still be processing")
    # Get the current blockchain timestamp
    current_block = aggregator.eth_client.w3.eth.get_block("latest")
    current_timestamp = current_block["timestamp"]

    # Get interval duration once
    interval_seconds = (
        aggregator.eth_client.rewards_coordinator.functions.CALCULATION_INTERVAL_SECONDS().call()
    )
    init_interval_datetime = (
        aggregator.eth_client.service_manager.functions.firstIntervalTimestamp().call()
    )

    # Fast forward time by the interval duration
    aggregator.eth_client.w3.provider.make_request(
        "evm_increaseTime",
        [init_interval_datetime + interval_seconds - current_timestamp + 1],
    )
    aggregator.eth_client.w3.provider.make_request("evm_mine", [])

    # Get the owner address from the private key
    owner_address = Account.from_key(os.getenv("PRIVATE_KEY")).address
    # Get the current interval and initial operator rewards
    currentInterval: int = (
        aggregator.eth_client.service_manager.functions.getCurrentInterval().call()
    )
    return {
        "current_interval": currentInterval,
        "owner_address": owner_address,
        "interval_seconds": interval_seconds,
    }


@pytest.fixture(scope="session")
def models_root():
    """Create an empty temporary directory and remove it after the test.

    Returns:
        Path: path to the created empty directory.
    """
    path = Path(tempfile.mkdtemp(prefix="pytest-empty-"))
    try:
        yield path
    finally:
        shutil.rmtree(path, ignore_errors=True)


@pytest.fixture(scope="function")
def write_model(dummy_address):
    """
    Fixture to create a helper function which creates test models.
    """
    created_dirs: list[Path] = []

    def _write_model(tmp_root: Path, name: str, is_active: bool = True, **overrides):
        model_dir = tmp_root / name
        model_dir.mkdir(parents=True, exist_ok=True)
        # input.py with CircuitInput
        (model_dir / "input.py").write_text(
            "\nfrom models.execution_layer.base_input import BaseInput"
            "\n"
            "\nclass CircuitInput(BaseInput):"
            "\n    @classmethod"
            "\n    def generate(cls):"
            "\n        return [1, 2, 3]"
        )
        # metadata.json
        metadata = {
            "name": name.upper(),
            "description": f"desc {name}",
            "author": "tester",
            "version": "0.0.1",
            "proof_system": "EZKL",
            "type": "proof_of_computation",
            "verification_strategy": "offchain",
            "model_verifier_address": dummy_address,
            "compute_cost": 100,
            "required_fucus": 10,
            "is_active": is_active,
        }
        metadata.update(overrides)
        (model_dir / "metadata.json").write_text(json.dumps(metadata))
        # Create empty network.onnx and settings.json files
        (model_dir / "network.onnx").touch()
        (model_dir / "settings.json").write_text("{}")
        created_dirs.append(model_dir)
        return model_dir

    yield _write_model

    # Cleanup created model directories
    for d in created_dirs:
        shutil.rmtree(d, ignore_errors=True)


@pytest.fixture(scope="function")
def dummy_address() -> str:
    """Return a valid EIP-55 Ethereum address for tests."""
    raw = "0x" + os.urandom(20).hex()
    return Web3.to_checksum_address(raw)
