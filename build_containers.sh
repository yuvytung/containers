#!/usr/bin/env bash
# Build and push Bitnami containers to Docker Hub (parallel)
# Usage: ./build_containers.sh container1 container2 ...
# Example: ./build_containers.sh activemq redis nginx

set -euo pipefail

DOCKER_USER="${DOCKER_USER:?ERROR: DOCKER_USER env is not set}"
MAX_PARALLEL=5
LOG_DIR="./logs"
#PLATFORM=linux/amd64
PLATFORM=linux/amd64,linux/arm64

if [ $# -eq 0 ]; then
    echo "Usage: $0 <container1> [container2] ..."
    echo "Example: $0 activemq redis nginx"
    exit 1
fi

mkdir -p "$LOG_DIR"

build_one() {
    local CONTAINER="$1"
    local LOG_FILE="${LOG_DIR}/${CONTAINER}.log"
    local CONTAINER_DIR="bitnami/${CONTAINER}"

    {
        if [ ! -d "$CONTAINER_DIR" ]; then
            echo "[ERROR] Container '${CONTAINER}' not found in bitnami/"
            return 1
        fi

        LATEST_VERSION_DIR=$(find "$CONTAINER_DIR" -mindepth 1 -maxdepth 1 -type d \
            | grep -E '/[0-9]' \
            | sort -t/ -k3 -V \
            | tail -n1)

        if [ -z "$LATEST_VERSION_DIR" ]; then
            echo "[ERROR] No version directory found for '${CONTAINER}'"
            return 1
        fi

        MAJOR_MINOR=$(basename "$LATEST_VERSION_DIR")
        DOCKERFILE_DIR=$(find "$LATEST_VERSION_DIR" -mindepth 1 -maxdepth 1 -type d | head -n1)
        DOCKERFILE="${DOCKERFILE_DIR}/Dockerfile"

        if [ ! -f "$DOCKERFILE" ]; then
            echo "[ERROR] Dockerfile not found at '${DOCKERFILE}'"
            return 1
        fi

        FULL_VERSION=$(grep -oP 'org\.opencontainers\.image\.version="\K[^"]+' "$DOCKERFILE")

        if [ -z "$FULL_VERSION" ]; then
            echo "[ERROR] Could not extract version from '${DOCKERFILE}'"
            return 1
        fi

        REPO="${DOCKER_USER}/${CONTAINER}"

        echo "Building: ${CONTAINER} (${FULL_VERSION})"
        echo "  Tags: ${REPO}:${MAJOR_MINOR}, ${REPO}:${FULL_VERSION}, ${REPO}:latest"

        docker buildx build \
            --platform "${PLATFORM}" \
            -t "${REPO}:${MAJOR_MINOR}" \
            -t "${REPO}:${FULL_VERSION}" \
            -t "${REPO}:latest" \
            --push \
            "${DOCKERFILE_DIR}"

        echo "[OK] ${CONTAINER} pushed successfully"
    } 2>&1 | tee "$LOG_FILE"
}

FAILED=()
SUCCEEDED=()
PIDS=()
NAMES=()

for CONTAINER in "$@"; do
    # Wait if we already have MAX_PARALLEL jobs running
    while [ ${#PIDS[@]} -ge $MAX_PARALLEL ]; do
        # Wait for any one job to finish
        WAIT_DONE=false
        for i in "${!PIDS[@]}"; do
            if ! kill -0 "${PIDS[$i]}" 2>/dev/null; then
                wait "${PIDS[$i]}" && SUCCEEDED+=("${NAMES[$i]}") || FAILED+=("${NAMES[$i]}")
                unset 'PIDS[i]' 'NAMES[i]'
                PIDS=("${PIDS[@]}")
                NAMES=("${NAMES[@]}")
                WAIT_DONE=true
                break
            fi
        done
        if [ "$WAIT_DONE" = false ]; then
            sleep 1
        fi
    done

    echo "[START] ${CONTAINER}"
    build_one "$CONTAINER" &
    PIDS+=($!)
    NAMES+=("$CONTAINER")
done

# Wait for remaining jobs
for i in "${!PIDS[@]}"; do
    wait "${PIDS[$i]}" && SUCCEEDED+=("${NAMES[$i]}") || FAILED+=("${NAMES[$i]}")
done

# Summary

echo ""
echo "BUILD SUMMARY==============================="
echo "Succeeded (${#SUCCEEDED[@]}): ${SUCCEEDED[*]:-<none>}"
echo "Failed    (${#FAILED[@]}): ${FAILED[*]:-<none>}"
echo ""
echo "Logs: ${LOG_DIR}/"
echo "============================================"

[ ${#FAILED[@]} -eq 0 ] || exit 1
