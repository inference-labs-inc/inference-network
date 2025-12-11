// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import {IInferenceNodesManager} from "../../interfaces/IInferenceNodesManager.sol";

/**
 * @title InferenceNodesManagerMock
 * @notice Basic mock implementation of InferenceNodesManager for testing purposes
 * @dev Always returns success/positive responses - assumes infinite FUCUS and all models supported
 */
contract InferenceNodesManagerMock is IInferenceNodesManager {
    uint256 public override nextNodeId = 1;
    mapping(uint256 => mapping(uint256 => NodeModelConfig)) public override nodeModelConfigs;
    mapping(address => mapping(uint256 => uint256)) public override operatorAllocatedFucus;

    // Simple storage for basic functionality
    mapping(uint256 => address) public nodeOperators;

    function nodes(
        uint256 nodeId
    )
        external
        view
        override
        returns (uint256, address, string memory, string memory, uint256, bool, uint256)
    {
        return (
            nodeId,
            nodeOperators[nodeId],
            "Mock Node",
            "Mock metadata",
            1000000,
            true,
            block.timestamp
        );
    }

    function registerNode(
        string memory,
        string memory,
        uint256
    ) external override returns (uint256 nodeId) {
        nodeId = nextNodeId++;
        nodeOperators[nodeId] = msg.sender;
        emit NodeRegistered(nodeId, msg.sender, "Mock Node", 1000000);
    }

    function updateNode(
        uint256 nodeId,
        string memory name,
        string memory metadata,
        uint256
    ) external override {
        emit NodeUpdated(nodeId, name, metadata);
    }

    function removeNode(uint256 nodeId) external override {
        delete nodeOperators[nodeId];
        emit NodeRemoved(nodeId, msg.sender);
    }

    function deactivateNode(uint256 nodeId) external override {
        emit NodeDeactivated(nodeId, msg.sender);
    }

    function reactivateNode(uint256 nodeId) external override {
        emit NodeReactivated(nodeId, msg.sender);
    }

    function addModelSupport(
        uint256 nodeId,
        uint256 modelId,
        uint256 allocatedFucus
    ) external override {
        nodeModelConfigs[nodeId][modelId] = NodeModelConfig(allocatedFucus, true);
        emit ModelSupportAdded(nodeId, modelId, allocatedFucus);
    }

    function removeModelSupport(uint256 nodeId, uint256 modelId) external override {
        delete nodeModelConfigs[nodeId][modelId];
        emit ModelSupportRemoved(nodeId, modelId);
    }

    function updateModelSupport(
        uint256 nodeId,
        uint256 modelId,
        uint256 newAllocatedFucus
    ) external override {
        nodeModelConfigs[nodeId][modelId].allocatedFucus = newAllocatedFucus;
        emit ModelSupportUpdated(nodeId, modelId, newAllocatedFucus);
    }

    function allocateFucusForTask(
        address operator,
        uint256 modelId,
        uint256 requiredFucus
    ) external override returns (bool) {
        operatorAllocatedFucus[operator][modelId] += requiredFucus;
        emit FucusAllocated(operator, modelId, requiredFucus);
        return true; // Always succeeds
    }

    function releaseFucusForTask(
        address operator,
        uint256 modelId,
        uint256 fucusToRelease
    ) external override {
        if (operatorAllocatedFucus[operator][modelId] >= fucusToRelease) {
            operatorAllocatedFucus[operator][modelId] -= fucusToRelease;
        } else {
            operatorAllocatedFucus[operator][modelId] = 0;
        }
        emit FucusReleased(operator, modelId, fucusToRelease);
    }

    // View functions - return mock data
    function getOperatorNodes(address) external pure override returns (uint256[] memory) {
        uint256[] memory nodeIds = new uint256[](1);
        nodeIds[0] = 1;
        return nodeIds;
    }

    function getNodeSupportedModels(uint256) external pure override returns (uint256[] memory) {
        uint256[] memory models = new uint256[](1);
        models[0] = 1;
        return models;
    }

    function getNodeModelsFucus(uint256) external pure override returns (uint256[] memory) {
        uint256[] memory fucus = new uint256[](1);
        fucus[0] = 1000000;
        return fucus;
    }

    function getModelSupportingNodes(uint256) external pure override returns (uint256[] memory) {
        uint256[] memory nodeIds = new uint256[](1);
        nodeIds[0] = 1;
        return nodeIds;
    }

    function getTotalAllocatedFucusForNode(uint256) external pure override returns (uint256) {
        return 0; // No allocation limits
    }

    function getTotalFucusForOperatorModel(
        address,
        uint256
    ) external pure override returns (uint256) {
        return 1000000; // Infinite FUCUS
    }

    function getAvailableFucusForOperatorModel(
        address,
        uint256
    ) external pure override returns (uint256) {
        return 1000000; // Always available
    }

    function getNodeDetails(
        uint256 nodeId
    )
        external
        view
        override
        returns (
            address,
            string memory,
            string memory,
            uint256,
            uint256,
            uint256,
            bool,
            uint256,
            uint256
        )
    {
        return (
            nodeOperators[nodeId],
            "Mock Node",
            "Mock metadata",
            1000000,
            0,
            1000000,
            true,
            block.timestamp,
            1
        );
    }

    function getAvailableOperatorsForModel(
        uint256,
        uint256
    )
        external
        pure
        override
        returns (address[] memory availableOperators, uint256[] memory availableFucus)
    {
        availableOperators = new address[](1);
        availableOperators[0] = address(0x1);
        availableFucus = new uint256[](1);
        availableFucus[0] = 1000000;
    }
}
