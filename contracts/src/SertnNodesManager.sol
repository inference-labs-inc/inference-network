// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import {IAVSRegistrar} from "@eigenlayer/contracts/interfaces/IAVSRegistrar.sol";
import {IAllocationManager, IAllocationManagerTypes} from "@eigenlayer/contracts/interfaces/IAllocationManager.sol";
import {IDelegationManager} from "@eigenlayer/contracts/interfaces/IDelegationManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IRewardsCoordinator} from "@eigenlayer/contracts/interfaces/IRewardsCoordinator.sol";
import {ISertnTaskManager} from "../interfaces/ISertnTaskManager.sol";
import {ISertnNodesManager} from "../interfaces/ISertnNodesManager.sol";
import {IStrategy} from "@eigenlayer/contracts/interfaces/IStrategy.sol";
import {IVerifier} from "../interfaces/IVerifier.sol";
import {IModelRegistry} from "../interfaces/IModelRegistry.sol";
import {ModelRegistry} from "./ModelRegistry.sol";
import {OwnableUpgradeable} from "@openzeppelin-upgrades/contracts/access/OwnableUpgradeable.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {OperatorSet} from "@eigenlayer/contracts/libraries/OperatorSetLib.sol";

/**
 * @title SertnNodesManager
 * @author Inference Labs, Inc.
 * @notice SertnNodesManager is a contract that manages nodes in the Sertn network.
 */
contract SertnNodesManager is OwnableUpgradeable, ISertnNodesManager {
    using EnumerableSet for EnumerableSet.UintSet;
    using EnumerableSet for EnumerableSet.AddressSet;

    // ============ STATE VARIABLES ============
    // Core contracts
    IDelegationManager public delegationManager;
    ISertnTaskManager public sertnTaskManager;
    ModelRegistry public modelRegistry;

    // Node management
    uint256 public nextNodeId = 1;
    mapping(uint256 => Node) public nodes; // nodeId => Node
    mapping(address => EnumerableSet.UintSet) private operatorNodes; // operator => nodeIds

    // Model support and resource allocation
    mapping(uint256 => mapping(uint256 => NodeModelConfig)) public nodeModelConfigs; // nodeId => modelId => config
    mapping(address => mapping(uint256 => uint256)) public operatorAllocatedFucus; // operator => modelId => allocated FUCUs

    // Track which nodes support which models
    mapping(uint256 => EnumerableSet.UintSet) private modelSupportingNodes; // modelId => nodeIds
    mapping(uint256 => EnumerableSet.UintSet) private nodeSupportedModels; // nodeId => modelIds

    // ============ MODIFIERS ============

    modifier onlyNodeOperator(uint256 nodeId) {
        if (nodes[nodeId].operator != msg.sender) {
            revert NotNodeOperator(nodeId);
        }
        _;
    }

    modifier nodeExists(uint256 nodeId) {
        if (nodes[nodeId].operator == address(0)) {
            revert NodeDoesNotExist(nodeId);
        }
        _;
    }

    modifier nodeActive(uint256 nodeId) {
        if (!nodes[nodeId].isActive) {
            revert NodeInactive(nodeId);
        }
        _;
    }

    modifier validModel(uint256 modelId) {
        if (modelRegistry.modelVerifier(modelId) == address(0)) {
            revert InvalidModelId(modelId);
        }
        _;
    }

    // ============ INITIALIZATION ============

    function initialize(
        address _delegationManager,
        address _sertnTaskManager,
        address _modelRegistry
    ) public initializer {
        __Ownable_init();
        if (
            _delegationManager == address(0) ||
            _sertnTaskManager == address(0) ||
            _modelRegistry == address(0)
        ) {
            revert ZeroAddress();
        }
        delegationManager = IDelegationManager(_delegationManager);
        sertnTaskManager = ISertnTaskManager(_sertnTaskManager);
        modelRegistry = ModelRegistry(_modelRegistry);
        nextNodeId = 1;
    }

    // ============ NODE MANAGEMENT ============

    /**
     * @notice Register a new node for the calling operator
     * @param name Human-readable name for the node
     * @param metadata Additional metadata (IPFS hash, specs, etc.)
     * @param totalFucus Total functional compute units available on this node
     */
    function registerNode(
        string memory name,
        string memory metadata,
        uint256 totalFucus
    ) external returns (uint256 nodeId) {
        if (totalFucus == 0) {
            revert InvalidFucusAmount();
        }

        if (!delegationManager.isOperator(msg.sender)) {
            revert NotNodeOperator(0);
        }

        nodeId = nextNodeId++;

        nodes[nodeId] = Node({
            nodeId: nodeId,
            operator: msg.sender,
            name: name,
            metadata: metadata,
            totalFucus: totalFucus,
            isActive: true,
            createdAt: block.timestamp
        });

        operatorNodes[msg.sender].add(nodeId);

        emit NodeRegistered(nodeId, msg.sender, name, totalFucus);
    }

    /**
     * @notice Update node information (only by operator)
     */
    function updateNode(
        uint256 nodeId,
        string memory name,
        string memory metadata,
        uint256 totalFucus
    ) external nodeExists(nodeId) onlyNodeOperator(nodeId) {
        uint256 currentAllocated = getTotalAllocatedFucusForNode(nodeId);
        if (totalFucus < currentAllocated) {
            revert InsufficientFucus(totalFucus, currentAllocated);
        }
        nodes[nodeId].name = name;
        nodes[nodeId].metadata = metadata;
        nodes[nodeId].totalFucus = totalFucus;

        emit NodeUpdated(nodeId, name, metadata);
    }

    /**
     * @notice Remove a node (only by operator)
     */
    function removeNode(uint256 nodeId) external nodeExists(nodeId) onlyNodeOperator(nodeId) {
        // Remove all model supports first
        for (uint256 i = 0; i < nodeSupportedModels[nodeId].length(); i++) {
            uint256 modelId = nodeSupportedModels[nodeId].at(i);
            delete nodeModelConfigs[nodeId][modelId];
            modelSupportingNodes[modelId].remove(nodeId);
        }
        delete nodeSupportedModels[nodeId];
        // Remove node from operator's set
        operatorNodes[nodes[nodeId].operator].remove(nodeId);
        // Finally delete the node
        delete nodes[nodeId];
        emit NodeRemoved(nodeId, msg.sender);
    }

    /**
     * @notice Deactivate a node (only by operator)
     */
    function deactivateNode(uint256 nodeId) external nodeExists(nodeId) onlyNodeOperator(nodeId) {
        nodes[nodeId].isActive = false;
        emit NodeDeactivated(nodeId, msg.sender);
    }

    /**
     * @notice Reactivate a node (only by operator)
     */
    function reactivateNode(uint256 nodeId) external nodeExists(nodeId) onlyNodeOperator(nodeId) {
        nodes[nodeId].isActive = true;
        emit NodeReactivated(nodeId, msg.sender);
    }

    // ============ MODEL SUPPORT MANAGEMENT ============

    /**
     * @notice Add support for a model on a node with allocated FUCUs
     */
    function addModelSupport(
        uint256 nodeId,
        uint256 modelId,
        uint256 allocatedFucus
    ) external nodeExists(nodeId) onlyNodeOperator(nodeId) nodeActive(nodeId) validModel(modelId) {
        if (allocatedFucus == 0) {
            revert InvalidFucusAmount();
        }

        if (nodeModelConfigs[nodeId][modelId].isSupported) {
            revert ModelAlreadySupported(nodeId, modelId);
        }

        // Check if node has enough total FUCUs for this allocation
        uint256 currentAllocated = getTotalAllocatedFucusForNode(nodeId);
        if (currentAllocated + allocatedFucus > nodes[nodeId].totalFucus) {
            revert InsufficientFucus(currentAllocated + allocatedFucus, nodes[nodeId].totalFucus);
        }

        nodeModelConfigs[nodeId][modelId] = NodeModelConfig({
            allocatedFucus: allocatedFucus,
            isSupported: true
        });

        modelSupportingNodes[modelId].add(nodeId);
        nodeSupportedModels[nodeId].add(modelId);

        emit ModelSupportAdded(nodeId, modelId, allocatedFucus);
    }

    /**
     * @notice Remove model support from a node
     */
    function removeModelSupport(
        uint256 nodeId,
        uint256 modelId
    ) external nodeExists(nodeId) onlyNodeOperator(nodeId) {
        if (!nodeModelConfigs[nodeId][modelId].isSupported) {
            revert ModelNotSupported(nodeId, modelId);
        }

        delete nodeModelConfigs[nodeId][modelId];
        modelSupportingNodes[modelId].remove(nodeId);
        nodeSupportedModels[nodeId].remove(modelId);

        emit ModelSupportRemoved(nodeId, modelId);
    }

    /**
     * @notice Update allocated FUCUs for a model on a node
     */
    function updateModelSupport(
        uint256 nodeId,
        uint256 modelId,
        uint256 newAllocatedFucus
    ) external nodeExists(nodeId) onlyNodeOperator(nodeId) nodeActive(nodeId) {
        if (!nodeModelConfigs[nodeId][modelId].isSupported) {
            revert ModelNotSupported(nodeId, modelId);
        }

        if (newAllocatedFucus == 0) {
            revert InvalidFucusAmount();
        }

        // Calculate current allocation excluding this model
        uint256 currentAllocated = getTotalAllocatedFucusForNode(nodeId) -
            nodeModelConfigs[nodeId][modelId].allocatedFucus;

        if (currentAllocated + newAllocatedFucus > nodes[nodeId].totalFucus) {
            revert InsufficientFucus(
                currentAllocated + newAllocatedFucus,
                nodes[nodeId].totalFucus
            );
        }

        nodeModelConfigs[nodeId][modelId].allocatedFucus = newAllocatedFucus;

        emit ModelSupportUpdated(nodeId, modelId, newAllocatedFucus);
    }

    // ============ TASK ALLOCATION ============

    /**
     * @notice Allocate FUCUs for a model task (called by task manager)
     * @param operator The operator to allocate FUCUs for
     * @param modelId The model requiring computation
     * @param requiredFucus The amount of FUCUs needed
     */
    function allocateFucusForTask(
        address operator,
        uint256 modelId,
        uint256 requiredFucus
    ) external validModel(modelId) returns (bool success) {
        // Only task manager should be able to allocate FUCUs
        if (msg.sender != address(sertnTaskManager)) {
            revert OnlyTaskManager();
        }

        uint256 availableFucus = getAvailableFucusForOperatorModel(operator, modelId);

        if (availableFucus < requiredFucus) {
            return false; // Not enough capacity
        }

        operatorAllocatedFucus[operator][modelId] += requiredFucus;

        emit FucusAllocated(operator, modelId, requiredFucus);
        return true;
    }

    /**
     * @notice Release allocated FUCUs after task completion
     */
    function releaseFucusForTask(
        address operator,
        uint256 modelId,
        uint256 fucusToRelease
    ) external {
        // Only task manager should be able to release FUCUs
        if (msg.sender != address(sertnTaskManager)) {
            revert OnlyTaskManager();
        }

        uint256 currentAllocated = operatorAllocatedFucus[operator][modelId];
        require(currentAllocated >= fucusToRelease, "Attempting to release more than allocated");
        operatorAllocatedFucus[operator][modelId] = currentAllocated - fucusToRelease;

        emit FucusReleased(operator, modelId, fucusToRelease);
    }

    // ============ VIEW FUNCTIONS ============

    /**
     * @notice Get all node IDs for an operator
     */
    function getOperatorNodes(address operator) external view returns (uint256[] memory) {
        uint256[] memory nodeIds = new uint256[](operatorNodes[operator].length());
        for (uint256 i = 0; i < operatorNodes[operator].length(); i++) {
            nodeIds[i] = operatorNodes[operator].at(i);
        }
        return nodeIds;
    }

    /**
     * @notice Get all model IDs supported by a node with their allocated FUCUs
     */
    function getNodeSupportedModels(
        uint256 nodeId
    ) external view returns (uint256[] memory modelIds) {
        uint256 length = nodeSupportedModels[nodeId].length();
        modelIds = new uint256[](length);

        for (uint256 i = 0; i < length; i++) {
            uint256 modelId = nodeSupportedModels[nodeId].at(i);
            modelIds[i] = modelId;
        }
    }

    /**
     * @notice Get allocated FUCUs for each model supported by a node
     * @dev Returns an array of allocated FUCUs corresponding to the models in getNodeSupportedModels
     */
    function getNodeModelsFucus(
        uint256 nodeId
    ) external view returns (uint256[] memory allocatedFucus) {
        uint256 length = nodeSupportedModels[nodeId].length();
        allocatedFucus = new uint256[](length);

        for (uint256 i = 0; i < length; i++) {
            uint256 modelId = nodeSupportedModels[nodeId].at(i);
            allocatedFucus[i] = nodeModelConfigs[nodeId][modelId].allocatedFucus;
        }
    }

    /**
     * @notice Get all node IDs that support a specific model
     */
    function getModelSupportingNodes(uint256 modelId) external view returns (uint256[] memory) {
        uint256[] memory nodeIds = new uint256[](modelSupportingNodes[modelId].length());
        for (uint256 i = 0; i < modelSupportingNodes[modelId].length(); i++) {
            nodeIds[i] = modelSupportingNodes[modelId].at(i);
        }
        return nodeIds;
    }

    /**
     * @notice Get total FUCUs allocated across all models for a specific node
     */
    function getTotalAllocatedFucusForNode(
        uint256 nodeId
    ) public view returns (uint256 totalAllocated) {
        for (uint256 i = 0; i < nodeSupportedModels[nodeId].length(); i++) {
            uint256 modelId = nodeSupportedModels[nodeId].at(i);
            totalAllocated += nodeModelConfigs[nodeId][modelId].allocatedFucus;
        }
    }

    /**
     * @notice Get total available FUCUs for an operator for a specific model
     */
    function getTotalFucusForOperatorModel(
        address operator,
        uint256 modelId
    ) public view returns (uint256 totalFucus) {
        for (uint256 i = 0; i < operatorNodes[operator].length(); i++) {
            uint256 nodeId = operatorNodes[operator].at(i);
            if (nodes[nodeId].isActive && nodeModelConfigs[nodeId][modelId].isSupported) {
                totalFucus += nodeModelConfigs[nodeId][modelId].allocatedFucus;
            }
        }
    }

    /**
     * @notice Get available (unallocated) FUCUs for an operator for a specific model
     */
    function getAvailableFucusForOperatorModel(
        address operator,
        uint256 modelId
    ) public view returns (uint256) {
        uint256 totalFucus = getTotalFucusForOperatorModel(operator, modelId);
        uint256 allocatedFucus = operatorAllocatedFucus[operator][modelId];

        return totalFucus > allocatedFucus ? totalFucus - allocatedFucus : 0;
    }

    /**
     * @notice Get detailed node information
     */
    function getNodeDetails(
        uint256 nodeId
    )
        external
        view
        nodeExists(nodeId)
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
        )
    {
        Node memory node = nodes[nodeId];
        uint256 allocated = getTotalAllocatedFucusForNode(nodeId);

        return (
            node.operator,
            node.name,
            node.metadata,
            node.totalFucus,
            allocated,
            node.totalFucus > allocated ? node.totalFucus - allocated : 0,
            node.isActive,
            node.createdAt,
            nodeSupportedModels[nodeId].length()
        );
    }

    // ============ OPERATOR SELECTION HELPERS ============

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
    ) external view returns (address[] memory availableOperators, uint256[] memory availableFucus) {
        // Get all nodes supporting this model
        uint256[] memory supportingNodeIds = new uint256[](modelSupportingNodes[modelId].length());
        for (uint256 i = 0; i < modelSupportingNodes[modelId].length(); i++) {
            supportingNodeIds[i] = modelSupportingNodes[modelId].at(i);
        }

        // Build list of unique operators (using temporary arrays)
        address[] memory tempAllOperators = new address[](supportingNodeIds.length);
        uint256 operatorCount = 0;

        for (uint256 i = 0; i < supportingNodeIds.length; i++) {
            uint256 nodeId = supportingNodeIds[i];
            if (nodes[nodeId].isActive) {
                address operator = nodes[nodeId].operator;

                // Check if operator is already in the list
                bool alreadyAdded = false;
                for (uint256 j = 0; j < operatorCount; j++) {
                    if (tempAllOperators[j] == operator) {
                        alreadyAdded = true;
                        break;
                    }
                }

                if (!alreadyAdded) {
                    tempAllOperators[operatorCount] = operator;
                    operatorCount++;
                }
            }
        }

        // Filter operators who have enough capacity
        address[] memory tempOperators = new address[](operatorCount);
        uint256[] memory tempFucus = new uint256[](operatorCount);
        uint256 validCount = 0;

        for (uint256 i = 0; i < operatorCount; i++) {
            address operator = tempAllOperators[i];
            uint256 available = getAvailableFucusForOperatorModel(operator, modelId);

            if (available >= requiredFucus) {
                tempOperators[validCount] = operator;
                tempFucus[validCount] = available;
                validCount++;
            }
        }

        // Resize arrays to actual count
        availableOperators = new address[](validCount);
        availableFucus = new uint256[](validCount);

        for (uint256 i = 0; i < validCount; i++) {
            availableOperators[i] = tempOperators[i];
            availableFucus[i] = tempFucus[i];
        }
    }

    /**
     * @notice Get all nodes with their details and supported models in a single call
     * @return nodeDetails Array of node details packed as uint256[8] arrays:
     *         [0] nodeId, [1] operator (as uint256), [2] totalFucus, [3] allocatedFucus,
     *         [4] availableFucus, [5] isActive (1/0), [6] createdAt, [7] supportedModelsCount
     * @return supportedModels Array of arrays containing supported model IDs for each node
     * @return modelAllocations Array of arrays containing FUCUS allocations for each model on each node
     * @dev This function is gas-optimized for batch operations. String data (name, metadata)
     *      lengths are returned but not the strings themselves to save gas. Use getNodeDetails
     *      for individual nodes if string data is needed.
     */
    function getAllNodesWithDetails()
        external
        view
        returns (
            uint256[8][] memory nodeDetails,
            uint256[][] memory supportedModels,
            uint256[][] memory modelAllocations
        )
    {
        // First pass: count valid nodes
        uint256 validCount = 0;
        for (uint256 i = 1; i < nextNodeId; i++) {
            if (nodes[i].operator != address(0) && nodes[i].isActive) {
                validCount++;
            }
        }

        // Initialize return arrays
        nodeDetails = new uint256[8][](validCount);
        supportedModels = new uint256[][](validCount);
        modelAllocations = new uint256[][](validCount);

        // Second pass: populate data
        uint256 index = 0;
        for (uint256 i = 1; i < nextNodeId; i++) {
            if (nodes[i].operator != address(0) && nodes[i].isActive) {
                Node memory node = nodes[i];
                uint256 allocated = getTotalAllocatedFucusForNode(i);
                uint256 available = node.totalFucus > allocated ? node.totalFucus - allocated : 0;

                // Pack node details into uint256 array
                nodeDetails[index][0] = i; // nodeId
                nodeDetails[index][1] = uint256(uint160(node.operator)); // operator as uint256
                nodeDetails[index][2] = node.totalFucus;
                nodeDetails[index][3] = allocated;
                nodeDetails[index][4] = available;
                nodeDetails[index][5] = node.isActive ? 1 : 0;
                nodeDetails[index][6] = node.createdAt;
                nodeDetails[index][7] = nodeSupportedModels[i].length(); // supportedModelsCount

                // Get supported models and their allocations
                uint256 modelCount = nodeSupportedModels[i].length();
                supportedModels[index] = new uint256[](modelCount);
                modelAllocations[index] = new uint256[](modelCount);

                for (uint256 j = 0; j < modelCount; j++) {
                    uint256 modelId = nodeSupportedModels[i].at(j);
                    supportedModels[index][j] = modelId;
                    modelAllocations[index][j] = nodeModelConfigs[i][modelId].allocatedFucus;
                }

                index++;
            }
        }
    }
}
