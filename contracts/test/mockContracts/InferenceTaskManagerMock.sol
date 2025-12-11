// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

contract MockInferenceTaskManager {
    address public inferenceServiceManager;

    function setServiceManager(address _serviceManager) external {
        inferenceServiceManager = _serviceManager;
    }
}
