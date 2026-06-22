#!/usr/bin/env bash
# CTX Installer Script
# Installs CTX to /Applications/CTX.app
set -euo pipefail

APP_NAME="CTX"
TARGET_DIR="/Applications"
APP_PATH="$TARGET_DIR/$APP_NAME.app"
TMP_DIR=$(mktemp -d)

# Cleanup temp folder on exit
trap 'rm -rf "$TMP_DIR"' EXIT

echo "=== CTX Installer ==="

# Check if running on macOS
if [[ "$(uname)" != "Darwin" ]]; then
  echo "Error: CTX is a native macOS application and can only be installed on macOS." >&2
  exit 1
fi

# Resolve the download URL
# If CTX_DOWNLOAD_URL is supplied (e.g. from JFrog Fly or Artifactory), use it.
# Otherwise, fall back to GitHub Releases.
if [[ -n "${CTX_DOWNLOAD_URL:-}" ]]; then
  DOWNLOAD_URL="$CTX_DOWNLOAD_URL"
  echo "Using custom download URL: $DOWNLOAD_URL"
else
  echo "Fetching latest version metadata from GitHub..."
  LATEST_RELEASE_JSON=$(curl -fsSL "https://api.github.com/repos/eliasaf-abargel/CTX/releases/latest")
  DOWNLOAD_URL=$(echo "$LATEST_RELEASE_JSON" | grep -o '"browser_download_url": "[^"]*' | head -n 1 | cut -d'"' -f4)
  
  if [[ -z "$DOWNLOAD_URL" ]]; then
    echo "Error: Could not resolve download URL from GitHub Releases." >&2
    exit 1
  fi
fi

ZIP_PATH="$TMP_DIR/CTX.zip"

echo "Downloading CTX..."
# Pass credentials if supplied (for private Artifactory/Fly registries)
if [[ -n "${CTX_REPO_CREDS:-}" ]]; then
  curl -fsSL -u "$CTX_REPO_CREDS" "$DOWNLOAD_URL" -o "$ZIP_PATH"
else
  curl -fsSL "$DOWNLOAD_URL" -o "$ZIP_PATH"
fi

echo "Installing to $TARGET_DIR..."
# Remove existing version if present
if [[ -d "$APP_PATH" ]]; then
  echo "Removing older version of CTX..."
  killall "$APP_NAME" >/dev/null 2>&1 || true
  rm -rf "$APP_PATH"
fi

# Unzip and move
unzip -q "$ZIP_PATH" -d "$TMP_DIR"

# Move the app bundle
mv "$TMP_DIR/$APP_NAME.app" "$APP_PATH"

# Remove macOS quarantine flag to allow running ad-hoc signed apps smoothly
echo "Configuring permissions..."
xattr -rd com.apple.quarantine "$APP_PATH" >/dev/null 2>&1 || true
chmod +x "$APP_PATH/Contents/MacOS/$APP_NAME"

echo "=== Installation Completed Successfully! ==="
echo "CTX is now installed at: $APP_PATH"
echo "You can open it from your Applications folder or by running: open $APP_PATH"
