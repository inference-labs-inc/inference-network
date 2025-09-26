from datetime import datetime, timezone
from typing import List, Optional

from common.config import ModelConfig, NodeConfig
from common.logging import get_logger
from common.eth import EthereumClient

logger = get_logger("operator")


class OperatorNodesManager:
    def __init__(
        self,
        private_key: str,
        operator_address: str,
        eth_client: EthereumClient,
        nodes_config: List[NodeConfig],
    ):
        self.private_key = private_key
        self.operator_address = operator_address
        self.eth_client = eth_client
        self.nodes_config = nodes_config
        self.registered_models = self.get_registered_models()

    def get_registered_models(self) -> dict[str, int]:
        """
        Get all registered models in `ModelRegistry` contract.
        :return: Dictionary with model URIs as keys and their IDs as values.
        """
        models: dict[str, int] = {}

        # Get the current model index (total number of models + 1)
        model_index = self.eth_client.model_registry.functions.modelIndex().call()

        # Iterate through all model IDs (starting from 1)
        for model_id in range(1, model_index):
            # Get the model Name for this model ID
            model_name = self.eth_client.model_registry.functions.modelName(
                model_id
            ).call()
            if model_name:  # Only add models with non-empty Names
                models[model_name] = int(model_id)
            else:
                logger.info(
                    f"Model ID {model_id} has an empty Name, skipping.",
                )
        return models

    def sync_nodes(self):
        # get all nodes ids registered by the operator from the blockchain
        registered_node_ids: list[int] = (
            self.eth_client.nodes_manager.functions.getOperatorNodes(
                self.operator_address
            ).call()
        )
        # iterate through registered nodes, syncing their state with the config
        updated_nodes = set()
        for registered_node_id in registered_node_ids:
            node_name = self.sync_node_state(registered_node_id)
            if node_name:
                updated_nodes.add(node_name)

        new_nodes_registered = False
        for config_node in self.nodes_config:
            if config_node.node_name not in updated_nodes:
                # register new node
                self.register_node(
                    config_node.node_name,
                    config_node.metadata,
                    config_node.total_fucus,
                )
                new_nodes_registered = True

        if new_nodes_registered:
            for node_id in self.eth_client.nodes_manager.functions.getOperatorNodes(
                self.operator_address
            ).call():
                if node_id not in registered_node_ids:
                    # register new node
                    self.sync_node_state(node_id)
                    logger.info(
                        f"Node with ID {node_id} is registered, and has synced state from the blockchain.",
                    )

    def sync_node_state(self, node_id: int) -> Optional[str]:
        """
        Sync the state of a node in the blockchain.
        :param node_id: The ID of the node to sync.
        """
        # get node details from the blockchain
        (
            operator,
            node_name,
            metadata,
            totalFucus,
            allocatedFucus,
            availableFucus,
            isActive,
            createdAt,
            supportedModelsCount,
        ) = self.eth_client.nodes_manager.functions.getNodeDetails(node_id).call()
        # check if the node is in the config
        try:
            config_node = [
                node for node in self.nodes_config if node.node_name == node_name
            ][0]
        except IndexError:
            # Node not found in the config, removing from blockchain...
            self.deregister_node(node_id)
            logger.info(
                f"Node {node_name} with ID {node_id} not found in config, deregistered from blockchain.",
            )
            return None

        # activate or deactivate the node based on the config
        if isActive != config_node.is_active:
            if config_node.is_active:
                self.activate_node(node_id)
            else:
                self.deactivate_node(node_id)

        # update node details according to the config
        if (
            node_name != config_node.node_name
            or metadata != config_node.metadata
            or totalFucus != config_node.total_fucus
        ):
            logger.info(
                f"Updating node {node_name} with ID {node_id} details in the blockchain.",
            )
            # update node details
            self.update_node(
                node_id,
                config_node.node_name,
                config_node.metadata,
                config_node.total_fucus,
            )

        # update supported models for the node
        self.update_node_models(node_id, config_node.models)

        return node_name

    def update_node_models(self, node_id: int, models: List[ModelConfig]):
        """
        Update the supported models for a node in the blockchain.
        :param node_id: The ID of the node to update.
        :param models: List of ModelConfig objects to support.
        """
        supported_models: list[int] = (  # model_allocated_fucus
            self.eth_client.nodes_manager.functions.getNodeSupportedModels(
                node_id
            ).call()
        )
        model_allocated_fucus: list[int] = (
            self.eth_client.nodes_manager.functions.getNodeModelsFucus(node_id).call()
        )

        actual_models = dict(zip(supported_models, model_allocated_fucus))
        config_models = {
            # Validated model URIs are guaranteed to exist in registered_models by Pydantic validation
            self.registered_models[model.model_name]: model.allocated_fucus
            for model in models
        }

        # Add new models
        for model_id, allocated_fucus in config_models.items():
            if model_id not in actual_models:
                self.eth_client.execute_transaction(
                    self.eth_client.nodes_manager,
                    "addModelSupport",
                    self.private_key,
                    [int(node_id), model_id, int(allocated_fucus)],
                )
                logger.info(
                    f"Added model {model_id} with {allocated_fucus} FUCUs to node {node_id}",
                )
                continue
            if actual_models[model_id] != allocated_fucus:
                self.eth_client.execute_transaction(
                    self.eth_client.nodes_manager,
                    "updateModelSupport",
                    self.private_key,
                    [node_id, model_id, allocated_fucus],
                )
                logger.info(
                    f"Updated model {model_id} with {allocated_fucus} FUCUs for node {node_id}",
                )
            del actual_models[model_id]

        # Remove models that are no longer supported
        for model_id in actual_models.keys():
            if model_id not in config_models:  # kinda unnecessary check
                self.eth_client.execute_transaction(
                    self.eth_client.nodes_manager,
                    "removeModelSupport",
                    self.private_key,
                    [node_id, model_id],
                )
                logger.info(
                    f"Removed model {model_id} from node {node_id}",
                )

    def register_node(self, name: str, metadata: str, total_fucus: int):
        """
        Register a node in the blockchain.
        :param name: The name of the node.
        :param metadata: Metadata associated with the node.
        :param total_fucus: Total fucus allocated to the node.
        """
        self.eth_client.execute_transaction(
            self.eth_client.nodes_manager,
            "registerNode",
            self.private_key,
            [
                name,
                metadata,
                total_fucus,
            ],
        )

        logger.info(
            f'Successfully registered the "{name}" node in the blockchain',
        )

    def deregister_node(self, node_id: int):
        """
        Deregister a node from the blockchain.
        :param node_id: The ID of the node to deregister.
        """
        self.eth_client.execute_transaction(
            self.eth_client.nodes_manager, "removeNode", self.private_key, [node_id]
        )

        logger.info(
            f'Successfully deregistered the "{node_id}" node from the contract',
        )

    def activate_node(self, node_id: int):
        """
        Activate a node in the blockchain.
        :param node_id: The ID of the node to activate.
        """
        self.eth_client.execute_transaction(
            self.eth_client.nodes_manager, "reactivateNode", self.private_key, [node_id]
        )

        logger.info(
            f'Successfully activated the "{node_id}" node in the contract',
        )

    def deactivate_node(self, node_id: int):
        """
        Deactivate a node in the blockchain.
        :param node_id: The ID of the node to deactivate.
        """
        self.eth_client.execute_transaction(
            self.eth_client.nodes_manager, "deactivateNode", self.private_key, [node_id]
        )

        logger.info(
            f'Successfully deactivated the "{node_id}" node in the contract',
        )

    def update_node(
        self,
        node_id: int,
        name: str,
        metadata: str,
        total_fucus: int,
    ):
        """
        Update a node's details in the blockchain.
        :param node_id: The ID of the node to update.
        :param name: The new name of the node.
        :param metadata: The new metadata associated with the node.
        :param total_fucus: The new total fucus allocated to the node.
        """
        self.eth_client.execute_transaction(
            self.eth_client.nodes_manager,
            "updateNode",
            self.private_key,
            [node_id, name, metadata, total_fucus],
        )

        logger.info(
            f'Successfully updated the "{node_id}" node in the contract',
        )

    def print_nodes(self):
        """
        Print the details of all nodes registered by the operator.
        """
        # Get all node IDs registered by the operator
        registered_node_ids: list[int] = (
            self.eth_client.nodes_manager.functions.getOperatorNodes(
                self.operator_address
            ).call()
        )

        if not registered_node_ids:
            print("No nodes registered for this operator.")
            return

        print(
            f"\n📋 Nodes registered for operator {self.operator_address}:",
        )
        print("=" * 80)

        # Create reverse mapping from model ID to model URI
        model_id_to_name = {
            model_id: model_name
            for model_name, model_id in self.registered_models.items()
        }

        for i, node_id in enumerate(registered_node_ids, 1):
            try:
                # Get node details
                (
                    operator,
                    node_name,
                    metadata,
                    total_fucus,
                    allocated_fucus,
                    available_fucus,
                    is_active,
                    created_at,
                    supported_models_count,
                ) = self.eth_client.nodes_manager.functions.getNodeDetails(
                    node_id
                ).call()

                # Get supported models
                supported_model_ids: list[int] = (
                    self.eth_client.nodes_manager.functions.getNodeSupportedModels(
                        node_id
                    ).call()
                )
                model_allocated_fucus: list[int] = (
                    self.eth_client.nodes_manager.functions.getNodeModelsFucus(
                        node_id
                    ).call()
                )

                # Print node header
                if is_active:
                    print(f"\n{i}. Node ID: {node_id} - 🟢 ACTIVE")
                else:
                    print(f"\n{i}. Node ID: {node_id} - 🔴 INACTIVE")

                print("-" * 60)

                # Print basic node information
                print(f"   Name: {node_name}")
                print(
                    f"   Metadata: {metadata if metadata else 'N/A'}",
                )
                print(f"   Total FUCUs: {total_fucus:,}")
                print(f"   Allocated FUCUs: {allocated_fucus:,}")
                print(f"   Available FUCUs: {available_fucus:,}")
                readable_created_at = datetime.fromtimestamp(
                    created_at, tz=timezone.utc
                ).strftime("%Y-%m-%d %H:%M:%S UTC")
                print(f"   Created At: {created_at} ({readable_created_at})")
                print(
                    f"   Supported Models Count: {supported_models_count}",
                )

                # Print supported models
                if supported_model_ids:
                    print("\n   📦 Supported Models:")
                    for model_id, model_fucus in zip(
                        supported_model_ids, model_allocated_fucus
                    ):
                        model_name = model_id_to_name.get(
                            model_id, f"Unknown (ID: {model_id})"
                        )
                        print(f"      • Model: {model_name}")
                        print(
                            f"        Allocated FUCUs: {model_fucus:,}",
                        )
                else:
                    print("   📦 No models supported")

            except Exception as e:
                print(
                    f"   ❌ Error getting details for node {node_id}: {e}",
                )

        print("\n" + "=" * 80)
        print(f"Total nodes: {len(registered_node_ids)}")
