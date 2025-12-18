#!/bin/bash
set -e

CONFIG_FILE="${1:-vendor.json}"
REGISTRY="${2:-ghcr.io}"
REPO_NAME="${3}"

if [ -z "$REPO_NAME" ]; then
    echo "Error: Repository name is required"
    echo "Usage: $0 <config.json> <registry> <repo-name>"
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

echo "Processing images from $CONFIG_FILE..."
echo "Using skopeo for multi-arch image vendoring"

# Process each image and its tag regex
MAPPINGS=""
PROCESSED_COUNT=0
FAILED_COUNT=0

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
        done <<< "$TAGS"
    fi
done <<< "$(jq -r 'keys[]' "$CONFIG_FILE")"

echo ""

# Check if we processed anything at all
if [ $PROCESSED_COUNT -eq 0 ] && [ $FAILED_COUNT -eq 0 ]; then
    echo "Error: No valid image mappings found"
    exit 1
fi

echo "=== Vendoring Summary ==="
echo "Successfully vendored: ${PROCESSED_COUNT} images"
echo "Failed: ${FAILED_COUNT} images"
echo ""
echo "Image mappings:"
echo "$MAPPINGS"

if [ $FAILED_COUNT -gt 0 ]; then
    echo ""
    if [ $PROCESSED_COUNT -eq 0 ]; then
        echo "Error: All operations failed"
        exit 1
    else
        echo "Warning: Some operations failed, but ${PROCESSED_COUNT} succeeded"
        # Don't exit with error if at least some succeeded
    fi
fi

