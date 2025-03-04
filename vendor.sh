#!/bin/bash
set -e

CONFIG_FILE="${1:-images.json}"
REGISTRY="${2:-ghcr.io}"
REPO_NAME="${3}"

if [ -z "$REPO_NAME" ]; then
    echo "Error: Repository name is required"
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

TARGET_PREFIX="${REGISTRY}/${REPO_NAME}"

echo "Processing images from $CONFIG_FILE..."

# Process each image and its tag regex
MAPPINGS=""
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

        # Generate mapping entry
        while IFS= read -r TAG; do
            if [ -n "$TAG" ]; then
                SOURCE="${IMAGE}:${TAG}"
                TARGET="${TARGET_PREFIX}/${IMAGE#*/}:${TAG}"
                MAPPINGS="${MAPPINGS}${SOURCE}=${TARGET}"$'\n'

                echo "Vendoring ${SOURCE} -> ${TARGET}"
                docker pull "$SOURCE"
                docker tag "$SOURCE" "$TARGET"
                docker push "$TARGET"
                echo "Successfully processed ${SOURCE}"
            fi
        done <<< "$TAGS"
    fi
done <<< "$(jq -r 'keys[]' "$CONFIG_FILE")"

if [ -z "$MAPPINGS" ]; then
    echo "Error: No valid image mappings found"
    exit 1
fi

echo "Successfully vendored images:"
echo "$MAPPINGS"