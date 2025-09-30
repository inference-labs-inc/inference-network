// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.12;

import {IInferenceRegistrar} from "../../interfaces/IInferenceRegistrar.sol";

contract MockAVSRegistrar is IInferenceRegistrar {
    event OperatorRegistered(
        address operator,
        address avsIdentifier,
        uint32[] operatorSetIds,
        bytes data
    );
    event OperatorDeregistered(address operator, address avsIdentifier, uint32[] operatorSetIds);

    function registerOperator(
        address operator,
        address avsIdentifier,
        uint32[] calldata operatorSetIds,
        bytes calldata data
    ) external override {
        emit OperatorRegistered(operator, avsIdentifier, operatorSetIds, data);
    }

    function deregisterOperator(
        address operator,
        address avsIdentifier,
        uint32[] calldata operatorSetIds
    ) external override {
        emit OperatorDeregistered(operator, avsIdentifier, operatorSetIds);
    }

    function supportsAVS(address) external pure returns (bool) {
        // For the mock, we assume all AVS are supported
        return true;
    }
}
