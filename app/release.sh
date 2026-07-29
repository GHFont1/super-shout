#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

VERSION="2.0.2"
SITE="../site"
ARCHIVE="$SITE/releases/SuperShout-$VERSION.zip"

./build-app.sh
ditto -c -k --keepParent build/SuperShout.app "$ARCHIVE"

NOTARY_ISSUER="$(tr -d '\r\n' < "$HOME/.appstoreconnect/issuer_id")"
xcrun notarytool submit "$ARCHIVE" \
  --key "$HOME/.appstoreconnect/private_keys/AuthKey_J27RZMP54D.p8" \
  --key-id J27RZMP54D --issuer "$NOTARY_ISSUER" --wait
xcrun stapler staple build/SuperShout.app

ditto -c -k --keepParent build/SuperShout.app "$ARCHIVE"
cp "$ARCHIVE" "$SITE/SuperShout.zip"
.build/artifacts/sparkle/Sparkle/bin/generate_appcast \
  --account com.gca.supershout \
  --download-url-prefix "https://ghfont1.github.io/super-shout/releases/" \
  --embed-release-notes --maximum-deltas 0 \
  --maximum-versions 8 \
  -o "$SITE/appcast.xml" "$SITE/releases"

codesign --verify --deep --strict --verbose=2 build/SuperShout.app
xcrun stapler validate build/SuperShout.app
spctl -a -vv -t exec build/SuperShout.app
