import requests

from aggregator.main import Aggregator
from avs_operator.main import TaskOperator
from common.config import OperatorConfig
from tests.conftest import OPERATOR_NODES


def get_nodes_list():
    response = requests.get("http://localhost:8090/nodes")
    return response.json()


def get_model_ids():
    response = requests.get("http://localhost:8090/models")
    res = response.json()
    return {m["name"]: m["id"] for m in res}


def get_expected_nodes(nodes_config=OPERATOR_NODES):
    model_ids = get_model_ids()
    return {
        n["node_name"]: {
            "metadata": n["metadata"],
            "total_fucus": n["total_fucus"],
            "is_active": n["is_active"],
            "supported_models": [
                {
                    "model_id": model_ids[model["model_name"]],
                    "allocated_fucus": model["allocated_fucus"],
                }
                for model in n["models"]
            ],
        }
        for n in nodes_config
        if n["is_active"]
    }


def test_operator_initialization(operator: TaskOperator, aggregator_server: Aggregator):
    expected_result = get_expected_nodes(OPERATOR_NODES)
    resp = get_nodes_list()

    assert len(resp) == len(expected_result), "Node count mismatch"
    for node in resp:
        node_name = node["name"]
        assert node_name in expected_result, f"Unexpected node name: {node_name}"
        expected_node = expected_result[node_name]
        assert (
            node["metadata"] == expected_node["metadata"]
        ), f"Metadata mismatch for {node_name}"
        assert (
            node["total_fucus"] == expected_node["total_fucus"]
        ), f"Total fucus mismatch for {node_name}"
        assert (
            node["is_active"] == expected_node["is_active"]
        ), f"Is active mismatch for {node_name}"
        assert len(node["supported_models"]) == len(
            expected_node["supported_models"]
        ), f"Supported models count mismatch for {node_name}"
        assert (
            node["operator"].lower() == operator.operator_address.lower()
        ), f"Operator address mismatch for {node_name}"
        for model in node["supported_models"]:
            match = next(
                (
                    m
                    for m in expected_node["supported_models"]
                    if m["model_id"] == model["model_id"]
                ),
                None,
            )
            assert (
                match is not None
            ), f"Unexpected model ID {model['model_id']} for {node_name}"
            assert (
                model["allocated_fucus"] == match["allocated_fucus"]
            ), f"Allocated fucus mismatch for model ID {model['model_id']} in {node_name}"


def test_operator_nodes_update(aggregator_server: Aggregator):
    nodes_config = OPERATOR_NODES.copy()
    # Deactivate the first node
    nodes_config[0]["is_active"] = False
    # Update the second node's fucus
    nodes_config[1]["total_fucus"] = 1000
    nodes_config[1]["models"][0]["allocated_fucus"] = 1000

    # initialize a new operator instance with the updated config
    operator = TaskOperator(
        OperatorConfig(
            eth_rpc_url="http://localhost:8545",
            aggregator_server_ip_port_address="localhost:8090",
            ecdsa_private_key_store_path="tests/keys/operator.ecdsa.key.json",
            auto_update=False,
            nodes=nodes_config,
        )
    )
    # sync nodes with the updated config
    operator.nodes_manager.sync_nodes()

    # get the nodes list from the server and verify the updates
    expected_result = get_expected_nodes(nodes_config)
    resp = get_nodes_list()

    assert len(resp) == 1, "Node count mismatch"
    node = resp[0]
    assert node["total_fucus"] == 1000, f"Total fucus mismatch"

    # Sync back to original config - reduce back allocated fucus
    nodes_config[1]["models"][0]["allocated_fucus"] = 900
    TaskOperator(
        OperatorConfig(
            eth_rpc_url="http://localhost:8545",
            aggregator_server_ip_port_address="localhost:8090",
            ecdsa_private_key_store_path="tests/keys/operator.ecdsa.key.json",
            auto_update=False,
            nodes=nodes_config,
        )
    ).nodes_manager.sync_nodes()
    # reduce back total fucus
    nodes_config[0]["is_active"] = True
    nodes_config[1]["total_fucus"] = 900
    TaskOperator(
        OperatorConfig(
            eth_rpc_url="http://localhost:8545",
            aggregator_server_ip_port_address="localhost:8090",
            ecdsa_private_key_store_path="tests/keys/operator.ecdsa.key.json",
            auto_update=False,
            nodes=nodes_config,
        )
    ).nodes_manager.sync_nodes()
