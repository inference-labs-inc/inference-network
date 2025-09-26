"""
Management commands for AVS Owner operations.

This module contains CLI commands for managing models, rewards, and other
AVS owner operations.
"""

import os
from typing import Optional

import typer

from common.config import OwnerConfig, load_config
from common.constants import MODELS_DATA_DIR
from common.logging import get_logger, setup_logging
from common.eth import load_ecdsa_private_key
from models.execution_layer.model_registry import ModelRegistry

# Create a sub-application for management commands
manage_app = typer.Typer(
    name="manage",
    help="AVS management commands for owners",
    add_completion=False,
)

logger = get_logger("manage")


@manage_app.command("sync-models")
def sync_models(
    config: str = typer.Option(
        ...,
        "--config",
        "-c",
        help="Path to config file",
    ),
    verbose: bool = typer.Option(
        False,
        "--verbose",
        help="Enable verbose logging (debug level)",
    ),
    log_file: Optional[str] = typer.Option(
        None,
        "--log-file",
        "-l",
        help="Path to log file (optional)",
    ),
) -> None:
    """
    Add a new model to the AVS.

    This command validates the model structure and creates a new entry
    in the ModelRegistry contract.

    Example:
        sertn manage sync-models --config config.yaml --verbose
    """
    setup_logging(verbose=verbose, log_file=log_file)

    try:
        # Load and validate config
        config_obj: OwnerConfig = load_config(config, "owner")
        logger.info(f"Loaded config from: {config}")
    except Exception as e:
        logger.error(f"Failed to load config: {e}")
        raise typer.Exit(1)

    model_registry = ModelRegistry(
        private_key=load_ecdsa_private_key(
            keystore_path=str(config_obj.ecdsa_private_key_store_path),
            password=os.environ.get("OWNER_ECDSA_KEY_PASSWORD", ""),
        ),
        eth_rpc_url=config_obj.eth_rpc_url,
        gas_strategy=config_obj.gas_strategy,
    )
    logger.info(f"Syncing models according to model path {MODELS_DATA_DIR}...")

    model_registry.sync_models()
    model_registry.print_models()


@manage_app.command("submit-rewards")
def submit_rewards(
    config: str = typer.Option(
        ...,
        "--config",
        "-c",
        help="Path to config file",
    ),
    interval: int = typer.Option(
        ...,
        "--interval",
        "-i",
        help="Interval number for reward submission",
    ),
    gas_limit: Optional[int] = typer.Option(
        None,
        "--gas-limit",
        "-g",
        help="Gas limit for the transaction",
    ),
    gas_multiplier: float = typer.Option(
        1.1,
        "--gas-multiplier",
        "-m",
        help="Gas multiplier for estimation buffer",
    ),
    verbose: bool = typer.Option(
        False,
        "--verbose",
        help="Enable verbose logging (debug level)",
    ),
    log_file: Optional[str] = typer.Option(
        None,
        "--log-file",
        "-l",
        help="Path to log file (optional)",
    ),
) -> None:
    """
    Submit rewards for a specific interval.

    This command submits rewards to the service manager for the given interval.

    Example:
        sertn manage submit-rewards --config config.yaml --interval 5
    """
    setup_logging(verbose=verbose, log_file=log_file)
    logger = get_logger("submit-rewards")

    try:
        # Load and validate config
        config_obj: OwnerConfig = load_config(config, "owner")
        logger.info(f"Loaded config from: {config}")
    except Exception as e:
        logger.error(f"Failed to load config: {e}")
        raise typer.Exit(1)

    try:
        # Load private key from keystore
        private_key = load_ecdsa_private_key(
            keystore_path=str(config_obj.ecdsa_private_key_store_path),
            password=os.environ.get("OWNER_ECDSA_KEY_PASSWORD", ""),
        )

        # Initialize AVS Owner
        avs_owner = AvsOwner(private_key, config_obj.eth_rpc_url)
        logger.info(f"Initialized AVS Owner with address: {avs_owner.owner_address}")

        # Prepare gas kwargs
        gas_kwargs = {}
        if gas_limit:
            gas_kwargs["gas_limit"] = gas_limit
        if gas_multiplier != 1.1:
            gas_kwargs["gas_multiplier"] = gas_multiplier

        # Submit rewards
        avs_owner.submit_rewards_for_interval(interval, **gas_kwargs)

        logger.info(f"🎉 Successfully submitted rewards for interval {interval}")
        typer.echo(f"✅ Rewards submitted successfully!")
        typer.echo(f"📊 Interval: {interval}")

    except Exception as e:
        logger.error(f"❌ Failed to submit rewards: {e}")
        typer.echo(f"❌ Failed to submit rewards: {e}", err=True)
        raise typer.Exit(1)
