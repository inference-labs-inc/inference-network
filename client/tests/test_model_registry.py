import json
import shutil
import uuid
import requests

from common.constants import MODELS_FOLDER
from models.execution_layer.base_input import BaseInput
from models.execution_layer.model_registry import (
    ModelRegistry,
    ensure_external_files,
    load_circuit_input_class,
)


def update_model_metadata(models_root, model_name, **kwargs):
    with open(models_root / model_name / "metadata.json", "r+") as f:
        metadata = json.load(f)
        metadata.update(kwargs)
        f.seek(0)
        f.truncate()
        json.dump(metadata, f)


def request_models_from_api():
    resp = requests.get("http://localhost:8090/models")
    assert resp.status_code == 200
    return {m["name"]: m for m in resp.json()}


def test_load_circuit_input_class(models_root, write_model):
    write_model(models_root, "model_ok", is_active=True)

    cls = load_circuit_input_class("model_ok", models_root=models_root)

    assert issubclass(cls, BaseInput)
    assert list(cls.generate()) == [1, 2, 3]


def test_ensure_external_files(models_root, write_model):
    write_model(
        models_root,
        "model_ok",
        is_active=True,
        external_files={
            "external_file.png": "https://www.python.org/static/img/python-logo.png"
        },
    )

    # First call should download the file
    assert ensure_external_files(models_root=models_root, timeout=5) == 1

    # Check that external files were fetched/created
    assert (models_root / "model_ok" / "external_file.png").exists()

    # second call should find existing file and not download it again
    assert ensure_external_files(models_root=models_root, timeout=5) == 0


def test_sync_models_create_update_disable(
    models_root, write_model, owner, dummy_address, aggregator_server
):
    try:
        model_registry = ModelRegistry(
            private_key=owner.private_key,
            eth_rpc_url=owner.eth_rpc_url,
            gas_strategy=owner.gas_strategy,
            models_root=models_root,
        )
        model_registry.sync_models()
        # now test model_root should be empty, so no active models
        active_chain_models = [
            model
            for model in model_registry._get_blockchain_models().values()
            if model["active"]
        ]
        assert len(active_chain_models) == 0

        # Create a new active model with a random name to avoid collisions
        model_name = f"model_{uuid.uuid4().hex[:8]}"
        write_model(
            models_root, model_name, is_active=True, compute_cost=111, required_fucus=55
        )

        # smoke test `/models` endpoint - new model is not there yet
        api_models = request_models_from_api()
        assert model_name not in api_models

        # and sync one more time
        model_registry.sync_models()

        # check active models in contract
        active_chain_models = [
            (model_id, model)
            for model_id, model in model_registry._get_blockchain_models().items()
            if model["active"]
        ]
        assert len(active_chain_models) == 1
        model_id, model = active_chain_models[0]
        assert model["name"] == model_name
        assert model["compute_cost"] == 111
        assert model["required_fucus"] == 55

        # and now the model should be in the API response
        api_models = request_models_from_api()
        assert model_name in api_models
        assert api_models[model_name]["id"] == model_id
        assert api_models[model_name]["compute_cost"] == 111

        # change the model cost and fucus
        update_model_metadata(
            models_root,
            model_name,
            compute_cost=222,
            required_fucus=77,
            model_verifier_address=dummy_address,
        )
        model_registry.sync_models()
        model = model_registry._get_blockchain_models()[model_id]
        assert model["compute_cost"] == 222
        assert model["required_fucus"] == 77
        assert model["verifier"] == dummy_address

        # check that the model is updated in the API response
        api_models = request_models_from_api()
        assert api_models[model_name]["id"] == model_id
        assert api_models[model_name]["compute_cost"] == 222

        # disable the model
        update_model_metadata(models_root, model_name, is_active=False)
        model_registry.sync_models()
        active_chain_models = [
            model
            for model in model_registry._get_blockchain_models().values()
            if model["active"]
        ]
        assert len(active_chain_models) == 0

        # check the model is not anymore in the API response
        assert model_name not in request_models_from_api()

        # activate the model again
        update_model_metadata(models_root, model_name, is_active=True)
        model_registry.sync_models()
        active_chain_models = [
            model
            for model in model_registry._get_blockchain_models().values()
            if model["active"]
        ]
        assert len(active_chain_models) == 1
        # check the model is again in the API response
        assert model_name in request_models_from_api()

        # and again disable it removing the model directory
        shutil.rmtree(models_root / model_name, ignore_errors=True)
        model_registry.sync_models()
        active_chain_models = [
            model
            for model in model_registry._get_blockchain_models().values()
            if model["active"]
        ]
        assert len(active_chain_models) == 0
        # and again nothing in the API response
        assert len(request_models_from_api()) == 0
    finally:
        # set "real" models from "real" models folder back to the chain
        model_registry = ModelRegistry(
            private_key=owner.private_key,
            eth_rpc_url=owner.eth_rpc_url,
            gas_strategy=owner.gas_strategy,
            models_root=MODELS_FOLDER,
        )
        model_registry.sync_models()
