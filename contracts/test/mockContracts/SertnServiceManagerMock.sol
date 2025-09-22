// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.29;

contract MockSertnServiceManager {
    mapping(address => bool) public aggregators;

    event FeesPulled(address user, address token, uint256 amount);
    event TaskCompleted(address operator, uint256 fee, address strategy);
    event OperatorSlashed(address operator, uint256 fee, uint32 operatorSetId, address strategy);

    function addAggregator(address aggregator) external {
        aggregators[aggregator] = true;
    }

    function isAggregator(address aggregator) external view returns (bool) {
        return aggregators[aggregator];
    }

    function pullFeeFromUser(address user, address token, uint256 fee) external {
        emit FeesPulled(user, token, fee);
    }

    function taskResolved(address operator, uint256 fee, address strategy, uint32) external {
        emit TaskCompleted(operator, fee, strategy);
    }

    function slashOperator(
        address operator,
        uint256 fee,
        uint32 operatorSetId,
        address strategy
    ) external {
        emit OperatorSlashed(operator, fee, operatorSetId, strategy);
    }
}
