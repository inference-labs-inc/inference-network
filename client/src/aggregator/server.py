from typing import TYPE_CHECKING, Optional

import uvicorn
from fastapi import APIRouter, FastAPI, HTTPException, Query
from pydantic import BaseModel
from starlette.concurrency import run_in_threadpool

from .errors import InvalidProofError

if TYPE_CHECKING:
    from aggregator.main import Aggregator

ZERO_ADDRESS = "0x0000000000000000000000000000000000000000"
ADDRESS_REGEXP = r"^0x[a-fA-F0-9]{40}$"


class ProofRequest(BaseModel):
    """Pydantic model for operator-submitted proof."""

    task_id: int
    proof: str
    signature: str


class AggregatorServer:
    def __init__(self, aggregator: "Aggregator"):
        self.aggregator = aggregator
        self.eth_client = aggregator.eth_client
        self.app = FastAPI()
        self.router = APIRouter()
        self._register_routes()

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
        self.app.include_router(self.router)

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

    async def inference_stats(
        self,
        model_id: Optional[int] = Query(None, description="Filter by model ID"),
        operator: Optional[str] = Query(
            None, pattern=ADDRESS_REGEXP, description="Filter by operator address"
        ),
        user: Optional[str] = Query(
            None, pattern=ADDRESS_REGEXP, description="Filter by user address"
        ),
    ):
        """
        Get inference task statistics with optional filtering.

        Returns aggregated statistics about tasks including totals, success rates, etc.
        Can filter by model, operator, or user.
        """
        try:
            stats = await run_in_threadpool(
                self._get_task_history_stats, model_id or 0, operator, user
            )
            return {"stats": stats}
        except Exception as exc:
            raise HTTPException(
                status_code=500,
                detail=f"Failed to retrieve inference statistics: {str(exc)}",
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

    def _get_task_history_stats(
        self, model_id: int, operator: Optional[str], user: Optional[str]
    ) -> dict:
        """Get task history statistics."""

        # Convert None to zero address for contract call
        operator_param = operator if operator else ZERO_ADDRESS
        user_param = user if user else ZERO_ADDRESS

        # Get stats from contract
        total_tasks, completed_tasks, rejected_tasks, pending_tasks = (
            self.eth_client.task_manager.functions.getTaskHistoryStats(
                model_id, operator_param, user_param
            ).call()
        )

        return {
            "total_tasks": total_tasks,
            "completed_tasks": completed_tasks,  # RESOLVED tasks
            "rejected_tasks": rejected_tasks,
            "pending_tasks": pending_tasks,  # ASSIGNED + CHALLENGED + COMPLETED
            "success_rate": (
                round(completed_tasks / total_tasks * 100, 2) if total_tasks > 0 else 0
            ),
            "filters": {
                "model_id": model_id if model_id > 0 else None,
                "operator": operator,
                "user": user,
            },
        }

    def _format_task_data(self, task_id: int, task_data: tuple) -> dict:
        """Format raw contract task data into a readable dictionary."""
        from common.contract_constants import TaskStructMap, TaskStateMap

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

    async def health(self):
        return {"status": "running"}

    def start(self):
        host, port = self.aggregator.config.aggregator_server_ip_port_address.split(":")
        uvicorn.run(self.app, host=host, port=int(port))
