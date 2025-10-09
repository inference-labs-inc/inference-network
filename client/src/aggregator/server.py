from typing import TYPE_CHECKING, Optional

import uvicorn
from fastapi import APIRouter, FastAPI, HTTPException, Query
from pydantic import BaseModel
from starlette.concurrency import run_in_threadpool

from aggregator.errors import InvalidProofError
from common.abis import (
    ERC20_ABI,
    STRATEGY_ABI,
)
from common.constants import (
    ADDRESS_REGEXP,
    ETH_STRATEGY_ADDRESSES,
    OPERATOR_SET_ID,
    SERVICE_MANAGER_ADDRESS,
    STRATEGIES_ADDRESSES,
)
from common.contract_constants import TaskStateMap, TaskStructMap

if TYPE_CHECKING:
    from aggregator.main import Aggregator


class ProofRequest(BaseModel):
    """Pydantic model for operator-submitted proof."""

    task_id: int
    proof: str
    signature: str


class AggregatorServer:
    # List of all strategy addresses
    strategies = STRATEGIES_ADDRESSES + ETH_STRATEGY_ADDRESSES
    # OperatorSet is a struct with (avs, id)
    operator_set = (SERVICE_MANAGER_ADDRESS, OPERATOR_SET_ID)

    def __init__(self, aggregator: "Aggregator"):
        self.aggregator = aggregator
        self.eth_client = aggregator.eth_client
        self.app = FastAPI()
        self.router = APIRouter()
        self._register_routes()

    def start(self):
        host, port = self.aggregator.config.aggregator_server_ip_port_address.split(":")
        uvicorn.run(self.app, host=host, port=int(port))

    def _register_routes(self) -> None:
        self.router.add_api_route("/health", self.health, methods=["GET"])
        self.router.add_api_route("/proof", self.submit_proof, methods=["POST"])
        self.router.add_api_route("/models", self.models_list, methods=["GET"])
        self.router.add_api_route(
            "/model-inference-history", self.model_inference_history, methods=["GET"]
        )
        self.router.add_api_route(
            "/operator-inference-history",
            self.operator_inference_history,
            methods=["GET"],
        )
        self.router.add_api_route(
            "/user-inference-history", self.user_inference_history, methods=["GET"]
        )
        self.router.add_api_route(
            "/state-inference-history", self.state_inference_history, methods=["GET"]
        )
        self.router.add_api_route(
            "/inference-stats", self.inference_stats, methods=["GET"]
        )
        self.router.add_api_route("/nodes", self.nodes_list, methods=["GET"])
        self.router.add_api_route("/tvl", self.tvl, methods=["GET"])
        self.app.include_router(self.router)

    async def health(self):
        return {"status": "running"}

    async def submit_proof(self, data: ProofRequest):
        try:
            await run_in_threadpool(
                self.aggregator.process_submitted_proof,
                data.task_id,
                data.proof,
                data.signature,
            )
            return {"status": "ok"}
        except InvalidProofError as exc:
            raise HTTPException(status_code=400, detail=str(exc))

    async def models_list(self):
        try:
            # Get all active models with their details in a single contract call
            models_with_details = await run_in_threadpool(
                self.eth_client.model_registry.functions.getActiveModelsWithDetails().call
            )

            # Convert the contract response to a more readable format
            models = []
            for model_data in models_with_details:
                models.append(
                    {
                        "id": model_data[0],  # modelId
                        "name": model_data[1],  # modelName
                        "verifier": model_data[2],  # modelVerifier
                        "verification_strategy": model_data[3],  # verificationStrategy
                        "compute_cost": model_data[4],  # computeCost
                        "required_fucus": model_data[5],  # requiredFUCUs
                        "is_active": model_data[6],  # isActive
                    }
                )

            return models
        except Exception as exc:
            raise HTTPException(
                status_code=500, detail=f"Failed to retrieve models: {str(exc)}"
            )

    async def model_inference_history(
        self,
        model_id: int = Query(..., description="Model ID to get inference history for"),
        offset: int = Query(0, ge=0, description="Pagination offset"),
        limit: int = Query(20, ge=1, le=100, description="Pagination limit (max 100)"),
        include_details: bool = Query(False, description="Include full task details"),
    ):
        """
        Get inference task history for a specific model with pagination.

        Returns paginated list of task IDs and optionally full task details.
        """
        return await self.inference_history(
            model_id=model_id,
            offset=offset,
            limit=limit,
            include_details=include_details,
        )

    async def operator_inference_history(
        self,
        operator: str = Query(
            ...,
            pattern=ADDRESS_REGEXP,
            description="Operator address to get inference history for",
        ),
        offset: int = Query(0, ge=0, description="Pagination offset"),
        limit: int = Query(20, ge=1, le=100, description="Pagination limit (max 100)"),
        include_details: bool = Query(False, description="Include full task details"),
    ):
        """
        Get inference task history for a specific operator with pagination.

        Returns paginated list of task IDs and optionally full task details.
        """
        return await self.inference_history(
            operator=operator,
            offset=offset,
            limit=limit,
            include_details=include_details,
        )

    async def user_inference_history(
        self,
        user: str = Query(
            ...,
            pattern=ADDRESS_REGEXP,
            description="User address to get inference history for",
        ),
        offset: int = Query(0, ge=0, description="Pagination offset"),
        limit: int = Query(20, ge=1, le=100, description="Pagination limit (max 100)"),
        include_details: bool = Query(False, description="Include full task details"),
    ):
        """
        Get inference task history for a specific user with pagination.

        Returns paginated list of task IDs and optionally full task details.
        """
        return await self.inference_history(
            user=user, offset=offset, limit=limit, include_details=include_details
        )

    async def state_inference_history(
        self,
        state: int = Query(
            ...,
            description=(
                "Task state to get inference history for "
                "(0=CREATED, 1=ASSIGNED, 2=COMPLETED, 3=CHALLENGED, 4=REJECTED, 5=RESOLVED)"
            ),
        ),
        offset: int = Query(0, ge=0, description="Pagination offset"),
        limit: int = Query(20, ge=1, le=100, description="Pagination limit (max 100)"),
        include_details: bool = Query(False, description="Include full task details"),
    ):
        """
        Get inference task history for a specific task state with pagination.

        Returns paginated list of task IDs and optionally full task details.
        """
        return await self.inference_history(
            state=state, offset=offset, limit=limit, include_details=include_details
        )

    async def inference_history(
        self,
        model_id: Optional[int] = None,
        operator: Optional[str] = None,
        user: Optional[str] = None,
        state: Optional[int] = None,
        offset: int = 0,
        limit: int = 20,
        include_details: bool = False,
    ):
        """
        Get inference task history with filtering and pagination.

        Returns paginated list of task IDs and optionally full task details.
        Can filter by model, operator, user, or task state.
        """
        try:

            # Determine which filtering method to use based on provided parameters
            task_ids = await run_in_threadpool(
                self._get_filtered_task_ids,
                model_id,
                operator,
                user,
                state,
                offset,
                limit,
            )

            # If no task details requested, return just the IDs
            if not include_details:
                return {
                    "tasks": task_ids,
                    "pagination": {
                        "offset": offset,
                        "limit": limit,
                        "returned_count": len(task_ids),
                    },
                }

            # Get full task details for each task ID
            tasks = []
            for task_id in task_ids:
                task_data = await run_in_threadpool(
                    self.eth_client.task_manager.functions.getTask(task_id).call
                )
                tasks.append(self._format_task_data(task_id, task_data))

            return {
                "tasks": tasks,
                "pagination": {
                    "offset": offset,
                    "limit": limit,
                    "returned_count": len(tasks),
                },
            }

        except Exception as exc:
            raise HTTPException(
                status_code=500,
                detail=f"Failed to retrieve inference history: {str(exc)}",
            )

    async def inference_stats(self):
        """
        Get inference task statistics with optional filtering.

        Returns aggregated statistics about tasks including totals, success rates, etc.
        Can filter by model, operator, or user.
        """
        try:
            stats = await run_in_threadpool(self._get_task_history_stats)
            return {"stats": stats}
        except Exception as exc:
            raise HTTPException(
                status_code=500,
                detail=f"Failed to retrieve inference statistics: {str(exc)}",
            )

    async def nodes_list(self):
        """
        Get list of all active nodes with full details.

        Returns list of active nodes with complete details including
        operator, name, metadata, FUCUS allocation, and supported models.
        """
        try:
            # Use the efficient contract function to get all active nodes with details
            (
                node_details_arrays,
                supported_models_arrays,
                model_allocations_arrays,
            ) = await run_in_threadpool(
                self.eth_client.nodes_manager.functions.getAllNodesWithDetails().call
            )

            nodes = []
            for i, node_details in enumerate(node_details_arrays):
                # Unpack the uint256[10] array
                node_id = node_details[0]
                operator_uint = node_details[1]
                total_fucus = node_details[2]
                allocated_fucus = node_details[3]
                available_fucus = node_details[4]
                is_active_int = node_details[5]
                created_at = node_details[6]
                supported_models_count = node_details[7]

                # Convert operator back to address
                operator = f"0x{operator_uint:040x}"
                is_active = is_active_int == 1

                # Get name and metadata from individual contract call
                node_data = await run_in_threadpool(
                    self.eth_client.nodes_manager.functions.nodes(node_id).call
                )
                name = node_data[2]
                metadata = node_data[3]

                # Build model configurations
                model_configs = []
                for j, model_id in enumerate(supported_models_arrays[i]):
                    model_configs.append(
                        {
                            "model_id": model_id,
                            "allocated_fucus": model_allocations_arrays[i][j],
                        }
                    )

                nodes.append(
                    {
                        "node_id": node_id,
                        "operator": operator,
                        "name": name,
                        "metadata": metadata,
                        "total_fucus": total_fucus,
                        "allocated_fucus": allocated_fucus,
                        "available_fucus": available_fucus,
                        "is_active": is_active,
                        "created_at": created_at,
                        "supported_models_count": supported_models_count,
                        "supported_models": model_configs,
                    }
                )

            return nodes

        except Exception as exc:
            raise HTTPException(
                status_code=500, detail=f"Failed to retrieve nodes: {str(exc)}"
            )

    async def tvl(self):
        """
        Get Total Value Locked (TVL) for the AVS
        Returns TVL by strategy, showing the total shares delegated.
        """

        try:
            return await run_in_threadpool(self._get_avs_shares)
        except Exception as exc:
            raise HTTPException(
                status_code=500, detail=f"Failed to calculate TVL: {str(exc)}"
            )

    def _get_filtered_task_ids(
        self,
        model_id: Optional[int],
        operator: Optional[str],
        user: Optional[str],
        state: Optional[int],
        offset: int = 0,
        limit: int = 20,
    ) -> list[int]:
        """Get filtered task IDs based on provided filters."""

        # Priority order for filtering (most specific first)
        if state is not None:
            # Filter by task state
            return self.eth_client.task_manager.functions.getTasksByState(
                state, offset, limit
            ).call()
        elif model_id is not None:
            # Filter by model ID
            return self.eth_client.task_manager.functions.getTasksByModel(
                model_id, offset, limit
            ).call()
        elif operator is not None:
            # Filter by operator address
            return self.eth_client.task_manager.functions.getTasksByOperator(
                operator, offset, limit
            ).call()
        elif user is not None:
            # Filter by user address
            return self.eth_client.task_manager.functions.getTasksByUser(
                user, offset, limit
            ).call()
        else:
            # No filters provided, return just latest tasks with pagination
            tasksCount = self.eth_client.task_manager.functions.taskNonce().call() - 1
            if offset >= tasksCount:
                return []
            returnListLength = (
                limit if (offset + limit) <= tasksCount else (tasksCount - offset)
            )
            returnList = []
            for i in range(returnListLength):
                returnList.append(tasksCount - offset - i)
            return returnList

    def _get_task_history_stats(self) -> dict:
        """Get task history statistics."""

        # Get stats from contract
        total_tasks, completed_tasks, rejected_tasks, pending_tasks = (
            self.eth_client.task_manager.functions.getTaskHistoryStats().call()
        )

        return {
            "total_tasks": total_tasks,
            "completed_tasks": completed_tasks,  # RESOLVED tasks
            "rejected_tasks": rejected_tasks,
            "pending_tasks": pending_tasks,  # ASSIGNED + CHALLENGED + COMPLETED
            "success_rate": (
                round(completed_tasks / total_tasks * 100, 2) if total_tasks > 0 else 0
            ),
        }

    def _format_task_data(self, task_id: int, task_data: tuple) -> dict:
        """Format raw contract task data into a readable dictionary."""

        return {
            "task_id": task_id,
            "start_block": task_data[TaskStructMap.START_BLOCK],
            "start_timestamp": task_data[TaskStructMap.START_TIME],
            "model_id": task_data[TaskStructMap.MODEL_ID],
            "inputs": (
                task_data[TaskStructMap.INPUTS].decode("utf-8", errors="ignore")
                if task_data[TaskStructMap.INPUTS]
                else ""
            ),
            "proof_hash": (
                task_data[TaskStructMap.PROOF_HASH].hex()
                if task_data[TaskStructMap.PROOF_HASH]
                else ""
            ),
            "user": task_data[TaskStructMap.USER],
            "nonce": task_data[TaskStructMap.NONCE],
            "operator": task_data[TaskStructMap.OPERATOR],
            "state": {
                "value": task_data[TaskStructMap.STATE],
                "name": TaskStateMap.from_int(task_data[TaskStructMap.STATE]).name,
            },
            "output": (
                task_data[TaskStructMap.OUTPUT].decode("utf-8", errors="ignore")
                if task_data[TaskStructMap.OUTPUT]
                else ""
            ),
            "fee": task_data[TaskStructMap.FEE],
        }

    def _get_avs_shares(self) -> dict:
        """
        Get AVS shares across all strategies and aggregate by strategy and operator.
        TODO: cache it?
        """
        # Get all operators registered to the AVS operator set
        operators = self.eth_client.allocation_manager.functions.getMembers(
            self.operator_set
        ).call()

        # Batch call to get all operators' shares across all strategies
        # Returns uint256[][] - array of arrays where operators_shares[i][j] is
        # operator[i]'s shares in strategy[j]
        operators_shares = (
            (
                self.eth_client.delegation_manager.functions.getOperatorsShares(
                    operators, self.strategies
                ).call()
            )
            if operators
            else []
        )

        # Get strategy metadata (token details) for all strategies
        strategy_metadata: dict[str, dict[str, str]] = self._get_strategies_details(
            self.strategies
        )

        # Aggregate shares by strategy
        # strategy_addr -> {total_shares, total_amount, token, symbol, decimals}
        tvl_by_strategy = {}
        # Also prepare breakdown by operator
        # operator_addr -> [(token_addr, symbol, amount), ...]
        tvl_by_operator = {}

        for op_idx, operator in enumerate(operators):
            operator_tokens = []

            for strategy_idx, strategy_address in enumerate(self.strategies):
                shares = operators_shares[op_idx][strategy_idx]

                if shares > 0:
                    # Initialize strategy entry if not exists
                    if strategy_address not in tvl_by_strategy:
                        metadata = strategy_metadata.get(strategy_address, {})
                        tvl_by_strategy[strategy_address] = {
                            "total_shares": 0,
                            "total_amount": 0.0,
                            "operators_count": 0,
                            **metadata,
                        }

                    # Add to strategy total
                    tvl_by_strategy[strategy_address]["total_shares"] += shares
                    tvl_by_strategy[strategy_address]["operators_count"] += 1

                    # Add to operator's token breakdown
                    operator_tokens.append(
                        {
                            "strategy": strategy_address,
                            "token": tvl_by_strategy[strategy_address]["token"],
                            "symbol": tvl_by_strategy[strategy_address]["symbol"],
                            "shares": shares,
                            "amount": shares,
                        }
                    )

                    # Update human-readable amount if we have decimals
                    if "decimals" in tvl_by_strategy[strategy_address]:
                        decimals = tvl_by_strategy[strategy_address]["decimals"]
                        tvl_by_strategy[strategy_address]["total_amount"] = (
                            tvl_by_strategy[strategy_address]["total_shares"]
                            / (10**decimals)
                        )
                        operator_tokens[-1]["amount"] = shares / (10**decimals)
                    else:
                        tvl_by_strategy[strategy_address]["total_amount"] += shares

            if operator_tokens:
                tvl_by_operator[operator] = operator_tokens

        return {
            "total_operators": len(operators),
            "active_operators": len(tvl_by_operator),
            "strategies_count": len(self.strategies),
            "tvl_by_strategy": tvl_by_strategy,
            "tvl_by_operator": tvl_by_operator,
        }

    def _get_strategies_details(
        self, strategies: list[str]
    ) -> dict[str, dict[str, str]]:
        """
        Get strategy details including underlying token symbol and decimals.
        Returns a mapping of strategy address to its details (token, symbol, decimals).
        TODO: cache this result to avoid repeated calls.
        """
        strategies_metadata = {}
        for strategy_address in strategies:
            strategy_contract = self.eth_client.w3.eth.contract(
                address=strategy_address,
                abi=STRATEGY_ABI,
            )
            token_address = strategy_contract.functions.underlyingToken().call()
            token_contract = self.eth_client.w3.eth.contract(
                address=token_address,
                abi=ERC20_ABI,
            )
            symbol = token_contract.functions.symbol().call()
            decimals = token_contract.functions.decimals().call()

            strategies_metadata[strategy_address] = {
                "token": token_address,
                "symbol": symbol,
                "decimals": decimals,
            }
        return strategies_metadata
