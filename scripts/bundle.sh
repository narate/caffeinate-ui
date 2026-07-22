#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

swift build -c release

# Run the self-check against the release binary specifically. This is the only
# thing proving the preconditions survived -O and were not optimized away.
.build/release/caffeinate-ui --self-check

APP="build/caffeinate-ui.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/caffeinate-ui "$APP/Contents/MacOS/caffeinate-ui"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# The icon is generated here rather than committed, so it cannot drift from the
# script that draws it. iconutil ships with Command Line Tools.
swift scripts/make-icon.swift build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature. SMAppService identifies a login item by its code signature,
# and an entirely unsigned bundle is rejected on registration. "-" is ad-hoc:
# no certificate and no Developer ID, which is enough for a locally built app
# and is all Command Line Tools can produce anyway.
codesign --force --sign - "$APP"

echo "built $APP"
