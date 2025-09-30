// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

import {Test, console2 as console} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {InferenceNodesManager} from "../src/InferenceNodesManager.sol";
import {ModelRegistry} from "../src/ModelRegistry.sol";
import {IInferenceNodesManager} from "../interfaces/IInferenceNodesManager.sol";
import {IModelRegistry} from "../interfaces/IModelRegistry.sol";
import {DelegationManagerMock} from "./mockContracts/DelegationManagerMock.sol";
import {MockInferenceTaskManager} from "./mockContracts/InferenceTaskManagerMock.sol";
import {MockVerifier} from "./mockContracts/VerifierMock.sol";
import {MockVerifier2} from "./mockContracts/VerifierMock2.sol";

contract InferenceNodesManagerTest is Test {
    Vm.Wallet internal owner;
    Vm.Wallet internal operator1;
    Vm.Wallet internal operator2;
    MockInferenceTaskManager internal taskManager;

    InferenceNodesManager nodesManager;
    ModelRegistry modelRegistry;
    DelegationManagerMock delegationManager;
    MockVerifier mockVerifier;
    MockVerifier2 mockVerifier2;

    uint256 modelId1;
    uint256 modelId2;

    // Test data
    string constant NODE_NAME = "Test Node";
    uint256 constant NODE_FUCUS = 1000;
    uint256 constant MODEL_FUCUS = 500;

    function setUp() public {
        console.log("InferenceNodesManagerTest setUp");

        // Create test users
        owner = vm.createWallet("owner_wallet");
        operator1 = vm.createWallet("operator1_wallet");
        operator2 = vm.createWallet("operator2_wallet");
        taskManager = new MockInferenceTaskManager();

        // Deploy mock contracts as owner
        vm.startPrank(owner.addr);

        // Deploy mock delegation manager, and register operators
        delegationManager = new DelegationManagerMock();
        delegationManager.setAllUsersAreOperators(false);
        delegationManager.registerAsOperator(operator1.addr, 0, "");
        delegationManager.registerAsOperator(operator2.addr, 0, "");

        // Deploy model registry
        modelRegistry = new ModelRegistry();
        modelRegistry.initialize();

        // Deploy mock verifiers
        mockVerifier = new MockVerifier();
        mockVerifier2 = new MockVerifier2();

        // Create test models
        modelId1 = modelRegistry.createNewModel(
            address(mockVerifier),
            IModelRegistry.VerificationStrategy.Onchain,
            "model1",
            100,
            50
        );

        modelId2 = modelRegistry.createNewModel(
            address(mockVerifier2),
            IModelRegistry.VerificationStrategy.Offchain,
            "model2",
            200,
            100
        );

        // Deploy nodes manager
        nodesManager = new InferenceNodesManager();
        nodesManager.initialize(
            address(delegationManager),
            address(taskManager),
            address(modelRegistry)
        );

        vm.stopPrank();
    }

    // ============ NODE REGISTRATION TESTS ============

    function testRegisterNode() public {
        vm.startPrank(operator1.addr);

        vm.expectEmit(true, true, false, true);
        emit IInferenceNodesManager.NodeRegistered(1, operator1.addr, NODE_NAME, NODE_FUCUS);

        uint256 nodeId = nodesManager.registerNode(NODE_NAME, "", NODE_FUCUS);

        assertEq(nodeId, 1);
        assertEq(nodesManager.nextNodeId(), 2);

        // Verify node data
        (
            address operator,
            string memory name,
            string memory metadata,
            uint256 totalFucus,
            uint256 allocatedFucus,
            uint256 availableFucus,
            bool isActive,
            uint256 createdAt,
            uint256 supportedModelsCount
        ) = nodesManager.getNodeDetails(nodeId);

        assertEq(operator, operator1.addr);
        assertEq(name, NODE_NAME);
        assertEq(metadata, "");
        assertEq(totalFucus, NODE_FUCUS);
        assertEq(allocatedFucus, 0);
        assertEq(availableFucus, NODE_FUCUS);
        assertTrue(isActive);
        assertEq(createdAt, block.timestamp);
        assertEq(supportedModelsCount, 0);

        vm.stopPrank();
    }

    function testRegisterNodeWithZeroFucus() public {
        vm.prank(operator1.addr);
        vm.expectRevert(IInferenceNodesManager.InvalidFucusAmount.selector);
        nodesManager.registerNode(NODE_NAME, "", 0);
    }

    function testRegisterMultipleNodes() public {
        vm.startPrank(operator1.addr);

        uint256 nodeId1 = nodesManager.registerNode("Node 1", "metadata1", 1000);
        uint256 nodeId2 = nodesManager.registerNode("Node 2", "metadata2", 2000);

        assertEq(nodeId1, 1);
        assertEq(nodeId2, 2);
        assertEq(nodesManager.nextNodeId(), 3);

        uint256[] memory operatorNodes = nodesManager.getOperatorNodes(operator1.addr);
        assertEq(operatorNodes.length, 2);
        assertEq(operatorNodes[0], 1);
        assertEq(operatorNodes[1], 2);

        vm.stopPrank();
    }

    function testRegisterNodeNotOperator() public {
        vm.prank(owner.addr); // not operator

        vm.expectRevert(abi.encodeWithSelector(IInferenceNodesManager.NotNodeOperator.selector, 0));
        nodesManager.registerNode(NODE_NAME, "", NODE_FUCUS);
    }

    // ============ NODE UPDATE TESTS ============

    function testUpdateNode() public {
        vm.startPrank(operator1.addr);

        uint256 nodeId = nodesManager.registerNode(NODE_NAME, "", NODE_FUCUS);

        string memory newName = "Updated Node";
        string memory newMetadata = "ipfs://updated-metadata";
        uint256 newFucus = 2000;

        vm.expectEmit(true, false, false, true);
        emit IInferenceNodesManager.NodeUpdated(nodeId, newName, newMetadata);

        nodesManager.updateNode(nodeId, newName, newMetadata, newFucus);

        (
            address operator,
            string memory name,
            string memory metadata,
            uint256 totalFucus,
            ,
            ,
            ,
            ,

        ) = nodesManager.getNodeDetails(nodeId);

        assertEq(operator, operator1.addr);
        assertEq(name, newName);
        assertEq(metadata, newMetadata);
        assertEq(totalFucus, newFucus);

        vm.stopPrank();
    }

    function testUpdateNodeNotOperator() public {
        vm.prank(operator1.addr);
        uint256 nodeId = nodesManager.registerNode(NODE_NAME, "", NODE_FUCUS);

        vm.prank(operator2.addr);
        vm.expectRevert(
            abi.encodeWithSelector(IInferenceNodesManager.NotNodeOperator.selector, nodeId)
        );
        nodesManager.updateNode(nodeId, "New Name", "new metadata", 1500);
    }

    function testUpdateNonexistentNode() public {
        vm.prank(operator1.addr);
        vm.expectRevert(
            abi.encodeWithSelector(IInferenceNodesManager.NodeDoesNotExist.selector, 999)
        );
        nodesManager.updateNode(999, "New Name", "new metadata", 1500);
    }

    function testUpdateNodeTooLowFucus() public {
        vm.startPrank(operator1.addr);
        uint256 nodeId = nodesManager.registerNode(NODE_NAME, "", NODE_FUCUS);

        // add model support
        nodesManager.addModelSupport(nodeId, modelId1, MODEL_FUCUS);

        // Try to update with too low Fucus for running the model
        vm.expectRevert(
            abi.encodeWithSelector(
                IInferenceNodesManager.InsufficientFucus.selector,
                MODEL_FUCUS - 1,
                MODEL_FUCUS
            )
        );
        nodesManager.updateNode(nodeId, NODE_NAME, "", MODEL_FUCUS - 1);

        vm.stopPrank();
    }

    // ============ NODE ACTIVATION/DEACTIVATION TESTS ============

    function testDeactivateNode() public {
        vm.startPrank(operator1.addr);

        uint256 nodeId = nodesManager.registerNode(NODE_NAME, "", NODE_FUCUS);

        // Deactivation
        vm.expectEmit(true, true, false, false);
        emit IInferenceNodesManager.NodeDeactivated(nodeId, operator1.addr);

        nodesManager.deactivateNode(nodeId);

        (, , , , , , bool isActive, , ) = nodesManager.getNodeDetails(nodeId);
        assertFalse(isActive);

        // Activation again
        vm.expectEmit(true, true, false, false);
        emit IInferenceNodesManager.NodeReactivated(nodeId, operator1.addr);

        nodesManager.reactivateNode(nodeId);

        (, , , , , , bool isActiveUpdated, , ) = nodesManager.getNodeDetails(nodeId);
        assertTrue(isActiveUpdated);

        vm.stopPrank();
    }

    function testDeactivateNodeNotOperator() public {
        vm.prank(operator1.addr);
        uint256 nodeId = nodesManager.registerNode(NODE_NAME, "", NODE_FUCUS);

        vm.prank(operator2.addr); // not correct operator

        // trying to deactivate
        vm.expectRevert(
            abi.encodeWithSelector(IInferenceNodesManager.NotNodeOperator.selector, nodeId)
        );
        nodesManager.deactivateNode(nodeId);

        // trying to reactivate
        vm.expectRevert(
            abi.encodeWithSelector(IInferenceNodesManager.NotNodeOperator.selector, nodeId)
        );
        nodesManager.reactivateNode(nodeId);
        vm.stopPrank();
    }

    // ============ NODE REMOVAL TESTS ============

    function testRemoveNode() public {
        vm.startPrank(operator1.addr);

        uint256 nodeId = nodesManager.registerNode(NODE_NAME, "", NODE_FUCUS);

        vm.expectEmit(true, true, false, false);
        emit IInferenceNodesManager.NodeRemoved(nodeId, operator1.addr);

        nodesManager.removeNode(nodeId);

        vm.expectRevert(
            abi.encodeWithSelector(IInferenceNodesManager.NodeDoesNotExist.selector, nodeId)
        );
        nodesManager.getNodeDetails(nodeId);

        uint256[] memory operatorNodes = nodesManager.getOperatorNodes(operator1.addr);
        assertEq(operatorNodes.length, 0);

        vm.stopPrank();
    }

    function testRemoveNodeNotOperator() public {
        vm.prank(operator1.addr);
        uint256 nodeId = nodesManager.registerNode(NODE_NAME, "", NODE_FUCUS);

        vm.prank(operator2.addr); // not correct operator

        vm.expectRevert(
            abi.encodeWithSelector(IInferenceNodesManager.NotNodeOperator.selector, nodeId)
        );
        nodesManager.removeNode(nodeId);
    }

    function testRemoveNodeWithModelSupports() public {
        vm.startPrank(operator1.addr);

        uint256 nodeId = nodesManager.registerNode(NODE_NAME, "", NODE_FUCUS);
        nodesManager.addModelSupport(nodeId, modelId1, MODEL_FUCUS);

        // Verify model support exists
        uint256[] memory supportingNodes = nodesManager.getModelSupportingNodes(modelId1);
        assertEq(supportingNodes.length, 1);
        assertEq(supportingNodes[0], nodeId);

        nodesManager.removeNode(nodeId);

        // Verify model support is removed
        supportingNodes = nodesManager.getModelSupportingNodes(modelId1);
        assertEq(supportingNodes.length, 0);

        vm.stopPrank();
    }

    function testRemoveNonExistentNode() public {
        vm.prank(operator1.addr);
        vm.expectRevert(
            abi.encodeWithSelector(IInferenceNodesManager.NodeDoesNotExist.selector, 999)
        );
        nodesManager.removeNode(999);
    }

    // ============ MODEL SUPPORT TESTS ============

    function testAddModelSupport() public {
        vm.startPrank(operator1.addr);

        uint256 nodeId = nodesManager.registerNode(NODE_NAME, "", NODE_FUCUS);

        vm.expectEmit(true, true, false, true);
        emit IInferenceNodesManager.ModelSupportAdded(nodeId, modelId1, MODEL_FUCUS);

        nodesManager.addModelSupport(nodeId, modelId1, MODEL_FUCUS);

        // Verify model support is added
        uint256[] memory supportedModels = nodesManager.getNodeSupportedModels(nodeId);
        assertEq(supportedModels.length, 1);
        assertEq(supportedModels[0], modelId1);

        uint256[] memory modelFucus = nodesManager.getNodeModelsFucus(nodeId);
        assertEq(modelFucus.length, 1);
        assertEq(modelFucus[0], MODEL_FUCUS);

        uint256[] memory supportingNodes = nodesManager.getModelSupportingNodes(modelId1);
        assertEq(supportingNodes.length, 1);
        assertEq(supportingNodes[0], nodeId);

        vm.stopPrank();
    }

    function testAddModelSupportInvalidModel() public {
        vm.startPrank(operator1.addr);

        uint256 nodeId = nodesManager.registerNode(NODE_NAME, "", NODE_FUCUS);

        vm.expectRevert(
            abi.encodeWithSelector(IInferenceNodesManager.InvalidModelId.selector, 999)
        );
        nodesManager.addModelSupport(nodeId, 999, MODEL_FUCUS);

        vm.stopPrank();
    }

    function testAddModelSupportZeroFucus() public {
        vm.startPrank(operator1.addr);

        uint256 nodeId = nodesManager.registerNode(NODE_NAME, "", NODE_FUCUS);

        vm.expectRevert(IInferenceNodesManager.InvalidFucusAmount.selector);
        nodesManager.addModelSupport(nodeId, modelId1, 0);

        vm.stopPrank();
    }

    function testAddModelSupportInsufficientFucus() public {
        vm.startPrank(operator1.addr);

        uint256 nodeId = nodesManager.registerNode(NODE_NAME, "", NODE_FUCUS);

        vm.expectRevert(
            abi.encodeWithSelector(
                IInferenceNodesManager.InsufficientFucus.selector,
                NODE_FUCUS + 1,
                NODE_FUCUS
            )
        );
        nodesManager.addModelSupport(nodeId, modelId1, NODE_FUCUS + 1);

        vm.stopPrank();
    }

    function testAddModelSupportAlreadySupported() public {
        vm.startPrank(operator1.addr);

        uint256 nodeId = nodesManager.registerNode(NODE_NAME, "", NODE_FUCUS);
        nodesManager.addModelSupport(nodeId, modelId1, MODEL_FUCUS);

        vm.expectRevert(
            abi.encodeWithSelector(
                IInferenceNodesManager.ModelAlreadySupported.selector,
                nodeId,
                modelId1
            )
        );
        nodesManager.addModelSupport(nodeId, modelId1, MODEL_FUCUS);

        vm.stopPrank();
    }

    function testRemoveModelSupport() public {
        vm.startPrank(operator1.addr);

        uint256 nodeId = nodesManager.registerNode(NODE_NAME, "", NODE_FUCUS);
        nodesManager.addModelSupport(nodeId, modelId1, MODEL_FUCUS);

        vm.expectEmit(true, true, false, false);
        emit IInferenceNodesManager.ModelSupportRemoved(nodeId, modelId1);

        nodesManager.removeModelSupport(nodeId, modelId1);

        // Verify model support is removed
        uint256[] memory supportedModels = nodesManager.getNodeSupportedModels(nodeId);
        assertEq(supportedModels.length, 0);

        uint256[] memory supportingNodes = nodesManager.getModelSupportingNodes(modelId1);
        assertEq(supportingNodes.length, 0);

        vm.stopPrank();
    }

    function testRemoveModelSupportNotSupported() public {
        vm.startPrank(operator1.addr);

        uint256 nodeId = nodesManager.registerNode(NODE_NAME, "", NODE_FUCUS);

        vm.expectRevert(
            abi.encodeWithSelector(
                IInferenceNodesManager.ModelNotSupported.selector,
                nodeId,
                modelId1
            )
        );
        nodesManager.removeModelSupport(nodeId, modelId1);

        vm.stopPrank();
    }

    function testUpdateModelSupport() public {
        vm.startPrank(operator1.addr);

        uint256 nodeId = nodesManager.registerNode(NODE_NAME, "", NODE_FUCUS);
        nodesManager.addModelSupport(nodeId, modelId1, MODEL_FUCUS);

        uint256 newFucus = 300;
        vm.expectEmit(true, true, false, true);
        emit IInferenceNodesManager.ModelSupportUpdated(nodeId, modelId1, newFucus);

        nodesManager.updateModelSupport(nodeId, modelId1, newFucus);

        uint256[] memory modelFucus = nodesManager.getNodeModelsFucus(nodeId);
        assertEq(modelFucus[0], newFucus);

        vm.stopPrank();
    }

    function testUpdateModelSupportNotSupported() public {
        vm.startPrank(operator1.addr);

        uint256 nodeId = nodesManager.registerNode(NODE_NAME, "", NODE_FUCUS);

        vm.expectRevert(
            abi.encodeWithSelector(
                IInferenceNodesManager.ModelNotSupported.selector,
                nodeId,
                modelId1
            )
        );
        nodesManager.updateModelSupport(nodeId, modelId1, 300);

        vm.stopPrank();
    }

    function testUpdateModelSupportZeroFucus() public {
        vm.startPrank(operator1.addr);

        uint256 nodeId = nodesManager.registerNode(NODE_NAME, "", NODE_FUCUS);
        nodesManager.addModelSupport(nodeId, modelId1, MODEL_FUCUS);

        vm.expectRevert(IInferenceNodesManager.InvalidFucusAmount.selector);
        nodesManager.updateModelSupport(nodeId, modelId1, 0);

        vm.stopPrank();
    }

    // ============ TASK ALLOCATION TESTS ============

    function testAllocateFucusForTask() public {
        // Setup: Register node and add model support
        vm.prank(operator1.addr);
        uint256 nodeId = nodesManager.registerNode(NODE_NAME, "", NODE_FUCUS);
        vm.prank(operator1.addr);
        nodesManager.addModelSupport(nodeId, modelId1, MODEL_FUCUS);

        // Test allocation from task manager
        vm.prank(address(taskManager));
        vm.expectEmit(true, true, false, true);
        emit IInferenceNodesManager.FucusAllocated(operator1.addr, modelId1, 100);

        bool success = nodesManager.allocateFucusForTask(operator1.addr, modelId1, 100);
        assertTrue(success);

        assertEq(nodesManager.operatorAllocatedFucus(operator1.addr, modelId1), 100);
        assertEq(
            nodesManager.getAvailableFucusForOperatorModel(operator1.addr, modelId1),
            MODEL_FUCUS - 100
        );
    }

    function testAllocateFucusInsufficientCapacity() public {
        vm.prank(operator1.addr);
        uint256 nodeId = nodesManager.registerNode(NODE_NAME, "", NODE_FUCUS);
        vm.prank(operator1.addr);
        nodesManager.addModelSupport(nodeId, modelId1, MODEL_FUCUS);

        vm.prank(address(taskManager));
        bool success = nodesManager.allocateFucusForTask(operator1.addr, modelId1, MODEL_FUCUS + 1);
        assertFalse(success);
    }

    function testAllocateFucusNotTaskManager() public {
        vm.prank(operator1.addr);
        uint256 nodeId = nodesManager.registerNode(NODE_NAME, "", NODE_FUCUS);
        vm.prank(operator1.addr);
        nodesManager.addModelSupport(nodeId, modelId1, MODEL_FUCUS);

        vm.prank(operator2.addr);
        vm.expectRevert(IInferenceNodesManager.OnlyTaskManager.selector);
        nodesManager.allocateFucusForTask(operator1.addr, modelId1, 100);
    }

    function testReleaseFucusForTask() public {
        // Setup allocation first
        vm.prank(operator1.addr);
        uint256 nodeId = nodesManager.registerNode(NODE_NAME, "", NODE_FUCUS);
        vm.prank(operator1.addr);
        nodesManager.addModelSupport(nodeId, modelId1, MODEL_FUCUS);
        vm.prank(address(taskManager));
        nodesManager.allocateFucusForTask(operator1.addr, modelId1, 200);

        // Test release
        vm.prank(address(taskManager));
        vm.expectEmit(true, true, false, true);
        emit IInferenceNodesManager.FucusReleased(operator1.addr, modelId1, 100);

        nodesManager.releaseFucusForTask(operator1.addr, modelId1, 100);

        assertEq(nodesManager.operatorAllocatedFucus(operator1.addr, modelId1), 100);
        assertEq(
            nodesManager.getAvailableFucusForOperatorModel(operator1.addr, modelId1),
            MODEL_FUCUS - 100
        );
    }

    function testReleaseFucusExceedsAllocated() public {
        vm.prank(operator1.addr);
        uint256 nodeId = nodesManager.registerNode(NODE_NAME, "", NODE_FUCUS);
        vm.prank(operator1.addr);
        nodesManager.addModelSupport(nodeId, modelId1, MODEL_FUCUS);
        vm.prank(address(taskManager));
        nodesManager.allocateFucusForTask(operator1.addr, modelId1, 100);

        vm.prank(address(taskManager));
        vm.expectRevert("Attempting to release more than allocated");
        nodesManager.releaseFucusForTask(operator1.addr, modelId1, 200);

        // Verify the allocated amount is unchanged
        assertEq(nodesManager.operatorAllocatedFucus(operator1.addr, modelId1), 100);
    }

    // ============ VIEW FUNCTION TESTS ============

    function testGetTotalAllocatedFucusForNode() public {
        vm.startPrank(operator1.addr);

        uint256 nodeId = nodesManager.registerNode(NODE_NAME, "", NODE_FUCUS);
        nodesManager.addModelSupport(nodeId, modelId1, 300);
        nodesManager.addModelSupport(nodeId, modelId2, 400);

        uint256 totalAllocated = nodesManager.getTotalAllocatedFucusForNode(nodeId);
        assertEq(totalAllocated, 700);

        vm.stopPrank();
    }

    function testGetTotalFucusForOperatorModel() public {
        vm.startPrank(operator1.addr);

        uint256 nodeId1 = nodesManager.registerNode("Node 1", "", NODE_FUCUS);
        uint256 nodeId2 = nodesManager.registerNode("Node 2", "", NODE_FUCUS);

        nodesManager.addModelSupport(nodeId1, modelId1, 300);
        nodesManager.addModelSupport(nodeId2, modelId1, 400);

        uint256 totalFucus = nodesManager.getTotalFucusForOperatorModel(operator1.addr, modelId1);
        assertEq(totalFucus, 700);

        vm.stopPrank();
    }

    function testGetTotalFucusForOperatorModelInactiveNode() public {
        vm.startPrank(operator1.addr);

        uint256 nodeId1 = nodesManager.registerNode("Node 1", "", NODE_FUCUS);
        uint256 nodeId2 = nodesManager.registerNode("Node 2", "", NODE_FUCUS);

        nodesManager.addModelSupport(nodeId1, modelId1, 300);
        nodesManager.addModelSupport(nodeId2, modelId1, 400);

        // Deactivate one node
        nodesManager.deactivateNode(nodeId2);

        uint256 totalFucus = nodesManager.getTotalFucusForOperatorModel(operator1.addr, modelId1);
        assertEq(totalFucus, 300); // Only active node

        vm.stopPrank();
    }

    function testGetAvailableOperatorsForModel() public {
        // Setup multiple operators with different capacities
        vm.prank(operator1.addr);
        uint256 nodeId1 = nodesManager.registerNode("Op1 Node", "", 1000);
        vm.prank(operator1.addr);
        nodesManager.addModelSupport(nodeId1, modelId1, 800);

        vm.prank(operator2.addr);
        uint256 nodeId2 = nodesManager.registerNode("Op2 Node", "", 500);
        vm.prank(operator2.addr);
        nodesManager.addModelSupport(nodeId2, modelId1, 400);

        (address[] memory availableOperators, uint256[] memory availableFucus) = nodesManager
            .getAvailableOperatorsForModel(modelId1, 300);

        assertEq(availableOperators.length, 2);
        assertEq(availableFucus.length, 2);

        // Both operators should be available
        bool op1Found = false;
        bool op2Found = false;
        for (uint256 i = 0; i < availableOperators.length; i++) {
            if (availableOperators[i] == operator1.addr) {
                op1Found = true;
                assertEq(availableFucus[i], 800);
            } else if (availableOperators[i] == operator2.addr) {
                op2Found = true;
                assertEq(availableFucus[i], 400);
            }
        }
        assertTrue(op1Found);
        assertTrue(op2Found);
    }

    function testGetAvailableOperatorsForModelHighRequirement() public {
        vm.prank(operator1.addr);
        uint256 nodeId1 = nodesManager.registerNode("Op1 Node", "", 1000);
        vm.prank(operator1.addr);
        nodesManager.addModelSupport(nodeId1, modelId1, 800);

        vm.prank(operator2.addr);
        uint256 nodeId2 = nodesManager.registerNode("Op2 Node", "", 500);
        vm.prank(operator2.addr);
        nodesManager.addModelSupport(nodeId2, modelId1, 400);

        (address[] memory availableOperators, uint256[] memory availableFucus) = nodesManager
            .getAvailableOperatorsForModel(modelId1, 500);

        // Only operator1 should be available (has 800 >= 500)
        assertEq(availableOperators.length, 1);
        assertEq(availableOperators[0], operator1.addr);
        assertEq(availableFucus[0], 800);
    }

    // ============ COMPLEX SCENARIO TESTS ============

    function testComplexFucusAllocationScenario() public {
        // Setup: operator1 has 2 nodes, both support modelId1
        vm.startPrank(operator1.addr);

        uint256 nodeId1 = nodesManager.registerNode("Node 1", "", 1000);
        uint256 nodeId2 = nodesManager.registerNode("Node 2", "", 1500);

        nodesManager.addModelSupport(nodeId1, modelId1, 600); // 600 FUCUs for model1
        nodesManager.addModelSupport(nodeId2, modelId1, 800); // 800 FUCUs for model1

        vm.stopPrank();

        // Total available: 1400 FUCUs for model1
        assertEq(nodesManager.getTotalFucusForOperatorModel(operator1.addr, modelId1), 1400);
        assertEq(nodesManager.getAvailableFucusForOperatorModel(operator1.addr, modelId1), 1400);

        // Allocate some FUCUs
        vm.prank(address(taskManager));
        bool success = nodesManager.allocateFucusForTask(operator1.addr, modelId1, 500);
        assertTrue(success);

        assertEq(nodesManager.getAvailableFucusForOperatorModel(operator1.addr, modelId1), 900);

        // Allocate more
        vm.prank(address(taskManager));
        success = nodesManager.allocateFucusForTask(operator1.addr, modelId1, 600);
        assertTrue(success);

        assertEq(nodesManager.getAvailableFucusForOperatorModel(operator1.addr, modelId1), 300);

        // Try to allocate more than available
        vm.prank(address(taskManager));
        success = nodesManager.allocateFucusForTask(operator1.addr, modelId1, 400);
        assertFalse(success);

        // Release some and try again
        vm.prank(address(taskManager));
        nodesManager.releaseFucusForTask(operator1.addr, modelId1, 200);

        assertEq(nodesManager.getAvailableFucusForOperatorModel(operator1.addr, modelId1), 500);

        vm.prank(address(taskManager));
        success = nodesManager.allocateFucusForTask(operator1.addr, modelId1, 400);
        assertTrue(success);
    }

    function testMultipleOperatorsMultipleModels() public {
        // Setup complex scenario with multiple operators and models
        vm.startPrank(operator1.addr);
        uint256 op1NodeId = nodesManager.registerNode("Op1 Node", "", 1000);
        nodesManager.addModelSupport(op1NodeId, modelId1, 600);
        nodesManager.addModelSupport(op1NodeId, modelId2, 400);
        vm.stopPrank();

        vm.startPrank(operator2.addr);
        uint256 op2NodeId = nodesManager.registerNode("Op2 Node", "", 800);
        nodesManager.addModelSupport(op2NodeId, modelId1, 500);
        // operator2 only supports modelId1
        vm.stopPrank();

        // Test availability for model1 (both operators support it)
        (address[] memory availableOps1, uint256[] memory availableFucus1) = nodesManager
            .getAvailableOperatorsForModel(modelId1, 100);
        assertEq(availableOps1.length, 2);
        assertTrue(availableFucus1.length > 0); // Use the variable

        // Test availability for model2 (only operator1 supports it)
        (address[] memory availableOps2, uint256[] memory availableFucus2) = nodesManager
            .getAvailableOperatorsForModel(modelId2, 100);
        assertEq(availableOps2.length, 1);
        assertEq(availableOps2[0], operator1.addr);
        assertTrue(availableFucus2.length > 0); // Use the variable

        // Allocate from both operators for model1
        vm.prank(address(taskManager));
        nodesManager.allocateFucusForTask(operator1.addr, modelId1, 300);
        vm.prank(address(taskManager));
        nodesManager.allocateFucusForTask(operator2.addr, modelId1, 200);

        assertEq(nodesManager.getAvailableFucusForOperatorModel(operator1.addr, modelId1), 300);
        assertEq(nodesManager.getAvailableFucusForOperatorModel(operator2.addr, modelId1), 300);
        assertEq(nodesManager.getAvailableFucusForOperatorModel(operator1.addr, modelId2), 400); // Unaffected
    }

    // ============ EDGE CASE TESTS ============

    function testNodeWithoutModelSupport() public {
        vm.prank(operator1.addr);
        uint256 nodeId = nodesManager.registerNode(NODE_NAME, "", NODE_FUCUS);

        uint256[] memory supportedModels = nodesManager.getNodeSupportedModels(nodeId);
        assertEq(supportedModels.length, 0);

        uint256[] memory modelFucus = nodesManager.getNodeModelsFucus(nodeId);
        assertEq(modelFucus.length, 0);

        assertEq(nodesManager.getTotalAllocatedFucusForNode(nodeId), 0);
    }

    function testModelWithoutSupportingNodes() public view {
        uint256[] memory supportingNodes = nodesManager.getModelSupportingNodes(modelId1);
        assertEq(supportingNodes.length, 0);

        assertEq(nodesManager.getTotalFucusForOperatorModel(operator1.addr, modelId1), 0);
        assertEq(nodesManager.getAvailableFucusForOperatorModel(operator1.addr, modelId1), 0);
    }

    function testOperatorWithoutNodes() public view {
        uint256[] memory operatorNodes = nodesManager.getOperatorNodes(operator1.addr);
        assertEq(operatorNodes.length, 0);

        assertEq(nodesManager.getTotalFucusForOperatorModel(operator1.addr, modelId1), 0);
    }
}
