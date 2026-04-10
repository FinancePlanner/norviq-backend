# Local Container Workflow (Swift Container Plugin + Optional Apple Container CLI)

This is the local (developer) workflow for packaging the backend as a Linux container image from macOS.

## 1) Prerequisites

- Swift 6.3+
- `swift-container-plugin` dependency in `Package.swift`
- Static Linux SDK installed:

```bash
swift sdk install \
  https://download.swift.org/swift-6.3-release/static-sdk/swift-6.3-RELEASE/swift-6.3-RELEASE_static-linux-0.1.0.artifactbundle.tar.gz \
  --checksum d2078b69bdeb5c31202c10e9d8a11d6f66f82938b51a4b75f032ccb35c4c286c
```

## 2) Build + publish image locally (recommended)

Use the project helper script:

```bash
cd StockPlanBackend
./scripts/build_container_image_local.sh ghcr.io/<owner>/StockPlanBackend local-dev
```

or via Makefile:

```bash
make container-local APP_IMAGE=ghcr.io/<owner>/StockPlanBackend APP_IMAGE_TAG=local-dev
```

## 3) Optional: Apple `container` CLI usage

If you want to experiment with Apple’s `container` CLI locally, keep it as a local-only tool.
Production deploys should still rely on standard Docker Compose pull/run.

```bash
# example only (depends on local container CLI setup)
container build --arch amd64 .
```

## Notes

- CI remains the source of truth for production artifacts.
- This local workflow is for testing image packaging behavior before pushing changes.
