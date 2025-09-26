from typing import Optional

import typer

from aggregator import run_aggregator
from avs_operator import run_operator
from common.config import load_config
from common.logging import get_logger, setup_logging
from management import manage_app
from models.execution_layer.model_registry import ensure_external_files

app = typer.Typer(
    name="sertn",
    help="Sertn AVS Client",
    add_completion=False,
)

# Add the management sub-application
app.add_typer(manage_app, name="manage")


@app.command(name="start")
def start(
    mode: str = typer.Option(
        ...,
        "--mode",
        "-m",
        help="Operation mode: 'operator' or 'aggregator'",
    ),
    config: Optional[str] = typer.Option(
        None,
        "--config",
        "-c",
        help="Path to config file",
    ),
    verbose: bool = typer.Option(
        False,
        "--verbose",
        "-v",
        help="Enable verbose logging (debug level)",
    ),
    log_file: Optional[str] = typer.Option(
        None,
        "--log-file",
        "-l",
        help="Path to log file (optional)",
    ),
) -> None:
    # Setup logging first
    setup_logging(verbose=verbose, log_file=log_file)
    logger = get_logger()

    logger.debug(f"Starting Sertn in {mode} mode...")

    if not config:
        logger.error("Config file path is required. Use --config to specify the path.")
        raise typer.Exit(1)

    ensure_external_files()

    try:
        if mode == "operator":
            config_obj = load_config(config, "operator")
            run_operator(config_obj)
        elif mode == "aggregator":
            config_obj = load_config(config, "aggregator")
            run_aggregator(config_obj)
        else:
            logger.error(f"Invalid mode: {mode}. Use 'operator' or 'aggregator'")
            raise typer.Exit(1)
    except Exception as e:
        logger.error(f"Error loading or validating config: {e}")
        raise typer.Exit(1)


if __name__ == "__main__":
    app()
