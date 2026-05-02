#!/bin/sh
set -e

cd "$(dirname "$0")"

echo "→ Building iOS IPA…"
flutter build ipa

echo "→ Building Android AAB…"
flutter build appbundle

echo ""
echo "✓ IPA:  build/ios/ipa/vardn.ipa"
echo "✓ AAB:  build/app/outputs/bundle/release/app-release.aab"
echo ""
echo "→ Opening Transporter for iOS upload…"
open build/ios/ipa/vardn.ipa

echo ""
echo "Upload AAB at: https://play.google.com/console"
