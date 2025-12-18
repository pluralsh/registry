# Registry - Container Image Vendoring

This repository vendors container images to GitHub Container Registry (GHCR) with full multi-arch support.

## Features

- **Multi-arch support**: Uses `skopeo` to preserve all platform architectures (amd64, arm64, etc.)
- **Manifest list preservation**: Maintains original multi-platform manifest lists
- **Scalable**: Efficient direct registry-to-registry transfers without local storage
- **Flexible tag filtering**: Uses regex patterns to select specific image tags

## How it works

The vendoring process uses `skopeo copy --all` to copy images directly from source registries to GHCR while preserving all architectures and manifest lists. This is more efficient and reliable than traditional `docker pull/tag/push` workflows.

## Configuration

Images are configured in `vendor.json`:

```json
{
  "docker.io/nginx": "stable-alpine[34]\\.[0-9]+-slim",
  "docker.io/postgres": "^1[4567]$"
}
```

Each entry maps a source image to a regex pattern for matching tags.

## Usage

### Local execution

```bash
./vendor.sh vendor.json ghcr.io your-org/repo-name
```

### GitHub Actions

The workflow automatically runs when:
- `vendor.json` is modified and pushed
- Manually triggered via workflow_dispatch

### Adding new images

1. Edit `vendor.json` and add your image with a tag regex pattern
2. Commit and push the changes
3. The workflow will automatically vendor the matching images

## Requirements

- `skopeo` (installed automatically in CI)
- `jq` (for JSON parsing)
- Registry authentication (handled via `skopeo login`)

