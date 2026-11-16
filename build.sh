#!/usr/bin/env bash
set -euo pipefail

APP_NAME="SoundBoost"
APP_BUNDLE="${APP_NAME}.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
TMP_DIR="$(mktemp -d)"

# Resolve version: CLI arg -> git tag -> Info.plist fallback
if [[ -n "${1:-}" ]]; then
  APP_VERSION="${1#v}"
elif TAG="$(git describe --tags --abbrev=0 2>/dev/null || true)" && [[ -n "${TAG}" ]]; then
  APP_VERSION="${TAG#v}"
else
  APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
fi

BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

echo "-> Creating ${APP_BUNDLE} (${APP_VERSION} build ${BUILD_NUMBER})..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"
cp Info.plist "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${APP_VERSION}" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER}" "${CONTENTS_DIR}/Info.plist"

echo "-> Generating Retina AppIcon.icns..."
MASTER_PNG="${TMP_DIR}/AppIcon.png"
ICONSET_DIR="${TMP_DIR}/AppIcon.iconset"
mkdir -p "${ICONSET_DIR}"

swift generate_icon.swift "${MASTER_PNG}"

for size in 16 32 128 256 512; do
  sips -z "${size}" "${size}" "${MASTER_PNG}" --out "${ICONSET_DIR}/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "${double}" "${double}" "${MASTER_PNG}" --out "${ICONSET_DIR}/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "${ICONSET_DIR}" -o "${RESOURCES_DIR}/AppIcon.icns"

echo "-> Compiling ${APP_NAME} binary..."
swiftc -O \
  -target "$(uname -m)-apple-macosx14.2" \
  -o "${MACOS_DIR}/${APP_NAME}" \
  AudioTapEngine.swift AppModel.swift MenuBarView.swift AppMain.swift \
  -framework SwiftUI \
  -framework AppKit \
  -framework CoreAudio \
  -framework AudioToolbox \
  -framework Accelerate \
  -framework ServiceManagement

echo "-> Ad-hoc signing ${APP_BUNDLE}..."
xattr -cr "${APP_BUNDLE}"
codesign --force --deep --sign - "${APP_BUNDLE}"

echo "-> Done! Bundle size:"
du -sh "${APP_BUNDLE}"
