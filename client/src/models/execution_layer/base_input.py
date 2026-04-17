from __future__ import annotations
from abc import ABC, abstractmethod
from typing import Any

from models.execution_layer.request_type import RequestType


class BaseInput(ABC):
    """
    Base class for circuit-specific input data. Stores and provides interface
    for manipulating circuit input data.
    """

    def __init__(
        self,
        request_type: RequestType,
        data: dict[str, Any] | None = None,
    ) -> None:
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
        """Generate new benchmarking input data for this circuit.

        Returns:
            List of float values representing the generated input data.
        """
        pass

    @staticmethod
    @abstractmethod
    def validate(data: dict[str, Any]) -> None:
        """Validate raw input data before processing.

        Args:
            data: Raw input data dictionary to validate.

        Raises:
            ValueError: If the input data is invalid.
        """
        pass

    @staticmethod
    @abstractmethod
    def process(data: dict[str, Any]) -> dict[str, Any]:
        """Process raw input data into standardized format.

        Args:
            data: Raw input data dictionary to process.

        Returns:
            Processed data in standardized format.
        """
        pass
