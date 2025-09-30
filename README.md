# INFERENCE NETWORK

## Project Structure

- `/contracts` - Solidity smart contracts
- `/client` - Python implementation of operator and aggregator
  - `/src/avs_operator` - AVS operator implementation
  - `/src/aggregator` - Aggregator implementation
  - `/src/common` - Shared utilities
- `/.github` - GitHub workflows and CI/CD configurations
- `/init.sh` - Initialization script

## Quick Start

### Prerequisites

- Python 3.10-3.12
- Foundry/Forge
- Make
- UV (install with `curl -LsSf https://astral.sh/uv/install.sh | sh`)

### Setup

1. Initialize the project and install Forge dependencies:

```bash
make init
```

2. Set up Python environment (from the client directory):

```bash
uv venv
source .venv/bin/activate
uv pip install -e .
```

3. Build and deploy contracts:

```bash
make build-contracts
make deploy-eigenlayer-contracts
make deploy-inference-contracts
```

### Running the Services

The operator and aggregator services can be managed through the CLI:

```bash
# From the client directory with venv activated
inference --help
```

### Development

Run contract tests:

```bash
make tests-contract
```

Run Python tests:

```bash
# From the client directory
pytest
```

The project uses a Makefile for common operations:

- `make help` - Show available commands
- `make build-anvil-state-with-deployed-contracts` - Build local test state
- `forge script script/LocalnetDeploy.s.sol --rpc-url http://localhost:8545 --broadcast` - Deploy contracts to local anvil network
- `make spam-tasks` - Generate test tasks

## Chain Configuration

- Chain ID: 31337
- Strategy Address: 0x7a2088a1bFc9d81c55368AE168C2C02570cB814F

## License

MIT
