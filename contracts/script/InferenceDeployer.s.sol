pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/Test.sol";

import {CoreDeploymentLib} from "./utils/CoreDeploymentLib.sol";
import {UpgradeableProxyLib} from "./utils/UpgradeableProxyLib.sol";
import {StrategyBase} from "@eigenlayer/contracts/strategies/StrategyBase.sol";
import {ERC20Mock} from "../test/mockContracts/ERC20Mock.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {StrategyFactory} from "@eigenlayer/contracts/strategies/StrategyFactory.sol";
import {StrategyManager} from "@eigenlayer/contracts/core/StrategyManager.sol";
import {IRewardsCoordinator} from "@eigenlayer/contracts/interfaces/IRewardsCoordinator.sol";

import {InferenceServiceManager} from "../src/InferenceServiceManager.sol";
import {IStrategy} from "@eigenlayer/contracts/interfaces/IStrategy.sol";

import {IERC20, StrategyFactory} from "@eigenlayer/contracts/strategies/StrategyFactory.sol";
import {InferenceTaskManager} from "../src/InferenceTaskManager.sol";
import {ModelRegistry} from "../src/ModelRegistry.sol";
import {InferenceRegistrar} from "../src/InferenceRegistrar.sol";
import {InferenceNodesManager} from "../src/InferenceNodesManager.sol";
import "forge-std/Test.sol";

contract InferenceDeployer is Script, Test {
    using CoreDeploymentLib for *;
    using UpgradeableProxyLib for address;

    address private deployer;
    address proxyAdmin;
    address rewardsOwner;
    address rewardsInitiator;
    IStrategy inferenceStrategy;
    CoreDeploymentLib.DeploymentData coreDeployment;

    ERC20Mock token;

    IStrategy[] _tokenToStrategy;
    IStrategy[] _ethStrategies;
    IStrategy _serStrategy;
    IStrategy[] strategies;

    uint32[] opSetIds;

    ERC20Mock public ethToken1;
    ERC20Mock public ethToken2;
    ERC20Mock public serToken;

    InferenceServiceManager inferenceServiceManager;
    InferenceTaskManager inferenceTaskManager;
    ModelRegistry modelRegistry;
    InferenceRegistrar inferenceRegistrar;
    InferenceNodesManager inferenceNodesManager;

    function setUp() public virtual {
        deployer = vm.rememberKey(vm.envUint("PRIVATE_KEY"));
        vm.label(deployer, "Deployer");

        coreDeployment = CoreDeploymentLib.readDeploymentJson("deployments/core/", block.chainid);
    }

    function run() external {
        vm.startBroadcast(deployer);
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

        inferenceServiceManager = new InferenceServiceManager();
        modelRegistry = new ModelRegistry();
        inferenceRegistrar = new InferenceRegistrar();
        inferenceTaskManager = new InferenceTaskManager();
        inferenceNodesManager = new InferenceNodesManager();

        inferenceRegistrar.initialize(address(inferenceServiceManager));

        inferenceServiceManager.initialize(
            coreDeployment.rewardsCoordinator,
            coreDeployment.delegationManager,
            coreDeployment.allocationManager,
            address(inferenceRegistrar),
            strategies,
            ""
        );

        modelRegistry.initialize();

        inferenceTaskManager.initialize(
            coreDeployment.rewardsCoordinator,
            coreDeployment.delegationManager,
            coreDeployment.allocationManager,
            address(inferenceServiceManager),
            address(modelRegistry),
            address(inferenceNodesManager)
        );

        inferenceNodesManager.initialize(
            address(coreDeployment.delegationManager),
            address(inferenceTaskManager),
            address(modelRegistry)
        );

        inferenceServiceManager.updateTaskManager(address(inferenceTaskManager));
        inferenceServiceManager.updateModelRegistry(address(modelRegistry));

        // save some contracts addresses to the deployment json
        string memory json = vm.serializeAddress(
            "InferenceDeployment",
            "inferenceServiceManager",
            address(inferenceServiceManager)
        );
        json = vm.serializeAddress(
            "InferenceDeployment",
            "inferenceTaskManager",
            address(inferenceTaskManager)
        );
        json = vm.serializeAddress(
            "InferenceDeployment",
            "inferenceRegistrar",
            address(inferenceRegistrar)
        );
        json = vm.serializeAddress(
            "InferenceDeployment",
            "rewardsCoordinator",
            address(coreDeployment.rewardsCoordinator)
        );
        json = vm.serializeAddress(
            "InferenceDeployment",
            "allocationManager",
            address(coreDeployment.allocationManager)
        );
        for (uint256 i = 0; i < strategies.length; i++) {
            json = vm.serializeAddress(
                "InferenceDeployment",
                string.concat("strategy_", Strings.toString(i)),
                address(strategies[i])
            );
        }
        for (uint256 i = 0; i < _ethStrategies.length; i++) {
            json = vm.serializeAddress(
                "InferenceDeployment",
                string.concat("eth_strategy_", Strings.toString(i)),
                address(_ethStrategies[i])
            );
        }
        vm.writeFile("deployments/inferenceDeployment.json", json);

        vm.stopBroadcast();
    }

    function addStrategy(address _token) public returns (IStrategy) {
        StrategyFactory strategyFactory = StrategyFactory(coreDeployment.strategyFactory);
        IStrategy newStrategy = strategyFactory.deployNewStrategy(IERC20(_token));
        return newStrategy;
    }
}
