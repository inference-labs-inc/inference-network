// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {OwnableUpgradeable} from "@openzeppelin-upgrades/contracts/access/OwnableUpgradeable.sol";
import {IInferenceAggregator} from "../interfaces/IInferenceAggregator.sol";
import {IInferenceTaskManager} from "../interfaces/IInferenceTaskManager.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/**
 * @title Inference Aggregator
 * @author Inference Labs, Inc.
 * @notice Aggregator for Inference tasks.
 */
contract InferenceAggregator is OwnableUpgradeable, IInferenceAggregator {
    address public aggregatorEOA;
    IInferenceTaskManager public inferenceTaskManager;

    function initialize(address _aggregatorEOA, address _inferenceTaskManager) public initializer {
        __Ownable_init();
        aggregatorEOA = _aggregatorEOA;
        inferenceTaskManager = IInferenceTaskManager(_inferenceTaskManager);
    }

    function updateAggregatorEOA(address _aggregatorEOA) external onlyOwner {
        if (_aggregatorEOA == address(0)) {
            revert ZeroAddress();
        }
        aggregatorEOA = _aggregatorEOA;
    }

    function updateInferenceTaskManager(address _inferenceTaskManager) external onlyOwner {
        if (_inferenceTaskManager == address(0)) {
            revert ZeroAddress();
        }
        inferenceTaskManager = IInferenceTaskManager(_inferenceTaskManager);
    }

    function submitTask(IInferenceTaskManager.Task memory _task, bytes memory _proof) external {
        bytes32 messageHash = keccak256(abi.encode(_task));
        address signer = ECDSA.recover(ECDSA.toEthSignedMessageHash(messageHash), _proof);

        if (signer != aggregatorEOA) {
            revert InvalidEOASignature();
        }

        inferenceTaskManager.sendTask(_task);
        emit TaskSubmitted(messageHash, msg.sender);
    }
}
