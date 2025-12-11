// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {InferenceServiceManager} from "../src/InferenceServiceManager.sol";
import {InferenceTaskManager} from "../src/InferenceTaskManager.sol";
import {InferenceNodesManager} from "../src/InferenceNodesManager.sol";
import {ModelRegistry} from "../src/ModelRegistry.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {IAllocationManager} from "@eigenlayer/contracts/interfaces/IAllocationManager.sol";
import {IStrategy} from "@eigenlayer/contracts/interfaces/IStrategy.sol";
import {IAllocationManagerTypes} from "@eigenlayer/contracts/interfaces/IAllocationManager.sol";

contract DeployHolesky is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("HOLESKY_DEPLOYER_KEY");
        address allocationManager = vm.envAddress("ALLOCATION_MANAGER");
        address strategy = vm.envAddress("STRATEGY_ADDRESS");
        address rewardsCoordinator = vm.envAddress("REWARDS_COORDINATOR");
        address delegationManager = vm.envAddress("DELEGATION_MANAGER");
        address inferenceRegistrar = vm.envAddress("INFERENCE_REGISTRAR");
        string memory avsMetadata = vm.envString("AVS_METADATA_URI");

        vm.startBroadcast(deployerKey);

        ProxyAdmin proxyAdmin = new ProxyAdmin();
        console2.log("Deployed ProxyAdmin at:", address(proxyAdmin));

        ModelRegistry modelRegistryImpl = new ModelRegistry();
        InferenceTaskManager taskManagerImpl = new InferenceTaskManager();
        InferenceServiceManager serviceManagerImpl = new InferenceServiceManager();
        InferenceNodesManager nodesManagerImpl = new InferenceNodesManager();

        console2.log("Deployed implementations:");
        console2.log("- ModelRegistry:", address(modelRegistryImpl));
        console2.log("- TaskManager:", address(taskManagerImpl));
        console2.log("- ServiceManager:", address(serviceManagerImpl));
        console2.log("- NodesManager:", address(nodesManagerImpl));

        bytes memory empty = "";
        TransparentUpgradeableProxy modelRegistryProxy = new TransparentUpgradeableProxy(
            address(modelRegistryImpl),
            address(proxyAdmin),
            empty
        );

        TransparentUpgradeableProxy taskManagerProxy = new TransparentUpgradeableProxy(
            address(taskManagerImpl),
            address(proxyAdmin),
            empty
        );

        TransparentUpgradeableProxy serviceManagerProxy = new TransparentUpgradeableProxy(
            address(serviceManagerImpl),
            address(proxyAdmin),
            empty
        );

        console2.log("Deployed proxies:");
        console2.log("- ModelRegistry:", address(modelRegistryProxy));
        console2.log("- TaskManager:", address(taskManagerProxy));
        console2.log("- ServiceManager:", address(serviceManagerProxy));

        IStrategy[] memory strategiesForInit = new IStrategy[](1);
        strategiesForInit[0] = IStrategy(strategy);

        ModelRegistry(address(modelRegistryProxy)).initialize();
        InferenceTaskManager(address(taskManagerProxy)).initialize(
            rewardsCoordinator,
            delegationManager,
            allocationManager,
            address(serviceManagerProxy),
            address(modelRegistryProxy),
            address(nodesManagerImpl)
        );
        InferenceServiceManager(address(serviceManagerProxy)).initialize(
            rewardsCoordinator,
            delegationManager,
            allocationManager,
            inferenceRegistrar,
            strategiesForInit,
            avsMetadata
        );

        InferenceServiceManager(address(serviceManagerProxy)).updateTaskManager(
            address(taskManagerProxy)
        );
        InferenceServiceManager(address(serviceManagerProxy)).updateModelRegistry(
            address(modelRegistryProxy)
        );

        IAllocationManager allocMgr = IAllocationManager(allocationManager);

        IStrategy[] memory strategiesForSet = new IStrategy[](1);
        strategiesForSet[0] = IStrategy(strategy);

        IAllocationManagerTypes.CreateSetParams[]
            memory sets = new IAllocationManagerTypes.CreateSetParams[](1);
        sets[0] = IAllocationManagerTypes.CreateSetParams({
            operatorSetId: 1,
            strategies: strategiesForSet
        });
        allocMgr.createOperatorSets(address(serviceManagerProxy), sets);

        uint32[] memory operatorSetIds = new uint32[](1);
        operatorSetIds[0] = 1;

        IAllocationManagerTypes.RegisterParams memory register = IAllocationManagerTypes
            .RegisterParams({
                avs: address(serviceManagerProxy),
                operatorSetIds: operatorSetIds,
                data: ""
            });
        allocMgr.registerForOperatorSets(address(serviceManagerProxy), register);

        string memory deploymentInfo = string(
            abi.encodePacked(
                "{\n",
                '    "proxyAdmin": "',
                vm.toString(address(proxyAdmin)),
                '",\n',
                '    "modelRegistry": {\n',
                '        "implementation": "',
                vm.toString(address(modelRegistryImpl)),
                '",\n',
                '        "proxy": "',
                vm.toString(address(modelRegistryProxy)),
                '"\n',
                "    },\n",
                '    "taskManager": {\n',
                '        "implementation": "',
                vm.toString(address(taskManagerImpl)),
                '",\n',
                '        "proxy": "',
                vm.toString(address(taskManagerProxy)),
                '"\n',
                "    },\n",
                '    "serviceManager": {\n',
                '        "implementation": "',
                vm.toString(address(serviceManagerImpl)),
                '",\n',
                '        "proxy": "',
                vm.toString(address(serviceManagerProxy)),
                '"\n',
                "    }\n",
                "}"
            )
        );

        vm.writeFile("deployments/holesky.json", deploymentInfo);

        vm.stopBroadcast();
    }
}
