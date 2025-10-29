// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import {Test, console2 as console} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@eigenlayer/contracts/permissions/Pausable.sol";
import {StrategyBase} from "@eigenlayer/contracts/strategies/StrategyBase.sol";
import {IStrategyManager} from "@eigenlayer/contracts/interfaces/IStrategyManager.sol";
import {IStrategy} from "@eigenlayer/contracts/interfaces/IStrategy.sol";
import "@eigenlayer/contracts/libraries/OperatorSetLib.sol";
import {SertnTaskManager} from "../src/SertnTaskManager.sol";
import {ISertnTaskManager} from "../interfaces/ISertnTaskManager.sol";
import {ISertnServiceManager} from "../interfaces/ISertnServiceManager.sol";
import {ModelRegistry} from "../src/ModelRegistry.sol";
import {IModelRegistry} from "../interfaces/IModelRegistry.sol";
import {MockVerifier} from "./mockContracts/VerifierMock.sol";
import {MockAllocationManager} from "./mockContracts/AllocationManagerMock.sol";
import {MockPauserRegistry} from "./mockContracts/PauserRegistryMock.sol";
import {MockSertnServiceManager} from "./mockContracts/SertnServiceManagerMock.sol";
import {SertnNodesManagerMock} from "./mockContracts/SertnNodesManagerMock.sol";
import {ERC20Mock} from "./mockContracts/ERC20Mock.sol";

import {Test, console2 as console} from "forge-std/Test.sol";

contract MockDelegationManager {
    // Empty implementation
}

contract MockRewardsCoordinator {
    // Empty implementation
}

contract SertnTaskManagerTest is Test {
    SertnTaskManager taskManager;
    MockAllocationManager mockAllocationManager;
    MockDelegationManager mockDelegationManager;
    MockRewardsCoordinator mockRewardsCoordinator;
    MockSertnServiceManager mockServiceManager;
    SertnNodesManagerMock mockNodesManager;
    ModelRegistry modelRegistry;
    MockVerifier mockVerifier;
    ERC20Mock mockToken;
    StrategyBase mockStrategy;

    address owner = vm.addr(1);
    address aggregator = vm.addr(2);
    address operator = vm.addr(3);
    address user = vm.addr(4);
    address nonAggregator = vm.addr(5);

    uint256 modelId;

    function setUp() public {
        vm.startPrank(owner);

        // Deploy mock contracts
        mockAllocationManager = new MockAllocationManager();
        mockDelegationManager = new MockDelegationManager();
        mockRewardsCoordinator = new MockRewardsCoordinator();
        mockServiceManager = new MockSertnServiceManager();
        mockNodesManager = new SertnNodesManagerMock();
        mockToken = new ERC20Mock();
        mockStrategy = new StrategyBase(
            IStrategyManager(address(0)),
            IPauserRegistry(address(new MockPauserRegistry())),
            "0"
        );
        // mockStrategy.initialize(ERC20(address(mockToken)));

        // Deploy and initialize ModelRegistry
        modelRegistry = new ModelRegistry();
        modelRegistry.initialize();

        mockVerifier = new MockVerifier();

        // Create a model for testing
        modelId = modelRegistry.createNewModel(
            address(mockVerifier),
            IModelRegistry.VerificationStrategy.Onchain,
            "test_model",
            100,
            10
        );

        // Deploy and initialize TaskManager
        taskManager = new SertnTaskManager();
        taskManager.initialize(
            address(mockRewardsCoordinator),
            address(mockDelegationManager),
            address(mockAllocationManager),
            address(mockServiceManager),
            address(modelRegistry),
            address(mockNodesManager)
        );

        // Setup mock data
        mockServiceManager.addAggregator(aggregator);

        // Setup allocation data for operator
        OperatorSet[] memory sets = new OperatorSet[](1);
        sets[0] = OperatorSet({id: 1, avs: address(0)});
        mockAllocationManager.setAllocatedSets(operator, sets);

        IStrategy[] memory strategies = new IStrategy[](1);
        strategies[0] = mockStrategy;
        mockAllocationManager.setAllocatedStrategies(operator, sets[0], strategies);

        vm.stopPrank();
    }

    function test_initialize() public view {
        assertEq(address(taskManager.allocationManager()), address(mockAllocationManager));
        assertEq(address(taskManager.delegationManager()), address(mockDelegationManager));
        assertEq(address(taskManager.rewardsCoordinator()), address(mockRewardsCoordinator));
        assertEq(address(taskManager.sertnServiceManager()), address(mockServiceManager));
        assertEq(address(taskManager.modelRegistry()), address(modelRegistry));
        assertEq(taskManager.taskNonce(), 1); // Starts at 1
    }

    function test_sendTask_success() public {
        assertEq(taskManager.getPendingTasksIds().length, 0);

        ISertnTaskManager.Task memory task = _createValidTask();

        vm.expectEmit(true, true, false, true);
        emit ISertnTaskManager.TaskCreated(task.nonce, user);

        vm.expectEmit(true, true, false, true);
        emit ISertnTaskManager.TaskAssigned(task.nonce, operator);

        vm.prank(aggregator);
        taskManager.sendTask(task);

        assertEq(taskManager.taskNonce(), task.nonce + 1);
        // check the task ID has been added to the pending list
        uint256[] memory expected_ids = new uint256[](1);
        expected_ids[0] = task.nonce;
        assertEq(taskManager.getPendingTasksIds(), expected_ids);

        ISertnTaskManager.Task memory storedTask = taskManager.getTask(task.nonce);
        assertEq(uint8(storedTask.state), uint8(ISertnTaskManager.TaskState.ASSIGNED));
        assertEq(storedTask.operator, operator);
        assertEq(storedTask.user, user);
        assertEq(storedTask.modelId, modelId);
    }

    function test_sendTask_revertNotAggregator() public {
        ISertnTaskManager.Task memory task = _createValidTask();

        vm.expectRevert(ISertnTaskManager.NotAggregator.selector);
        vm.prank(nonAggregator);
        taskManager.sendTask(task);
    }

    function test_sendTask_revertInvalidModelId() public {
        ISertnTaskManager.Task memory task = _createValidTask();
        task.modelId = 999; // Invalid model ID

        vm.expectRevert(ISertnTaskManager.InvalidModelId.selector);
        vm.prank(aggregator);
        taskManager.sendTask(task);
    }

    function test_getTask_revertTaskDoesNotExist() public {
        vm.expectRevert(ISertnTaskManager.TaskDoesNotExist.selector);
        taskManager.getTask(999);
    }

    function test_submitTaskOutput_success() public {
        // First send a task
        ISertnTaskManager.Task memory task = _createValidTask();
        vm.prank(aggregator);
        taskManager.sendTask(task);

        bytes memory output = "test output";

        vm.expectEmit(true, true, false, true);
        emit ISertnTaskManager.TaskCompleted(task.nonce, operator);

        vm.prank(operator);
        taskManager.submitTaskOutput(task.nonce, output);

        assertEq(
            uint8(taskManager.getTask(task.nonce).state),
            uint8(ISertnTaskManager.TaskState.COMPLETED)
        );
        assertEq(taskManager.getTask(task.nonce).output, output);
    }

    function test_submitTaskOutput_revertTaskDoesNotExist() public {
        vm.expectRevert(ISertnTaskManager.TaskDoesNotExist.selector);
        vm.prank(operator);
        taskManager.submitTaskOutput(999, "output");
    }

    function test_submitTaskOutput_revertNotAssignedToTask() public {
        // Send a task assigned to operator
        ISertnTaskManager.Task memory task = _createValidTask();
        vm.prank(aggregator);
        taskManager.sendTask(task);

        // Try to submit output from different address
        vm.expectRevert(ISertnTaskManager.NotAssignedToTask.selector);
        vm.prank(user);
        taskManager.submitTaskOutput(0, "output");
    }

    function test_submitTaskOutput_revertTaskStateIncorrect() public {
        // Send and complete a task
        ISertnTaskManager.Task memory task = _createValidTask();
        vm.prank(aggregator);
        taskManager.sendTask(task);

        vm.prank(operator);
        taskManager.submitTaskOutput(task.nonce, "output");

        // Try to submit output again
        vm.expectRevert(
            abi.encodeWithSelector(
                ISertnTaskManager.TaskStateIncorrect.selector,
                ISertnTaskManager.TaskState.COMPLETED
            )
        );
        vm.prank(operator);
        taskManager.submitTaskOutput(task.nonce, "output2");
    }

    function test_challengeTask_success() public {
        // Send and complete a task
        ISertnTaskManager.Task memory task = _createValidTask();
        vm.prank(aggregator);
        taskManager.sendTask(task);

        vm.prank(operator);
        taskManager.submitTaskOutput(1, "output");

        vm.expectEmit(true, true, false, true);
        emit ISertnTaskManager.TaskChallenged(1, aggregator);

        vm.prank(aggregator);
        taskManager.challengeTask(1);
    }

    function test_challengeTask_revertNotAggregator() public {
        vm.expectRevert(ISertnTaskManager.NotAggregator.selector);
        vm.prank(nonAggregator);
        taskManager.challengeTask(0);
    }

    function test_challengeTask_revertTaskDoesNotExist() public {
        vm.expectRevert(ISertnTaskManager.TaskDoesNotExist.selector);
        vm.prank(aggregator);
        taskManager.challengeTask(999);
    }

    function test_submitProofForTask_success() public {
        // Send, complete, and challenge a task
        ISertnTaskManager.Task memory task = _createValidTask();
        vm.prank(aggregator);
        taskManager.sendTask(task);

        vm.prank(operator);
        taskManager.submitTaskOutput(task.nonce, "output");

        vm.prank(aggregator);
        taskManager.challengeTask(task.nonce);

        bytes memory proof = bytes("1");

        vm.expectEmit(true, false, false, true);
        emit ISertnTaskManager.ProofSubmitted(task.nonce, keccak256(proof));

        vm.prank(operator);
        taskManager.submitProofForTask(task.nonce, proof);

        assertEq(
            uint8(taskManager.getTask(task.nonce).state),
            uint8(ISertnTaskManager.TaskState.RESOLVED)
        );
    }

    function test_submitProofForTask_revertTaskDoesNotExist() public {
        vm.expectRevert(ISertnTaskManager.TaskDoesNotExist.selector);
        vm.prank(operator);
        taskManager.submitProofForTask(999, "proof");
    }

    function test_submitProofForTask_revertNotAssignedToTask() public {
        // Send, complete, and challenge a task
        ISertnTaskManager.Task memory task = _createValidTask();
        vm.prank(aggregator);
        taskManager.sendTask(task);

        vm.prank(operator);
        taskManager.submitTaskOutput(task.nonce, "output");

        vm.prank(aggregator);
        taskManager.challengeTask(task.nonce);

        vm.expectRevert(ISertnTaskManager.NotAssignedToTask.selector);
        vm.prank(user);
        taskManager.submitProofForTask(task.nonce, "proof");
    }

    function test_submitProofForTask_revertTaskStateIncorrect() public {
        // Send a task but don't challenge it
        ISertnTaskManager.Task memory task = _createValidTask();
        vm.prank(aggregator);
        taskManager.sendTask(task);

        vm.prank(operator);
        taskManager.submitTaskOutput(task.nonce, "output");

        vm.expectRevert(
            abi.encodeWithSelector(
                ISertnTaskManager.TaskStateIncorrect.selector,
                ISertnTaskManager.TaskState.CHALLENGED
            )
        );
        vm.prank(operator);
        taskManager.submitProofForTask(task.nonce, "proof");
    }

    function test_resolveTask_success() public {
        // Send, complete, and challenge a task
        ISertnTaskManager.Task memory task = _createValidTask();
        vm.prank(aggregator);
        taskManager.sendTask(task);

        vm.prank(operator);
        taskManager.submitTaskOutput(task.nonce, "output");

        vm.prank(aggregator);
        taskManager.challengeTask(task.nonce);

        // check the task ID sill in the pending list
        uint256[] memory expected_ids = new uint256[](1);
        expected_ids[0] = task.nonce;
        assertEq(taskManager.getPendingTasksIds(), expected_ids);

        vm.expectEmit(true, true, false, true);
        emit ISertnTaskManager.TaskResolved(task.nonce, operator);

        vm.prank(aggregator);
        taskManager.resolveTask(task.nonce, true);

        // check the task ID is not in the pending list anymore
        assertEq(taskManager.getPendingTasksIds().length, 0);

        assertEq(
            uint8(taskManager.getTask(task.nonce).state),
            uint8(ISertnTaskManager.TaskState.RESOLVED)
        );
    }

    function test_resolveTask_reject() public {
        // Send, complete, and challenge a task
        ISertnTaskManager.Task memory task = _createValidTask();
        vm.prank(aggregator);
        taskManager.sendTask(task);

        vm.prank(operator);
        taskManager.submitTaskOutput(task.nonce, "output");

        vm.prank(aggregator);
        taskManager.challengeTask(task.nonce);

        // check the task ID sill in the pending list
        uint256[] memory expected_ids = new uint256[](1);
        expected_ids[0] = task.nonce;
        assertEq(taskManager.getPendingTasksIds(), expected_ids);

        vm.expectEmit(true, true, false, true);
        emit ISertnTaskManager.TaskRejected(task.nonce, operator);

        vm.prank(aggregator);
        taskManager.resolveTask(task.nonce, false);

        assertEq(
            uint8(taskManager.getTask(task.nonce).state),
            uint8(ISertnTaskManager.TaskState.REJECTED)
        );

        // check the task ID is not in the pending list anymore
        assertEq(taskManager.getPendingTasksIds().length, 0);
    }

    function test_resolveTask_revertNotAggregator() public {
        vm.expectRevert(ISertnTaskManager.NotAggregator.selector);
        vm.prank(nonAggregator);
        taskManager.resolveTask(0, true);
    }

    function test_resolveTask_revertTaskDoesNotExist() public {
        vm.expectRevert(ISertnTaskManager.TaskDoesNotExist.selector);
        vm.prank(aggregator);
        taskManager.resolveTask(999, true);
    }

    function test_resolveTask_revertTaskStateIncorrect() public {
        // Send a task but don't challenge it
        ISertnTaskManager.Task memory task = _createValidTask();
        vm.prank(aggregator);
        taskManager.sendTask(task);

        vm.expectRevert(
            abi.encodeWithSelector(
                ISertnTaskManager.TaskStateIncorrect.selector,
                ISertnTaskManager.TaskState.ASSIGNED
            )
        );
        vm.prank(aggregator);
        taskManager.resolveTask(task.nonce, true);
    }

    function test_taskNonceIncrementsCorrectly() public {
        ISertnTaskManager.Task memory task = _createValidTask();

        assertEq(taskManager.taskNonce(), task.nonce);

        vm.prank(aggregator);
        taskManager.sendTask(task);
        assertEq(taskManager.taskNonce(), task.nonce + 1);

        vm.prank(aggregator);
        taskManager.sendTask(task);
        assertEq(taskManager.taskNonce(), task.nonce + 2);
    }

    // === HISTORY TESTS ===

    function test_getTasksByModel() public {
        // Create a second model for testing
        vm.startPrank(owner);
        uint256 modelId2 = modelRegistry.createNewModel(
            address(new MockVerifier()),
            IModelRegistry.VerificationStrategy.Onchain,
            "test_model_2",
            200,
            20
        );
        vm.stopPrank();

        // Send tasks for both models
        ISertnTaskManager.Task memory task1 = _createValidTask();
        vm.prank(aggregator);
        taskManager.sendTask(task1);

        ISertnTaskManager.Task memory task2 = _createValidTask();
        task2.modelId = modelId2;
        task2.nonce = 2;
        vm.prank(aggregator);
        taskManager.sendTask(task2);

        ISertnTaskManager.Task memory task3 = _createValidTask();
        task3.nonce = 3;
        vm.prank(aggregator);
        taskManager.sendTask(task3);

        // Get tasks for first model (should have 2 tasks: task1 and task3)
        uint256[] memory tasksModel1 = taskManager.getTasksByModel(modelId, 0, 10);
        assertEq(tasksModel1.length, 2, "Model 1 should have 2 tasks");
        assertTrue(
            (tasksModel1[0] == 1 && tasksModel1[1] == 3) ||
                (tasksModel1[0] == 3 && tasksModel1[1] == 1),
            "Should contain correct task IDs for model 1"
        );

        // Get tasks for second model (should have 1 task: task2)
        uint256[] memory tasksModel2 = taskManager.getTasksByModel(modelId2, 0, 10);
        assertEq(tasksModel2.length, 1, "Model 2 should have 1 task");
        assertEq(tasksModel2[0], 2, "Should contain correct task ID for model 2");
    }

    function test_getTasksByModel_pagination() public {
        // Send 5 tasks with the same model
        for (uint256 i = 0; i < 5; i++) {
            ISertnTaskManager.Task memory task = _createValidTask();
            task.nonce = i + 1;
            vm.prank(aggregator);
            taskManager.sendTask(task);
        }

        // Test pagination - first page (limit 3)
        uint256[] memory page1 = taskManager.getTasksByModel(modelId, 0, 3);
        assertEq(page1.length, 3, "First page should have 3 items");
        assertEq(page1[0], 5, "First item should be task 5");
        assertEq(page1[1], 4, "Second item should be task 4");
        assertEq(page1[2], 3, "Third item should be task 3");

        // Test pagination - second page (offset 3, limit 3)
        uint256[] memory page2 = taskManager.getTasksByModel(modelId, 3, 3);
        assertEq(page2.length, 2, "Second page should have 2 remaining items");
        assertEq(page2[0], 2, "First item on page 2 should be task 2");
        assertEq(page2[1], 1, "Second item on page 2 should be task 1");

        // Test pagination - beyond available data
        uint256[] memory page3 = taskManager.getTasksByModel(modelId, 10, 3);
        assertEq(page3.length, 0, "Should return empty array when offset is beyond data");
    }

    function test_getTasksByOperator() public {
        address operator2 = vm.addr(100);

        // Setup allocation for second operator
        vm.startPrank(owner);
        OperatorSet[] memory sets = new OperatorSet[](1);
        sets[0] = OperatorSet({id: 2, avs: address(0)});
        mockAllocationManager.setAllocatedSets(operator2, sets);

        IStrategy[] memory strategies = new IStrategy[](1);
        strategies[0] = mockStrategy;
        mockAllocationManager.setAllocatedStrategies(operator2, sets[0], strategies);
        vm.stopPrank();

        // Send tasks for different operators
        ISertnTaskManager.Task memory task1 = _createValidTask();
        vm.prank(aggregator);
        taskManager.sendTask(task1);

        ISertnTaskManager.Task memory task2 = _createValidTask();
        task2.operator = operator2;
        task2.nonce = 2;
        vm.prank(aggregator);
        taskManager.sendTask(task2);

        ISertnTaskManager.Task memory task3 = _createValidTask();
        task3.nonce = 3;
        vm.prank(aggregator);
        taskManager.sendTask(task3);

        // Get tasks for first operator (should have 2 tasks)
        uint256[] memory tasksOp1 = taskManager.getTasksByOperator(operator, 0, 10);
        assertEq(tasksOp1.length, 2, "Operator 1 should have 2 tasks");

        // Get tasks for second operator (should have 1 task)
        uint256[] memory tasksOp2 = taskManager.getTasksByOperator(operator2, 0, 10);
        assertEq(tasksOp2.length, 1, "Operator 2 should have 1 task");
        assertEq(tasksOp2[0], 2, "Should contain correct task ID for operator 2");

        // Get tasks for an operator with no tasks
        address unknownOperator = vm.addr(999);
        uint256[] memory tasks = taskManager.getTasksByOperator(unknownOperator, 0, 10);
        assertEq(tasks.length, 0, "Should return empty array for operator with no tasks");
    }

    function test_getTasksByUser() public {
        address user2 = vm.addr(200);

        // Send tasks for different users
        ISertnTaskManager.Task memory task1 = _createValidTask();
        vm.prank(aggregator);
        taskManager.sendTask(task1);

        ISertnTaskManager.Task memory task2 = _createValidTask();
        task2.user = user2;
        task2.nonce = 2;
        vm.prank(aggregator);
        taskManager.sendTask(task2);

        ISertnTaskManager.Task memory task3 = _createValidTask();
        task3.nonce = 3;
        vm.prank(aggregator);
        taskManager.sendTask(task3);

        // Get tasks for first user (should have 2 tasks)
        uint256[] memory tasksUser1 = taskManager.getTasksByUser(user, 0, 10);
        assertEq(tasksUser1.length, 2, "User 1 should have 2 tasks");

        // Get tasks for second user (should have 1 task)
        uint256[] memory tasksUser2 = taskManager.getTasksByUser(user2, 0, 10);
        assertEq(tasksUser2.length, 1, "User 2 should have 1 task");
        assertEq(tasksUser2[0], 2, "Should contain correct task ID for user 2");

        // Get tasks for an user with no tasks
        address unknownUser = vm.addr(999);
        uint256[] memory tasks = taskManager.getTasksByUser(unknownUser, 0, 10);
        assertEq(tasks.length, 0, "Should return empty array for user with no tasks");
    }

    function test_getTasksByState_assigned() public {
        // Send tasks with different states
        ISertnTaskManager.Task memory task1 = _createValidTask();
        vm.prank(aggregator);
        taskManager.sendTask(task1); // This will be in ASSIGNED state

        ISertnTaskManager.Task memory task2 = _createValidTask();
        task2.nonce = 2;
        vm.prank(aggregator);
        taskManager.sendTask(task2); // This will be in ASSIGNED state

        // Get tasks in ASSIGNED state (should be 2)
        uint256[] memory assignedTasks = taskManager.getTasksByState(
            ISertnTaskManager.TaskState.ASSIGNED,
            0,
            10
        );
        assertEq(assignedTasks.length, 2, "Should have 2 task in ASSIGNED state");

        // Complete one task
        vm.prank(operator);
        taskManager.submitTaskOutput(1, "output");

        // Get tasks in ASSIGNED state (should be 1)
        assignedTasks = taskManager.getTasksByState(ISertnTaskManager.TaskState.ASSIGNED, 0, 10);
        assertEq(assignedTasks.length, 1, "Should have 1 task in ASSIGNED state");
        assertEq(assignedTasks[0], 2, "Task 2 should be in ASSIGNED state");

        // Get tasks in COMPLETED state (should be 1)
        uint256[] memory completedTasks = taskManager.getTasksByState(
            ISertnTaskManager.TaskState.COMPLETED,
            0,
            10
        );
        assertEq(completedTasks.length, 1, "Should have 1 task in COMPLETED state");
        assertEq(completedTasks[0], 1, "Task 1 should be in COMPLETED state");

        // Get tasks in REJECTED state (should be 0)
        uint256[] memory rejectedTasks = taskManager.getTasksByState(
            ISertnTaskManager.TaskState.REJECTED,
            0,
            10
        );
        assertEq(rejectedTasks.length, 0, "Should have 0 tasks in REJECTED state");
    }

    function test_getTaskHistoryStats_global() public {
        // Send and process several tasks with different outcomes

        // Task 1: Send and resolve
        ISertnTaskManager.Task memory task1 = _createValidTask();
        task1.nonce = 1;
        vm.prank(aggregator);
        taskManager.sendTask(task1);

        vm.prank(operator);
        taskManager.submitTaskOutput(task1.nonce, "output1");

        vm.prank(aggregator);
        taskManager.challengeTask(task1.nonce);

        vm.prank(aggregator);
        taskManager.resolveTask(task1.nonce, true); // RESOLVED

        // Task 2: Send and reject
        ISertnTaskManager.Task memory task2 = _createValidTask();
        task2.nonce = 2;
        vm.prank(aggregator);
        taskManager.sendTask(task2);

        vm.prank(operator);
        taskManager.submitTaskOutput(2, "output2");

        vm.prank(aggregator);
        taskManager.challengeTask(2);

        vm.prank(aggregator);
        taskManager.resolveTask(2, false); // REJECTED

        // Task 3: Send and leave pending
        ISertnTaskManager.Task memory task3 = _createValidTask();
        task3.nonce = 3;
        vm.prank(aggregator);
        taskManager.sendTask(task3); // ASSIGNED (pending)

        // Get global stats (all parameters zero/null)
        (
            uint256 totalTasks,
            uint256 resolvedTasks,
            uint256 rejectedTasks,
            uint256 pendingTasksCount
        ) = taskManager.getTaskHistoryStats();

        assertEq(totalTasks, 3, "Should have 3 total tasks");
        assertEq(resolvedTasks, 1, "Should have 1 resolved task");
        assertEq(rejectedTasks, 1, "Should have 1 rejected task");
        assertEq(pendingTasksCount, 1, "Should have 1 pending task");
    }

    function test_task_history_tracking_on_send() public {
        // Send a task and verify it's tracked in all relevant mappings
        ISertnTaskManager.Task memory task = _createValidTask();
        vm.prank(aggregator);
        taskManager.sendTask(task);

        // Verify task is in model history
        uint256[] memory modelTasks = taskManager.getTasksByModel(modelId, 0, 10);
        assertEq(modelTasks.length, 1, "Task should be tracked in model history");
        assertEq(modelTasks[0], 1, "Task ID should match");

        // Verify task is in operator history
        uint256[] memory operatorTasks = taskManager.getTasksByOperator(operator, 0, 10);
        assertEq(operatorTasks.length, 1, "Task should be tracked in operator history");
        assertEq(operatorTasks[0], 1, "Task ID should match");

        // Verify task is in user history
        uint256[] memory userTasks = taskManager.getTasksByUser(user, 0, 10);
        assertEq(userTasks.length, 1, "Task should be tracked in user history");
        assertEq(userTasks[0], 1, "Task ID should match");

        // Verify task is in state history
        uint256[] memory stateTasks = taskManager.getTasksByState(
            ISertnTaskManager.TaskState.ASSIGNED,
            0,
            10
        );
        assertEq(stateTasks.length, 1, "Task should be tracked in state history");
        assertEq(stateTasks[0], 1, "Task ID should match");
    }

    function test_pagination_edge_cases() public {
        // Test empty results with various offset/limit combinations
        uint256[] memory empty1 = taskManager.getTasksByModel(modelId, 0, 0);
        assertEq(empty1.length, 0, "Should return empty array with limit 0");

        uint256[] memory empty2 = taskManager.getTasksByModel(modelId, 100, 10);
        assertEq(empty2.length, 0, "Should return empty array with high offset");

        // Send one task
        ISertnTaskManager.Task memory task = _createValidTask();
        vm.prank(aggregator);
        taskManager.sendTask(task);

        // Test with offset equal to array length
        uint256[] memory edge1 = taskManager.getTasksByModel(modelId, 1, 10);
        assertEq(edge1.length, 0, "Should return empty array when offset equals array length");

        // Test with limit larger than remaining items
        uint256[] memory edge2 = taskManager.getTasksByModel(modelId, 0, 100);
        assertEq(edge2.length, 1, "Should return all available items when limit is larger");
    }

    // Helper function to create a valid task
    function _createValidTask() internal view returns (ISertnTaskManager.Task memory) {
        return
            ISertnTaskManager.Task({
                startBlock: block.number,
                startTimestamp: uint32(block.timestamp),
                modelId: modelId,
                inputs: "test inputs",
                proofHash: "",
                user: user,
                nonce: 1,
                operator: operator,
                state: ISertnTaskManager.TaskState.CREATED,
                output: "",
                fee: 1000
            });
    }
}
