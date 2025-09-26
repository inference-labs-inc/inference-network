// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.12;

import {SertnServiceManager} from "../src/SertnServiceManager.sol";
import {SertnTaskManager} from "../src/SertnTaskManager.sol";
import {SertnNodesManager} from "../src/SertnNodesManager.sol";
import "../interfaces/ISertnServiceManager.sol";
import "../interfaces/ISertnTaskManager.sol";
import "../interfaces/IModelRegistry.sol";
import {Vm} from "forge-std/Vm.sol";

import {CoreDeploymentLib} from "../script/utils/CoreDeploymentLib.sol";
import {UpgradeableProxyLib} from "../script/utils/UpgradeableProxyLib.sol";
import {ERC20Mock} from "./mockContracts/ERC20Mock.sol";
import {IERC20, StrategyFactory} from "@eigenlayer/contracts/strategies/StrategyFactory.sol";
import {IPermissionController} from "@eigenlayer/contracts/interfaces/IPermissionController.sol";
import {IStrategy} from "@eigenlayer/contracts/interfaces/IStrategy.sol";

import {IStrategyManager} from "@eigenlayer/contracts/interfaces/IStrategyManager.sol";
import {IDelegationManagerTypes} from "@eigenlayer/contracts/interfaces/IDelegationManager.sol";
import {IDelegationManager} from "@eigenlayer/contracts/interfaces/IDelegationManager.sol";
import {AllocationManager} from "@eigenlayer/contracts/core/AllocationManager.sol";
import {IAllocationManager} from "@eigenlayer/contracts/interfaces/IAllocationManager.sol";
import {IAllocationManagerTypes} from "@eigenlayer/contracts/interfaces/IAllocationManager.sol";
import {IAVSRegistrar} from "@eigenlayer/contracts/interfaces/IAVSRegistrar.sol";
import {OperatorSet} from "@eigenlayer/contracts/libraries/OperatorSetLib.sol";
import "@eigenlayer/contracts/interfaces/IRewardsCoordinator.sol";

import {Test, console2 as console} from "forge-std/Test.sol";
import {ECDSAUpgradeable} from "@openzeppelin-upgrades/contracts/utils/cryptography/ECDSAUpgradeable.sol";
import {MockVerifier} from "./mockContracts/VerifierMock.sol";
import {MockVerifier2} from "./mockContracts/VerifierMock2.sol";
import {ModelRegistry} from "../src/ModelRegistry.sol";

import {MockAVSRegistrar} from "./mockContracts/RegistrarMock.sol";

contract AVSSetup2 is Test {
    struct Operator {
        Vm.Wallet key;
        Vm.Wallet signingKey;
    }

    struct AVSOwner {
        Vm.Wallet key;
    }

    struct User {
        Vm.Wallet key;
    }

    Operator[] internal operators;
    AVSOwner internal owner;
    User internal user;

    OperatorSet internal opSet; // address avs; uint32 id;
    uint32[] opSetIds;

    // SertnDeploymentLib.DeploymentData internal sertnDeployment;
    CoreDeploymentLib.DeploymentData internal coreDeployment;
    CoreDeploymentLib.DeploymentConfigData coreConfigData;

    IStrategy[] _tokenToStrategy;
    IStrategy[] _ethStrategies;
    IStrategy _serStrategy;
    IStrategy[] strategies;

    ERC20Mock public ethToken1;
    ERC20Mock public ethToken2;
    ERC20Mock public serToken;

    SertnServiceManager sertnServiceManager;
    SertnTaskManager sertnTaskManager;
    SertnNodesManager sertnNodesManager;
    MockVerifier mockVerifier;
    ModelRegistry modelRegistry;

    uint256 modelId;

    mapping(address => IStrategy) public tokenToStrategy;

    function setUp() public virtual {
        console.log("AVSSetup1 setUp");
        // owner = AVSOwner({key: vm.createWallet("owner_wallet")});
        address proxyAdmin = UpgradeableProxyLib.deployProxyAdmin();
        console.log("ProxyAdmin deployed");
        coreConfigData = CoreDeploymentLib.readDeploymentConfigValues(
            "test/mockData/config/core/",
            1337
        ); // TODO: Fix this to correct path
        console.log("Config read");
        coreDeployment = CoreDeploymentLib.deployContracts(proxyAdmin, coreConfigData);
        console.log("CoreDeploymentLib deployed");

        initStrategiest();

        vm.startPrank(owner.key.addr);
        console.log("Deploying AVS as sertnRegistrar");
        MockAVSRegistrar sertnRegistrar = new MockAVSRegistrar();

        sertnNodesManager = new SertnNodesManager();

        console.log("Deployed AVS as sertnRegistrar");
        sertnServiceManager = new SertnServiceManager();
        sertnServiceManager.initialize(
            coreDeployment.rewardsCoordinator,
            coreDeployment.delegationManager,
            coreDeployment.allocationManager,
            address(sertnRegistrar),
            strategies,
            ""
        );

        // // sertnRegistrar.initialize(address(sertnServiceManager));
        mockVerifier = new MockVerifier();
        modelRegistry = new ModelRegistry();
        modelRegistry.initialize();
        modelId = modelRegistry.createNewModel(
            address(mockVerifier),
            IModelRegistry.VerificationStrategy.Onchain,
            "model1",
            100,
            10
        );

        sertnTaskManager = new SertnTaskManager();
        sertnTaskManager.initialize(
            coreDeployment.rewardsCoordinator,
            coreDeployment.delegationManager,
            coreDeployment.allocationManager,
            address(sertnServiceManager),
            address(modelRegistry),
            address(sertnNodesManager)
        );
        // // console.log(sertnServiceManager.owner(), owner.key.addr);
        sertnServiceManager.updateTaskManager(address(sertnTaskManager));
        // sertnServiceManager.updateModelRegistry(address(modelRegistry));

        sertnNodesManager.initialize(
            address(coreDeployment.delegationManager),
            address(sertnTaskManager),
            address(modelRegistry)
        );

        vm.stopPrank();
        // labelContracts(coreDeployment);
    }

    function initStrategiest() internal {
        console.log("Init strategies");
        ethToken1 = new ERC20Mock();
        ethToken2 = new ERC20Mock();
        serToken = new ERC20Mock();
        IStrategy strategy1 = addStrategy(address(ethToken1));
        IStrategy strategy2 = addStrategy(address(ethToken2));
        _serStrategy = addStrategy(address(serToken));
        strategies.push(_serStrategy);
        strategies.push(strategy1);
        strategies.push(strategy2);
        _ethStrategies.push(strategy1);
        _ethStrategies.push(strategy2);
        console.log("Strategies pushed");
    }

    function addStrategy(address token) public returns (IStrategy) {
        if (tokenToStrategy[token] != IStrategy(address(0))) {
            return tokenToStrategy[token];
        }
        console.log("Creating strategy");
        StrategyFactory strategyFactory = StrategyFactory(coreDeployment.strategyFactory);
        console.log("StrategyFactory created");
        IStrategy newStrategy = strategyFactory.deployNewStrategy(IERC20(token));
        tokenToStrategy[token] = newStrategy;
        return newStrategy;
    }

    function labelContracts(CoreDeploymentLib.DeploymentData memory coreDeployment) internal {
        vm.label(coreDeployment.delegationManager, "DelegationManager");
        vm.label(coreDeployment.allocationManager, "AllocationManager");
        vm.label(coreDeployment.strategyManager, "StrategyManager");
        vm.label(coreDeployment.eigenPodManager, "EigenPodManager");
        vm.label(coreDeployment.rewardsCoordinator, "RewardsCoordinator");
        vm.label(coreDeployment.eigenPodBeacon, "EigenPodBeacon");
        vm.label(coreDeployment.pauserRegistry, "PauserRegistry");
        vm.label(coreDeployment.strategyFactory, "StrategyFactory");
        vm.label(coreDeployment.strategyBeacon, "StrategyBeacon");
        vm.label(address(sertnServiceManager), "SertnServiceManager");
        vm.label(address(sertnTaskManager), "SertnTaskManager");
        // vm.label(sertnDeployment.stakeRegistry, "StakeRegistry");
    }

    function mintMockTokens(Operator memory operator, uint256 amount) internal {
        ethToken1.mint(operator.key.addr, amount);
        ethToken2.mint(operator.key.addr, amount);
        serToken.mint(operator.key.addr, amount);
    }

    function depositTokenIntoStrategy(
        Operator memory operator,
        address token,
        uint256 amount
    ) internal returns (uint256) {
        IStrategy strategy = IStrategy(tokenToStrategy[token]);
        require(address(strategy) != address(0), "Strategy was not found");
        IStrategyManager strategyManager = IStrategyManager(coreDeployment.strategyManager);

        vm.startPrank(operator.key.addr);
        ethToken1.approve(address(strategyManager), amount);
        ethToken2.approve(address(strategyManager), amount);
        serToken.approve(address(strategyManager), amount);

        uint256 shares = strategyManager.depositIntoStrategy(strategy, IERC20(token), amount);
        vm.stopPrank();

        return shares;
    }

    function registerAsOperator(Operator memory operator) internal {
        IDelegationManager delegationManager = IDelegationManager(coreDeployment.delegationManager);

        IDelegationManagerTypes.OperatorDetails memory operatorDetails = IDelegationManagerTypes
            .OperatorDetails({
                __deprecated_earningsReceiver: operator.key.addr,
                delegationApprover: address(0),
                __deprecated_stakerOptOutWindowBlocks: 0
            });

        vm.prank(operator.key.addr);
        delegationManager.registerAsOperator(address(operator.key.addr), 0, "");
    }

    function registerAsOperatorToAVS(Operator memory operator) internal {
        IAllocationManager allocationManager = IAllocationManager(coreDeployment.allocationManager);
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
        IAllocationManagerTypes.RegisterParams memory registerParams = IAllocationManagerTypes
            .RegisterParams({
                avs: address(sertnServiceManager),
                operatorSetIds: opSetIds, // [0]
                data: _data
            });
        vm.startPrank(operator.key.addr);
        allocationManager.registerForOperatorSets(operator.key.addr, registerParams);
        vm.stopPrank();
    }

    function createAndAddOperator() internal returns (Operator memory) {
        Vm.Wallet memory operatorKey = vm.createWallet(
            string.concat("operator", vm.toString(operators.length))
        );
        Vm.Wallet memory signingKey = vm.createWallet(
            string.concat("signing", vm.toString(operators.length))
        );

        Operator memory newOperator = Operator({key: operatorKey, signingKey: signingKey});

        operators.push(newOperator);
        return newOperator;
    }

    function registerOperatorNodes(Operator memory operator) internal {
        vm.startPrank(operator.key.addr);
        uint256 node_id = sertnNodesManager.registerNode("node1", "", 1000000);
        sertnNodesManager.addModelSupport(node_id, modelId, 1000000);
        vm.stopPrank();
    }
}

contract RegisterOperatorToAVS2 is AVSSetup2 {
    uint256 internal constant INITIAL_BALANCE = 100 ether;
    uint256 internal constant DEPOSIT_AMOUNT = 1 ether;
    uint256 internal constant OPERATOR_COUNT = 4;
    IDelegationManager internal delegationManager;
    AllocationManager internal allocationManager;
    IPermissionController internal permissionController;

    IStrategy[] strat;
    IAllocationManagerTypes.CreateSetParams[] setParams;

    function setUp() public virtual override {
        console.log("AVSSetup2 setUp");
        super.setUp();

        /// Setting to internal state for convenience
        delegationManager = IDelegationManager(coreDeployment.delegationManager);
        allocationManager = AllocationManager(coreDeployment.allocationManager);
        permissionController = IPermissionController(coreDeployment.permissionController);

        opSet = OperatorSet({avs: address(sertnServiceManager), id: 0});
        opSetIds.push(0);

        while (operators.length < OPERATOR_COUNT) {
            createAndAddOperator();
        }

        // WTF is this?
        uint64[] memory _newMags = new uint64[](3);
        _newMags[0] = 1 ether;
        _newMags[1] = 1 ether;
        _newMags[2] = 1 ether;

        IAllocationManagerTypes.AllocateParams[]
            memory allocateParams = new IAllocationManagerTypes.AllocateParams[](1);
        allocateParams[0] = IAllocationManagerTypes.AllocateParams({
            operatorSet: opSet,
            strategies: strategies,
            newMagnitudes: _newMags
        });

        address[] memory _operatorKeys = new address[](OPERATOR_COUNT);
        for (uint8 i = 0; i < OPERATOR_COUNT; i++) {
            _operatorKeys[i] = operators[i].key.addr;
        }

        // TODO: We need to deploy the strategies before we can allocate them
        for (uint256 i = 0; i < OPERATOR_COUNT; i++) {
            console.log("Minting tokens...");
            mintMockTokens(operators[i], INITIAL_BALANCE);
            console.log("Depositing tokens into strategy 1...");
            depositTokenIntoStrategy(operators[i], address(ethToken1), DEPOSIT_AMOUNT);
            console.log("Depositing tokens into strategy 2...");
            depositTokenIntoStrategy(operators[i], address(ethToken2), DEPOSIT_AMOUNT);
            console.log("Depositing tokens into strategy 3...");
            depositTokenIntoStrategy(operators[i], address(serToken), DEPOSIT_AMOUNT);
            console.log("Registering as operator...");
            registerAsOperator(operators[i]);
            console.log("Registering as operator to AVS...");
            registerAsOperatorToAVS(operators[i]);
            registerOperatorNodes(operators[i]);
            vm.startPrank(_operatorKeys[i]);
            console.log("Set allocation delay to 1 block...");
            allocationManager.setAllocationDelay(operators[i].key.addr, 1);
            vm.roll(block.number + 1);
            console.log("Set allocation...");
            //////////////////////////////////////////////////////////////////////////////////
            allocationManager.modifyAllocations(
                _operatorKeys[i], // operator address
                allocateParams //
            );
            console.log("Operator allocated");
            vm.stopPrank();
        }
    }

    function test_sendTaskWrongModelId() public {
        vm.roll(1e9);
        vm.warp(86400 * 3);
        user = User({key: vm.createWallet("user_wallet")});
        ISertnTaskManager.Task memory task = ISertnTaskManager.Task({
            startBlock: 0,
            startTimestamp: uint32(block.timestamp),
            modelId: 999, // Wrong model ID
            inputs: bytes(""),
            proofHash: "",
            user: user.key.addr,
            nonce: 1,
            operator: operators[0].key.addr,
            state: ISertnTaskManager.TaskState.CREATED,
            output: bytes(""),
            fee: 1e2
        });
        console.log("Task created with wrong model ID");

        _prepare_aggregator(user.key.addr);
        console.log("Sending task");

        vm.startPrank(user.key.addr);
        vm.expectRevert(ISertnTaskManager.InvalidModelId.selector);
        sertnTaskManager.sendTask(task);
        vm.stopPrank();
    }

    function test_sendTask() public {
        vm.roll(1e9);
        vm.warp(86400 * 3);
        user = User({key: vm.createWallet("user_wallet")});
        ISertnTaskManager.Task memory task = ISertnTaskManager.Task({
            startBlock: 0,
            startTimestamp: uint32(block.timestamp),
            modelId: modelId,
            inputs: bytes(""),
            proofHash: "",
            user: user.key.addr,
            nonce: 1,
            operator: operators[0].key.addr,
            state: ISertnTaskManager.TaskState.CREATED,
            output: bytes(""),
            fee: 1e2
        });
        console.log("Task created");
        _prepare_aggregator(user.key.addr);

        // send the actual task
        vm.startPrank(user.key.addr);

        vm.expectEmit(true, true, false, true);
        emit ISertnTaskManager.TaskCreated(1, task.user);

        vm.expectEmit(true, true, false, true);
        emit ISertnTaskManager.TaskAssigned(1, task.operator);

        sertnTaskManager.sendTask(task);
        uint256 taskNonce = sertnTaskManager.taskNonce() - 1;
        console.log("Task sent with nonce: %s", taskNonce);
        vm.stopPrank();

        // respond to the task
        _respondToTask(operators[0].key.addr, task.nonce);
        string memory output = _checkTaskResponse(user.key.addr, taskNonce);
        require(
            keccak256(abi.encodePacked(output)) == keccak256(abi.encodePacked("dummy output")),
            "Task output is incorrect"
        );
        _slashTask(task.nonce);
        //     vm.roll(block.number + 100);
        //     taskId = _sendTask(user.key.addr, task);
        //     _respondToTask1(operators[0].key.addr, taskId, false, bytes(""), false);
        //     _checkTaskResponse(user.key.addr, taskId);
        //     _slashTask(taskId);
    }

    // function test_base() public {
    //     vm.roll(1e9);
    //     user = User({key: vm.createWallet("user_wallet")});
    //     ISertnTaskManager.Task memory task = ISertnTaskManager.Task({
    //         startBlock: 0,
    //         modelId: 0,
    //         inputs: bytes(""),
    //         proofHash: "",
    //         user: user.key.addr,
    //         nonce: 0,
    //         operator: address(0),
    //         state: ISertnTaskManager.TaskState.CREATED,
    //         output: bytes(""),
    //         fee: 1e2
    //     });
    //     bytes memory taskId = _sendTask(user.key.addr, task);
    //     _respondToTask1(operators[0].key.addr, taskId, true, bytes("1"), false);
    //     _checkTaskResponse(user.key.addr, taskId);
    //     _slashTask(taskId);
    //     vm.roll(block.number + 100);
    // }

    // function test_bbb() public {
    //     vm.roll(1e9);
    //     vm.startPrank(owner.key.addr);

    //     uint256 modelId = modelRegistry.createNewModel(
    //         address(mockVerifier),
    //         IModelRegistry.VerificationStrategy.Onchain,
    //         "model1",
    //         1e2,
    //         15
    //     );

    //     require(modelId == 0, "Model ID should be 0");

    //     modelRegistry.updateModelName(modelId, "model1_updated");
    //     require(
    //         keccak256(abi.encodePacked(modelRegistry.modelName(modelId))) ==
    //             keccak256(abi.encodePacked("model1_updated")),
    //         "Model URI should be updated"
    //     );

    //     vm.stopPrank();

    //////////////////////////////////////////////////////////////////

    //     uint256[] memory _ethShares = new uint256[](2);
    //     _ethShares[0] = 10;
    //     _ethShares[1] = 10;

    //     address[] memory _operators = new address[](1);
    //     _operators[0] = operators[0].key.addr;
    //     _model[0] = ISertnServiceManager.Model({
    //         title_: "WassupModel",
    //         description_: "Returns wassup",
    //         modelVerifier_: address(mockVerifier2),
    //         operators_: _operators
    //     });

    //     ISertnServiceManager.OperatorModel[]
    //         memory _operatorModel = new ISertnServiceManager.OperatorModel[](1);
    //     _operatorModel[0] = ISertnServiceManager.OperatorModel({
    //         operator_: operators[0].key.addr,
    //         modelId_: 2 ** 96 - 1,
    //         maxBlocks_: 1e2,
    //         ethStrategies_: _ethStrategies,
    //         ethShares_: _ethShares,
    //         baseFee_: 1e2,
    //         maxSer_: 1e4,
    //         computeType_: bytes32("model2"),
    //         proveOnResponse_: true,
    //         available_: true
    //     });

    //     bytes32[] memory _computeUnitNames = new bytes32[](2);
    //     _computeUnitNames[0] = bytes32("model1");
    //     _computeUnitNames[1] = bytes32("model2");
    //     uint256[] memory _computeUnits = new uint256[](2);
    //     _computeUnits[0] = 10;
    //     _computeUnits[1] = 10;
    //     _addModel(operators[0].key.addr, _model, _operatorModel);
    //     _addCompute(operators[0].key.addr, _computeUnitNames, _computeUnits);

    //     user = User({key: vm.createWallet("user_wallet")});
    //     ISertnServiceManager.Task memory task = ISertnServiceManager.Task({
    //         operatorModelId_: 4,
    //         inputs_: bytes(""),
    //         poc_: 1e2,
    //         startTime_: 0,
    //         startingBlock_: 0,
    //         proveOnResponse_: true,
    //         user_: user.key.addr
    //     });
    //     bytes memory taskId = _sendTask(user.key.addr, task);
    //     vm.roll(block.number + 50);
    //     _respondToTask2(operators[0].key.addr, taskId, true, bytes("1"), false);
    //     vm.roll(block.number + 10);
    //     _respondToTask2(operators[0].key.addr, taskId, true, bytes("2"), false);
    //     _checkTaskResponse(user.key.addr, taskId);
    //     vm.roll(block.number + 1e2);
    //     // _clearTask(taskId);

    //     _slashTask(taskId);
    // }

    function _prepare_aggregator(address _user) internal {
        // make user an aggregator
        vm.startPrank(owner.key.addr);
        sertnServiceManager.addAggregator(_user);
        vm.stopPrank();

        vm.startPrank(_user);
        console.log("Minting tokens");

        ethToken1.mint(_user, 1 ether);
        ethToken2.mint(_user, 1 ether);
        serToken.mint(_user, 1 ether);

        console.log("Approving tokens");
        ethToken1.approve(address(sertnServiceManager), 1e4);
        ethToken2.approve(address(sertnServiceManager), 1e4);
        serToken.approve(address(sertnServiceManager), 1e4);

        console.log("Approving for task manager");
        ethToken1.approve(address(sertnTaskManager), 1e4);
        ethToken2.approve(address(sertnTaskManager), 1e4);
        serToken.approve(address(sertnTaskManager), 1e4);

        vm.stopPrank();
    }

    function _respondToTask(address operator, uint256 _taskId) internal {
        vm.startPrank(operator);
        console.log("Responding to task with id: %s", _taskId);
        sertnTaskManager.submitTaskOutput(_taskId, bytes("dummy output"));

        console.log("Task response submitted");

        // ISertnServiceManager.Operator memory _operator = abi.decode(
        //     sertnServiceManager.opInfo(operator),
        //     (ISertnServiceManager.Operator)
        // );
        console.log(
            "Task state: %s",
            sertnTaskManager.getTask(_taskId).state == ISertnTaskManager.TaskState.COMPLETED
        );
        require(
            sertnTaskManager.getTask(_taskId).state == ISertnTaskManager.TaskState.COMPLETED,
            "Not completed task"
        );
        // ISertnServiceManager.TaskResponse
        //     memory _taskResponse = ISertnServiceManager.TaskResponse({
        //         taskId_: _taskId,
        //         output_: bytes("hello world"),
        //         proven_: _alreadyVerified
        //     });
        // sertnTaskManager.submitTaskOutput(_taskResponse, _verification, _proof);
        vm.stopPrank();
    }

    function _respondToTask2(
        address operator,
        bytes memory _taskId,
        bool _verification,
        bytes memory _proof,
        bool _alreadyVerified
    ) internal {
        vm.startPrank(operator);
        // ISertnServiceManager.Operator memory _operator = abi.decode(
        //     sertnServiceManager.opInfo(operator),
        //     (ISertnServiceManager.Operator)
        // );
        // require(_inBytesArray(_operator.openTasks_, _taskId), "Not open task");
        // ISertnServiceManager.TaskResponse
        //     memory _taskResponse = ISertnServiceManager.TaskResponse({
        //         taskId_: _taskId,
        //         output_: bytes("wassup"),
        //         proven_: _alreadyVerified
        //     });
        // sertnTaskManager.submitTask(_taskResponse, _verification, _proof);
        vm.stopPrank();
    }

    function _checkTaskResponse(
        address _user,
        uint256 _taskId
    ) internal returns (string memory _outputData) {
        vm.startPrank(_user);
        ISertnTaskManager.Task memory _task = sertnTaskManager.getTask(_taskId);

        _outputData = string(_task.output);
        console.log("Task output: %s", _outputData);
        return _outputData;
    }

    function _slashTask(uint256 _taskId) internal {
        address[] memory _operatorKeys = new address[](OPERATOR_COUNT);
        for (uint8 i = 0; i < OPERATOR_COUNT; i++) {
            _operatorKeys[i] = operators[i].key.addr;
        }
        vm.startPrank(owner.key.addr);
        console.log(
            allocationManager.getMinimumSlashableStake(
                opSet,
                _operatorKeys,
                strategies,
                uint32(vm.getBlockNumber())
            )[0][0],
            "min slashable"
        );
        // sertnServiceManager.slashOperator(_taskId, "test");
        console.log(
            allocationManager.getMinimumSlashableStake(
                opSet,
                _operatorKeys,
                strategies,
                uint32(vm.getBlockNumber())
            )[0][0],
            "min slashable"
        );
        vm.stopPrank();
    }

    // function _addModel(
    //     address _modelVerifier,
    //     VerificationStrategy _verificationStrategy,
    //     string memory _modelName,
    //     uint256 _computeCost
    // ) internal {
    //     sertnServiceManager.addModels(_operatorModels);
    // }

    function _addCompute(
        address _operator,
        bytes32[] memory _computeUnitNames,
        uint256[] memory _computeUnits
    ) internal {
        vm.startPrank(_operator);
        // sertnServiceManager.modifyCompute(_computeUnitNames, _computeUnits);
        vm.stopPrank();
    }

    function _clearTask(bytes memory _taskId) internal {
        vm.startPrank(owner.key.addr);
        // sertnTaskManager.clearTask(_taskId, false);
        vm.stopPrank();
    }

    function _getLatestTaskId(address operator) internal pure returns (bytes memory) {
        // ISertnServiceManager.Operator memory _operator = abi.decode(
        //     sertnServiceManager.opInfo(operator),
        //     (ISertnServiceManager.Operator)
        // );
        // require(_operator.openTasks_.length > 0, "No open tasks");
        // return (_operator.openTasks_[_operator.openTasks_.length - 1]);
        return bytes("0x");
    }

    function _inBytesArray(
        bytes[] memory _byteArray,
        bytes memory _byteElement
    ) internal pure returns (bool) {
        bytes32 elementHash = keccak256(_byteElement);
        for (uint256 i = 0; i < _byteArray.length; i++) {
            if (_byteArray[i].length > 0 && elementHash == keccak256(_byteArray[i])) {
                return true;
            }
        }
        return false;
    }
}
