#!/usr/bin/env bash
# Packs build/JeanNotch.app (from scripts/bundle.sh) into the release assets:
# build/JeanNotch-<tag>.zip and build/JeanNotch-<tag>.pkg (installs to /Applications).
set -euo pipefail

tag="${1:?usage: scripts/package.sh vX.Y.Z}"
cd "$(dirname "$0")/.."
app="build/JeanNotch.app"
[[ -d "$app" ]] || { echo "Missing $app: run scripts/bundle.sh first" >&2; exit 1; }

ditto -c -k --keepParent "$app" "build/JeanNotch-$tag.zip"

root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
ditto "$app" "$root/JeanNotch.app"
# Installer relocates a relocatable bundle to any other copy it finds (e.g. a dev build).
pkgbuild --analyze --root "$root" "$root.plist" >/dev/null
plutil -replace 0.BundleIsRelocatable -bool NO "$root.plist"
pkgbuild --root "$root" --component-plist "$root.plist" --install-location /Applications \
  --identifier build.jean.notch --version "${tag#v}" "build/JeanNotch-$tag.pkg"
rm -f "$root.plist"
echo "Built build/JeanNotch-$tag.zip and build/JeanNotch-$tag.pkg"
