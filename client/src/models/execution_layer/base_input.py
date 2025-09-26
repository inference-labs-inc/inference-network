from __future__ import annotations
from abc import ABC, abstractmethod
from models.execution_layer.request_type import RequestType


class BaseInput(ABC):
    """
    Base class for circuit-specific input data. Stores and provides interface
    for manipulating circuit input data.
    """

    def __init__(
        self,
        request_type: RequestType,
        data: dict[str, object] | None = None,
    ):
        self.request_type = request_type
        if request_type == RequestType.BENCHMARK:
            self.data = self.generate()
        else:
            if data is None:
                raise ValueError("Data must be provided for non-benchmark requests")
            self.validate(data)
            self.data = self.process(data)

    @staticmethod
    @abstractmethod
    def generate() -> list[float]:
        """Generates new benchmarking input data for this circuit"""
        pass

    @staticmethod
    @abstractmethod
    def process(self, data: dict[str, object]) -> dict[str, object]:
        """Processes raw input data into standardized format"""
        pass
