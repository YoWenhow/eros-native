#!/usr/bin/env bash
# Produce and verify an unsigned IPA only; signing/install are explicit separate commands.
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$script_dir/env.sh"
cd "$script_dir/.."
configuration=${1:-debug}
case "$configuration" in debug|release) ;; *) echo 'Usage: build.sh [debug|release]' >&2; exit 64 ;; esac
mkdir -p "dist/$configuration"
swift package resolve --force-resolved-versions
xtool dev build --configuration "$configuration" --triple arm64-apple-ios27.0 --ipa
python3 scripts/verify-ipa.py xtool/ErosNative.ipa > "dist/$configuration/verification.json"
cp xtool/ErosNative.ipa "dist/$configuration/ErosNative-unsigned.ipa"
sha256sum "dist/$configuration/ErosNative-unsigned.ipa" > "dist/$configuration/SHA256SUMS"
cat "dist/$configuration/verification.json"

python3 scripts/write-build-manifest.py "$configuration"
