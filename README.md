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
├── PNPM_HOME
└── RSTUDIO_PASSWORD
```

## Prerequisites

- [Podman](https://podman.io/getting-started/installation)
- [pnpm](https://pnpm.io/) on the host (manages Node.js via `pnpm env use`)
- A Claude.ai Pro account

## Quick Start

### 0. Install prerequisites

**Debian/Ubuntu:**
```bash
# Podman
sudo apt-get install -y podman

# pnpm (standalone installer — manages Node.js too)
curl -fsSL https://get.pnpm.io/install.sh | sh -
source ~/.bashrc

# Node.js (via pnpm)
pnpm env use --global 20
```

**macOS (Homebrew):**
```bash
brew install podman pnpm
podman machine init && podman machine start

# Node.js (via pnpm)
pnpm env use --global 20
```

### 1. Install and authenticate Claude Code on the host

```bash
pnpm add -g @anthropic-ai/claude-code
claude   # choose: Login with Claude.ai → complete in browser
```

After authenticating, install the provided global CLAUDE.md so that GCS access
restrictions are enforced in every Claude Code session inside containers:

```bash
cp templates/CLAUDE.md ~/.claude/CLAUDE.md
```

This file instructs Claude to respect `GCS_READ_PATHS` and `GCS_WRITE_PATHS`
(set via `GCP_BUCKET_ACCESS` in `config.env`) and refuse any GCS operation
outside those declared paths.

### 2. Configure config.env

```bash
# PNPM_HOME is auto-detected via `pnpm bin -g` — only edit config.env for
# passwords, ports, or R/Python versions
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
   ```
2. Add a `c)` case to `build.sh`, `run.sh`, `stop.sh`, and `status.sh`

## Available versions

- R versions (rocker tags): https://hub.docker.com/r/rocker/tidyverse/tags
- Python versions: 3.8, 3.9, 3.10, 3.11, 3.12 (via conda-forge)

## Updating Claude Code

Update on the host — all containers see it immediately:

```bash
pnpm update -g @anthropic-ai/claude-code
```
