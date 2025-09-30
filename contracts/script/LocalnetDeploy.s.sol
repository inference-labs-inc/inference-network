// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.12;

import {Script} from "forge-std/Script.sol";
import {InferenceServiceManager} from "../src/InferenceServiceManager.sol";
import {CoreDeploymentLib} from "./utils/CoreDeploymentLib.sol";
import {UpgradeableProxyLib} from "./utils/UpgradeableProxyLib.sol";
import {ERC20Mock} from "../test/mockContracts/ERC20Mock.sol";
import {IERC20, StrategyFactory} from "@eigenlayer/contracts/strategies/StrategyFactory.sol";
import {IStrategy} from "eigenlayer-contracts/src/contracts/interfaces/IStrategy.sol";
import {Test, console2} from "forge-std/Test.sol";

contract LocalnetDeploy is Script {
    function run() external {
        console2.log("starting deployment");
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        address proxyAdmin = UpgradeableProxyLib.deployProxyAdmin();

        CoreDeploymentLib.DeploymentConfigData memory coreConfigData = CoreDeploymentLib
            .readDeploymentConfigValues("config/core/", 31337);

        CoreDeploymentLib.DeploymentData memory coreDeployment = CoreDeploymentLib.deployContracts(
            proxyAdmin,
            coreConfigData
        );

        ERC20Mock ethToken1 = new ERC20Mock();
        ERC20Mock ethToken2 = new ERC20Mock();
        ERC20Mock serToken = new ERC20Mock();

        StrategyFactory strategyFactory = StrategyFactory(coreDeployment.strategyFactory);

        IStrategy[] memory strategies = new IStrategy[](3);
        strategies[0] = strategyFactory.deployNewStrategy(IERC20(address(serToken)));
        strategies[1] = strategyFactory.deployNewStrategy(IERC20(address(ethToken1)));
        strategies[2] = strategyFactory.deployNewStrategy(IERC20(address(ethToken2)));

        console2.log("Deploying InferenceServiceManager");
        InferenceServiceManager inferenceServiceManagerImpl = new InferenceServiceManager(); // Deploy implementation first
        // TODO: Deploy proxy and point to implementation, then initialize proxy
        // For now, just initializing the implementation directly for simplicity
        inferenceServiceManagerImpl.initialize(
            coreDeployment.rewardsCoordinator,
            coreDeployment.delegationManager,
            coreDeployment.allocationManager,
            address(0), // FIXME: Provide the actual InferenceRegistrar address
            strategies,
            "" // FIXME: Provide the actual AVS metadata URI
        );

        console2.log("Deployment Complete");
        console2.log(
            "InferenceServiceManager (Implementation):",
            address(inferenceServiceManagerImpl)
        );
        console2.log("ETH Token 1:", address(ethToken1));
        console2.log("ETH Token 2:", address(ethToken2));
        console2.log("SER Token:", address(serToken));

        vm.stopBroadcast();
    }
}
