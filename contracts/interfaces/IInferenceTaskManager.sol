// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

interface IInferenceTaskManager {
    /// @notice Thrown when the model id is invalid
    error InvalidModelId();

    /// @notice Thrown when not called by an aggregator
    error NotAggregator();

    /// @notice Thrown when not called by an operator
    error NotOperator();

    /// @notice Thrown when the task does not exist
    error TaskDoesNotExist();

    /// @notice Thrown when a non-operator attempts to submit a task
    error NotAssignedToTask();

    /// @notice Thrown when the task state is incorrect
    error TaskStateIncorrect(TaskState expected);

    /// @notice Thrown when the proof is invalid
    error InvalidProof(uint256 taskId, bytes32 proofHash);

    /// @notice Thrown when the task model does not imply a verification, but a proof is submitted
    error InvalidVerificationStrategy(uint256 taskId);

    /// @notice Thrown when there is insufficient FUCUs capacity and the task cannot be executed by the operator
    error InsufficientFucusCapacity(address operator, uint256 modelId, uint256 required);

    /// @notice Emitted when a task is created
    event TaskCreated(uint256 indexed taskId, address indexed user);

    /// @notice Emitted when a task is assigned to an operator
    event TaskAssigned(uint256 indexed taskId, address indexed operator);

    /// @notice Emitted when a task is completed by an operator
    event TaskCompleted(uint256 indexed taskId, address indexed operator);

    /// @notice Emitted when a task is challenged by a user
    event TaskChallenged(uint256 indexed taskId, address indexed user);

    /// @notice Emitted when a proof is submitted for a task
    event ProofSubmitted(uint256 indexed taskId, bytes32 proofHash);

    /// @notice Emitted when a task is rejected and the operator is slashed
    event TaskRejected(uint256 indexed taskId, address indexed operator);

    /// @notice Emitted when a task is resolved and the operator is rewarded
    event TaskResolved(uint256 indexed taskId, address indexed operator);

    /**
     * @notice The task struct
     * XXX: changing this struct, don't forget to take care of `client/src/common/contract_constants.py`
     * @param startBlock The block number when the task was created
     * @param modelId The model id
     * @param inputs The inputs to the model
     * @param proof The proof of completion
     * @param proveOnResponse Whether to prove on response
     * @param user The user who created the task
     * @param nonce The nonce for the task
     * @param operator The operator who is assigned to the task
     */
    struct Task {
        uint256 startBlock;
        uint32 startTimestamp;
        uint256 modelId;
        bytes inputs;
        bytes32 proofHash;
        address user;
        uint256 nonce;
        address operator;
        TaskState state;
        bytes output;
        uint256 fee;
    }

    /**
     * @notice The task state enum
     * XXX: changing this enum, don't forget to take care of `client/src/common/contract_constants.py`
     * @param CREATED Task has been created and is waiting to be assigned to an operator
     * @param ASSIGNED Task has been assigned to an operator
     * @param COMPLETED Task has been completed by an operator
     * @param CHALLENGED Task has been challenged by a user
     * @param REJECTED Task has been rejected, and the operator has been slashed
     * @param RESOLVED Task has been resolved, and the operator has been rewarded
     */
    enum TaskState {
        CREATED,
        ASSIGNED,
        COMPLETED,
        CHALLENGED,
        REJECTED,
        RESOLVED
    }

    /**
     * @notice Send a task to the task manager
     * @param _task The task to send
     */
    function sendTask(Task memory _task) external;

    /**
     * @notice Submit a task to the task manager
     * @param taskId The task id
     * @param output The output of the task
     */
    function submitTaskOutput(uint256 taskId, bytes calldata output) external;

    /**
     * @notice Challenge a task
     * @param taskId The task id
     */
    function challengeTask(uint256 taskId) external;

    /**
     * @notice Submit a task response to the task manager
     * @param taskId The task id
     * @param proof The proof of completion
     */
    function submitProofForTask(uint256 taskId, bytes calldata proof) external;
}
