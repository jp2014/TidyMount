#!/bin/bash

APP_NAME="TidyMount"
BUNDLE_DIR="${APP_NAME}.app"
CONTENTS_DIR="${BUNDLE_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"

# Create bundle structure
echo "Creating bundle structure..."
mkdir -p "${MACOS_DIR}"

# Compile Universal Binary
echo "Compiling Universal Binary (arm64 + x86_64)..."
swiftc -o "${MACOS_DIR}/${APP_NAME}" \
    -sdk $(xcrun --show-sdk-path) \
    -framework NetFS \
    -framework SwiftUI \
    -framework AppKit \
    -framework ServiceManagement \
    -framework Network \
    -framework Combine \
    -target arm64-apple-macos13.0 \
    -target x86_64-apple-macos13.0 \
    Sources/TidyMount/*.swift

if [ $? -eq 0 ]; then
    echo "Compilation successful."
else
    echo "Compilation failed."
    exit 1
fi

# Copy Info.plist
echo "Applying Info.plist..."
cp Resources/Info.plist "${CONTENTS_DIR}/"

# Clean up attributes
echo "Cleaning up extended attributes..."
xattr -cr "${BUNDLE_DIR}"

echo "Built ${BUNDLE_DIR} successfully."
echo "You can move it to your Applications folder or run it from here."
