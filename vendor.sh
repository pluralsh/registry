#!/bin/bash
set -e

# Parse arguments
MODE="${1:-vendor}"  # vendor, verify, or dry-run
CONFIG_FILE="${2:-vendor.json}"
REGISTRY="${3:-ghcr.io}"
REPO_NAME="${4}"

if [ "$MODE" != "vendor" ] && [ "$MODE" != "verify" ] && [ "$MODE" != "dry-run" ]; then
    # Backward compatibility: if first arg is not a mode, treat as old behavior
    CONFIG_FILE="${1:-vendor.json}"
    REGISTRY="${2:-ghcr.io}"
    REPO_NAME="${3}"
    MODE="vendor"
fi

if [ -z "$REPO_NAME" ]; then
    echo "Error: Repository name is required"
    echo "Usage: $0 [vendor|verify|dry-run] <config.json> <registry> <repo-name>"
    echo "  vendor   - Copy images to registry (default)"
    echo "  verify   - Check if vendored images have multi-arch support"
    echo "  dry-run  - Show what would be vendored without copying"
    exit 1
fi

# Check if config file exists
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: $CONFIG_FILE not found"
    exit 1
fi

# Validate JSON
jq . "$CONFIG_FILE" >/dev/null 2>&1 || {
    echo "Error: $CONFIG_FILE is not valid JSON"
    exit 1
}

# Check if skopeo is installed
if ! command -v skopeo &> /dev/null; then
    echo "Error: skopeo is not installed. Please install it first."
    exit 1
fi

TARGET_PREFIX="${REGISTRY}/${REPO_NAME}"

if [ "$MODE" = "verify" ]; then
    echo "Verifying multi-arch support for vendored images in $CONFIG_FILE..."
elif [ "$MODE" = "dry-run" ]; then
    echo "Dry-run mode: showing what would be vendored from $CONFIG_FILE..."
else
    echo "Processing images from $CONFIG_FILE..."
    echo "Using skopeo for multi-arch image vendoring"
fi

# Process each image and its tag regex
MAPPINGS=""
PROCESSED_COUNT=0
FAILED_COUNT=0
MULTIARCH_COUNT=0

while IFS= read -r IMAGE; do
    if [ -n "$IMAGE" ]; then
        TAG_REGEX=$(jq -r ".\"${IMAGE}\"" "$CONFIG_FILE")
        if [ "$TAG_REGEX" = "null" ]; then
            echo "Warning: No tag regex for ${IMAGE}, skipping"
            continue
        fi

        echo "Fetching tags for ${IMAGE} with regex ${TAG_REGEX}"
        TAGS=$(skopeo list-tags "docker://${IMAGE}" | jq -r '.Tags[]' | grep -E "${TAG_REGEX}" || true)

        if [ -z "$TAGS" ]; then
            echo "Warning: No tags found for ${IMAGE} matching ${TAG_REGEX}"
            continue
        fi

        # Process each matching tag
        while IFS= read -r TAG; do
            if [ -n "$TAG" ]; then
                SOURCE="${IMAGE}:${TAG}"
                TARGET="${TARGET_PREFIX}/${IMAGE#*/}:${TAG}"
                MAPPINGS="${MAPPINGS}${SOURCE}=${TARGET}"$'\n'

                if [ "$MODE" = "verify" ]; then
                    echo "Checking ${TARGET}..."
                    # Check if image exists and is multi-arch
                    if MANIFEST=$(skopeo inspect --raw "docker://${TARGET}" 2>/dev/null); then
                        MEDIA_TYPE=$(echo "$MANIFEST" | jq -r '.mediaType // empty')
                        if [[ "$MEDIA_TYPE" == *"manifest.list"* ]] || [[ "$MEDIA_TYPE" == *"image.index"* ]]; then
                            ARCH_COUNT=$(echo "$MANIFEST" | jq -r '.manifests | length')
                            echo "✓ ${TARGET} is multi-arch (${ARCH_COUNT} platforms)"
                            ((MULTIARCH_COUNT++))
                            ((PROCESSED_COUNT++))
                        else
                            echo "⚠ ${TARGET} is single-arch only"
                            ((PROCESSED_COUNT++))
                        fi
                    else
                        echo "✗ ${TARGET} not found"
                        ((FAILED_COUNT++))
                    fi
                elif [ "$MODE" = "dry-run" ]; then
                    echo "Would vendor: ${SOURCE} -> ${TARGET}"
                    ((PROCESSED_COUNT++))
                else
                    echo "Vendoring ${SOURCE} -> ${TARGET}"
                    # Use skopeo copy with --all to preserve multi-arch manifests
                    # --preserve-digests ensures digest references are maintained
                    # --retry-times for resilience
                    if skopeo copy \
                        --all \
                        --preserve-digests \
                        --retry-times 3 \
                        "docker://${SOURCE}" \
                        "docker://${TARGET}"; then
                        echo "✓ Successfully vendored ${SOURCE}"
                        ((PROCESSED_COUNT++))
                    else
                        echo "✗ Failed to vendor ${SOURCE}"
                        ((FAILED_COUNT++))
                    fi
                fi
            fi
        done <<< "$TAGS"
    fi
done <<< "$(jq -r 'keys[]' "$CONFIG_FILE")"

if [ -z "$MAPPINGS" ]; then
    echo "Error: No valid image mappings found"
    exit 1
fi

echo ""
if [ "$MODE" = "verify" ]; then
    echo "=== Verification Summary ==="
    echo "Images checked: ${PROCESSED_COUNT}"
    echo "Multi-arch images: ${MULTIARCH_COUNT}"
    echo "Failed/Not found: ${FAILED_COUNT}"
    if [ $MULTIARCH_COUNT -gt 0 ]; then
        echo ""
        echo "✓ Multi-arch support confirmed for ${MULTIARCH_COUNT} images"
    fi
elif [ "$MODE" = "dry-run" ]; then
    echo "=== Dry-run Summary ==="
    echo "Would vendor: ${PROCESSED_COUNT} images"
    echo ""
    echo "Image mappings:"
    echo "$MAPPINGS"
else
    echo "=== Vendoring Summary ==="
    echo "Successfully vendored: ${PROCESSED_COUNT} images"
    echo "Failed: ${FAILED_COUNT} images"
    echo ""
    echo "Image mappings:"
    echo "$MAPPINGS"
fi

if [ $FAILED_COUNT -gt 0 ] && [ "$MODE" != "dry-run" ]; then
    echo ""
    echo "Warning: Some operations failed"
    exit 1
fi

