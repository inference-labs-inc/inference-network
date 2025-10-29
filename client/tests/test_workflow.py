import time

import requests

from aggregator.main import Aggregator
from avs_operator.main import TaskOperator
from common.addresses import addresses
from common.contract_constants import TaskStateMap, TaskStructMap
from management.owner import AvsOwner


class TestWorkflow:

    def make_request(self, path, **params):
        params = {"limit": 100, "offset": 0, "include_details": False, **params}
        res = requests.get(f"http://localhost:8090/{path}", params=params)
        assert res.status_code == 200
        return res.json()

    def test_process_task(
        self,
        aggregator: Aggregator,
        aggregator_server: Aggregator,
        operator: TaskOperator,
        owner: AvsOwner,
        init_environment: dict,
        strategies: list,
    ):
        """
        Simulate end-to-end task processing workflow:
        - Create a new task
        - Operator processes the task
        - Aggregator challenges the task
        - Operator generates proof
        - Aggregator resolves the task
        - Verify rewards distribution
        """
        # get underlying token address for the future task
        token_address = strategies[0].functions.underlyingToken().call()

        # Get the operator's fees before processing the task
        res = self.make_request("fees", hours=24)
        base_operator_fee = (
            res["rewards_by_operator"]
            .get(operator.operator_address, {})
            .get(token_address, {})
            .get("operator_share", 0)
        )

        # create a new task
        task_id = aggregator.send_new_task(1)
        assert task_id is not None, "Task ID should not be None"

        # here task should be assigned to the operator
        res = self.make_request(
            "operator-inference-history", operator=operator.operator_address
        )
        assert task_id in res["tasks"]

        # check that the task is visible in the stats endpoint
        res = self.make_request(
            "state-inference-history", state=TaskStateMap.ASSIGNED.value
        )
        assert task_id in res["tasks"]

        # process the task by the operator
        processed_count = operator.listen_for_events(loop_running=False)
        assert processed_count == 1, "Operator should process one task"
        # the task should be marked as completed

        # check that the task is not visible in the assigned state
        res = self.make_request(
            "state-inference-history", state=TaskStateMap.ASSIGNED.value
        )
        assert task_id not in res["tasks"]
        # and is visible in the completed state
        res = self.make_request(
            "state-inference-history", state=TaskStateMap.COMPLETED.value
        )
        assert task_id in res["tasks"]

        # checkout the completed task
        processed_count = aggregator.listen_for_events(loop_running=False)
        assert processed_count == 1, "Aggregator should process one task"
        # At this point the task should be challenged

        time.sleep(5)
        # Check that the task is not visible in the completed state
        res = self.make_request(
            "state-inference-history", state=TaskStateMap.COMPLETED.value
        )
        assert task_id not in res["tasks"]
        # and is visible in the challenged state
        res = self.make_request(
            "state-inference-history", state=TaskStateMap.CHALLENGED.value
        )
        assert task_id in res["tasks"]

        # check events by the operator, it should process the challenge and generate proof
        processed_count = operator.listen_for_events(loop_running=False)
        assert processed_count == 1, "Operator should process one challenge"
        # the proof should be sent to the aggregator

        # here the task should be resolved by the aggregator
        task = aggregator.eth_client.task_manager.functions.getTask(task_id).call()
        assert task[TaskStructMap.STATE] == TaskStateMap.RESOLVED
        model_id = task[TaskStructMap.MODEL_ID]
        user = task[TaskStructMap.USER]

        # Check that the model is not visible in the challenged state
        res = self.make_request(
            "state-inference-history", state=TaskStateMap.CHALLENGED.value
        )
        assert task_id not in res["tasks"]
        # and is visible in the resolved state
        res = self.make_request(
            "state-inference-history",
            state=TaskStateMap.RESOLVED.value,
            limit=1,
            offset=0,
        )
        assert [task_id] == res["tasks"]
        # and the task is visible in the model-specific history
        res = self.make_request("model-inference-history", model_id=model_id)
        assert task_id in res["tasks"]
        # and the task is visible in the user-specific history
        res = self.make_request("user-inference-history", user=user, limit=1, offset=0)
        assert [task_id] == res["tasks"]

        # check rewards collected for the operator
        operators_in_interval: list = (
            aggregator.eth_client.service_manager.functions.getOperatorsInInterval(
                init_environment["current_interval"]
            ).call()
        )
        strategies_in_interval: list = (
            aggregator.eth_client.service_manager.functions.getStrategiesInInterval(
                init_environment["current_interval"]
            ).call()
        )
        # Get the rewards for the operator after processing the task
        rewards = aggregator.eth_client.service_manager.functions.getIntervalRewards(
            init_environment["current_interval"],
            operator.operator_address,
            addresses.STRATEGIES_ADDRESSES[0],
        ).call()
        model_cost: int = aggregator.eth_client.model_registry.functions.computeCost(
            model_id
        ).call()
        assert operators_in_interval == [
            operator.operator_address,
        ], "Operator should be in the current interval"
        assert strategies_in_interval == [
            addresses.STRATEGIES_ADDRESSES[0],
        ], "Aggregator should be in the current interval"
        assert (
            rewards == model_cost
        ), "Operator should receive rewards equal to the model cost"

        # Fast forward blockchain time by one interval
        aggregator.eth_client.w3.provider.make_request(
            "evm_increaseTime", [init_environment["interval_seconds"]]
        )
        aggregator.eth_client.w3.provider.make_request("evm_mine", [])

        # Submit rewards for the interval
        owner.submit_rewards_for_interval(init_environment["current_interval"])

        # Check the fees accumulated during the interval (smoke test)
        res = self.make_request("fees", hours=24)
        updated_operator_fee = (
            res["rewards_by_operator"]
            .get(operator.operator_address, {})
            .get(token_address, {})
            .get("operator_share", 0)
        )
        assert (
            updated_operator_fee > base_operator_fee
        ), "Operator's fees should increase after processing the task"

    def test_task_incorrect_proof(
        self,
        aggregator: Aggregator,
        aggregator_server: Aggregator,
        operator: TaskOperator,
        owner: AvsOwner,
        init_environment: dict,
    ):
        """Just a smoke test to ensure send_new_task runs without errors"""

        # Mock the generate_proof_for_task method to return incorrect proof
        def mock_generate_proof_for_task(*args, **kwargs) -> str:
            return '{"instances":[[1,2,3,4,5,6]]}'

        operator.generate_proof_for_task = mock_generate_proof_for_task
        initial_shares = (
            aggregator.eth_client.delegation_manager.functions.operatorShares(
                operator.operator_address, addresses.STRATEGIES_ADDRESSES[0]
            ).call()
        )
        initial_rewards = (
            aggregator.eth_client.service_manager.functions.getIntervalRewards(
                init_environment["current_interval"],
                operator.operator_address,
                addresses.STRATEGIES_ADDRESSES[0],
            ).call()
        )

        # create a new task
        task_id = aggregator.send_new_task(2)
        assert task_id is not None, "Task ID should not be None"
        # here task  should be assigned to the operator

        # process the task by the operator
        processed_count = operator.listen_for_events(loop_running=False)
        assert processed_count == 1, "Operator should process one task"
        # the task should be marked as completed

        # checkout the completed task
        processed_count = aggregator.listen_for_events(loop_running=False)
        assert processed_count == 1, "Aggregator should process one task"
        # At this point the task should be challenged

        time.sleep(5)

        # check events by the operator, it should process the challenge and generate proof
        processed_count = operator.listen_for_events(loop_running=False)
        assert processed_count == 1, "Operator should process one challenge"
        # the proof should be sent to the aggregator

        # here the task should be resolved by the aggregator
        task = aggregator.eth_client.task_manager.functions.getTask(task_id).call()
        assert task[TaskStructMap.STATE] == TaskStateMap.REJECTED.value

        # Check that the task is not visible in the challenged state
        res = self.make_request(
            "state-inference-history", state=TaskStateMap.CHALLENGED.value
        )
        assert task_id not in res["tasks"]
        # and is visible in the rejected state
        res = self.make_request(
            "state-inference-history", state=TaskStateMap.REJECTED.value
        )
        assert task_id in res["tasks"]

        # check rewards collected for the operator
        operators_in_interval: list = (
            aggregator.eth_client.service_manager.functions.getOperatorsInInterval(
                init_environment["current_interval"]
            ).call()
        )
        assert (
            operator.operator_address not in operators_in_interval
        ), "Operator should NOT be in the current interval"

        final_shares = (
            aggregator.eth_client.delegation_manager.functions.operatorShares(
                operator.operator_address, addresses.STRATEGIES_ADDRESSES[0]
            ).call()
        )
        assert (
            initial_shares - final_shares
        ) / initial_shares == 0.1, "Operator's shares are reduced by 10%"

        final_rewards = (
            aggregator.eth_client.service_manager.functions.getIntervalRewards(
                init_environment["current_interval"],
                operator.operator_address,
                addresses.STRATEGIES_ADDRESSES[0],
            ).call()
        )
        assert final_rewards == initial_rewards, "No new rewards for the operator"

    def test_tvl_endpoint(self, aggregator_server):
        """
        Just a smoke test to ensure /tvl endpoint works and returns expected fields
        """
        response = requests.get("http://localhost:8090/tvl")
        assert response.status_code == 200
        data = response.json()
        assert "tvl_by_operator" in data
        assert "tvl_by_strategy" in data
        assert data["total_operators"] == 1
        assert data["active_operators"] == 1
        assert data["strategies_count"] == 5
