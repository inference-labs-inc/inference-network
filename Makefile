############################# HELP MESSAGE #############################
# Make sure the help command stays first, so that it's printed by default when `make` is called without arguments
.PHONY: help tests
help:
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

-----------------------------: ##

___ANVIL_STATE___: ##

init:
	@chmod +x ./init.sh
	./init.sh  # TODO: modify init.sh to actually install all stuff

build-anvil-state-with-deployed-contracts: ## builds anvil state with deployed contracts and generates a state
	@chmod +x ./contracts/anvil/build-state.sh
	./contracts/anvil/build-state.sh

start-anvil:
	@chmod +x ./contracts/anvil/start-anvil.sh
	./contracts/anvil/start-anvil.sh

start-anvil-background:
	@chmod +x ./contracts/anvil/start-anvil.sh
	./contracts/anvil/start-anvil.sh true

stop-anvil: ## stops anvil
	@chmod +x ./contracts/anvil/stop-anvil.sh
	./contracts/anvil/stop-anvil.sh

___CONTRACTS___: ##

build-contracts: ## builds all contracts and generates ABIs
	cd contracts && forge build
	cd contracts && forge inspect InferenceTaskManager abi --json > ../abis/InferenceTaskManager.abi.json
	cd contracts && forge inspect InferenceServiceManager abi --json > ../abis/InferenceServiceManager.abi.json
	cd contracts && forge inspect StrategyBase abi --json > ../abis/StrategyBase.abi.json
	cd contracts && forge inspect ERC20Mock abi --json > ../abis/ERC20Mock.abi.json
	cd contracts && forge inspect ERC20 abi --json > ../abis/ERC20.abi.json
	cd contracts && forge inspect DelegationManager abi --json > ../abis/DelegationManager.abi.json
	cd contracts && forge inspect StrategyManager abi --json > ../abis/StrategyManager.abi.json
	cd contracts && forge inspect AllocationManager abi --json > ../abis/AllocationManager.abi.json
	cd contracts && forge inspect ModelRegistry abi --json > ../abis/ModelRegistry.abi.json
	cd contracts && forge inspect RewardsCoordinator abi --json > ../abis/RewardsCoordinator.abi.json
	cd contracts && forge inspect InferenceNodesManager abi --json > ../abis/InferenceNodesManager.abi.json

deploy-eigenlayer-contracts:
	@chmod +x ./contracts/anvil/deploy-el.sh
	./contracts/anvil/deploy-el.sh

deploy-inference-contracts:
	@chmod +x ./contracts/anvil/deploy-inference.sh
	./contracts/anvil/deploy-inference.sh

init-local-workers:  # init operator and aggregator for local testing
	@chmod +x ./contracts/anvil/init-local-workers.sh
	./contracts/anvil/init-local-workers.sh

__CLI__: ##

send-fund: ## sends fund to the operator saved in tests/keys/test.ecdsa.key.json
	cast send 0x860B6912C2d0337ef05bbC89b0C2CB6CbAEAB4A5 --value 10ether --private-key 0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6

-----------------------------: ##
# We pipe all zapper logs through https://github.com/maoueh/zap-pretty so make sure to install it
# TODO: piping to zap-pretty only works when zapper environment is set to production, unsure why
____OFFCHAIN_SOFTWARE___:
start-operator: ## start operator (part of quickstart)
	cd client && uv run src/main.py -m operator --config configs/operator.yaml

start-aggregator: ## start aggregator (part of quickstart)
	cd client && uv run src/main.py -m aggregator --config configs/aggregator.yaml

-----------------------------: ##
_____HELPER_____: ##
test-contracts: ## runs all forge tests
	cd contracts && forge test

test-client: ## runs all client tests
	cd client && uv run pytest
