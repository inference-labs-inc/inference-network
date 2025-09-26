import importlib.util
import sys
from pathlib import Path
from typing import Dict, Optional

import requests

from common.config import GasStrategy
from common.constants import MODELS_FOLDER
from common.contract_constants import ContractVerificationStrategy
from common.eth import EthereumClient
from common.logging import get_logger
from models.execution_layer.base_input import BaseInput
from models.execution_layer.model_config import (
    VERIFICATION_STRATEGY_MAP,
    ModelMetadata,
    load_model_metadata,
)
from models.execution_layer.request_type import RequestType

logger = get_logger("model_registry")


def load_circuit_input_class(model_name: str, models_root: Path = MODELS_FOLDER):
    """
    Dynamically load the CircuitInput class from the model's input.py file.

    :param model_name: Name of the model (for error reporting)
    :return: CircuitInput class
    :raises ModelValidationError: If class loading fails
    """
    input_file = models_root / model_name / "input.py"
    spec = importlib.util.spec_from_file_location(f"{model_name}_input", input_file)
    if spec is None or spec.loader is None:
        raise ModelValidationError(f"Failed to load module from {input_file}")

    module = importlib.util.module_from_spec(spec)

    # Add the model path to sys.path temporarily to resolve relative imports
    model_dir_str = str(input_file.parent)
    if model_dir_str not in sys.path:
        sys.path.insert(0, model_dir_str)

    try:
        spec.loader.exec_module(module)
    except Exception as e:
        raise ModelValidationError(f"Failed to execute module {input_file}: {e}")
    finally:
        # Clean up sys.path
        if model_dir_str in sys.path:
            sys.path.remove(model_dir_str)

    # Check if CircuitInput class exists
    if not hasattr(module, "CircuitInput"):
        raise ModelValidationError(
            f"Module {input_file} does not contain a 'CircuitInput' class"
        )

    circuit_input_class = getattr(module, "CircuitInput")

    # Verify it's a subclass of BaseInput
    if not issubclass(circuit_input_class, BaseInput):
        raise ModelValidationError(
            f"CircuitInput class in '{model_name}' must inherit from BaseInput"
        )

    return circuit_input_class


class ModelValidationError(Exception):
    """Raised when model validation fails"""

    pass


def ensure_external_files(models_root: Path = MODELS_FOLDER, timeout: int = 60) -> int:
    """
    Ensure external files declared in each model's metadata.json are present locally.
    """
    if not models_root.exists():
        logger.error(f"Models folder not found: {models_root}")
        return 0

    downloaded = 0
    for model_path in models_root.iterdir():
        if not model_path.is_dir():
            continue

        model_name = model_path.name
        logger.info(f"Checking external files for model: {model_name}")
        metadata_path = model_path / "metadata.json"
        if not metadata_path.exists():
            logger.warning(f"Skipping {model_name}: no metadata.json")
            continue

        try:
            metadata = load_model_metadata(metadata_path)
        except Exception as e:
            logger.error(f"Failed to load metadata for {model_name}: {e}")
            continue

        ext = getattr(metadata, "external_files", None)
        if not ext:
            continue

        for filename, src in ext.items():
            try:
                target_path = model_path / filename

                if target_path.exists():
                    continue

                logger.info(f"Fetching external file: {filename} -> {src}")
                if isinstance(src, str) and src.startswith(("http://", "https://")):
                    with requests.get(src, stream=True, timeout=timeout) as r:
                        r.raise_for_status()
                        with open(target_path, "wb") as f:
                            for chunk in r.iter_content(chunk_size=1024 * 1024):
                                logger.debug(f"...")
                                if chunk:  # filter out keep-alive chunks
                                    f.write(chunk)
                    logger.info("✅")
                    downloaded += 1
                else:
                    logger.error(
                        f"Unknown external file source for {model_name}: {filename} -> {src}"
                    )
            except Exception as e:
                logger.error(
                    f"Failed to fetch external file for {model_name}/{filename}: {e}"
                )
    return downloaded


class ModelRegistry:
    def __init__(
        self,
        private_key: str,
        eth_rpc_url: str,
        gas_strategy: GasStrategy,
        models_root: Path = MODELS_FOLDER,
    ):
        self.eth_client = EthereumClient(
            eth_rpc_url=eth_rpc_url, gas_strategy=gas_strategy
        )
        self.private_key = private_key
        self.models_root = models_root

    def sync_models(self) -> Dict[str, int]:
        """
        Synchronize local models with the blockchain registry.

        This function:
        1. Scans `models_root` for model folders
        2. Validates each model's metadata.json with ModelMetadata
        3. Validates each model's implementation with _validate_model
        4. Compares with blockchain registry and updates as needed

        :return: Dictionary mapping model names to their blockchain model IDs
        :raises ModelValidationError: If model validation fails
        :raises FileNotFoundError: If required files are missing
        """
        logger.info("Starting model synchronization...")

        if not self.models_root.exists():
            raise FileNotFoundError(f"Models folder not found: {self.models_root}")

        # Step 1: Discover and validate local models
        local_models = self._discover_local_models()
        logger.info(
            f"Discovered {len(local_models)} local models: {list(local_models.keys())}"
        )

        # Step 2: Get blockchain registry state
        blockchain_models = self._get_blockchain_models()
        logger.info(f"Found {len(blockchain_models)} models in blockchain registry")

        # Step 3: Disable models that were removed locally or marked inactive
        for model_id, bc in blockchain_models.items():
            name = bc.get("name")
            if name not in local_models or local_models[name].is_active is False:
                # Local folder removed -> disable on-chain if active
                if bc["active"]:
                    logger.info(f"Disabling model '{name}' (id {model_id})...")
                    self._disable_blockchain_model(model_id)
                continue

        # Step 4: Synchronize models (create/update active ones)
        model_id_mapping: Dict[str, int] = {}
        for model_name, metadata in local_models.items():
            # Skip inactive models entirely
            if metadata.is_active is False:
                continue

            # Check if model exists in blockchain
            existing_model_id: Optional[int] = None
            for model_id, model_data in blockchain_models.items():
                if model_data["name"].lower() == model_name.lower():
                    existing_model_id = model_id
                    break

            if existing_model_id is not None:
                # Model exists, check if update is needed
                logger.debug(
                    f"Model '{model_name}' exists in blockchain with ID {existing_model_id}"
                )

                if model_data["active"] is False:
                    logger.info(
                        f"Enabling model '{model_name}' (id {existing_model_id})..."
                    )
                    self._update_model_verifier(  # activates the model
                        existing_model_id, metadata.model_verifier_address
                    )

                needs_update = self._check_model_needs_update(
                    existing_model_id, metadata, blockchain_models[existing_model_id]
                )

                if needs_update:
                    logger.info(f"Updating model '{model_name}' in blockchain...")
                    self._update_blockchain_model(existing_model_id, metadata)
                    logger.info(f"✓ Model '{model_name}' updated successfully")
                else:
                    logger.info(f"Model '{model_name}' is up to date")

                model_id_mapping[model_name] = existing_model_id
            else:
                # Model doesn't exist, create it
                logger.info(f"Creating new model '{model_name}' in blockchain...")

                model_id = self._create_blockchain_model(model_name, metadata)
                model_id_mapping[model_name] = model_id

                logger.info(f"✓ Model '{model_name}' created with ID {model_id}")

        logger.info(
            f"Model synchronization completed. Model ID mapping: {model_id_mapping}"
        )
        return model_id_mapping

    def _discover_local_models(
        self,
    ) -> Dict[str, ModelMetadata]:
        """
        Discover model folders in `models_root` that contain metadata.json.
        """
        local_models = {}

        # Scan for model directories
        for item in self.models_root.iterdir():
            if not item.is_dir():
                continue
            local_models[item.name] = self._validate_model(item)

        return local_models

    def _get_blockchain_models(self) -> Dict[int, Dict]:
        """
        Retrieve all models from the blockchain registry.

        :return: Dictionary mapping model IDs to their blockchain data
        """
        blockchain_models = {}

        try:
            # Get current model index to know how many models exist
            model_index = self.eth_client.model_registry.functions.modelIndex().call()

            logger.debug(f"Blockchain model index: {model_index}")

            # Iterate through all model IDs (starting from 1)
            for model_id in range(1, model_index):
                try:
                    # Get model data from blockchain
                    model_verifier = (
                        self.eth_client.model_registry.functions.modelVerifier(
                            model_id
                        ).call()
                    )
                    model_name = self.eth_client.model_registry.functions.modelName(
                        model_id
                    ).call()
                    verification_strategy = (
                        self.eth_client.model_registry.functions.verificationStrategy(
                            model_id
                        ).call()
                    )
                    compute_cost = self.eth_client.model_registry.functions.computeCost(
                        model_id
                    ).call()
                    required_fucus = (
                        self.eth_client.model_registry.functions.requiredFUCUs(
                            model_id
                        ).call()
                    )
                    active = self.eth_client.model_registry.functions.isActive(
                        model_id
                    ).call()

                    blockchain_models[model_id] = {
                        "verifier": model_verifier,
                        "name": model_name,
                        "verification_strategy": verification_strategy,
                        "compute_cost": compute_cost,
                        "required_fucus": required_fucus,
                        "active": bool(active),
                    }

                    logger.debug(f"Retrieved blockchain model {model_id}: {model_name}")

                except Exception as e:
                    logger.warning(
                        f"Failed to retrieve model {model_id} from blockchain: {e}"
                    )
                    continue

        except Exception as e:
            logger.error(f"Failed to get blockchain models: {e}")
            raise RuntimeError(f"Failed to retrieve blockchain registry state: {e}")

        return blockchain_models

    def _check_model_needs_update(
        self,
        model_id: int,
        local_metadata: ModelMetadata,
        blockchain_data: Dict,
    ) -> bool:
        """
        Check if a blockchain model needs to be updated based on local metadata.

        :param model_id: Blockchain model ID
        :param local_metadata: Local model metadata
        :param blockchain_data: Current blockchain model data
        :return: True if update is needed, False otherwise
        """
        # Map verification strategy
        expected_verification_strategy = VERIFICATION_STRATEGY_MAP[
            local_metadata.verification_strategy
        ]

        # Check for differences
        needs_update = False

        if blockchain_data["compute_cost"] != local_metadata.compute_cost:
            logger.info(
                f"Model {model_id} compute cost differs: {blockchain_data['compute_cost']} vs {local_metadata.compute_cost}"
            )
            needs_update = True

        if blockchain_data["required_fucus"] != int(local_metadata.required_fucus):
            logger.info(
                f"Model {model_id} required FUCUS differs: {blockchain_data['required_fucus']} vs {int(local_metadata.required_fucus)}"
            )
            needs_update = True

        if blockchain_data["verification_strategy"] != expected_verification_strategy:
            logger.info(
                f"Model {model_id} verification strategy differs: {blockchain_data['verification_strategy']} vs {expected_verification_strategy}"
            )
            needs_update = True

        # Check verifier address if provided in metadata
        if (
            hasattr(local_metadata, "model_verifier_address")
            and local_metadata.model_verifier_address
        ):
            if (
                blockchain_data["verifier"].lower()
                != local_metadata.model_verifier_address.lower()
            ):
                logger.info(
                    f"Model {model_id} verifier address differs: {blockchain_data['verifier']} vs {local_metadata.model_verifier_address}"
                )
                needs_update = True

        return needs_update

    def _update_blockchain_model(self, model_id: int, metadata: ModelMetadata) -> None:
        """
        Update an existing model in the blockchain registry.

        :param model_id: Blockchain model ID to update
        :param metadata: New metadata to apply
        """
        try:
            verification_strategy = VERIFICATION_STRATEGY_MAP[
                metadata.verification_strategy
            ]

            # Update compute cost
            self.eth_client.execute_transaction(
                self.eth_client.model_registry,
                "updateComputeCost",
                self.private_key,
                [model_id, metadata.compute_cost],
            )

            # Update required FUCUS
            self.eth_client.execute_transaction(
                self.eth_client.model_registry,
                "updateRequiredFUCUs",
                self.private_key,
                [model_id, metadata.required_fucus],
            )

            # Update verification strategy
            self.eth_client.execute_transaction(
                self.eth_client.model_registry,
                "updateVerificationStrategy",
                self.private_key,
                [model_id, verification_strategy],
            )

            current_verifier = self.eth_client.model_registry.functions.modelVerifier(
                model_id
            ).call()
            if current_verifier.lower() != metadata.model_verifier_address.lower():
                self._update_model_verifier(model_id, metadata.model_verifier_address)

        except Exception as e:
            logger.error(f"Failed to update model {model_id}: {e}")
            raise RuntimeError(f"Failed to update blockchain model {model_id}: {e}")

    def _update_model_verifier(self, model_id: int, new_verifier: str) -> None:
        try:
            self.eth_client.execute_transaction(
                self.eth_client.model_registry,
                "updateModelVerifier",
                self.private_key,
                [model_id, new_verifier],
            )
        except Exception as e:
            logger.error(f"Failed to update model verifier for {model_id}: {e}")
            raise

    def _disable_blockchain_model(self, model_id: int) -> None:
        try:
            self.eth_client.execute_transaction(
                self.eth_client.model_registry,
                "disableModel",
                self.private_key,
                [model_id],
            )
        except Exception as e:
            logger.error(f"Failed to disable model {model_id}: {e}")
            raise

    def _create_blockchain_model(self, model_name: str, metadata: ModelMetadata) -> int:
        """
        Create a new model in the blockchain registry.

        :param model_name: Name of the model
        :param metadata: Model metadata
        :return: New model ID
        """
        try:
            verification_strategy = VERIFICATION_STRATEGY_MAP[
                metadata.verification_strategy
            ]

            # Use model verifier address from metadata or a default placeholder
            model_verifier_address = getattr(metadata, "model_verifier_address", None)
            if not model_verifier_address:
                # Use a placeholder address if not specified
                model_verifier_address = "0x0000000000000000000000000000000000000001"
                logger.warning(
                    f"Model '{model_name}' has no verifier address, using placeholder"
                )

            # Create the model
            return self.add_model(
                model_name=model_name,
                model_verifier_address=model_verifier_address,
                verification_strategy=verification_strategy,
                compute_cost=metadata.compute_cost,
                required_fucus=metadata.required_fucus,
            )

        except Exception as e:
            logger.error(f"Failed to create model '{model_name}': {e}")
            raise RuntimeError(f"Failed to create blockchain model '{model_name}': {e}")

    def add_model(
        self,
        model_name: str,
        model_verifier_address: str,
        verification_strategy: int = ContractVerificationStrategy.ONCHAIN,
        compute_cost: int = 100,
        required_fucus: int = 10,
        **gas_kwargs,
    ) -> int:
        """
        Add a new model to the AVS by validating it and creating a transaction to the ModelRegistry contract.

        :param model_name: Name of the model (should match folder name in `models_root`)
        :param model_verifier_address: Address of the verifier contract for this model
        :param verification_strategy: Verification strategy (0=None, 1=Onchain, 2=Offchain)
        :param compute_cost: Computational cost of running this model
        :param required_fucus: Required FUCUS for this model
        :param gas_kwargs: Optional gas parameters (gas_limit, max_fee_per_gas, etc.)
        :return: Model ID assigned by the contract
        """
        model_path = self.models_root / model_name
        if not model_path.exists():
            raise FileNotFoundError(f"Model data not found: {model_path}")

        # Create the model in the ModelRegistry contract
        logger.info(f"Adding model '{model_name}' to ModelRegistry...")

        receipt = self.eth_client.execute_transaction(
            self.eth_client.model_registry,
            "createNewModel",
            self.private_key,
            [
                model_verifier_address,
                verification_strategy.value,
                model_name,  # Using model_name as URI
                compute_cost,
                required_fucus,
            ],
            **gas_kwargs,
        )

        # Extract model ID from the ModelCreated event
        model_id = self._extract_model_id_from_receipt(receipt)
        logger.info(f"Successfully added model '{model_name}' with ID: {model_id}")

        return model_id

    def _validate_model(self, model_path: Path) -> ModelMetadata:
        """
        Validate that the model has proper structure and a valid CircuitInput implementation.

        :param model_path: Path to the model directory
        :raises ModelValidationError: If validation fails
        """
        model_name = model_path.name
        logger.info(f"Validating model {model_name}...")

        metadata = load_model_metadata(model_path / "metadata.json")

        # Check for required input.py file
        input_file = model_path / "input.py"
        if not input_file.exists():
            raise ModelValidationError(
                f"Model '{model_name}' is missing required 'input.py' file"
            )

        # Check for other expected model files (optional validation)
        expected_files = ["network.onnx", "settings.json"]
        missing_files = []
        for file_name in expected_files:
            if not (model_path / file_name).exists():
                missing_files.append(file_name)

        if missing_files:
            logger.warning(
                f"Model '{model_name}' is missing optional files: {missing_files}"
            )

        # Load and validate the CircuitInput class
        try:
            load_circuit_input_class(model_name, models_root=self.models_root)
        except Exception as e:
            raise ModelValidationError(
                f"Failed to load CircuitInput class from '{model_name}': {e}"
            )

        return metadata

    def _extract_model_id_from_receipt(self, receipt) -> int:
        """
        Extract the model ID from the ModelCreated event in the transaction receipt.

        :param receipt: Transaction receipt
        :return: Model ID
        :raises RuntimeError: If model ID cannot be extracted
        """
        try:
            # Get ModelCreated events from the receipt
            model_created_events = (
                self.eth_client.model_registry.events.ModelCreated().process_receipt(
                    receipt
                )
            )

            if not model_created_events:
                raise RuntimeError("No ModelCreated event found in transaction receipt")

            # Extract model ID from the first (and should be only) event
            model_id = model_created_events[0]["args"]["modelId"]
            return int(model_id)

        except Exception as e:
            raise RuntimeError(f"Failed to extract model ID from receipt: {e}")

    def print_models(self, truncate: bool = True) -> None:
        """
        Fetch all models from the blockchain and print a readable table to the CLI.

        :param truncate: If True, shorten long addresses for compact display
        """
        models = self._get_blockchain_models()
        if not models:
            logger.info("No models found in the blockchain registry.")
            return

        print("\nCurrently Registered Models in Blockchain:")
        # Prepare rows
        headers = ["ID", "NAME", "ACTIVE", "STRATEGY", "COMPUTE", "FUCUS", "VERIFIER"]

        def strategy_name(v: int) -> str:
            try:
                return ContractVerificationStrategy(v).name
            except Exception:
                return str(v)

        def short(addr: str) -> str:
            if not truncate or len(addr) <= 12:
                return addr
            return f"{addr[:6]}...{addr[-4:]}"

        rows = []
        for model_id in sorted(models.keys()):
            m = models[model_id]
            rows.append(
                [
                    str(model_id),
                    str(m.get("name", "")),
                    "yes" if m.get("active", True) else "no",
                    strategy_name(int(m.get("verification_strategy", 0))),
                    str(m.get("compute_cost", "")),
                    str(m.get("required_fucus", "")),
                    short(str(m.get("verifier", ""))),
                ]
            )

        # Compute column widths
        widths = [len(h) for h in headers]
        for row in rows:
            for i, cell in enumerate(row):
                widths[i] = max(widths[i], len(cell))

        # Build lines
        def fmt(row: list[str]) -> str:
            return " | ".join(cell.ljust(widths[i]) for i, cell in enumerate(row))

        header_line = fmt(headers)
        sep_line = "-" * len(header_line)

        print("\n" + header_line)
        print(sep_line)
        for row in rows:
            print(fmt(row))
