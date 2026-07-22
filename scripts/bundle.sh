#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

swift build -c release

# Run the self-check against the release binary specifically. This is the only
# thing proving the preconditions survived -O and were not optimized away.
.build/release/caffeinate-ui --self-check

APP="build/caffeinate-ui.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/caffeinate-ui "$APP/Contents/MacOS/caffeinate-ui"
cp Resources/Info.plist "$APP/Contents/Info.plist"

echo "built $APP"
