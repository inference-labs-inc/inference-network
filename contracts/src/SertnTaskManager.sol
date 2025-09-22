// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OwnableUpgradeable} from "@openzeppelin-upgrades/contracts/access/OwnableUpgradeable.sol";
import {IAVSRegistrar} from "@eigenlayer/contracts/interfaces/IAVSRegistrar.sol";
import {IAllocationManager, IAllocationManagerTypes} from "@eigenlayer/contracts/interfaces/IAllocationManager.sol";
import {IDelegationManager} from "@eigenlayer/contracts/interfaces/IDelegationManager.sol";
import {IRewardsCoordinator} from "@eigenlayer/contracts/interfaces/IRewardsCoordinator.sol";
import {IStrategy} from "@eigenlayer/contracts/interfaces/IStrategy.sol";
import {OperatorSet} from "@eigenlayer/contracts/libraries/OperatorSetLib.sol";
import {ISertnServiceManager} from "../interfaces/ISertnServiceManager.sol";
import {ISertnTaskManager} from "../interfaces/ISertnTaskManager.sol";
import {ISertnNodesManager} from "../interfaces/ISertnNodesManager.sol";
import {IVerifier} from "../interfaces/IVerifier.sol";
import {IModelRegistry} from "../interfaces/IModelRegistry.sol";
import {ModelRegistry} from "./ModelRegistry.sol";
import {SertnNodesManager} from "./SertnNodesManager.sol";

contract SertnTaskManager is OwnableUpgradeable, ISertnTaskManager {
    using EnumerableSet for EnumerableSet.UintSet;
    // queue of tasks that are waiting to be assigned to an operator
    address[] public operators;
    // queue of tasks that are waiting to be challenged
    bytes[] public slashingQueue;
    // nonce for tasks to ensure uniqueness
    uint256 public taskNonce = 1;
    // Mapping from taskId to Task struct
    mapping(uint256 => Task) public tasks;
    // all assigned tasks IDs, which are not resolved and not rejected
    EnumerableSet.UintSet private pendingTasks;

    // History tracking mappings for efficient task history queries
    // modelId => array of task IDs
    mapping(uint256 => uint256[]) public tasksByModel;
    // operator address => array of task IDs
    mapping(address => uint256[]) public tasksByOperator;
    // user/aggregator address => array of task IDs
    mapping(address => uint256[]) public tasksByUser;
    // TaskState => array of task IDs
    mapping(TaskState => uint256[]) public tasksByState;

    // Mapping to track task indices for efficient removal (if needed later)
    mapping(uint256 => mapping(uint8 => uint256)) private taskIndexInState; // taskId => state => index

    IERC20 public ser;

    IAllocationManager public allocationManager;
    IDelegationManager public delegationManager;
    IRewardsCoordinator public rewardsCoordinator;
    ISertnNodesManager public sertnNodesManager;
    ISertnServiceManager public sertnServiceManager;
    ModelRegistry public modelRegistry;

    modifier onlyAggregators() {
        if (!sertnServiceManager.isAggregator(msg.sender)) {
            revert NotAggregator();
        }
        _;
    }

    function initialize(
        address _rewardsCoordinator,
        address _delegationManager,
        address _allocationManager,
        address _sertnServiceManager,
        address _modelRegistry,
        address _sertnNodesManager
    ) public initializer {
        __Ownable_init();
        allocationManager = IAllocationManager(_allocationManager);
        delegationManager = IDelegationManager(_delegationManager);
        rewardsCoordinator = IRewardsCoordinator(_rewardsCoordinator);
        sertnServiceManager = ISertnServiceManager(_sertnServiceManager);
        modelRegistry = ModelRegistry(_modelRegistry);
        sertnNodesManager = ISertnNodesManager(_sertnNodesManager);
        taskNonce = 1; // Start task nonce at 1 to avoid zero-indexing issues
    }

    function sendTask(Task memory task) external onlyAggregators {
        // check if the task is valid
        if (modelRegistry.modelVerifier(task.modelId) == address(0)) revert InvalidModelId();
        task.startTimestamp = uint32(block.timestamp);
        task.nonce = taskNonce;
        tasks[taskNonce] = task;
        taskNonce++;
        IStrategy strategy = allocationManager.getAllocatedStrategies(
            task.operator,
            allocationManager.getAllocatedSets(task.operator)[0]
        )[0];
        IERC20 token = strategy.underlyingToken();
        sertnServiceManager.pullFeeFromUser(task.user, token, task.fee);

        emit TaskCreated(task.nonce, task.user);
        tasks[task.nonce].state = TaskState.ASSIGNED;
        pendingTasks.add(task.nonce);

        // Add to history tracking
        _addTaskToHistory(task.nonce, tasks[task.nonce]);

        // Allocate FUCUs for this task
        _allocateFucusForTask(task.nonce);

        emit TaskAssigned(task.nonce, task.operator);
    }

    function getTask(uint256 taskId) external view returns (Task memory) {
        if (taskId > taskNonce) {
            revert TaskDoesNotExist();
        }
        return tasks[taskId];
    }

    function submitTaskOutput(uint256 taskId, bytes calldata output) external {
        if (taskId > taskNonce) {
            revert TaskDoesNotExist();
        }
        Task memory task = tasks[taskId];
        if (task.operator != msg.sender) {
            revert NotAssignedToTask();
        }
        if (task.state != TaskState.ASSIGNED) {
            revert TaskStateIncorrect(task.state);
        }

        tasks[taskId].output = output;
        _updateTaskStateInHistory(taskId, tasks[taskId].state, TaskState.COMPLETED);
        tasks[taskId].state = TaskState.COMPLETED;
        emit TaskCompleted(taskId, task.operator);
    }

    function challengeTask(uint256 taskId) external onlyAggregators {
        Task memory task = tasks[taskId];
        if (taskId > taskNonce) {
            revert TaskDoesNotExist();
        }
        // TODO: configurable timeout
        if (
            (task.state == TaskState.ASSIGNED && task.startBlock + 300 < block.number) ||
            (task.state == TaskState.CHALLENGED && task.startBlock + 600 < block.number)
        ) {
            OperatorSet memory operatorSet = allocationManager.getAllocatedSets(task.operator)[0];
            IStrategy strategy = allocationManager.getAllocatedStrategies(
                task.operator,
                operatorSet
            )[0];

            sertnServiceManager.slashOperator(task.operator, task.fee, operatorSet.id, strategy);
        }
        if (task.state != TaskState.COMPLETED) {
            revert TaskStateIncorrect(TaskState.COMPLETED);
        }
        _updateTaskStateInHistory(taskId, tasks[taskId].state, TaskState.CHALLENGED);
        tasks[taskId].state = TaskState.CHALLENGED;
        emit TaskChallenged(taskId, msg.sender);
    }

    function _resolveTask(uint256 taskId, bool success) internal {
        if (taskId > taskNonce) {
            revert TaskDoesNotExist();
        }
        Task memory task = tasks[taskId];
        if (task.state != TaskState.CHALLENGED && task.state != TaskState.COMPLETED) {
            revert TaskStateIncorrect(TaskState.CHALLENGED);
        }
        OperatorSet memory operatorSet = allocationManager.getAllocatedSets(task.operator)[0];
        IStrategy strategy = allocationManager.getAllocatedStrategies(task.operator, operatorSet)[
            0
        ];

        if (success) {
            sertnServiceManager.taskResolved(
                task.operator,
                task.fee,
                strategy,
                task.startTimestamp
            );
            _updateTaskStateInHistory(task.nonce, task.state, TaskState.RESOLVED);
            tasks[taskId].state = TaskState.RESOLVED;
            emit TaskResolved(taskId, task.operator);
        } else {
            sertnServiceManager.slashOperator(task.operator, task.fee, operatorSet.id, strategy);
            _updateTaskStateInHistory(task.nonce, task.state, TaskState.REJECTED);
            tasks[taskId].state = TaskState.REJECTED;
            emit TaskRejected(taskId, task.operator);
        }

        // Release FUCUs regardless of success or failure
        _releaseFucusForTask(taskId);

        pendingTasks.remove(taskId);
    }

    function resolveTask(uint256 taskId, bool success) public onlyAggregators {
        if (taskId > taskNonce) {
            revert TaskDoesNotExist();
        }
        Task memory task = tasks[taskId];
        if (task.state != TaskState.CHALLENGED && task.state != TaskState.COMPLETED) {
            revert TaskStateIncorrect(task.state);
        }
        _resolveTask(taskId, success);
    }

    function submitProofForTask(uint256 taskId, bytes calldata proof) external {
        if (taskId > taskNonce) {
            revert TaskDoesNotExist();
        }
        Task memory task = tasks[taskId];
        if (task.operator != msg.sender) {
            revert NotAssignedToTask();
        }
        if (task.state != TaskState.CHALLENGED) {
            revert TaskStateIncorrect(TaskState.CHALLENGED);
        }

        // Verify the proof using the model verifier
        IVerifier verifier = IVerifier(modelRegistry.modelVerifier(task.modelId));

        bytes32 proofHash = keccak256(proof);
        tasks[taskId].proofHash = proofHash;
        if (
            modelRegistry.verificationStrategy(task.modelId) ==
            IModelRegistry.VerificationStrategy.Onchain
        ) {
            // On-chain verification
            if (verifier.verifyProof(proof)) {} else {
                revert InvalidProof(taskId, proofHash);
            }
            emit ProofSubmitted(taskId, proofHash);
            _resolveTask(taskId, true);
        } else if (
            modelRegistry.verificationStrategy(task.modelId) ==
            IModelRegistry.VerificationStrategy.Offchain
        ) {
            // Off-chain verification
            // The proof is expected to be verified off-chain by the aggregator
            // Operator must submit the proof to the aggregator
            // Here we just emit an event with the proof hash
            // TODO: check isn't it a second time submitted proof?
            emit ProofSubmitted(taskId, proofHash);
        } else {
            revert InvalidVerificationStrategy(taskId);
        }
    }

    function getPendingTasksIds() public view returns (uint256[] memory) {
        uint256[] memory result = new uint256[](pendingTasks.length());
        for (uint i = 0; i < pendingTasks.length(); i++) {
            result[i] = pendingTasks.at(i);
        }
        return result;
    }

    /**
     * @notice Allocate FUCUs for a task when it's assigned to an operator
     * @param taskId The ID of the task
     */
    function _allocateFucusForTask(uint256 taskId) internal {
        Task memory task = tasks[taskId];
        uint256 requiredFucus = modelRegistry.requiredFUCUs(task.modelId);

        // Try to allocate FUCUs for this task
        bool success = sertnNodesManager.allocateFucusForTask(
            task.operator,
            task.modelId,
            requiredFucus
        );

        if (!success) {
            revert ISertnTaskManager.InsufficientFucusCapacity(
                task.operator,
                task.modelId,
                requiredFucus
            );
        }
    }

    /**
     * @notice Release FUCUs when a task is completed or rejected
     * @param taskId The ID of the task
     */
    function _releaseFucusForTask(uint256 taskId) internal {
        Task memory task = tasks[taskId];
        uint256 requiredFucus = modelRegistry.requiredFUCUs(task.modelId);

        // Release the allocated FUCUs
        sertnNodesManager.releaseFucusForTask(task.operator, task.modelId, requiredFucus);
    }

    // === TASK HISTORY HELPER FUNCTIONS ===

    /**
     * @notice Internal helper function to paginate an array of task IDs
     * @param taskArray Storage reference to the array to paginate
     * @param offset Starting index
     * @param limit Maximum number of results
     * @return Paginated array of task IDs
     */
    function _paginateTaskIds(
        uint256[] storage taskArray,
        uint256 offset,
        uint256 limit
    ) internal view returns (uint256[] memory) {
        if (offset >= taskArray.length) {
            return new uint256[](0);
        }

        uint256 end = offset + limit;
        if (end > taskArray.length) {
            end = taskArray.length;
        }

        uint256[] memory result = new uint256[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            result[i - offset] = taskArray[i];
        }
        return result;
    }

    /**
     * @notice Add a task to the history tracking mappings
     * @param taskId The ID of the task
     * @param task The task data
     */
    function _addTaskToHistory(uint256 taskId, Task memory task) internal {
        // Add to model history
        tasksByModel[task.modelId].push(taskId);

        // Add to operator history
        tasksByOperator[task.operator].push(taskId);

        // Add to user history
        tasksByUser[task.user].push(taskId);

        // Add to state history
        tasksByState[task.state].push(taskId);
        taskIndexInState[taskId][uint8(task.state)] = tasksByState[task.state].length - 1;
    }

    /**
     * @notice Update task state in history tracking
     * @param taskId The ID of the task
     * @param oldState The previous state
     * @param newState The new state
     */
    function _updateTaskStateInHistory(
        uint256 taskId,
        TaskState oldState,
        TaskState newState
    ) internal {
        // Remove from old state array
        uint256 oldIndex = taskIndexInState[taskId][uint8(oldState)];
        uint256[] storage oldStateArray = tasksByState[oldState];
        uint256 lastTaskId = oldStateArray[oldStateArray.length - 1];

        // Move last element to the position of the element to remove
        oldStateArray[oldIndex] = lastTaskId;
        taskIndexInState[lastTaskId][uint8(oldState)] = oldIndex;

        // Remove last element
        oldStateArray.pop();

        // Add to new state array
        tasksByState[newState].push(taskId);
        taskIndexInState[taskId][uint8(newState)] = tasksByState[newState].length - 1;
    }

    // === TASK HISTORY QUERY FUNCTIONS ===

    /**
     * @notice Get paginated task IDs for a specific model
     * @param modelId The model ID to query
     * @param offset Starting index
     * @param limit Maximum number of results
     * @return Array of task IDs (paginated)
     */
    function getTasksByModel(
        uint256 modelId,
        uint256 offset,
        uint256 limit
    ) external view returns (uint256[] memory) {
        return _paginateTaskIds(tasksByModel[modelId], offset, limit);
    }

    /**
     * @notice Get paginated task IDs for a specific operator
     * @param operator The operator address to query
     * @param offset Starting index
     * @param limit Maximum number of results
     * @return Array of task IDs (paginated)
     */
    function getTasksByOperator(
        address operator,
        uint256 offset,
        uint256 limit
    ) external view returns (uint256[] memory) {
        return _paginateTaskIds(tasksByOperator[operator], offset, limit);
    }

    /**
     * @notice Get paginated task IDs for a specific user
     * @param user The user address to query
     * @param offset Starting index
     * @param limit Maximum number of results
     * @return Array of task IDs (paginated)
     */
    function getTasksByUser(
        address user,
        uint256 offset,
        uint256 limit
    ) external view returns (uint256[] memory) {
        return _paginateTaskIds(tasksByUser[user], offset, limit);
    }

    /**
     * @notice Get all task IDs with a specific state
     * @param state The task state to query
     * @param offset Starting index
     * @param limit Maximum number of results
     * @return Array of task IDs (paginated)
     */
    function getTasksByState(
        TaskState state,
        uint256 offset,
        uint256 limit
    ) external view returns (uint256[] memory) {
        return _paginateTaskIds(tasksByState[state], offset, limit);
    }

    /**
     * @notice Get task history counts for overview statistics
     * @param modelId The model ID (0 for all models)
     * @param operator The operator address (address(0) for all operators)
     * @param user The user address (address(0) for all users)
     * @return totalTasks Total number of tasks matching criteria
     * @return resolvedTasks Number of completed/resolved tasks
     * @return rejectedTasks Number of rejected tasks
     * @return pendingTasksCount Number of pending/assigned/challenged tasks
     */
    function getTaskHistoryStats(
        uint256 modelId,
        address operator,
        address user
    )
        external
        view
        returns (
            uint256 totalTasks,
            uint256 resolvedTasks,
            uint256 rejectedTasks,
            uint256 pendingTasksCount
        )
    {
        // This is a simplified version - for more complex filtering,
        // you might need to iterate through tasks or use additional mappings
        if (modelId > 0) {
            totalTasks = tasksByModel[modelId].length;
        } else if (operator != address(0)) {
            totalTasks = tasksByOperator[operator].length;
        } else if (user != address(0)) {
            totalTasks = tasksByUser[user].length;
        } else {
            // Global stats
            totalTasks = taskNonce - 1; // -1 because nonce starts at 1
        }

        // For detailed stats, you would need to iterate through the tasks
        // This is a basic implementation
        resolvedTasks = tasksByState[TaskState.RESOLVED].length;
        rejectedTasks = tasksByState[TaskState.REJECTED].length;
        pendingTasksCount =
            tasksByState[TaskState.ASSIGNED].length +
            tasksByState[TaskState.CHALLENGED].length +
            tasksByState[TaskState.COMPLETED].length;
    }
}
