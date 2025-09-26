// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import {Test, console2 as console} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {SertnServiceManager} from "../src/SertnServiceManager.sol";
import {ISertnServiceManager} from "../interfaces/ISertnServiceManager.sol";
import {ISertnTaskManager} from "../interfaces/ISertnTaskManager.sol";
import {IModelRegistry} from "../interfaces/IModelRegistry.sol";
import {ModelRegistry} from "../src/ModelRegistry.sol";
import {MockVerifier} from "./mockContracts/VerifierMock.sol";
import {ERC20Mock} from "./mockContracts/ERC20Mock.sol";
import {MockAllocationManager} from "./mockContracts/AllocationManagerMock.sol";
import {MockSertnTaskManager} from "./mockContracts/SertnTaskManagerMock.sol";
import {IStrategy} from "@eigenlayer/contracts/interfaces/IStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IRewardsCoordinator, IRewardsCoordinatorTypes} from "@eigenlayer/contracts/interfaces/IRewardsCoordinator.sol";

contract MockDelegationManager {
    // Empty implementation for testing
}

contract MockRewardsCoordinator {
    uint32 public constant CALCULATION_INTERVAL_SECONDS = 604800; // 1 week

    mapping(address => mapping(address => uint256)) public allowances;

    function createOperatorDirectedAVSRewardsSubmission(
        address avs,
        IRewardsCoordinatorTypes.OperatorDirectedRewardsSubmission[] memory submissions
    ) external view {
        // Mock implementation - just check allowances
        for (uint256 i = 0; i < submissions.length; i++) {
            uint256 totalAmount = 0;
            for (uint256 j = 0; j < submissions[i].operatorRewards.length; j++) {
                totalAmount += submissions[i].operatorRewards[j].amount;
            }
            require(
                submissions[i].token.allowance(msg.sender, address(this)) >= totalAmount,
                "Insufficient allowance"
            );
        }
    }
}

contract MockStrategy {
    address public underlyingToken;

    constructor(address _token) {
        underlyingToken = _token;
    }
}

contract MockSertnRegistrar {
    // Empty implementation for testing
}

contract SertnServiceManagerTest is Test {
    SertnServiceManager serviceManager;
    MockAllocationManager mockAllocationManager;
    MockDelegationManager mockDelegationManager;
    MockRewardsCoordinator mockRewardsCoordinator;
    MockSertnTaskManager mockTaskManager;
    MockSertnRegistrar mockRegistrar;
    ModelRegistry modelRegistry;
    MockVerifier mockVerifier;
    ERC20Mock mockToken1;
    ERC20Mock mockToken2;
    MockStrategy mockStrategy1;
    MockStrategy mockStrategy2;

    address owner = vm.addr(1);
    address aggregator1 = vm.addr(2);
    address aggregator2 = vm.addr(3);
    address operator = vm.addr(4);
    address user = vm.addr(5);
    address nonOwner = vm.addr(6);

    IStrategy[] strategies;
    string constant AVS_METADATA = "test_metadata_uri";

    function setUp() public {
        vm.startPrank(owner);
        // Deploy mock contracts
        mockAllocationManager = new MockAllocationManager();
        mockDelegationManager = new MockDelegationManager();
        mockRewardsCoordinator = new MockRewardsCoordinator();
        mockTaskManager = new MockSertnTaskManager();
        mockRegistrar = new MockSertnRegistrar();
        // Deploy tokens and strategies
        mockToken1 = new ERC20Mock();
        mockToken2 = new ERC20Mock();
        mockStrategy1 = new MockStrategy(address(mockToken1));
        mockStrategy2 = new MockStrategy(address(mockToken2));
        strategies.push(IStrategy(address(mockStrategy1)));
        strategies.push(IStrategy(address(mockStrategy2)));
        // Deploy and initialize ModelRegistry
        modelRegistry = new ModelRegistry();
        modelRegistry.initialize();
        mockVerifier = new MockVerifier();
        // Deploy and initialize ServiceManager
        serviceManager = new SertnServiceManager();
        serviceManager.initialize(
            address(mockRewardsCoordinator),
            address(mockDelegationManager),
            address(mockAllocationManager),
            address(mockRegistrar),
            strategies,
            AVS_METADATA
        );
        // Update references
        serviceManager.updateTaskManager(address(mockTaskManager));
        serviceManager.updateModelRegistry(address(modelRegistry));
        console.log("References updated in SertnServiceManager");
        vm.stopPrank();
    }

    function test_initialize() public view {
        assertEq(address(serviceManager.allocationManager()), address(mockAllocationManager));
        assertEq(address(serviceManager.delegationManager()), address(mockDelegationManager));
        assertEq(address(serviceManager.rewardsCoordinator()), address(mockRewardsCoordinator));
        assertEq(address(serviceManager.sertnTaskManager()), address(mockTaskManager));
        assertEq(address(serviceManager.modelRegistry()), address(modelRegistry));
        assertEq(address(serviceManager.sertnRegistrar()), address(mockRegistrar));

        // Check that owner is automatically added as aggregator
        assertTrue(serviceManager.isAggregator(owner));
    }

    function test_updateTaskManager_success() public {
        address newTaskManager = vm.addr(100);

        vm.prank(owner);
        serviceManager.updateTaskManager(newTaskManager);

        assertEq(address(serviceManager.sertnTaskManager()), newTaskManager);
    }

    function test_updateTaskManager_revertZeroAddress() public {
        vm.expectRevert(ISertnServiceManager.ZeroAddress.selector);
        vm.prank(owner);
        serviceManager.updateTaskManager(address(0));
    }

    function test_updateTaskManager_revertNotOwner() public {
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(nonOwner);
        serviceManager.updateTaskManager(vm.addr(100));
    }

    function test_updateModelRegistry_success() public {
        address newModelRegistry = vm.addr(101);

        vm.prank(owner);
        serviceManager.updateModelRegistry(newModelRegistry);

        assertEq(address(serviceManager.modelRegistry()), newModelRegistry);
    }

    function test_updateModelRegistry_revertZeroAddress() public {
        vm.expectRevert(ISertnServiceManager.ZeroAddress.selector);
        vm.prank(owner);
        serviceManager.updateModelRegistry(address(0));
    }

    function test_updateModelRegistry_revertNotOwner() public {
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(nonOwner);
        serviceManager.updateModelRegistry(vm.addr(101));
    }

    function test_addAggregator_success() public {
        assertFalse(serviceManager.isAggregator(aggregator1));
        vm.prank(owner);
        serviceManager.addAggregator(aggregator1);
        assertTrue(serviceManager.isAggregator(aggregator1));
    }

    function test_addAggregator_revertZeroAddress() public {
        vm.expectRevert(ISertnServiceManager.ZeroAddress.selector);
        vm.prank(owner);
        serviceManager.addAggregator(address(0));
    }

    function test_addAggregator_revertAlreadyExists() public {
        vm.startPrank(owner);
        serviceManager.addAggregator(aggregator1);

        vm.expectRevert(ISertnServiceManager.AggregatorAlreadyExists.selector);
        serviceManager.addAggregator(aggregator1);
        vm.stopPrank();
    }

    function test_addAggregator_revertNotOwner() public {
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(nonOwner);
        serviceManager.addAggregator(aggregator1);
    }

    function test_removeAggregator_success() public {
        vm.startPrank(owner);

        // Add multiple aggregators
        serviceManager.addAggregator(aggregator1);
        serviceManager.addAggregator(aggregator2);

        // Remove aggregator1
        serviceManager.removeAggregator(aggregator1);

        assertFalse(serviceManager.isAggregator(aggregator1));
        assertTrue(serviceManager.isAggregator(aggregator2));

        vm.stopPrank();
    }

    function test_removeAggregator_revertNotAggregator() public {
        vm.expectRevert(ISertnServiceManager.NotAggregator.selector);
        vm.prank(owner);
        serviceManager.removeAggregator(aggregator1);
    }

    function test_removeAggregator_revertNotOwner() public {
        vm.startPrank(owner);
        serviceManager.addAggregator(aggregator1);
        vm.stopPrank();

        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(nonOwner);
        serviceManager.removeAggregator(aggregator1);
    }

    function test_addStrategies_revertNotOwner() public {
        IStrategy[] memory newStrategies = new IStrategy[](1);
        newStrategies[0] = IStrategy(vm.addr(200));

        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(nonOwner);
        serviceManager.addStrategies(newStrategies, 0);
    }

    function test_pullFeeFromUser_success() public {
        // Setup: Add aggregator and give them permission to call pullFeeFromUser
        vm.prank(owner);
        serviceManager.addAggregator(aggregator1);

        // Setup: Mint tokens to user and approve service manager
        uint256 feeAmount = 1000;
        mockToken1.mint(user, feeAmount);

        vm.prank(user);
        mockToken1.approve(address(serviceManager), feeAmount);

        // Set task manager as caller (mock)
        vm.mockCall(
            address(mockTaskManager),
            abi.encodeWithSignature("sertnServiceManager()"),
            abi.encode(address(serviceManager))
        );

        // Test: Pull fee from user
        vm.prank(address(mockTaskManager));
        serviceManager.pullFeeFromUser(user, IERC20(address(mockToken1)), feeAmount);

        // Verify: Tokens transferred to service manager
        assertEq(mockToken1.balanceOf(address(serviceManager)), feeAmount);
        assertEq(mockToken1.balanceOf(user), 0);
    }

    function test_pullFeeFromUser_revertNotTaskManager() public {
        vm.expectRevert(ISertnServiceManager.NotTaskManager.selector);
        vm.prank(aggregator1);
        serviceManager.pullFeeFromUser(user, IERC20(address(mockToken1)), 1000);
    }

    function test_taskCompleted_success() public {
        // Setup: Add aggregator and mint tokens
        vm.prank(owner);
        serviceManager.addAggregator(aggregator1);

        uint256 feeAmount = 1000;
        mockToken1.mint(address(serviceManager), feeAmount);

        // Setup: Approve rewards coordinator
        vm.prank(address(serviceManager));
        mockToken1.approve(address(mockRewardsCoordinator), feeAmount);

        // Test: Complete task (called by task manager)
        vm.prank(address(mockTaskManager));
        vm.expectEmit(true, true, false, true);
        emit ISertnServiceManager.TaskRewardAccumulated(operator, feeAmount, 0); // currentInterval is mocked as 0
        serviceManager.taskCompleted(
            operator,
            feeAmount,
            IStrategy(address(mockStrategy1)),
            12345 // start Timestamp (mocked)
        );

        // Verify: Operator reward is accumulated
        assertTrue(
            serviceManager.getOperatorsInInterval(0)[0] == operator,
            "Operator should be in the interval"
        );
        assertTrue(
            serviceManager.getStrategiesInInterval(0)[0] == address(mockStrategy1),
            "Strategy should be in the interval"
        );
        assertEq(
            serviceManager.getIntervalRewards(0, operator, address(mockStrategy1)),
            feeAmount,
            "Operator reward should match fee amount"
        );

        // No revert means success
    }

    function test_taskCompleted_revertNotTaskManager() public {
        vm.expectRevert(ISertnServiceManager.NotTaskManager.selector);
        vm.prank(aggregator1);
        serviceManager.taskCompleted(
            operator,
            1000,
            IStrategy(address(mockStrategy1)),
            12345 // start Timestamp (mocked)
        );
    }

    function test_slashOperator_success() public {
        // Test: Slash operator (called by task manager)
        vm.prank(address(mockTaskManager));
        serviceManager.slashOperator(
            operator,
            1000,
            0, // operatorSetId
            IStrategy(address(mockStrategy1))
        );

        // No revert means success
    }

    function test_slashOperator_revertNotTaskManager() public {
        vm.expectRevert(ISertnServiceManager.NotTaskManager.selector);
        vm.prank(aggregator1);
        serviceManager.slashOperator(operator, 1000, 0, IStrategy(address(mockStrategy1)));
    }

    function test_aggregatorManagement_comprehensive() public {
        vm.startPrank(owner);

        // Initially only owner should be aggregator
        assertTrue(serviceManager.isAggregator(owner));
        assertFalse(serviceManager.isAggregator(aggregator1));
        assertFalse(serviceManager.isAggregator(aggregator2));

        // Add first aggregator
        serviceManager.addAggregator(aggregator1);
        assertTrue(serviceManager.isAggregator(aggregator1));

        // Add second aggregator
        serviceManager.addAggregator(aggregator2);
        assertTrue(serviceManager.isAggregator(aggregator2));

        // Remove first aggregator
        serviceManager.removeAggregator(aggregator1);
        assertFalse(serviceManager.isAggregator(aggregator1));
        assertTrue(serviceManager.isAggregator(aggregator2));

        // Verify array management (aggregator2 should still be accessible)
        // Note: The implementation swaps with last element, so indexes might change
        assertTrue(serviceManager.isAggregator(aggregator2));

        vm.stopPrank();
    }

    function test_modifierRestrictions() public {
        // Test onlyOwner modifier
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(nonOwner);
        serviceManager.addAggregator(aggregator1);

        // Test onlyTaskManager modifier
        vm.expectRevert(ISertnServiceManager.NotTaskManager.selector);
        vm.prank(nonOwner);
        serviceManager.pullFeeFromUser(user, IERC20(address(mockToken1)), 1000);
    }

    function test_integrationWithModelRegistry() public {
        vm.startPrank(owner);

        // Create a model in the registry
        uint256 modelId = modelRegistry.createNewModel(
            address(mockVerifier),
            IModelRegistry.VerificationStrategy.Onchain,
            "test_model",
            100,
            10
        );

        // Verify model exists
    assertEq(modelRegistry.modelName(modelId), "test_model");
        assertEq(address(serviceManager.modelRegistry()), address(modelRegistry));

        vm.stopPrank();
    }

    function test_complexWorkflow() public {
        vm.startPrank(owner);

        // Setup: Create model and add aggregator
        uint256 modelId = modelRegistry.createNewModel(
            address(mockVerifier),
            IModelRegistry.VerificationStrategy.Onchain,
            "workflow_model",
            500,
            10
        );
        serviceManager.addAggregator(aggregator1);

        vm.stopPrank();

        // Workflow: Aggregator initiates fee pull
        uint256 feeAmount = 2000;
        mockToken1.mint(user, feeAmount);

        vm.prank(user);
        mockToken1.approve(address(serviceManager), feeAmount);

        vm.prank(address(mockTaskManager));
        serviceManager.pullFeeFromUser(user, IERC20(address(mockToken1)), feeAmount);

        // Workflow: Task completed, rewards distributed
        vm.prank(address(mockTaskManager));
        serviceManager.taskCompleted(
            operator,
            feeAmount,
            IStrategy(address(mockStrategy1)),
            12345 // start Timestamp (mocked)
        );

        // Verify final state
        assertEq(mockToken1.balanceOf(address(serviceManager)), feeAmount);
        assertTrue(serviceManager.isAggregator(aggregator1));
    assertEq(modelRegistry.modelName(modelId), "workflow_model");

        uint32 currentInterval = serviceManager.getCurrentInterval();

        // Verify operator rewards
        assertEq(
            serviceManager.getIntervalRewards(currentInterval, operator, address(mockStrategy1)),
            feeAmount,
            "Operator reward should match fee amount"
        );
        assertEq(
            serviceManager.getOperatorsInInterval(currentInterval)[0],
            operator,
            "Operator should be in the current interval"
        );
        assertEq(
            serviceManager.getStrategiesInInterval(currentInterval)[0],
            address(mockStrategy1),
            "Strategy should be in the current interval"
        );

        vm.stopPrank();

        // Submit rewards to operator
        vm.startPrank(owner);
        vm.warp(block.timestamp + 604800); // Fast forward one week (604800 seconds)

        // Just smoke test:
        serviceManager.submitRewardsForInterval(currentInterval);
    }
}
