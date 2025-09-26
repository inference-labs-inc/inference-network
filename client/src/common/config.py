"""
Configuration models and validation for Sertn AVS.

This module provides Pydantic models for validating YAML configuration files
used by both operators and aggregators.
"""

from enum import Enum
from pathlib import Path
from typing import List, Literal, Optional, Union

import yaml
from pydantic import BaseModel, Field, field_validator, model_validator


class Environment(str, Enum):
    """Environment types for logging and behavior configuration."""

    PRODUCTION = "production"
    DEVELOPMENT = "development"
    TESTING = "testing"


class GasStrategy(str, Enum):
    """Gas strategies for transaction execution."""

    SLOW = "slow"
    STANDARD = "standard"
    FAST = "fast"
    PRIORITY = "priority"


class ModelConfig(BaseModel):
    """Configuration for a model supported by an operator node."""

    model_name: str = Field(
        ..., description="Name identifier for the model", min_length=1
    )
    allocated_fucus: int = Field(
        ..., description="Amount of FUCUs allocated to this model", gt=0
    )


class NodeConfig(BaseModel):
    """Configuration for an operator node."""

    node_name: str = Field(
        ..., description="Unique name for the node", min_length=1, max_length=100
    )
    metadata: Optional[str] = Field(
        default="", description="Optional metadata for the node", max_length=500
    )
    total_fucus: int = Field(
        ..., description="Total FUCUs available for this node", gt=0
    )
    is_active: bool = Field(default=True, description="Whether the node is active")
    models: List[ModelConfig] = Field(
        default_factory=list, description="List of models supported by this node"
    )

    @model_validator(mode="after")
    def validate_fucus_allocation(self) -> "NodeConfig":
        """Validate that allocated FUCUs don't exceed total FUCUs."""
        if not self.models:
            return self

        total_allocated = sum(model.allocated_fucus for model in self.models)
        if total_allocated > self.total_fucus:
            raise ValueError(
                f"Total allocated FUCUs ({total_allocated}) exceeds "
                f"total available FUCUs ({self.total_fucus})"
            )
        return self


class BaseConfig(BaseModel):
    """Base configuration shared by both operator and aggregator."""

    model_config = {"extra": "forbid"}  # Prevent unknown fields

    environment: Environment = Field(
        default=Environment.PRODUCTION,
        description="Environment setting for logging and behavior",
    )
    eth_rpc_url: str = Field(description="Ethereum RPC URL")
    ecdsa_private_key_store_path: Path = Field(
        ..., description="Path to ECDSA private key file"
    )
    gas_strategy: GasStrategy = Field(
        default=GasStrategy.STANDARD,
        description="Gas strategy for transaction execution",
    )
    auto_update: bool = Field(
        default=True,
        description="Enable automatic updates for the application",
    )

    @field_validator("ecdsa_private_key_store_path")
    @classmethod
    def validate_key_file_exists(cls, v: Path) -> Path:
        """Validate that the ECDSA key file exists."""
        if not v.exists() or not v.is_file():
            raise ValueError(f"ECDSA private key file not found: {v}")
        return v


class OperatorConfig(BaseConfig):
    """Configuration for Sertn AVS Operator."""

    aggregator_server_ip_port_address: str = Field(
        description="Address where aggregator server listens",
        pattern=r"^[^:]+:\d+$",
    )

    nodes: List[NodeConfig] = Field(
        default_factory=list, description="List of operator nodes"
    )

    @model_validator(mode="after")
    def validate_unique_node_names(self) -> "OperatorConfig":
        """Validate that all node names are unique."""
        if not self.nodes:
            return self

        node_names = [node.node_name for node in self.nodes]
        if len(node_names) != len(set(node_names)):
            duplicates = [name for name in node_names if node_names.count(name) > 1]
            raise ValueError(f"Duplicate node names found: {set(duplicates)}")
        return self


class AggregatorConfig(BaseConfig):
    """Configuration for Sertn AVS Aggregator."""

    eth_ws_url: str = Field(
        default="ws://localhost:8545",
        description="Ethereum WebSocket URL for event listening",
    )
    aggregator_server_ip_port_address: str = Field(
        description="Address where aggregator server listens",
        pattern=r"^[^:]+:\d+$",
    )
    proof_request_probability: float = Field(
        default=0.4,
        description="Probability of requesting proofs from operators (0.0 to 1.0)",
        ge=0.0,
        le=1.0,
    )


class OwnerConfig(BaseConfig):
    """Configuration for AVS Owner operations."""

    pass


def load_config(
    config_path: Union[str, Path],
    config_type: Literal["operator", "aggregator", "owner"],
) -> Union[OperatorConfig, AggregatorConfig, OwnerConfig]:
    """
    Load and validate configuration from a YAML file.

    Args:
        config_path: Path to the YAML configuration file
        config_type: Type of configuration to load ("operator", "aggregator", or "owner")

    Returns:
        Validated configuration object

    Raises:
        FileNotFoundError: If config file doesn't exist
        ValueError: If configuration is invalid
        yaml.YAMLError: If YAML is malformed
    """
    config_path = Path(config_path)

    if not config_path.exists():
        raise FileNotFoundError(f"Configuration file not found: {config_path}")

    try:
        with open(config_path, "r", encoding="utf-8") as f:
            config_data = yaml.safe_load(f)
    except yaml.YAMLError as e:
        raise yaml.YAMLError(f"Invalid YAML in {config_path}: {e}") from e

    if config_data is None:
        config_data = {}

    try:
        if config_type == "operator":
            return OperatorConfig(**config_data)
        elif config_type == "aggregator":
            return AggregatorConfig(**config_data)
        elif config_type == "owner":
            return OwnerConfig(**config_data)
        else:
            raise ValueError(f"Unknown config type: {config_type}")
    except Exception as e:
        raise ValueError(
            f"Configuration validation failed for {config_path}: {e}"
        ) from e
