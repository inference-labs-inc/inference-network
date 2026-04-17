import json
import subprocess
import traceback
from enum import Enum
from typing import Iterable

import ezkl

from common.logging import get_logger
from common.constants import MODELS_FOLDER, PROOFS_FOLDER, LOCAL_EZKL_PATH

logger = get_logger("models")


class EZKLInputType(Enum):
    F16 = ezkl.PyInputType.F16
    F32 = ezkl.PyInputType.F32
    F64 = ezkl.PyInputType.F64
    Int = ezkl.PyInputType.Int
    Bool = ezkl.PyInputType.Bool
    TDim = ezkl.PyInputType.TDim


class EZKLHandler:
    """
    Handler for the EZKL proof system.
    This class provides methods for generating and verifying proofs using EZKL.
    """

    def __init__(self, model_id: str, task_id: str, inputs: list[float] | None) -> None:
        """Initialize EZKL handler for proof generation and verification.

        Args:
            model_id: Model identifier used to locate model files.
            task_id: Task identifier for proof file organization.
            inputs: Input data as a list of floats.
        """
        self.input_data = inputs

        model_path = MODELS_FOLDER / model_id
        self.compiled_model_path = model_path / "model.compiled"
        self.pk_path = model_path / "pk.key"
        self.vk_path = model_path / "vk.key"
        self.settings_path = model_path / "settings.json"

        # Properly close the file handle after loading settings
        with open(self.settings_path, "r", encoding="utf-8") as f:
            self.settings = json.load(f)

        self.proof_dir = PROOFS_FOLDER / task_id
        self.proof_dir.mkdir(parents=True, exist_ok=True)
        self.input_path = self.proof_dir / "inputs.json"
        self.witness_path = self.proof_dir / "witness.json"
        self.proof_filepath = self.proof_dir / "proof.json"

    def gen_input_file(self) -> None:
        """Generate input JSON file for EZKL proof generation."""
        logger.info("Generating input file")
        if isinstance(self.input_data, list):
            input_data = self.input_data
        else:
            input_data = self.input_data.to_array()
        data = {"input_data": [input_data]}
        self.input_path.parent.mkdir(parents=True, exist_ok=True)
        with open(self.input_path, "w", encoding="utf-8") as f:
            json.dump(data, f)
        logger.info(f"Generated input.json with data: {data}")

    def gen_proof(self) -> tuple[str, str]:
        """Generate a ZK proof using EZKL.

        Returns:
            Tuple of (proof_json_string, instances_json_string).

        Raises:
            Exception: If proof generation fails.
        """
        try:
            logger.info("Starting proof generation...")

            self.generate_witness()
            logger.debug("Generating proof")

            result = subprocess.run(
                [
                    str(LOCAL_EZKL_PATH),
                    "prove",
                    "--witness",
                    str(self.witness_path),
                    "--compiled-circuit",
                    str(self.compiled_model_path),
                    "--pk-path",
                    str(self.pk_path),
                    "--proof-path",
                    str(self.proof_filepath),
                ],
                check=True,
                capture_output=True,
                text=True,
            )

            logger.info(
                f"Proof generated: {self.proof_filepath}, result: {result.stdout}",
            )

            with open(self.proof_filepath, "r", encoding="utf-8") as f:
                proof = json.load(f)

            return json.dumps(proof), json.dumps(proof["instances"])

        except Exception as e:
            logger.error(f"An error occurred during proof generation: {e}")
            traceback.print_exc()
            raise

    def verify_proof(
        self,
        validator_inputs: Iterable[float],
        proof: str | dict,
    ) -> bool:
        """Verify a ZK proof using EZKL.

        Args:
            validator_inputs: Input values used for verification.
            proof: Proof data as JSON string or dictionary.

        Returns:
            True if proof is verified successfully, False otherwise.
        """
        if not proof:
            return False

        if isinstance(proof, str):
            proof_json = json.loads(proof)
        else:
            proof_json = proof

        input_instances = self.translate_inputs_to_instances(validator_inputs)
        proof_json["instances"] = [
            input_instances[:] + proof_json["instances"][0][len(input_instances) :]
        ]
        proof_json["transcript_type"] = "EVM"

        with open(self.proof_filepath, "w", encoding="utf-8") as f:
            json.dump(proof_json, f)

        try:
            result = subprocess.run(
                [
                    str(LOCAL_EZKL_PATH),
                    "verify",
                    "--settings-path",
                    str(self.settings_path),
                    "--proof-path",
                    str(self.proof_filepath),
                    "--vk-path",
                    str(self.vk_path),
                ],
                check=True,
                capture_output=True,
                text=True,
                timeout=600,
            )
            return "verified: true" in result.stdout
        except subprocess.TimeoutExpired:
            logger.warning("Verification process timed out after 600 seconds")
            return False
        except subprocess.CalledProcessError:
            return False

    def generate_witness(self, return_content: bool = False) -> list | dict:
        """Generate witness data for EZKL proof.

        Args:
            return_content: If True, return parsed JSON content. Otherwise return stdout.

        Returns:
            Witness data as list/dict or stdout string.
        """
        logger.debug("Generating witness...")

        result = subprocess.run(
            [
                str(LOCAL_EZKL_PATH),
                "gen-witness",
                "--data",
                str(self.input_path),
                "--compiled-circuit",
                str(self.compiled_model_path),
                "--output",
                str(self.witness_path),
                "--vk-path",
                str(self.vk_path),
            ],
            check=True,
            capture_output=True,
            text=True,
        )

        logger.debug(f"Gen witness result: {result.stdout}")

        if return_content:
            with open(self.witness_path, "r", encoding="utf-8") as f:
                return json.load(f)
        return result.stdout

    def translate_inputs_to_instances(self, validator_inputs: Iterable) -> list[int]:
        """Translate validator inputs to EZKL field element instances.

        Args:
            validator_inputs: Input values to translate.

        Returns:
            List of field element integers for EZKL verification.
        """
        scale_map = self.settings.get("model_input_scales", [])
        type_map = self.settings.get("input_types", [])
        return [
            ezkl.float_to_felt(x, scale_map[i], EZKLInputType[type_map[i]].value)
            for i, arr in enumerate(validator_inputs)
            for x in arr
        ]
