#!/bin/sh
# Copies the product payload into the installer's SharedSupport folder, preserving the folder
# hierarchy (Xcode's synchronized folders would flatten the Motion Templates).
#
# Add as a "Run Script" build phase of the installer target:
#   "${SRCROOT}/Scripts/embed-payload.sh"
# Expected layout (filled by the FxPlug release pipeline):
#   Payload/DepthStudio.app                          (signed + notarized FxPlug container)
#   Payload/Motion Templates/Effects/Depth Studio/
#   Payload/Motion Templates/Transitions/Depth Transitions/
set -eu

SOURCE="${SRCROOT}/Payload"
DESTINATION="${TARGET_BUILD_DIR}/${SHARED_SUPPORT_FOLDER_PATH}/Payload"

if [ ! -d "${SOURCE}" ]; then
    echo "warning: ${SOURCE} not found, the installer has no payload"
    exit 0
fi

mkdir -p "${DESTINATION}"
# -a keeps symlinks/permissions (required inside .app bundles); --delete drops stale files.
# Excluding ._* and .DS_Store avoids breaking the embedded app's code signature.
rsync -a --delete --exclude ".DS_Store" --exclude "._*" "${SOURCE}/" "${DESTINATION}/"
