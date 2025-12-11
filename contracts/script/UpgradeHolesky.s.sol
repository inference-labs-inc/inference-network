// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/Test.sol";
import {CoreDeploymentLib} from "./utils/CoreDeploymentLib.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {InferenceServiceManager} from "../src/InferenceServiceManager.sol";
import {InferenceTaskManager} from "../src/InferenceTaskManager.sol";
import {ModelRegistry} from "../src/ModelRegistry.sol";

contract UpgradeHolesky is Script {
    using stdJson for *;
    using Strings for uint256;

    struct DeploymentData {
        address serviceManager;
        address taskManager;
        address modelRegistry;
    }

    address private deployer;
    address proxyAdmin;

    function setUp() public virtual {
        console2.log("Starting setup...");
        string memory rpcUrl = vm.envString("RPC_URL");
        console2.log("Using RPC URL:", rpcUrl);

        uint256 forkId = vm.createFork(rpcUrl);
        vm.selectFork(forkId);
        console2.log("Fork created and selected");

        uint256 deployerKey = vm.envUint("HOLESKY_DEPLOYER_KEY");
        console2.log("Got deployer key:", deployerKey != 0);
        deployer = vm.rememberKey(deployerKey);
        console2.log("Actual deployer address:", deployer);

        proxyAdmin = vm.envAddress("PROXY_ADMIN");
        console2.log("Proxy admin from env:", proxyAdmin);
    }

    function readDeploymentJson() internal view returns (DeploymentData memory) {
        string memory filePath = string.concat(
            "deployments/inference/",
            vm.toString(block.chainid),
            ".json"
        );
        console2.log("Reading Inference deployment from:", filePath);

        require(vm.exists(filePath), "Deployment file does not exist");
        console2.log("File exists, reading contents...");

        string memory json = vm.readFile(filePath);
        console2.log("File contents read successfully");

        DeploymentData memory data;
        data.serviceManager = json.readAddress(".addresses.serviceManager");
        data.taskManager = json.readAddress(".addresses.taskManager");
        data.modelRegistry = json.readAddress(".addresses.modelRegistry");

        console2.log("Deployment data decoded successfully");
        console2.log("Service manager:", data.serviceManager);
        console2.log("Task manager:", data.taskManager);
        console2.log("Model registry:", data.modelRegistry);

        return data;
    }

    function run() external {
        console2.log("Starting upgrade script...");
        vm.startBroadcast(deployer);

        DeploymentData memory deployment = readDeploymentJson();

        console2.log("Deploying new implementations...");
        InferenceServiceManager newServiceManagerImpl = new InferenceServiceManager();
        console2.log("New service manager implementation:", address(newServiceManagerImpl));

        InferenceTaskManager newTaskManagerImpl = new InferenceTaskManager();
        console2.log("New task manager implementation:", address(newTaskManagerImpl));

        ModelRegistry newModelRegistryImpl = new ModelRegistry();
        console2.log("New model registry implementation:", address(newModelRegistryImpl));

        console2.log("Upgrading service manager...");
        ProxyAdmin(proxyAdmin).upgrade(
            ITransparentUpgradeableProxy(deployment.serviceManager),
            address(newServiceManagerImpl)
        );
        console2.log("Service manager upgraded successfully");

        console2.log("Upgrading task manager...");
        ProxyAdmin(proxyAdmin).upgrade(
            ITransparentUpgradeableProxy(deployment.taskManager),
            address(newTaskManagerImpl)
        );
        console2.log("Task manager upgraded successfully");

        if (deployment.modelRegistry != address(0)) {
            console2.log("Upgrading model registry...");
            ProxyAdmin(proxyAdmin).upgrade(
                ITransparentUpgradeableProxy(deployment.modelRegistry),
                address(newModelRegistryImpl)
            );
            console2.log("Model registry upgraded successfully");
        }

        vm.stopBroadcast();

        string memory deploymentPath = string.concat(
            "deployments/inference/",
            vm.toString(block.chainid),
            ".json"
        );
        string memory json = vm.readFile(deploymentPath);

        string memory addresses = string.concat(
            '"addresses":{',
            '"serviceManager":"',
            vm.toString(deployment.serviceManager),
            '",',
            '"taskManager":"',
            vm.toString(deployment.taskManager),
            '",',
            '"modelRegistry":"',
            vm.toString(deployment.modelRegistry),
            '"}'
        );

        string memory newJson = string.concat(
            "{",
            addresses,
            ",",
            '"implementations":{',
            '"serviceManager":"',
            vm.toString(address(newServiceManagerImpl)),
            '",',
            '"taskManager":"',
            vm.toString(address(newTaskManagerImpl)),
            '"'
        );

        if (deployment.modelRegistry != address(0)) {
            newJson = string.concat(
                newJson,
                ',"modelRegistry":"',
                vm.toString(address(newModelRegistryImpl)),
                '"'
            );
        }
        newJson = string.concat(newJson, "}}");

        vm.writeFile(deploymentPath, newJson);
        console2.log("Updated implementation addresses in:", deploymentPath);

        console2.log("\nUpgrade complete!");
    }
}
