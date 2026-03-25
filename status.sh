#!/bin/bash

set -a
source config.env
set +a

echo ""
echo "Running ds-env containers:"
echo "-----------------------------------------------------"
podman ps --filter "name=ds-" \
    --format "table {{.Names}}\t{{.Image}}\t{{.Ports}}\t{{.Status}}"
echo ""
echo "Available images:"
echo "-----------------------------------------------------"
podman images --filter "reference=ds-env-*" \
    --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}\t{{.CreatedSince}}"
echo ""
echo "Port map:"
echo "  Profile A → JupyterLab: http://localhost:${JUPYTER_PORT_A}"
echo "  Profile A → RStudio:    http://localhost:${RSTUDIO_PORT_A}"
echo "  Profile A → VS Code:    http://localhost:${VSCODE_PORT_A}"
echo "  Profile B → JupyterLab: http://localhost:${JUPYTER_PORT_B}"
echo "  Profile B → RStudio:    http://localhost:${RSTUDIO_PORT_B}"
echo "  Profile B → VS Code:    http://localhost:${VSCODE_PORT_B}"
echo ""
