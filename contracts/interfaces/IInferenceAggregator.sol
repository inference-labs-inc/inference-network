// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IInferenceTaskManager} from "./IInferenceTaskManager.sol";

/**
 * @title IInferenceAggregator
 * @author Inference Labs, Inc.
 * @notice Interface for the Aggregators within Inference
 */
interface IInferenceAggregator {
    /**
     * @notice Thrown when the EOA signature is invalid
     */
    error InvalidEOASignature();

    /**
     * @notice Thrown when the address is zero
     */
    error ZeroAddress();

    /**
     * @notice Emitted when a task is submitted
     * @param taskId The hash of the task
     * @param submitter The address that submitted the task
     */
    event TaskSubmitted(bytes32 indexed taskId, address indexed submitter);

    /**
     * @notice Submits a task to the Aggregator
     * @param _task The task to submit
     * @param _proof The proof of the task signed by aggregatorEOA
     */
    function submitTask(IInferenceTaskManager.Task memory _task, bytes memory _proof) external;

    /**
     * @notice Updates the Aggregator EOA
     * @param _aggregatorEOA The new Aggregator EOA
     */
    function updateAggregatorEOA(address _aggregatorEOA) external;

    /**
     * @notice Updates the InferenceTaskManager contract address
     * @param _inferenceTaskManager The new InferenceTaskManager contract address
     */
    function updateInferenceTaskManager(address _inferenceTaskManager) external;
}
