#!/bin/bash
# Build and publish the ds-env image tarball to GCS, where the ansible repo's
# playbooks/bake_compute_v2.yml downloads it to populate the read-only shared
# store baked into the compute-v2 GCP image.
#
# This step used to be manual and undocumented, which is exactly how the
# published tarball rotted weeks behind the repo: build.sh only builds a LOCAL
# image, nothing re-uploaded it, so every re-bake kept ingesting a stale
# `-latest.tar.gz` — shipping an old baked /entrypoint.sh (no rootless RStudio
# s6 bypass) in every image in the family. Run this after any change that must
# reach baked VMs (entrypoint.sh, Containerfile, denv contents), THEN re-bake
# (`packer build`) and migrate the VMs (migrate_baked_image.yml).
#
# What it uploads for tag T = ds-env-r<RA>-py<PYA> (RA/PYA from config.env):
#   T-<build_id>.tar.gz   immutable, versioned artifact (kept for rollback/repro)
#   T-latest.tar.gz       server-side copy of the above (the bake downloads this)
#   T-latest.json         provenance sidecar the bake reads:
#                         {tag, build_id, inputs_sha256, compute_v2_commit,
#                          tarball, built_at}
# build_id is the IMAGE_BUILD_ID build.sh stamps into the image; inputs_sha256 is
# sha256(Containerfile + entrypoint.sh) — the fingerprint of everything that
# changes the image's content — which the bake recomputes to detect a stale
# tarball. Keep the two files in sync with that computation.
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

# sha256 of the inputs that determine image CONTENT (Containerfile + entrypoint.sh).
# The bake recomputes this from its fresh clone and compares — so this must hash
# exactly the same files, same order, as bake_compute_v2.yml's guard.
inputs_sha256() { cat Containerfile entrypoint.sh | sha256sum | cut -d' ' -f1; }

publish_one() {
    local tag="$1"
    local tmpdir="${TMPDIR:-/tmp}"
    local tmp="${tmpdir}/${tag}-publish-$$.tar.gz"

    echo ">>> Publishing ${tag}"
    if ! podman image exists "${tag}"; then
        echo "Error: image '${tag}' not found locally — build it first (drop --skip-build)." >&2
        return 1
    fi

    # Provenance pulled from the built image + working tree.
    local build_id inputs commit
    build_id="$(podman image inspect "${tag}" --format '{{range .Config.Env}}{{println .}}{{end}}' \
                  | sed -n 's/^IMAGE_BUILD_ID=//p' | head -1)"
    [ -n "${build_id}" ] || build_id="unknown-$(date -u +%Y%m%dT%H%M%SZ)"
    inputs="$(inputs_sha256)"
    commit="$(git rev-parse HEAD 2>/dev/null || echo unknown)"

    local versioned="${tag}-${build_id}.tar.gz"
    local dest_versioned="${GCS_URI%/}/${versioned}"
    local dest_latest="${GCS_URI%/}/${tag}-latest.tar.gz"
    local dest_sidecar="${GCS_URI%/}/${tag}-latest.json"
    local sidecar="${tmpdir}/${tag}-latest.json"

    mkdir -p "${tmpdir}"
    # Stage to a temp file (not a stdin stream to gcloud) so the ~8 GB upload is
    # resumable and a transient blip doesn't force a full rebuild+resave.
    echo "  saving + compressing -> ${tmp}"
    podman save "${tag}" | gzip > "${tmp}"
    echo "  uploading $(du -h "${tmp}" | cut -f1) -> ${dest_versioned}"
    gcloud storage cp "${tmp}" "${dest_versioned}"
    rm -f "${tmp}"
    # -latest is a server-side copy of the immutable versioned object (no re-upload).
    echo "  pointing ${tag}-latest.tar.gz at ${versioned} (server-side copy)"
    gcloud storage cp "${dest_versioned}" "${dest_latest}"

    cat > "${sidecar}" <<EOF
{
  "tag": "${tag}",
  "build_id": "${build_id}",
  "inputs_sha256": "${inputs}",
  "compute_v2_commit": "${commit}",
  "tarball": "${versioned}",
  "built_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
    echo "  uploading provenance sidecar -> ${dest_sidecar}"
    gcloud storage cp "${sidecar}" "${dest_sidecar}"
    rm -f "${sidecar}"
    echo ">>> Done: ${tag}  build_id=${build_id}  inputs_sha256=${inputs:0:12}…"
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
