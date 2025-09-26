// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {OwnableUpgradeable} from "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import {IModelRegistry} from "../interfaces/IModelRegistry.sol";

/**
 * @title ModelRegistry
 * @author Inference Labs, Inc.
 * @notice ModelRegistry is a contract that stores models for the Sertn network.
 */
contract ModelRegistry is OwnableUpgradeable, IModelRegistry {
    using EnumerableSet for EnumerableSet.UintSet;
    // Current model index (starts at 1 to avoid zero-indexing issues)
    uint256 public modelIndex = 1;

    // modelVerifier => modelId
    mapping(address => uint256) public modelVerifiers;

    // modelId => modelVerifier
    mapping(uint256 => address) public modelVerifier;
    // modelId => modelName
    mapping(uint256 => string) public modelName;
    // modelName => modelId (enforce uniqueness of modelName values)
    mapping(string => uint256) public modelNameToId;
    // modelId => verificationStrategy
    mapping(uint256 => VerificationStrategy) public verificationStrategy;
    // modelId => computeCost
    mapping(uint256 => uint256) public computeCost;
    // modelId => requiredFUCUs
    mapping(uint256 => uint256) public requiredFUCUs;
    // Active models set for efficient presence check and enumeration
    EnumerableSet.UintSet private activeModelIds;

    function initialize() public initializer {
        __Ownable_init();
        modelIndex = 1; // Ensure we start at 1
    }

    /// @inheritdoc IModelRegistry
    function createNewModel(
        address _modelVerifier,
        VerificationStrategy _verificationStrategy,
        string memory _modelName,
        uint256 _computeCost,
        uint256 _requiredFUCUs
    ) external onlyOwner returns (uint256 modelId) {
        // Validation checks for model verifier
        if (_modelVerifier == address(0)) revert InvalidModelVerifier();
        if (modelVerifiers[_modelVerifier] != 0)
            revert ModelAlreadyExists(modelVerifiers[_modelVerifier]);
        // Ensure modelName is non-empty and unique
        if (bytes(_modelName).length == 0) revert InvalidModelName();
        // Ensure modelName is unique
        if (modelNameToId[_modelName] != 0) revert ModelAlreadyExists(modelNameToId[_modelName]);
        // Assign verifier and Name
        modelVerifier[modelIndex] = _modelVerifier;
        modelName[modelIndex] = _modelName;
        modelNameToId[_modelName] = modelIndex;
        verificationStrategy[modelIndex] = _verificationStrategy;
        computeCost[modelIndex] = _computeCost;
        requiredFUCUs[modelIndex] = _requiredFUCUs;
        activeModelIds.add(modelIndex);
        // Assign reverse mapping values
        modelVerifiers[_modelVerifier] = modelIndex;

        emit ModelCreated(
            modelIndex,
            _modelVerifier,
            _verificationStrategy,
            _modelName,
            _computeCost,
            _requiredFUCUs
        );
        modelId = modelIndex;
        // Increment model index
        modelIndex++;
    }

    /// @inheritdoc IModelRegistry
    function updateModelName(uint256 modelId, string memory _modelName) external onlyOwner {
        if (modelId >= modelIndex || modelId < 1) revert ModelDoesNotExist();
        // Enforce uniqueness: allow same modelId to keep its own name
        uint256 existing = modelNameToId[_modelName];
        if (existing != 0 && existing != modelId) revert ModelAlreadyExists(existing);
        // Update reverse mapping: remove old name mapping
        string memory oldName = modelName[modelId];
        if (bytes(oldName).length != 0) {
            // Clear only if previously set
            delete modelNameToId[oldName];
        }
        modelName[modelId] = _modelName;
        modelNameToId[_modelName] = modelId;
        emit ModelNameUpdated(modelId, _modelName);
    }

    /// @inheritdoc IModelRegistry
    function updateComputeCost(uint256 modelId, uint256 _computeCost) external onlyOwner {
        if (modelId >= modelIndex || modelId < 1) revert ModelDoesNotExist();
        computeCost[modelId] = _computeCost;
        emit ComputeCostUpdated(modelId, _computeCost);
    }

    /// @inheritdoc IModelRegistry
    function updateRequiredFUCUs(uint256 modelId, uint256 fucus) external onlyOwner {
        if (modelId >= modelIndex || modelId < 1) revert ModelDoesNotExist();
        requiredFUCUs[modelId] = fucus;
        emit RequiredFUCUsUpdated(modelId, fucus);
    }

    /// @inheritdoc IModelRegistry
    function updateModelVerifier(uint256 modelId, address _modelVerifier) external onlyOwner {
        if (modelId >= modelIndex || modelId < 1) revert ModelDoesNotExist();
        if (_modelVerifier == address(0)) revert InvalidModelVerifier();
        if (modelVerifiers[_modelVerifier] != 0)
            revert ModelAlreadyExists(modelVerifiers[_modelVerifier]);
        // Update the verifier
        address oldVerifier = modelVerifier[modelId];
        if (oldVerifier != address(0)) {
            delete modelVerifiers[oldVerifier];
        }
        modelVerifiers[_modelVerifier] = modelId;
        modelVerifier[modelId] = _modelVerifier;
        activeModelIds.add(modelId);
        emit ModelVerifierUpdated(modelId, _modelVerifier);
    }

    /// @inheritdoc IModelRegistry
    function updateVerificationStrategy(
        uint256 modelId,
        VerificationStrategy _verificationStrategy
    ) external onlyOwner {
        if (modelId >= modelIndex || modelId < 1) revert ModelDoesNotExist();
        verificationStrategy[modelId] = _verificationStrategy;
        emit VerificationStrategyUpdated(modelId, _verificationStrategy);
    }

    /// @inheritdoc IModelRegistry
    function disableModel(uint256 modelId) external onlyOwner {
        if (modelId >= modelIndex || modelId < 1) revert ModelDoesNotExist();
        address oldVerifier = modelVerifier[modelId];
        if (oldVerifier != address(0)) {
            delete modelVerifiers[oldVerifier];
        }
        modelVerifier[modelId] = address(0);
        activeModelIds.remove(modelId);
        emit ModelDisabled(modelId);
    }

    /// @inheritdoc IModelRegistry
    function activeModelsLength() external view returns (uint256) {
        return activeModelIds.length();
    }

    /// @inheritdoc IModelRegistry
    function getActiveModels() external view returns (uint256[] memory ids) {
        return activeModelIds.values();
    }

    /// @inheritdoc IModelRegistry
    function getRandomActiveModel(uint256 seed) external view returns (uint256) {
        uint256 len = activeModelIds.length();
        if (len == 0) revert NoActiveModels();
        uint256 idx = uint256(
            keccak256(abi.encodePacked(block.prevrandao, block.timestamp, seed))
        ) % len;
        return activeModelIds.at(idx);
    }

    /// @inheritdoc IModelRegistry
    function isActive(uint256 modelId) external view returns (bool) {
        return activeModelIds.contains(modelId);
    }
}
