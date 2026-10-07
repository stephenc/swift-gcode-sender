#!/bin/sh
set -eu

REPO_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP_NAME="G-code Sender"
DIST_DIR="$REPO_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$REPO_DIR/Packaging/Info.plist")
ZIP_PATH="$DIST_DIR/GCode-Sender-$APP_VERSION-macOS-arm64.zip"
IDENTITY=${SIGNING_IDENTITY:--}

export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app}
export CLANG_MODULE_CACHE_PATH="$REPO_DIR/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$REPO_DIR/.build/module-cache"

cd "$REPO_DIR"
swift build -c release --product GCodeSender --disable-sandbox -debug-info-format none
BIN_DIR=$(swift build -c release --show-bin-path --disable-sandbox)

rm -rf "$APP_BUNDLE"
rm -f "$ZIP_PATH"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources/Samples"
cp "$BIN_DIR/GCodeSender" "$APP_BUNDLE/Contents/MacOS/GCodeSender"
cp "$REPO_DIR/Packaging/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$REPO_DIR/LICENSE" "$APP_BUNDLE/Contents/Resources/LICENSE"
cp "$REPO_DIR"/Samples/* "$APP_BUNDLE/Contents/Resources/Samples/"
xcrun actool "$REPO_DIR/Assets/Assets.xcassets" \
    --compile "$APP_BUNDLE/Contents/Resources" \
    --platform macosx \
    --minimum-deployment-target 14.0 \
    --app-icon AppIcon \
    --output-partial-info-plist "$DIST_DIR/asset-info.plist"

if [ "$IDENTITY" = "-" ]; then
    codesign --force --sign - "$APP_BUNDLE"
    echo "Signed ad hoc (no Apple signing identity is installed)."
else
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP_BUNDLE"
    echo "Signed with: $IDENTITY"
fi

codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
plutil -lint "$APP_BUNDLE/Contents/Info.plist"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"

echo "$APP_BUNDLE"
echo "$ZIP_PATH"
