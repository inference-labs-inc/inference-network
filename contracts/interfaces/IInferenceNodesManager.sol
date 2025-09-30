// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import {IModelRegistry} from "./IModelRegistry.sol";

/**
 * @title IInferenceNodesManager
 * @author Inference Labs, Inc.
 * @notice Interface for InferenceNodesManager contract that manages nodes in the Inference network.
 */
interface IInferenceNodesManager {
    // ============ STRUCTS ============

    struct Node {
        uint256 nodeId;
        address operator;
        string name;
        string metadata; // IPFS hash or JSON metadata
        uint256 totalFucus; // Total functional compute units available
        bool isActive;
        uint256 createdAt;
    }

    struct NodeModelConfig {
        uint256 allocatedFucus; // FUCUs allocated for this specific model on this node
        bool isSupported; // Whether this node supports this model
    }

    // ============ EVENTS ============

    event NodeRegistered(
        uint256 indexed nodeId,
        address indexed operator,
        string name,
        uint256 totalFucus
    );
    event NodeUpdated(uint256 indexed nodeId, string name, string metadata);
    event NodeRemoved(uint256 indexed nodeId, address indexed operator);
    event NodeDeactivated(uint256 indexed nodeId, address indexed operator);
    event NodeReactivated(uint256 indexed nodeId, address indexed operator);
    event ModelSupportAdded(
        uint256 indexed nodeId,
        uint256 indexed modelId,
        uint256 allocatedFucus
    );
    event ModelSupportRemoved(uint256 indexed nodeId, uint256 indexed modelId);
    event ModelSupportUpdated(
        uint256 indexed nodeId,
        uint256 indexed modelId,
        uint256 newAllocatedFucus
    );
    event FucusAllocated(address indexed operator, uint256 indexed modelId, uint256 amount);
    event FucusReleased(address indexed operator, uint256 indexed modelId, uint256 amount);

    // ============ ERRORS ============

    error NodeDoesNotExist(uint256 nodeId);
    error NotNodeOperator(uint256 nodeId);
    error OnlyTaskManager();
    error NodeInactive(uint256 nodeId);
    error InsufficientFucus(uint256 required, uint256 available);
    error ModelNotSupported(uint256 nodeId, uint256 modelId);
    error InvalidFucusAmount();
    error ModelAlreadySupported(uint256 nodeId, uint256 modelId);
    error ZeroAddress();
    error InvalidModelId(uint256 modelId);

    // ============ NODE MANAGEMENT ============

    /**
     * @notice Register a new node for the calling operator
     * @param name Human-readable name for the node
     * @param metadata Additional metadata (IPFS hash, specs, etc.)
     * @param totalFucus Total functional compute units available on this node
     * @return nodeId The ID of the newly registered node
     */
    function registerNode(
        string memory name,
        string memory metadata,
        uint256 totalFucus
    ) external returns (uint256 nodeId);

    /**
     * @notice Update node information (only by operator)
     * @param nodeId The ID of the node to update
     * @param name New name for the node
     * @param metadata New metadata for the node
     */
    function updateNode(
        uint256 nodeId,
        string memory name,
        string memory metadata,
        uint256 totalFucus
    ) external;

    /**
     * @notice Remove a node (only by operator)
     * @param nodeId The ID of the node to remove
     */
    function removeNode(uint256 nodeId) external;

    /**
     * @notice Deactivate a node (only by operator)
     * @param nodeId The ID of the node to deactivate
     */
    function deactivateNode(uint256 nodeId) external;

    /**
     * @notice Reactivate a node (only by operator)
     * @param nodeId The ID of the node to reactivate
     */
    function reactivateNode(uint256 nodeId) external;

    // ============ MODEL SUPPORT MANAGEMENT ============

    /**
     * @notice Add support for a model on a node with allocated FUCUs
     * @param nodeId The ID of the node
     * @param modelId The ID of the model to support
     * @param allocatedFucus The number of FUCUs to allocate for this model
     */
    function addModelSupport(uint256 nodeId, uint256 modelId, uint256 allocatedFucus) external;

    /**
     * @notice Remove model support from a node
     * @param nodeId The ID of the node
     * @param modelId The ID of the model to remove support for
     */
    function removeModelSupport(uint256 nodeId, uint256 modelId) external;

    /**
     * @notice Update allocated FUCUs for a model on a node
     * @param nodeId The ID of the node
     * @param modelId The ID of the model
     * @param newAllocatedFucus The new number of allocated FUCUs
     */
    function updateModelSupport(
        uint256 nodeId,
        uint256 modelId,
        uint256 newAllocatedFucus
    ) external;

    // ============ TASK ALLOCATION ============

    /**
     * @notice Allocate FUCUs for a model task (called by service manager)
     * @param operator The operator to allocate FUCUs for
     * @param modelId The model requiring computation
     * @param requiredFucus The amount of FUCUs needed
     * @return success Whether the allocation was successful
     */
    function allocateFucusForTask(
        address operator,
        uint256 modelId,
        uint256 requiredFucus
    ) external returns (bool success);

    /**
     * @notice Release allocated FUCUs after task completion
     * @param operator The operator to release FUCUs for
     * @param modelId The model that was computed
     * @param fucusToRelease The amount of FUCUs to release
     */
    function releaseFucusForTask(
        address operator,
        uint256 modelId,
        uint256 fucusToRelease
    ) external;

    // ============ VIEW FUNCTIONS ============

    /**
     * @notice Get all node IDs for an operator
     * @param operator The operator address
     * @return Array of node IDs owned by the operator
     */
    function getOperatorNodes(address operator) external view returns (uint256[] memory);

    /**
     * @notice Get all model IDs supported by a node
     * @param nodeId The ID of the node
     * @return Array of model IDs supported by the node
     */
    function getNodeSupportedModels(uint256 nodeId) external view returns (uint256[] memory);

    /**
     * @notice Get list of FUCUs allocated for a node's models
     * @param nodeId The ID of the node
     * @return Array of FUCUs allocated for each model supported by the node
     *         according to the order of model IDs returned by `getNodeSupportedModels`
     */
    function getNodeModelsFucus(uint256 nodeId) external view returns (uint256[] memory);

    /**
     * @notice Get all node IDs that support a specific model
     * @param modelId The ID of the model
     * @return Array of node IDs that support the model
     */
    function getModelSupportingNodes(uint256 modelId) external view returns (uint256[] memory);

    /**
     * @notice Get total FUCUs allocated across all models for a specific node
     * @param nodeId The ID of the node
     * @return totalAllocated Total allocated FUCUs for the node
     */
    function getTotalAllocatedFucusForNode(
        uint256 nodeId
    ) external view returns (uint256 totalAllocated);

    /**
     * @notice Get total available FUCUs for an operator for a specific model
     * @param operator The operator address
     * @param modelId The ID of the model
     * @return totalFucus Total FUCUs available for the operator-model combination
     */
    function getTotalFucusForOperatorModel(
        address operator,
        uint256 modelId
    ) external view returns (uint256 totalFucus);

    /**
     * @notice Get available (unallocated) FUCUs for an operator for a specific model
     * @param operator The operator address
     * @param modelId The ID of the model
     * @return Available FUCUs for the operator-model combination
     */
    function getAvailableFucusForOperatorModel(
        address operator,
        uint256 modelId
    ) external view returns (uint256);

    /**
     * @notice Get detailed node information
     * @param nodeId The ID of the node
     * @return operator The operator who owns the node
     * @return name The name of the node
     * @return metadata The metadata of the node
     * @return totalFucus The total FUCUs available on the node
     * @return allocatedFucus The currently allocated FUCUs
     * @return availableFucus The available (unallocated) FUCUs
     * @return isActive Whether the node is active
     * @return createdAt When the node was created
     * @return supportedModelsCount The number of models supported by the node
     */
    function getNodeDetails(
        uint256 nodeId
    )
        external
        view
        returns (
            address operator,
            string memory name,
            string memory metadata,
            uint256 totalFucus,
            uint256 allocatedFucus,
            uint256 availableFucus,
            bool isActive,
            uint256 createdAt,
            uint256 supportedModelsCount
        );

    /**
     * @notice Get operators who can handle a specific model with required FUCUs
     * @param modelId The model to run
     * @param requiredFucus Required compute units
     * @return availableOperators Array of operators who can handle the model
     * @return availableFucus Array of available FUCUs for each operator
     */
    function getAvailableOperatorsForModel(
        uint256 modelId,
        uint256 requiredFucus
    ) external view returns (address[] memory availableOperators, uint256[] memory availableFucus);

    // ============ STATE VARIABLES (for external access) ============

    /**
     * @notice Get the next node ID that will be assigned
     * @return The next node ID
     */
    function nextNodeId() external view returns (uint256);

    /**
     * @notice Get node information by ID
     * @param nodeId The ID of the node
     * @return The Node struct
     */
    function nodes(
        uint256 nodeId
    )
        external
        view
        returns (uint256, address, string memory, string memory, uint256, bool, uint256);

    /**
     * @notice Get node model configuration
     * @param nodeId The ID of the node
     * @param modelId The ID of the model
     * @return allocatedFucus The allocated FUCUs for this node-model combination
     * @return isSupported Whether the node supports this model
     */
    function nodeModelConfigs(
        uint256 nodeId,
        uint256 modelId
    ) external view returns (uint256 allocatedFucus, bool isSupported);

    /**
     * @notice Get operator allocated FUCUs for a model
     * @param operator The operator address
     * @param modelId The ID of the model
     * @return The number of currently allocated FUCUs
     */
    function operatorAllocatedFucus(
        address operator,
        uint256 modelId
    ) external view returns (uint256);
}
