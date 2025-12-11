// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IStrategy} from "@eigenlayer/contracts/interfaces/IStrategy.sol";
import "@eigenlayer/contracts/libraries/OperatorSetLib.sol";
import {IAllocationManagerTypes} from "@eigenlayer/contracts/interfaces/IAllocationManager.sol";

import {Test, console2 as console} from "forge-std/Test.sol";

/**
 * @title MockAllocationManager
 * @notice Unified mock contract for testing both InferenceServiceManager and InferenceTaskManager
 */
contract MockAllocationManager {
    // AllocationManager... I hate you so God damn much!!!

    mapping(address => string) public avsMetadataURI;
    mapping(address => address) public avsRegistrar;
    mapping(address => OperatorSet[]) public allocatedSets;
    mapping(address => mapping(uint32 => IStrategy[])) public allocatedStrategies;

    function updateAVSMetadataURI(address avs, string memory metadataURI) external {
        avsMetadataURI[avs] = metadataURI;
    }

    function createOperatorSets(
        address avs,
        IAllocationManagerTypes.CreateSetParams[] memory // params
    ) external pure {
        // Mock implementation
        console.log("Mock createOperatorSets called for AVS:", avs);
    }

    function setAVSRegistrar(address avs, address registrar) external {
        avsRegistrar[avs] = registrar;
    }

    function setAllocatedSets(address operator, OperatorSet[] memory sets) external {
        allocatedSets[operator] = sets;
    }

    function setAllocatedStrategies(
        address operator,
        OperatorSet memory operatorSet,
        IStrategy[] memory strategies
    ) external {
        allocatedStrategies[operator][operatorSet.id] = strategies;
    }

    function getAllocatedSets(address operator) external view returns (OperatorSet[] memory) {
        return allocatedSets[operator];
    }

    function getAllocatedStrategies(
        address operator,
        OperatorSet memory operatorSet
    ) external view returns (IStrategy[] memory) {
        return allocatedStrategies[operator][operatorSet.id];
    }

    function slashOperator(
        address avs,
        IAllocationManagerTypes.SlashingParams memory slashingParams
    ) external {
        // Mock implementation
    }
}
