from __future__ import annotations
from pydantic import BaseModel
from models.execution_layer.base_input import BaseInput
from models.execution_layer.request_type import RequestType
import random

LIST_SIZE = 5


class CircuitInput(BaseInput):

    def __init__(
        self, request_type: RequestType, data: dict[str, object] | None = None
    ):
        super().__init__(request_type, data)

    @staticmethod
    def generate() -> list[float]:
        return [random.uniform(0.0, 0.85) for _ in range(LIST_SIZE)]

    @staticmethod
    def process(data: dict[str, object]) -> dict[str, object]:
        """
        No processing needs to take place, as all inputs are randomized.
        """
        return data
