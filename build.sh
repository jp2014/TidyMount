#!/bin/bash

APP_NAME="TidyMount"
BUNDLE_DIR="${APP_NAME}.app"
CONTENTS_DIR="${BUNDLE_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"

# Create bundle structure
echo "Creating bundle structure..."
mkdir -p "${MACOS_DIR}"

# Compile Binary
echo "Compiling Binary for $(uname -m)..."
swiftc -o "${MACOS_DIR}/${APP_NAME}" \
    -sdk $(xcrun --show-sdk-path) \
    -framework NetFS \
    -framework SwiftUI \
    -framework AppKit \
    -framework ServiceManagement \
    -framework Network \
    -framework Combine \
    -framework IOKit \
    -target $(uname -m)-apple-macos13.0 \
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

# Copy Icon if it exists
if [ -f "Resources/AppIcon.icns" ]; then
    echo "Copying AppIcon.icns..."
    mkdir -p "${CONTENTS_DIR}/Resources"
    cp Resources/AppIcon.icns "${CONTENTS_DIR}/Resources/"
fi

# Copy MenuBarIcon if it exists
if [ -f "Resources/MenuBarIconTemplate.png" ]; then
    echo "Copying MenuBarIcon..."
    mkdir -p "${CONTENTS_DIR}/Resources"
    cp Resources/MenuBarIconTemplate*.png "${CONTENTS_DIR}/Resources/"
fi

# Code Sign the app
echo "Code signing the app..."
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
ENTITLEMENTS="Resources/TidyMount.entitlements"

if [ "$SIGNING_IDENTITY" != "-" ]; then
    echo "Using Identity: $SIGNING_IDENTITY"
    codesign --force --deep --options runtime --entitlements "$ENTITLEMENTS" --sign "$SIGNING_IDENTITY" "${BUNDLE_DIR}"
else
    echo "Ad-hoc signing..."
    codesign --force --deep --sign - "${BUNDLE_DIR}"
fi

# Clean up attributes
echo "Cleaning up extended attributes..."
xattr -cr "${BUNDLE_DIR}"

echo "Built ${BUNDLE_DIR} successfully."
echo "You can move it to your Applications folder or run it from here."
