#!/bin/bash
set -e

set -a
source config.env
set +a

build_image() {
    local R_VERSION=$1
    local PYTHON_VERSION=$2
    local TAG="ds-env-r${R_VERSION}-py${PYTHON_VERSION}"

    echo "Building $TAG..."
    podman build \
        --build-arg R_VERSION=${R_VERSION} \
        --build-arg PYTHON_VERSION=${PYTHON_VERSION} \
        -f Containerfile \
        -t ${TAG} \
        .
    echo "Done: $TAG"
}

case "${1:-all}" in
    a)
        build_image $R_VERSION_A $PYTHON_VERSION_A
        ;;
    b)
        build_image $R_VERSION_B $PYTHON_VERSION_B
        ;;
    all)
        build_image $R_VERSION_A $PYTHON_VERSION_A
        build_image $R_VERSION_B $PYTHON_VERSION_B
        ;;
    *)
        echo "Usage: ./build.sh [a|b|all]"
        exit 1
        ;;
esac
