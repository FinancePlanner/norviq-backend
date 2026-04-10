#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "" ]; then
  echo "Usage: $0 <image_repository> [tag]"
  echo "Example: $0 ghcr.io/owner/StockPlanBackend local-dev"
  exit 1
fi

REPOSITORY="$1"
TAG="${2:-local-dev}"
SWIFT_SDK_ID="${SWIFT_SDK_ID:-x86_64-swift-linux-musl}"

if ! swift sdk list | rg -q "${SWIFT_SDK_ID}"; then
  echo "Swift SDK '${SWIFT_SDK_ID}' is not installed."
  echo "Install it with:"
  echo "  swift sdk install https://download.swift.org/swift-6.3-release/static-sdk/swift-6.3-RELEASE/swift-6.3-RELEASE_static-linux-0.1.0.artifactbundle.tar.gz --checksum d2078b69bdeb5c31202c10e9d8a11d6f66f82938b51a4b75f032ccb35c4c286c"
  exit 1
fi

RESOURCE_ARGS=()
if [ -d Public ]; then
  RESOURCE_ARGS+=(--resources Public)
fi
if [ -d Resources ]; then
  RESOURCE_ARGS+=(--resources Resources)
fi

swift package \
  --allow-network-connections all \
  --allow-writing-to-package-directory \
  --swift-sdk "${SWIFT_SDK_ID}" \
  build-container-image \
  --product StockPlanBackend \
  --repository "${REPOSITORY}" \
  --tag "${TAG}" \
  "${RESOURCE_ARGS[@]}" \
  --cmd serve --env production --hostname 0.0.0.0 --port 8080

echo "Built and published: ${REPOSITORY}:${TAG}"
