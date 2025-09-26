import asyncio
import threading
import time

import uvicorn

from aggregator.main import Aggregator
from avs_operator.main import TaskOperator
from common.constants import STRATEGIES_ADDRESSES
from common.contract_constants import TaskStateMap, TaskStructMap
from management.owner import AvsOwner


class TestWorkflow:

    def start_aggregator_server(self, aggregator: Aggregator):
        self._stop_event = threading.Event()
        config = uvicorn.Config(
            app=aggregator.server.app, host="0.0.0.0", port=8090, log_level="info"
        )
        self.server = uvicorn.Server(config)

        # Run server until stop event is set
        loop = asyncio.new_event_loop()
        asyncio.set_event_loop(loop)

        try:
            loop.run_until_complete(self.server.serve())
        except asyncio.CancelledError:
            pass
        finally:
            loop.close()

    def stop_aggregator_server(self):
        """Stop server thread"""
        if self.server:
            self.server.should_exit = True
        self._stop_event.set()

    def test_process_task(
        self,
        aggregator: Aggregator,
        operator: TaskOperator,
        owner: AvsOwner,
        init_environment: dict,
    ):
        """Just a smoke test to ensure send_new_task runs without errors"""

        # create a new task
        task_id = aggregator.send_new_task(1)
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

        # start aggregator server in a separate thread
        # This is necessary to allow the aggregator to listen for events and process the challenge
        aggregator_server = threading.Thread(
            target=self.start_aggregator_server, args=[aggregator]
        )
        aggregator_server.start()
        time.sleep(5)

        # check events by the operator, it should process the challenge and generate proof
        processed_count = operator.listen_for_events(loop_running=False)
        assert processed_count == 1, "Operator should process one challenge"
        # the proof should be sent to the aggregator

        # here the task should be resolved by the aggregator
        task = aggregator.eth_client.task_manager.functions.getTask(task_id).call()
        assert task[TaskStructMap.STATE] == TaskStateMap.RESOLVED
        model_id = task[TaskStructMap.MODEL_ID]

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
            STRATEGIES_ADDRESSES[0],
        ).call()
        model_cost: int = aggregator.eth_client.model_registry.functions.computeCost(
            model_id
        ).call()
        assert operators_in_interval == [
            operator.operator_address,
        ], "Operator should be in the current interval"
        assert strategies_in_interval == [
            STRATEGIES_ADDRESSES[0],
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

        self.stop_aggregator_server()
        if aggregator_server:
            aggregator_server.join(timeout=5)  # Wait up to 5 seconds

    def test_task_incorrect_proof(
        self,
        aggregator: Aggregator,
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
                operator.operator_address, STRATEGIES_ADDRESSES[0]
            ).call()
        )
        initial_rewards = (
            aggregator.eth_client.service_manager.functions.getIntervalRewards(
                init_environment["current_interval"],
                operator.operator_address,
                STRATEGIES_ADDRESSES[0],
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

        # start aggregator server in a separate thread
        # This is necessary to allow the aggregator to listen for events and process the challenge
        aggregator_server = threading.Thread(
            target=self.start_aggregator_server, args=[aggregator]
        )
        aggregator_server.start()
        time.sleep(5)

        # check events by the operator, it should process the challenge and generate proof
        processed_count = operator.listen_for_events(loop_running=False)
        assert processed_count == 1, "Operator should process one challenge"
        # the proof should be sent to the aggregator

        # here the task should be resolved by the aggregator
        task = aggregator.eth_client.task_manager.functions.getTask(task_id).call()
        assert task[TaskStructMap.STATE] == TaskStateMap.REJECTED.value
        # model_id = task[TaskStructMap.MODEL_ID]

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
                operator.operator_address, STRATEGIES_ADDRESSES[0]
            ).call()
        )
        assert (
            initial_shares - final_shares
        ) / initial_shares == 0.1, "Operator's shares are reduced by 10%"

        final_rewards = (
            aggregator.eth_client.service_manager.functions.getIntervalRewards(
                init_environment["current_interval"],
                operator.operator_address,
                STRATEGIES_ADDRESSES[0],
            ).call()
        )
        assert final_rewards == initial_rewards, "No new rewards for the operator"

        self.stop_aggregator_server()
        if aggregator_server:
            aggregator_server.join(timeout=5)  # Wait up to 5 seconds
