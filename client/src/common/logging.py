import logging
import sys
from typing import Optional

# Configure logging
logger = logging.getLogger("inference")


def setup_logging(verbose: bool = False, log_file: Optional[str] = None) -> None:
    """Setup logging configuration with optional verbosity and file output.

    Args:
        verbose: If True, set log level to DEBUG. Otherwise INFO.
        log_file: Optional path to write log output to.
    """
    # Set log level based on verbosity
    log_level = logging.DEBUG if verbose else logging.INFO

    # Create formatter
    formatter = logging.Formatter(
        "%(asctime)s - %(name)s - %(levelname)s - %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )

    # Clear any existing handlers
    logger.handlers.clear()

    # Console handler - always present
    console_handler = logging.StreamHandler(sys.stdout)
    console_handler.setFormatter(formatter)
    console_handler.setLevel(log_level)
    logger.addHandler(console_handler)

    # File handler - optional
    if log_file:
        file_handler = logging.FileHandler(log_file)
        file_handler.setFormatter(formatter)
        file_handler.setLevel(logging.DEBUG)  # Always log debug to file
        logger.addHandler(file_handler)

    # Set logger level
    logger.setLevel(logging.DEBUG)
    logger.propagate = False


def get_logger(name: Optional[str] = None) -> logging.Logger:
    """Get a logger instance.

    Args:
        name: Optional name suffix for the logger. If None, returns the root inference logger.

    Returns:
        Logger instance.
    """
    if name:
        return logging.getLogger(f"inference.{name}")
    return logger


# Backward compatibility - create module-level logger functions
def debug(message: str, *args, **kwargs) -> None:
    """Log debug message."""
    logger.debug(message, *args, **kwargs)


def info(message: str, *args, **kwargs) -> None:
    """Log info message."""
    logger.info(message, *args, **kwargs)


def warning(message: str, *args, **kwargs) -> None:
    """Log warning message."""
    logger.warning(message, *args, **kwargs)


def error(message: str, *args, **kwargs) -> None:
    """Log error message."""
    logger.error(message, *args, **kwargs)


def critical(message: str, *args, **kwargs) -> None:
    """Log critical message."""
    logger.critical(message, *args, **kwargs)
