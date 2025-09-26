from typing import TYPE_CHECKING

import uvicorn
from fastapi import APIRouter, FastAPI, HTTPException
from pydantic import BaseModel
from starlette.concurrency import run_in_threadpool

from .errors import InvalidProofError

if TYPE_CHECKING:
    from aggregator.main import Aggregator


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
        self.router.add_api_route("/proof", self.submit_proof, methods=["POST"])
        self.router.add_api_route("/health", self.health, methods=["GET"])
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

    async def health(self):
        return {"status": "running"}

    def start(self):
        host, port = self.aggregator.config.aggregator_server_ip_port_address.split(":")
        uvicorn.run(self.app, host=host, port=int(port))
