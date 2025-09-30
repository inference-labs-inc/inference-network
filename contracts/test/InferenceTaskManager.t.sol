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
import {InferenceTaskManager} from "../src/InferenceTaskManager.sol";
import {IInferenceTaskManager} from "../interfaces/IInferenceTaskManager.sol";
import {IInferenceServiceManager} from "../interfaces/IInferenceServiceManager.sol";
import {ModelRegistry} from "../src/ModelRegistry.sol";
import {IModelRegistry} from "../interfaces/IModelRegistry.sol";
import {MockVerifier} from "./mockContracts/VerifierMock.sol";
import {MockAllocationManager} from "./mockContracts/AllocationManagerMock.sol";
import {MockPauserRegistry} from "./mockContracts/PauserRegistryMock.sol";
import {MockInferenceServiceManager} from "./mockContracts/InferenceServiceManagerMock.sol";
import {InferenceNodesManagerMock} from "./mockContracts/InferenceNodesManagerMock.sol";
import {ERC20Mock} from "./mockContracts/ERC20Mock.sol";

import {Test, console2 as console} from "forge-std/Test.sol";

contract MockDelegationManager {
    // Empty implementation
}

contract MockRewardsCoordinator {
    // Empty implementation
}

contract InferenceTaskManagerTest is Test {
    InferenceTaskManager taskManager;
    MockAllocationManager mockAllocationManager;
    MockDelegationManager mockDelegationManager;
    MockRewardsCoordinator mockRewardsCoordinator;
    MockInferenceServiceManager mockServiceManager;
    InferenceNodesManagerMock mockNodesManager;
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
        mockServiceManager = new MockInferenceServiceManager();
        mockNodesManager = new InferenceNodesManagerMock();
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
        taskManager = new InferenceTaskManager();
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
        assertEq(address(taskManager.inferenceServiceManager()), address(mockServiceManager));
        assertEq(address(taskManager.modelRegistry()), address(modelRegistry));
        assertEq(taskManager.taskNonce(), 1); // Starts at 1
    }

    function test_sendTask_success() public {
        assertEq(taskManager.getPendingTasksIds().length, 0);

        IInferenceTaskManager.Task memory task = _createValidTask();

        vm.expectEmit(true, true, false, true);
        emit IInferenceTaskManager.TaskCreated(task.nonce, user);

        vm.expectEmit(true, true, false, true);
        emit IInferenceTaskManager.TaskAssigned(task.nonce, operator);

        vm.prank(aggregator);
        taskManager.sendTask(task);

        assertEq(taskManager.taskNonce(), task.nonce + 1);
        // check the task ID has been added to the pending list
        uint256[] memory expected_ids = new uint256[](1);
        expected_ids[0] = task.nonce;
        assertEq(taskManager.getPendingTasksIds(), expected_ids);

        IInferenceTaskManager.Task memory storedTask = taskManager.getTask(task.nonce);
        assertEq(uint8(storedTask.state), uint8(IInferenceTaskManager.TaskState.ASSIGNED));
        assertEq(storedTask.operator, operator);
        assertEq(storedTask.user, user);
        assertEq(storedTask.modelId, modelId);
    }

    function test_sendTask_revertNotAggregator() public {
        IInferenceTaskManager.Task memory task = _createValidTask();

        vm.expectRevert(IInferenceTaskManager.NotAggregator.selector);
        vm.prank(nonAggregator);
        taskManager.sendTask(task);
    }

    function test_sendTask_revertInvalidModelId() public {
        IInferenceTaskManager.Task memory task = _createValidTask();
        task.modelId = 999; // Invalid model ID

        vm.expectRevert(IInferenceTaskManager.InvalidModelId.selector);
        vm.prank(aggregator);
        taskManager.sendTask(task);
    }

    function test_getTask_revertTaskDoesNotExist() public {
        vm.expectRevert(IInferenceTaskManager.TaskDoesNotExist.selector);
        taskManager.getTask(999);
    }

    function test_submitTaskOutput_success() public {
        // First send a task
        IInferenceTaskManager.Task memory task = _createValidTask();
        vm.prank(aggregator);
        taskManager.sendTask(task);

        bytes memory output = "test output";

        vm.expectEmit(true, true, false, true);
        emit IInferenceTaskManager.TaskCompleted(task.nonce, operator);

        vm.prank(operator);
        taskManager.submitTaskOutput(task.nonce, output);

        assertEq(
            uint8(taskManager.getTask(task.nonce).state),
            uint8(IInferenceTaskManager.TaskState.COMPLETED)
        );
        assertEq(taskManager.getTask(task.nonce).output, output);
    }

    function test_submitTaskOutput_revertTaskDoesNotExist() public {
        vm.expectRevert(IInferenceTaskManager.TaskDoesNotExist.selector);
        vm.prank(operator);
        taskManager.submitTaskOutput(999, "output");
    }

    function test_submitTaskOutput_revertNotAssignedToTask() public {
        // Send a task assigned to operator
        IInferenceTaskManager.Task memory task = _createValidTask();
        vm.prank(aggregator);
        taskManager.sendTask(task);

        // Try to submit output from different address
        vm.expectRevert(IInferenceTaskManager.NotAssignedToTask.selector);
        vm.prank(user);
        taskManager.submitTaskOutput(0, "output");
    }

    function test_submitTaskOutput_revertTaskStateIncorrect() public {
        // Send and complete a task
        IInferenceTaskManager.Task memory task = _createValidTask();
        vm.prank(aggregator);
        taskManager.sendTask(task);

        vm.prank(operator);
        taskManager.submitTaskOutput(task.nonce, "output");

        // Try to submit output again
        vm.expectRevert(
            abi.encodeWithSelector(
                IInferenceTaskManager.TaskStateIncorrect.selector,
                IInferenceTaskManager.TaskState.COMPLETED
            )
        );
        vm.prank(operator);
        taskManager.submitTaskOutput(task.nonce, "output2");
    }

    function test_challengeTask_success() public {
        // Send and complete a task
        IInferenceTaskManager.Task memory task = _createValidTask();
        vm.prank(aggregator);
        taskManager.sendTask(task);

        vm.prank(operator);
        taskManager.submitTaskOutput(1, "output");

        vm.expectEmit(true, true, false, true);
        emit IInferenceTaskManager.TaskChallenged(1, aggregator);

        vm.prank(aggregator);
        taskManager.challengeTask(1);
    }

    function test_challengeTask_revertNotAggregator() public {
        vm.expectRevert(IInferenceTaskManager.NotAggregator.selector);
        vm.prank(nonAggregator);
        taskManager.challengeTask(0);
    }

    function test_challengeTask_revertTaskDoesNotExist() public {
        vm.expectRevert(IInferenceTaskManager.TaskDoesNotExist.selector);
        vm.prank(aggregator);
        taskManager.challengeTask(999);
    }

    function test_submitProofForTask_success() public {
        // Send, complete, and challenge a task
        IInferenceTaskManager.Task memory task = _createValidTask();
        vm.prank(aggregator);
        taskManager.sendTask(task);

        vm.prank(operator);
        taskManager.submitTaskOutput(task.nonce, "output");

        vm.prank(aggregator);
        taskManager.challengeTask(task.nonce);

        bytes memory proof = bytes("1");

        vm.expectEmit(true, false, false, true);
        emit IInferenceTaskManager.ProofSubmitted(task.nonce, keccak256(proof));

        vm.prank(operator);
        taskManager.submitProofForTask(task.nonce, proof);

        assertEq(
            uint8(taskManager.getTask(task.nonce).state),
            uint8(IInferenceTaskManager.TaskState.RESOLVED)
        );
    }

    function test_submitProofForTask_revertTaskDoesNotExist() public {
        vm.expectRevert(IInferenceTaskManager.TaskDoesNotExist.selector);
        vm.prank(operator);
        taskManager.submitProofForTask(999, "proof");
    }

    function test_submitProofForTask_revertNotAssignedToTask() public {
        // Send, complete, and challenge a task
        IInferenceTaskManager.Task memory task = _createValidTask();
        vm.prank(aggregator);
        taskManager.sendTask(task);

        vm.prank(operator);
        taskManager.submitTaskOutput(task.nonce, "output");

        vm.prank(aggregator);
        taskManager.challengeTask(task.nonce);

        vm.expectRevert(IInferenceTaskManager.NotAssignedToTask.selector);
        vm.prank(user);
        taskManager.submitProofForTask(task.nonce, "proof");
    }

    function test_submitProofForTask_revertTaskStateIncorrect() public {
        // Send a task but don't challenge it
        IInferenceTaskManager.Task memory task = _createValidTask();
        vm.prank(aggregator);
        taskManager.sendTask(task);

        vm.prank(operator);
        taskManager.submitTaskOutput(task.nonce, "output");

        vm.expectRevert(
            abi.encodeWithSelector(
                IInferenceTaskManager.TaskStateIncorrect.selector,
                IInferenceTaskManager.TaskState.CHALLENGED
            )
        );
        vm.prank(operator);
        taskManager.submitProofForTask(task.nonce, "proof");
    }

    function test_resolveTask_success() public {
        // Send, complete, and challenge a task
        IInferenceTaskManager.Task memory task = _createValidTask();
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
        emit IInferenceTaskManager.TaskResolved(task.nonce, operator);

        vm.prank(aggregator);
        taskManager.resolveTask(task.nonce, true);

        // check the task ID is not in the pending list anymore
        assertEq(taskManager.getPendingTasksIds().length, 0);

        assertEq(
            uint8(taskManager.getTask(task.nonce).state),
            uint8(IInferenceTaskManager.TaskState.RESOLVED)
        );
    }

    function test_resolveTask_reject() public {
        // Send, complete, and challenge a task
        IInferenceTaskManager.Task memory task = _createValidTask();
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
        emit IInferenceTaskManager.TaskRejected(task.nonce, operator);

        vm.prank(aggregator);
        taskManager.resolveTask(task.nonce, false);

        assertEq(
            uint8(taskManager.getTask(task.nonce).state),
            uint8(IInferenceTaskManager.TaskState.REJECTED)
        );

        // check the task ID is not in the pending list anymore
        assertEq(taskManager.getPendingTasksIds().length, 0);
    }

    function test_resolveTask_revertNotAggregator() public {
        vm.expectRevert(IInferenceTaskManager.NotAggregator.selector);
        vm.prank(nonAggregator);
        taskManager.resolveTask(0, true);
    }

    function test_resolveTask_revertTaskDoesNotExist() public {
        vm.expectRevert(IInferenceTaskManager.TaskDoesNotExist.selector);
        vm.prank(aggregator);
        taskManager.resolveTask(999, true);
    }

    function test_resolveTask_revertTaskStateIncorrect() public {
        // Send a task but don't challenge it
        IInferenceTaskManager.Task memory task = _createValidTask();
        vm.prank(aggregator);
        taskManager.sendTask(task);

        vm.expectRevert(
            abi.encodeWithSelector(
                IInferenceTaskManager.TaskStateIncorrect.selector,
                IInferenceTaskManager.TaskState.ASSIGNED
            )
        );
        vm.prank(aggregator);
        taskManager.resolveTask(task.nonce, true);
    }

    function test_taskNonceIncrementsCorrectly() public {
        IInferenceTaskManager.Task memory task = _createValidTask();

        assertEq(taskManager.taskNonce(), task.nonce);

        vm.prank(aggregator);
        taskManager.sendTask(task);
        assertEq(taskManager.taskNonce(), task.nonce + 1);

        vm.prank(aggregator);
        taskManager.sendTask(task);
        assertEq(taskManager.taskNonce(), task.nonce + 2);
    }

    // Helper function to create a valid task
    function _createValidTask() internal view returns (IInferenceTaskManager.Task memory) {
        return
            IInferenceTaskManager.Task({
                startBlock: block.number,
                startTimestamp: uint32(block.timestamp),
                modelId: modelId,
                inputs: "test inputs",
                proofHash: "",
                user: user,
                nonce: 1,
                operator: operator,
                state: IInferenceTaskManager.TaskState.CREATED,
                output: "",
                fee: 1000
            });
    }
}
