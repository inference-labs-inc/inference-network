Python implementation of operator and aggregator services for the Inference Network.

# Developer Guide

This document provides a guide for developers who contribute to the project.

## Managing Dependencies

We use [uv](https://github.com/astral-sh/uv) to manage dependencies.

Also the project required to [MCL](https://github.com/herumi/mcl) native package to be installed.

### Local Development

For starting local development create a virtual environment by running:

```sh
uv venv
```

Activate it:

```sh
source .venv/bin/activate
```

And then sync dependencies:

```sh
uv sync
```

This will create and activate a virtual environment in `.venv`

### Adding Dependencies

To add new dependencies, follow the steps below:

1. Add the package to `pyproject.toml`:

```sh
uv add <package-name>
```

The `--dev`, `--group`, or `--optional` flags can be used to add a dependencies to an alternative table.
Or in case you need to install a package from a specific source:

```sh
uv add "httpx @ git+https://github.com/encode/httpx"
```

2. Lock dependencies and generate `requirements.txt`:

```sh
uv lock
uv export -o requirements.txt
```

3. Sync dependencies:

```sh
uv sync --locked
```

### Updating Dependencies

To force uv to update all packages in an existing `pyproject.toml`, run `uv sync --upgrade`.

```sh
# only update the web3 package
$ uv sync --upgrade-package web3

# update both the web3 and requests packages
$ uv sync --upgrade-package web3 --upgrade-package requests

# update the web3 package to the latest, and requests to v2.0.0
$ uv sync --upgrade-package web3 --upgrade-package requests==2.0.0
```

### Removing a dependency:

```sh
uv remove <package-name>
# and then sync
uv lock
uv export -o requirements.txt
uv sync --locked
```
