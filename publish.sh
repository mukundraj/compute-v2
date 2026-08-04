#!/bin/bash
# Build and publish the ds-env image tarball to GCS, where the ansible repo's
# playbooks/bake_compute_v2.yml downloads it to populate the read-only shared
# store baked into the compute-v2 GCP image.
#
# This step used to be manual and undocumented, which is exactly how the
# published tarball rotted weeks behind the repo: build.sh only builds a LOCAL
# image, nothing re-uploaded it, so every re-bake kept ingesting a stale
# `-latest.tar.gz` — shipping an old baked /entrypoint.sh (no rootless RStudio
# bypass) in every image in the family. Run this after any change that must
# reach baked VMs (entrypoint.sh, Containerfile, denv contents), THEN re-bake
# (`packer build`) and migrate the VMs (migrate_baked_image.yml).
#
# Must run on a Linux x86_64 host with podman (build.sh builds --platform
# linux/amd64). Usage:
#   ./publish.sh [a|b|all] [--skip-build]
#     --skip-build   upload an already-built local image (skip ./build.sh)
set -euo pipefail

cd "$(dirname "$0")"
set -a
source config.env
[ -f config.local.env ] && source config.local.env
set +a

# GCS prefix to publish under. MUST match compute_v2_image_gcs_uri in the
# ansible repo's playbooks/bake_compute_v2.yml (kept in sync by hand — if you
# change one, change the other). Overridable via config.local.env for testing.
GCS_URI="${DS_ENV_PUBLISH_GCS_URI:-gs://mlab-ai-writable/mraj/}"

PROFILE=all
SKIP_BUILD=false
for arg in "$@"; do
    case "$arg" in
        a|b|all)      PROFILE="$arg" ;;
        --skip-build) SKIP_BUILD=true ;;
        *) echo "Usage: ./publish.sh [a|b|all] [--skip-build]" >&2; exit 1 ;;
    esac
done

tag_for() { echo "ds-env-r$1-py$2"; }

publish_one() {
    local tag="$1"
    local dest="${GCS_URI%/}/${tag}-latest.tar.gz"
    local tmpdir="${TMPDIR:-/tmp}"
    local tmp="${tmpdir}/${tag}-publish-$$.tar.gz"

    echo ">>> Publishing ${tag} -> ${dest}"
    if ! podman image exists "${tag}"; then
        echo "Error: image '${tag}' not found locally — build it first (drop --skip-build)." >&2
        return 1
    fi
    mkdir -p "${tmpdir}"
    # Stage to a temp file (not a stdin stream to gcloud) so the ~8 GB upload is
    # resumable and a transient blip doesn't force a full rebuild+resave.
    echo "  saving + compressing -> ${tmp}"
    podman save "${tag}" | gzip > "${tmp}"
    echo "  uploading $(du -h "${tmp}" | cut -f1) ..."
    gcloud storage cp "${tmp}" "${dest}"
    rm -f "${tmp}"
    echo ">>> Done: ${dest}"
}

[ "$SKIP_BUILD" = true ] || ./build.sh "$PROFILE"

TAG_A="$(tag_for "$R_VERSION_A" "$PYTHON_VERSION_A")"
TAG_B="$(tag_for "$R_VERSION_B" "$PYTHON_VERSION_B")"
case "$PROFILE" in
    a) publish_one "$TAG_A" ;;
    b) publish_one "$TAG_B" ;;
    all)
        publish_one "$TAG_A"
        if [ "$TAG_B" != "$TAG_A" ]; then
            publish_one "$TAG_B"
        else
            echo "Profile B tag ($TAG_B) is identical to A — already uploaded, skipping."
        fi
        ;;
esac
