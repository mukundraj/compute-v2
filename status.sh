#!/bin/bash

set -a
source config.env
[ -f config.local.env ] || { [ -f config.local.env.example ] && cp config.local.env.example config.local.env; }
[ -f config.local.env ] && source config.local.env
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

# Port map: print URLs for *running* containers using the live host port
# from `podman ps`, not the literal config.env value — that value is
# typically "auto" (resolved by run.sh's pick_port() at start time), which
# would otherwise show up as http://localhost:auto here. Mirrors the
# (local) / (public) banner run.sh prints at first start.
running=$(podman ps --filter "name=ds-" --format "{{.Names}}\t{{.Ports}}" 2>/dev/null)
if [ -n "$running" ]; then
    # Host IP for the (local) line — first non-loopback address on Linux,
    # ipconfig on Darwin, "localhost" if both fail.
    if [[ "$(uname)" == "Darwin" ]]; then
        HOST_IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "localhost")
    else
        HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    HOST_IP=${HOST_IP:-localhost}

    # Public IP, best-effort. Suppressed entirely when curl fails or times
    # out (no MTA on GCP images means we can't email anyway).
    PUBLIC_IP=$(curl -sf --max-time 3 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]')

    echo "Port map:"
    while IFS=$'\t' read -r name ports; do
        # Extract host port from patterns like "0.0.0.0:8901->8888/tcp".
        host_port=$(echo "$ports" | grep -oE '0\.0\.0\.0:[0-9]+' | head -1 | cut -d: -f2)
        if [ -n "$host_port" ]; then
            echo "  ${name} → http://${HOST_IP}:${host_port} (local)"
            [ -n "$PUBLIC_IP" ] && echo "  ${name} → http://${PUBLIC_IP}:${host_port} (public)"
        fi
    done <<< "$running"
    echo ""

    # VS Code Server needs a localhost origin (the browser sends Origin:
    # http://<remote>:port and code-server rejects it as cross-origin), so
    # mirror the tunnel hint that run.sh prints at first start for any running
    # ds-vscode-* container. Print a `gcloud compute ssh` command rather than
    # raw `ssh …@IP`: it resolves the VM by name (survives ephemeral-IP churn)
    # and authenticates via OS Login. GCE metadata gives us name/zone/project;
    # unlike the raw-ssh form it needs no PUBLIC_IP.
    _gce() { curl -sf --max-time 2 -H "Metadata-Flavor: Google" \
        "http://metadata.google.internal/computeMetadata/v1/$1" 2>/dev/null; }
    GCE_NAME=$(_gce instance/name)
    GCE_ZONE=$(_gce instance/zone); GCE_ZONE=${GCE_ZONE##*/}   # strip projects/NUM/zones/ prefix
    GCE_PROJECT=$(_gce project/project-id)
    if [ -n "$GCE_NAME" ] && [ -n "$GCE_ZONE" ] && [ -n "$GCE_PROJECT" ]; then
        while IFS=$'\t' read -r name ports; do
            [[ "$name" == ds-vscode-* ]] || continue
            host_port=$(echo "$ports" | grep -oE '0\.0\.0\.0:[0-9]+' | head -1 | cut -d: -f2)
            [ -n "$host_port" ] || continue
            echo "${name}: to connect from your laptop —"
            echo "  gcloud compute ssh ${GCE_NAME} --zone=${GCE_ZONE} --project=${GCE_PROJECT} -- -N -L ${host_port}:localhost:${host_port}"
            echo "Then open in your browser:"
            echo "  http://localhost:${host_port}"
            echo ""
        done <<< "$running"
    fi
fi
