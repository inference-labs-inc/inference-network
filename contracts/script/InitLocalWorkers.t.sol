// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import {IStrategy} from "@eigenlayer/contracts/interfaces/IStrategy.sol";
import {IStrategyManager} from "@eigenlayer/contracts/interfaces/IStrategyManager.sol";
import {IDelegationManager} from "@eigenlayer/contracts/interfaces/IDelegationManager.sol";
import {IAVSRegistrar} from "@eigenlayer/contracts/interfaces/IAVSRegistrar.sol";
import {ISignatureUtilsMixinTypes} from "@eigenlayer/contracts/interfaces/ISignatureUtilsMixin.sol";
import {IDelegationManagerTypes} from "@eigenlayer/contracts/interfaces/IDelegationManager.sol";
import {IAllocationManager} from "@eigenlayer/contracts/interfaces/IAllocationManager.sol";
import {IAllocationManagerTypes} from "@eigenlayer/contracts/interfaces/IAllocationManager.sol";
import {IModelRegistry} from "../interfaces/IModelRegistry.sol";
import {DelegationManager} from "@eigenlayer/contracts/core/DelegationManager.sol";
import {RewardsCoordinator} from "@eigenlayer/contracts/core/RewardsCoordinator.sol";
import {AllocationManager} from "@eigenlayer/contracts/core/AllocationManager.sol";
import {OperatorSet} from "@eigenlayer/contracts/libraries/OperatorSetLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {console2 as console} from "forge-std/Test.sol";

import {CoreDeploymentLib} from "./utils/CoreDeploymentLib.sol";
import {SertnRegistrar} from "../src/SertnRegistrar.sol";
import {SertnServiceManager} from "../src/SertnServiceManager.sol";
import {ISertnTaskManager} from "../interfaces/ISertnTaskManager.sol";
import {ERC20Mock} from "../test/mockContracts/ERC20Mock.sol";
import {MockVerifier} from "../test/mockContracts/VerifierMock.sol";

contract InitLocalEnvScript is Script {
    /*
    This script initializes the local environment for Sertn by registering an operator and an aggregator
    Also a model is created in the model registry
    */
    using CoreDeploymentLib for *;

    CoreDeploymentLib.DeploymentData coreDeployment;

    uint256 constant AMOUNT = 1 ether;

    // Contract instances
    SertnServiceManager serviceManager;
    RewardsCoordinator rewardsCoordinator;
    IStrategyManager strategyManager;
    AllocationManager allocationManager;
    IDelegationManager delegationManager;
    IStrategy strategy1;
    IStrategy strategy2;
    IStrategy strategy3;
    IStrategy[] strategies;
    IERC20 stakingToken;
    ERC20Mock stakingTokenMock;

    // Addresses
    address operatorAddress;
    address aggregatorAddress;
    uint256 operatorPrivateKey;
    uint256 aggregatorPrivateKey;
    address deployerPrivateKey;

    /**
     * @notice Helper function to advance blocks and time (for simulation only)
     * @param blocks Number of blocks to advance
     */
    function _advanceBlocks(uint256 blocks) internal view {
        console.log(
            "Would advance %s blocks from %s to %s (simulation only)",
            blocks,
            block.number,
            block.number + blocks
        );
        // NOTE: vm.roll() and vm.warp() only work in simulation, not on real blockchain
        // In real execution, you need to wait for actual time to pass
        console.log("Current block %s, timestamp %s", block.number, block.timestamp);
        console.log("WARNING: Time advancement only works in simulation!");
    }

    function _setupAddresses() internal {
        // deployer/owner private key
        deployerPrivateKey = vm.rememberKey(vm.envUint("PRIVATE_KEY"));
        address deployerAddress = vm.addr(uint256(vm.envUint("PRIVATE_KEY")));
        vm.label(deployerPrivateKey, "Deployer");
        console.log("Deployer address:", deployerAddress);

        // TODO: move to env variable or something, those keys are in `tests/keys/` folder
        // solidity does not support importing private keys from files, so here are same keys hardcoded:

        // aggregator user address
        aggregatorPrivateKey = 0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6;
        aggregatorAddress = vm.addr(aggregatorPrivateKey);

        // operator private key
        operatorPrivateKey = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        operatorAddress = vm.addr(operatorPrivateKey);

        console.log("Operator address:", operatorAddress);
    }

    function _setupContracts() internal {
        coreDeployment = CoreDeploymentLib.readDeploymentJson("deployments/core/", block.chainid);

        // Read deployment addresses from JSON file
        string memory deploymentFile = vm.readFile("./deployments/sertnDeployment.json");

        address strategyAddress1 = vm.parseJsonAddress(deploymentFile, ".strategy_0");
        address strategyAddress2 = vm.parseJsonAddress(deploymentFile, ".strategy_1");
        address strategyAddress3 = vm.parseJsonAddress(deploymentFile, ".strategy_2");

        // address strategyEth1Address = vm.parseJsonAddress(deploymentFile, ".eth_strategy_0");
        // address strategyEth2Address = vm.parseJsonAddress(deploymentFile, ".eth_strategy_1");
        address serviceManagerAddress = vm.parseJsonAddress(deploymentFile, ".sertnServiceManager");
        address taskManagerAddress = vm.parseJsonAddress(deploymentFile, ".sertnTaskManager");
        // address sertnRegistrarAddress = vm.parseJsonAddress(deploymentFile, ".sertnRegistrar");
        address rewardsCoordinatorAddress = vm.parseJsonAddress(
            deploymentFile,
            ".rewardsCoordinator"
        );

        console.log("Strategy Address:", strategyAddress1);
        console.log("Service Manager Address:", serviceManagerAddress);
        console.log("Task Manager Address:", taskManagerAddress);
        console.log("Rewards Coordinator Address:", rewardsCoordinatorAddress);
        console.log("AllocationManager Address:", coreDeployment.allocationManager);

        // Get contract objects
        serviceManager = SertnServiceManager(serviceManagerAddress);
        // ISertnTaskManager taskManager = ISertnTaskManager(taskManagerAddress);
        rewardsCoordinator = RewardsCoordinator(rewardsCoordinatorAddress);
        strategyManager = rewardsCoordinator.strategyManager();
        // SertnRegistrar sertnRegistrar = SertnRegistrar(sertnRegistrarAddress);
        allocationManager = AllocationManager(coreDeployment.allocationManager);
        delegationManager = rewardsCoordinator.delegationManager();

        strategy1 = IStrategy(strategyAddress1);
        strategy2 = IStrategy(strategyAddress2);
        strategy3 = IStrategy(strategyAddress3);
        strategies = new IStrategy[](3);
        strategies[0] = strategy1;
        strategies[1] = strategy2;
        strategies[2] = strategy3;
        // IStrategy strategyEth1 = IStrategy(strategyEth1Address);
        // IStrategy strategyEth2 = IStrategy(strategyEth2Address);

        console.log("Operator address:", operatorAddress);
        stakingToken = strategy1.underlyingToken();
        stakingTokenMock = ERC20Mock(address(stakingToken));

        console.log("Token address:", address(stakingToken));
    }

    function _labelContracts() internal {
        vm.label(address(stakingToken), "Staking_Token");
        vm.label(address(stakingTokenMock), "Staking_Token_Mock");
        vm.label(address(strategyManager), "Strategy_Manager");
        vm.label(address(delegationManager), "Delegation_Manager");
        vm.label(address(allocationManager), "Allocation_Manager");
        vm.label(address(serviceManager), "Service_Manager");
        vm.label(address(strategy1), "Strategy_1");
        vm.label(address(strategy2), "Strategy_2");
        vm.label(address(strategy3), "Strategy_3");
        vm.label(address(rewardsCoordinator), "Rewards_Coordinator");
        vm.label(address(operatorAddress), "Operator_Address");
        vm.label(address(aggregatorAddress), "Aggregator_Address");
        vm.label(address(strategy1.underlyingToken()), "Staking_Token");
        vm.label(address(serviceManager.modelRegistry()), "Model_Registry");
        vm.label(operatorAddress, "Operator");
        vm.label(aggregatorAddress, "Aggregator");
    }

    function _mintAndApproveTokens() internal {
        console.log("Minting tokens for the operator...");
        stakingTokenMock.mint(operatorAddress, AMOUNT);
        console.log("Minted tokens. Balance:", stakingToken.balanceOf(operatorAddress));

        console.log("Approving tokens for staking...");
        stakingToken.approve(address(strategyManager), AMOUNT);
        console.log(
            "Approved tokens. Allowance:",
            stakingToken.allowance(operatorAddress, address(strategyManager))
        );

        console.log("Minting tokens for the aggregator...");
        // TODO: actually mint tokens for some end user, which requests tasks, but for now we use aggregator
        stakingTokenMock.mint(aggregatorAddress, AMOUNT * 1000);
    }

    function _depositIntoStrategy() internal {
        console.log("Depositing tokens into the strategy...");
        uint256 shares = strategyManager.depositIntoStrategy(strategy1, stakingToken, AMOUNT);
        console.log("Deposited tokens. Shares received:", shares);
    }

    function _registerOperator() internal {
        console.log("Registering operator with the delegation manager...");
        delegationManager.registerAsOperator(address(operatorAddress), 1, "");
    }

    function _registerForOperatorSets() internal {
        console.log("Registering operator for operator sets...");
        bytes32[] memory _computeUnitNames = new bytes32[](1);
        _computeUnitNames[0] = bytes32("model1");
        uint256[] memory _computeUnits = new uint256[](1);
        _computeUnits[0] = 10;
        bytes memory _data = abi.encode(
            // TODO: some data here (about model?)
            // _model,
            // _operatorModel,
            _computeUnitNames,
            _computeUnits
        );

        uint32[] memory opSetIds = new uint32[](1);
        opSetIds[0] = 0; // Assuming operator set ID 0 is valid

        IAllocationManagerTypes.RegisterParams memory registerParams = IAllocationManagerTypes
            .RegisterParams({avs: address(serviceManager), operatorSetIds: opSetIds, data: _data});
        allocationManager.registerForOperatorSets(operatorAddress, registerParams);
    }

    function _allocateTokens() internal {
        console.log("Allocate tokens to the operator...");

        uint64[] memory _newMags = new uint64[](3);
        _newMags[0] = uint64(AMOUNT);
        _newMags[1] = uint64(AMOUNT);
        _newMags[2] = uint64(AMOUNT);

        OperatorSet memory opSet = OperatorSet({avs: address(serviceManager), id: 0});

        IAllocationManagerTypes.AllocateParams[]
            memory allocateParams = new IAllocationManagerTypes.AllocateParams[](1);
        allocateParams[0] = IAllocationManagerTypes.AllocateParams({
            operatorSet: opSet,
            strategies: strategies,
            newMagnitudes: _newMags
        });

        allocationManager.modifyAllocations(operatorAddress, allocateParams);
    }

    function _registerAggregator() internal {
        console.log("Registering aggregator with the delegation manager...");
        serviceManager.addAggregator(aggregatorAddress);
    }

    function _createModel(
        string memory modelUri,
        uint256 computeCost,
        uint256 requiredFUCUs
    ) internal {
        console.log("Creating new model in the model registry...");
        MockVerifier mockVerifier = new MockVerifier();
        uint256 modelId = serviceManager.modelRegistry().createNewModel(
            address(mockVerifier),
            IModelRegistry.VerificationStrategy.Offchain,
            modelUri,
            computeCost,
            requiredFUCUs
        );
        console.log("Model created with ID:", modelId);
    }

    function run() external {
        _setupAddresses();
        _setupContracts();

        vm.startBroadcast(operatorPrivateKey);

        _labelContracts();

        uint256 stage = vm.envUint("STAGE");

        // STAGE 1: Register operator and aggregator, mint tokens, approve, deposit into strategy
        if (stage == 1) {
            _mintAndApproveTokens();
            _depositIntoStrategy();
            _registerOperator();
            _registerForOperatorSets();
        }

        // STAGE 1.5: Wait a few blocks to simulate time passing

        // STAGE 2: Allocate tokens to the operator, register aggregator, create model
        if (stage == 2) {
            _allocateTokens();

            vm.stopBroadcast();

            vm.startBroadcast(deployerPrivateKey);

            _registerAggregator();
            _createModel("model_0", 1, 10);
            // _createModel("model_1", 2, 15);
            MockVerifier model2MockVerifier = new MockVerifier();
            console.log("Spare Verifier address 1:", address(model2MockVerifier));
            MockVerifier model3MockVerifier = new MockVerifier();
            console.log("Spare Verifier address 2:", address(model3MockVerifier));
            MockVerifier model4MockVerifier = new MockVerifier();
            console.log("Spare Verifier address 3:", address(model4MockVerifier));
        }

        vm.stopBroadcast();

        // uint32 requiredDelay = allocationManager.ALLOCATION_CONFIGURATION_DELAY();
        // _advanceBlocks(requiredDelay + 1); // +1 to be safe

        // (bool isDelaySet, uint32 operatorDelay) = allocationManager.getAllocationDelay(
        //     operatorAddress
        // );
        // console.log("Operator allocation delay is set: %s, delay: %s", isDelaySet, operatorDelay);

        // (isDelaySet, operatorDelay) = allocationManager.getAllocationDelay(operatorAddress);
        // console.log("Operator allocation delay is set: %s, delay: %s", isDelaySet, operatorDelay);
    }
}
