# compute-v2

A Podman container setup that runs JupyterLab and/or RStudio across two
independent profiles (A and B), each with their own R and Python versions.
Claude Code is provided via host mount. All configuration lives in one file.

## Single source of truth

Edit **only** `config.env` to change any version or setting:

```
config.env
├── R_VERSION_A / R_VERSION_B
├── PYTHON_VERSION_A / PYTHON_VERSION_B
├── Ports for each profile
├── NPM_GLOBAL_PREFIX
└── RSTUDIO_PASSWORD
```

## Prerequisites

- [Podman](https://podman.io/getting-started/installation)
- [Node.js + npm](https://nodejs.org/) on the host
- A Claude.ai Pro account

## Quick Start

### 1. Install and authenticate Claude Code on the host

```bash
npm install -g @anthropic-ai/claude-code
claude   # choose: Login with Claude.ai → complete in browser
```

### 2. Configure config.env

```bash
# Set your npm global prefix
npm config get prefix   # copy this value into NPM_GLOBAL_PREFIX

# Edit config.env
nano config.env
```

### 3. Make scripts executable

```bash
chmod +x build.sh run.sh stop.sh status.sh
```

### 4. Build images

```bash
./build.sh all   # builds both profiles
./build.sh a     # builds profile A only
./build.sh b     # builds profile B only
```

### 5. Run

```bash
# Single profile
./run.sh a jupyter    # http://localhost:8888
./run.sh a rstudio    # http://localhost:8787
./run.sh b jupyter    # http://localhost:8889
./run.sh b rstudio    # http://localhost:8788

# Both profiles simultaneously (different R versions side by side)
./run.sh a rstudio &
./run.sh b rstudio &

# Claude Code
./run.sh a claude

# Shell
./run.sh a bash
```

### 6. Monitor and stop

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
   ```
2. Add a `c)` case to `build.sh`, `run.sh`, `stop.sh`, and `status.sh`

## Available versions

- R versions (rocker tags): https://hub.docker.com/r/rocker/tidyverse/tags
- Python versions: 3.8, 3.9, 3.10, 3.11, 3.12 (via conda-forge)

## Updating Claude Code

Update on the host — all containers see it immediately:

```bash
npm update -g @anthropic-ai/claude-code
```
