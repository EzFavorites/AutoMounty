#!/bin/bash

set -eo pipefail

# 0. Run Tests
echo "Running Tests..."
swift test

# 1. Build the executable
echo "Building AutoMounty..."
swift build --disable-sandbox -c release

# 2. Define paths
BUILD_DIR=".build/out/Products/release"
APP_NAME="AutoMounty.app"
APP_DIR="$PWD/$APP_NAME"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

# 3. Create App Bundle Structure
echo "Creating App Bundle Structure..."
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

# 4. Copy Executable, Info.plist and Resources
echo "Copying files..."
cp "$BUILD_DIR/AutoMounty" "$MACOS_DIR/"
cp "Info.plist" "$CONTENTS_DIR/"
cp -r "source/Resources/"* "$RESOURCES_DIR/"

# 5. Sign the App (Ad-hoc)
echo "Signing app..."
codesign --force --deep --sign - "$APP_DIR"

echo "Done! App Bundle created at: $APP_DIR"
echo "You can now run it with: open $APP_NAME"
# 6. Restart the App
echo "Restarting app..."
PROCESS_NAME="${APP_NAME%.*}"

# Kill existing process if running
if pgrep -x "$PROCESS_NAME" > /dev/null; then
    echo "Stopping existing $PROCESS_NAME..."
    killall "$PROCESS_NAME"

    # Wait for it to close
    while pgrep -x "$PROCESS_NAME" > /dev/null; do
        sleep 0.5
    done
fi

echo "Starting $PROCESS_NAME..."
open "$APP_DIR"