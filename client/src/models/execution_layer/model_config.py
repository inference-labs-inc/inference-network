"""
Pydantic models for model metadata configuration.

This module provides Pydantic models for validating model metadata JSON files
used in the Sertn AVS system.
"""

import json
from enum import Enum
from pathlib import Path
from typing import Dict, Optional, Union

from common.contract_constants import ContractVerificationStrategy
from pydantic import BaseModel, Field, field_validator, HttpUrl


class ProofSystem(str, Enum):
    """Supported proof systems."""

    EZKL = "EZKL"
    RISC0 = "RISC0"
    SP1 = "SP1"


class ModelType(str, Enum):
    """Model types supported by the system."""

    PROOF_OF_COMPUTATION = "proof_of_computation"
    PROOF_OF_INFERENCE = "proof_of_inference"
    PROOF_OF_TRAINING = "proof_of_training"


class ConfigVerificationStrategy(str, Enum):
    """Verification strategies for model proofs."""

    ONCHAIN = "onchain"
    OFFCHAIN = "offchain"
    HYBRID = "hybrid"


VERIFICATION_STRATEGY_MAP = {
    ConfigVerificationStrategy.ONCHAIN: ContractVerificationStrategy.ONCHAIN,
    ConfigVerificationStrategy.OFFCHAIN: ContractVerificationStrategy.OFFCHAIN,
    ConfigVerificationStrategy.HYBRID: ContractVerificationStrategy.NONE,
}


class ModelMetadata(BaseModel):
    """
    Pydantic model for model metadata configuration.

    This model validates the metadata.json files found in model directories.
    """

    model_config = {"extra": "allow"}  # Allow unknown fields

    name: str = Field(
        ...,
        description="Human-readable name of the model",
        min_length=1,
        max_length=100,
    )

    description: str = Field(
        ...,
        description="Detailed description of the model's purpose and functionality",
        min_length=1,
        max_length=1000,
    )

    author: str = Field(
        ...,
        description="Author or organization that created the model",
        min_length=1,
        max_length=100,
    )

    version: str = Field(
        ...,
        description="Version of the model (semantic versioning recommended)",
        min_length=1,
        max_length=20,
        pattern=r"^\d+\.\d+\.\d+(-[a-zA-Z0-9-]+)?$",
    )

    proof_system: ProofSystem = Field(
        ..., description="Proof system used for generating proofs"
    )

    type: ModelType = Field(..., description="Type of the model based on its use case")

    external_files: Optional[Dict[str, Union[HttpUrl, str]]] = Field(
        default=None,
        description="External files required by the model (e.g., proving keys, verification keys)",
    )

    verification_strategy: ConfigVerificationStrategy = Field(
        ..., description="Strategy used for proof verification"
    )

    model_verifier_address: Optional[str] = Field(
        default=None,
        description="Ethereum address of the model verifier contract",
        pattern=r"^0x[a-fA-F0-9]{40}$",
    )

    compute_cost: int = Field(
        ...,
        description="Computational cost as an integer (e.g., WEI)",
        ge=0,
    )

    required_fucus: int = Field(
        ...,
        description="Required FUCUS (computational units) for running this model",
        ge=0,
    )

    is_active: bool = Field(
        default=True,
        description="If false, this model will be disabled on-chain and ignored locally",
    )

    @field_validator("external_files")
    @classmethod
    def validate_external_files(
        cls, v: Optional[Dict[str, Union[HttpUrl, str]]]
    ) -> Optional[Dict[str, Union[HttpUrl, str]]]:
        """Validate external files dictionary."""
        if v is None:
            return v

        # Validate that all values are either valid URLs or file paths
        for filename, url_or_path in v.items():
            if not filename:
                raise ValueError("External file names cannot be empty")

            # If it's a string, it should be a valid URL or file path
            if isinstance(url_or_path, str):
                if not (
                    url_or_path.startswith(("http://", "https://"))
                    or url_or_path.startswith(".")
                    or url_or_path.startswith("/")
                ):
                    raise ValueError(
                        f"External file '{filename}' must be a valid URL or file path"
                    )

        return v

    @field_validator("compute_cost")
    @classmethod
    def validate_compute_cost(cls, v: int) -> int:
        """Validate compute cost is a non-negative integer."""
        if v < 0:
            raise ValueError("Compute cost must be non-negative")
        return v


class ExternalFile(BaseModel):
    """Model for external file references in metadata."""

    name: str = Field(..., description="Name of the external file", min_length=1)

    url: HttpUrl = Field(..., description="URL to download the external file")

    checksum: Optional[str] = Field(
        default=None,
        description="SHA256 checksum of the file for integrity verification",
        pattern=r"^[a-fA-F0-9]{64}$",
    )

    size_bytes: Optional[int] = Field(
        default=None, description="Size of the file in bytes", gt=0
    )


def load_model_metadata(metadata_path: Union[str, Path]) -> ModelMetadata:
    """
    Load and validate model metadata from a JSON file.
    """
    metadata_path = Path(metadata_path)

    if not metadata_path.exists():
        raise FileNotFoundError(f"Metadata file not found: {metadata_path}")

    try:
        with open(metadata_path, "r", encoding="utf-8") as f:
            metadata_data = json.load(f)
    except json.JSONDecodeError as e:
        raise json.JSONDecodeError(
            f"Invalid JSON in {metadata_path}: {e}", e.doc, e.pos
        )

    return ModelMetadata(**metadata_data)
