# compute-v2

A Podman container setup that runs JupyterLab and/or RStudio across two
independent profiles (A and B), each with their own R and Python versions.
Claude Code is installed inside the image. All configuration lives in one file.

## Single source of truth

Edit **only** `config.env` to change any version or setting:

```
config.env
├── R_VERSION_A / R_VERSION_B
├── PYTHON_VERSION_A / PYTHON_VERSION_B
└── Ports for each profile (Jupyter, RStudio, VS Code)
```

## Prerequisites

- [Podman](https://podman.io/getting-started/installation)
- A Claude.ai Pro account

## Quick Start

### 0. Install prerequisites

**Debian/Ubuntu:**
```bash
sudo apt-get install -y podman
```

**macOS (Homebrew):**
```bash
brew install podman
podman machine init && podman machine start
```

### 1. Configure config.env

```bash
nano config.env   # set R/Python versions and ports
```

### 2. Make scripts executable

```bash
chmod +x build.sh run.sh stop.sh status.sh
```

### 3. Build images

> Claude Code is baked into the image at build time. Rebuilding is the way to update it.

```bash
./build.sh all   # builds both profiles
./build.sh a     # builds profile A only
./build.sh b     # builds profile B only
```

### 4. Run

```bash
# Single profile
./run.sh a jupyter    # http://localhost:8888
./run.sh a rstudio    # http://localhost:8787
./run.sh a vscode     # http://localhost:8901
./run.sh b jupyter    # http://localhost:8902
./run.sh b rstudio    # http://localhost:8903
./run.sh b vscode     # http://localhost:8904

# Both profiles simultaneously (different R versions side by side)
./run.sh a rstudio &
./run.sh b rstudio &

# Claude Code
./run.sh a claude

# Shell
./run.sh a bash
```

> **First-time Claude login:** Claude Code's config is stored in a named Podman volume
> (`ds-claude-config-<profile>`), isolated from the host. Run `/login` once inside the
> container to authenticate. Auth persists across restarts.

> **VS Code Server login:** The password is your local username (`whoami`). VS Code
> extensions and settings are stored in a named Podman volume
> (`ds-vscode-config-<profile>`) and persist across restarts.

### 5. Monitor and stop

```bash
./status.sh      # show running containers, images, and port map
./stop.sh a      # stop profile A containers
./stop.sh b      # stop profile B containers
./stop.sh all    # stop everything
```

## File Overview

| File | Edit? | Purpose |
|---|---|---|
| `config.env` | ✅ Yes — only this | All versions, ports, and settings |
| `Containerfile` | ❌ No | Image definition, no hardcoded versions |
| `entrypoint.sh` | ❌ No | Routes to jupyter/rstudio/claude/bash |
| `build.sh` | ❌ No | Reads config.env, builds images |
| `run.sh` | ❌ No | Reads config.env, runs services |
| `stop.sh` | ❌ No | Stops containers by profile |
| `status.sh` | ❌ No | Shows running containers and port map |

## Persistent packages

Packages are stored in `~/packages/<profile>/` on the host and mounted into
every container for that profile. They survive container restarts.

Both R and Python packages are managed with micromamba. Open a terminal in
JupyterLab or RStudio and run:

```bash
# R package (conda-forge, prefix r-)
micromamba install -n denv r-arrow

# Python package
micromamba install -n denv polars
```

`install.packages()` still works for R packages not on conda-forge — those
go to `~/packages/<profile>/r-libs` via `R_LIBS_USER`.

> **First run:** the first time a container starts against a fresh `~/packages`
> directory, it recreates `denv` inside the mounted volume. This takes a few
> minutes and only happens once per profile.

### Baking packages into the image

For packages needed by everyone from the start, add them to `Containerfile`
instead (avoids the runtime install step):

```dockerfile
RUN micromamba install -n denv -y r-arrow polars && micromamba clean --all --yes
```

Then rebuild: `./build.sh a`

## Shared vs Isolated work directories

By default both profiles share `./work`. To isolate per profile,
edit `run.sh` and change:

```bash
-v ./work:/home/rstudio/work:Z
# to:
-v ./work-${PROFILE}:/home/rstudio/work:Z
```

## Adding a third profile

1. Add to `config.env`:
   ```bash
   R_VERSION_C=4.2.3
   PYTHON_VERSION_C=3.10
   JUPYTER_PORT_C=8890
   RSTUDIO_PORT_C=8789
   VSCODE_PORT_C=8905
   ```
2. Add a `c)` case to `build.sh`, `run.sh`, `stop.sh`, and `status.sh`

## Available versions

- R versions (rocker tags): https://hub.docker.com/r/rocker/tidyverse/tags
- Python versions: 3.8, 3.9, 3.10, 3.11, 3.12 (via conda-forge)

## Updating Claude Code

Claude Code is baked into the image. To update, rebuild:

```bash
./build.sh all
```

The Claude Code install is near the end of the Containerfile, so only the last
few layers rebuild — this is fast (seconds, not minutes).
