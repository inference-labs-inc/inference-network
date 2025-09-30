// // SPDX-License-Identifier: UNLICENSED
// pragma solidity ^0.8.0;

// import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
// import {TransparentUpgradeableProxy} from
//     "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
// import {Script} from "forge-std/Script.sol";
// import {console2} from "forge-std/Test.sol";
// import {Vm} from "forge-std/Vm.sol";
// import {stdJson} from "forge-std/StdJson.sol";
// import {ECDSAStakeRegistry} from "@eigenlayer-middleware/src/unaudited/ECDSAStakeRegistry.sol";
// import {InferenceServiceManager} from "../../src/InferenceServiceManager.sol";
// import {IDelegationManager} from "@eigenlayer/contracts/interfaces/IDelegationManager.sol";
// import {IECDSAStakeRegistryTypes} from "@eigenlayer-middleware/src/interfaces/IECDSAStakeRegistry.sol";
// import {UpgradeableProxyLib} from "./UpgradeableProxyLib.sol";
// import {CoreDeploymentLib} from "./CoreDeploymentLib.sol";
// import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

// library InferenceDeploymentLib {
//     using stdJson for *;
//     using Strings for *;
//     using UpgradeableProxyLib for address;

//     Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

//     struct DeploymentData {
//         address inferenceServiceManager;
//         address stakeRegistry;
//         address strategy;
//         address token;
//     }

//     struct DeploymentConfigData {
//         address rewardsOwner;
//         address rewardsInitiator;
//         uint256 rewardsOwnerKey;
//         uint256 rewardsInitiatorKey;
//     }

//     function deployContracts(
//         address proxyAdmin,
//         CoreDeploymentLib.DeploymentData memory core,
//         IECDSAStakeRegistryTypes.Quorum memory quorum,
//         address rewardsInitiator,
//         address owner
//     ) internal returns (DeploymentData memory) {
//         DeploymentData memory result;

//         // First, deploy upgradeable proxy contracts that will point to the implementations.
//         result.inferenceServiceManager = UpgradeableProxyLib.setUpEmptyProxy(proxyAdmin);
//         // Deploy the implementation contracts, using the proxy contracts as inputs
//         address stakeRegistryImpl =
//             address(new ECDSAStakeRegistry(IDelegationManager(core.delegationManager)));
//         address inferenceServiceManagerImpl = address(
//             new InferenceServiceManager(
//                 core.rewardsCoordinator,
//                 core.delegationManager,
//                 core.allocationManager
//             )
//         );
//         // Upgrade contracts
//         bytes memory upgradeCall = abi.encodeCall(
//             ECDSAStakeRegistry.initialize, (result.inferenceServiceManager, 0, quorum)
//         );
//         UpgradeableProxyLib.upgradeAndCall(result.stakeRegistry, stakeRegistryImpl, upgradeCall);
//         upgradeCall = abi.encodeCall(InferenceServiceManager.initialize, (owner, rewardsInitiator));
//         UpgradeableProxyLib.upgradeAndCall(
//             result.inferenceServiceManager, inferenceServiceManagerImpl, upgradeCall
//         );

//         return result;
//     }

//     function readDeploymentJson(
//         uint256 chainId
//     ) internal view returns (DeploymentData memory) {
//         return readDeploymentJson("deployments/", chainId);
//     }

//     function readDeploymentJson(
//         string memory directoryPath,
//         uint256 chainId
//     ) internal view returns (DeploymentData memory) {
//         string memory fileName = string.concat(directoryPath, vm.toString(chainId), ".json");

//         require(vm.exists(fileName), "InferenceDeployment: Deployment file does not exist");

//         string memory json = vm.readFile(fileName);

//         DeploymentData memory data;
//         /// TODO: 2 Step for reading deployment json.  Read to the core and the AVS data
//         data.inferenceServiceManager = json.readAddress(".addresses.inferenceServiceManager");
//         data.stakeRegistry = json.readAddress(".addresses.stakeRegistry");
//         data.strategy = json.readAddress(".addresses.strategy");
//         data.token = json.readAddress(".addresses.token");

//         return data;
//     }

//     /// write to default output path
//     function writeDeploymentJson(
//         DeploymentData memory data
//     ) internal {
//         writeDeploymentJson("deployments/inference/", block.chainid, data);
//     }

//     function writeDeploymentJson(
//         string memory outputPath,
//         uint256 chainId,
//         DeploymentData memory data
//     ) internal {
//         address proxyAdmin =
//             address(UpgradeableProxyLib.getProxyAdmin(data.inferenceServiceManager));

//         string memory deploymentData = _generateDeploymentJson(data, proxyAdmin);

//         string memory fileName = string.concat(outputPath, vm.toString(chainId), ".json");
//         if (!vm.exists(outputPath)) {
//             vm.createDir(outputPath, true);
//         }

//         vm.writeFile(fileName, deploymentData);
//         console2.log("Deployment artifacts written to:", fileName);
//     }

//     function readDeploymentConfigValues(
//         string memory directoryPath,
//         string memory fileName
//     ) internal view returns (DeploymentConfigData memory) {
//         string memory pathToFile = string.concat(directoryPath, fileName);

//         require(
//             vm.exists(pathToFile), "InferenceDeployment: Deployment Config file does not exist"
//         );

//         string memory json = vm.readFile(pathToFile);

//         DeploymentConfigData memory data;
//         data.rewardsOwner = json.readAddress(".addresses.rewardsOwner");
//         data.rewardsInitiator = json.readAddress(".addresses.rewardsInitiator");
//         data.rewardsOwnerKey = json.readUint(".keys.rewardsOwner");
//         data.rewardsInitiatorKey = json.readUint(".keys.rewardsInitiator");
//         return data;
//     }

//     function readDeploymentConfigValues(
//         string memory directoryPath,
//         uint256 chainId
//     ) internal view returns (DeploymentConfigData memory) {
//         return
//             readDeploymentConfigValues(directoryPath, string.concat(vm.toString(chainId), ".json"));
//     }

//     function _generateDeploymentJson(
//         DeploymentData memory data,
//         address proxyAdmin
//     ) private view returns (string memory) {
//         return string.concat(
//             '{"lastUpdate":{"timestamp":"',
//             vm.toString(block.timestamp),
//             '","block_number":"',
//             vm.toString(block.number),
//             '"},"addresses":',
//             _generateContractsJson(data, proxyAdmin),
//             "}"
//         );
//     }

//     function _generateContractsJson(
//         DeploymentData memory data,
//         address proxyAdmin
//     ) private view returns (string memory) {
//         return string.concat(
//             '{"proxyAdmin":"',
//             proxyAdmin.toHexString(),
//             '","inferenceServiceManager":"',
//             data.inferenceServiceManager.toHexString(),
//             '","inferenceServiceManagerImpl":"',
//             data.inferenceServiceManager.getImplementation().toHexString(),
//             '","stakeRegistry":"',
//             data.stakeRegistry.toHexString(),
//             '","stakeRegistryImpl":"',
//             data.stakeRegistry.getImplementation().toHexString(),
//             '","strategy":"',
//             data.strategy.toHexString(),
//             '","token":"',
//             data.token.toHexString(),
//             '"}'
//         );
//     }
// }
