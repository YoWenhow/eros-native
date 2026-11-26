#!/usr/bin/env bash
# Intended for an ephemeral Debian 13 CI container. Does not install Apple tools.
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
eros_temp=$(mktemp -d)
python3 - "$script_dir/../Configuration/toolchain-lock.json" "$eros_temp" <<'PY'
import json,sys
from pathlib import Path
lock=json.loads(Path(sys.argv[1]).read_text())['swift']
if not lock['source'].startswith('https://download.swift.org/') or lock['platform']!='debian13':raise SystemExit('Unexpected toolchain source/platform')
Path(sys.argv[2],'url').write_text(lock['source'])
Path(sys.argv[2],'checksum').write_text(lock['sha256']+'  swift.tar.gz\n')
PY
curl --fail --location --retry 3 --proto '=https' --tlsv1.2 "$(cat "$eros_temp/url")" --output "$eros_temp/swift.tar.gz"
(cd "$eros_temp" && sha256sum --check checksum)
eros_destination="$HOME/.local/opt/swift-6.4.2-RELEASE-debian13"
if [[ -e "$eros_destination" ]]; then echo 'Refusing to overwrite an existing Swift installation' >&2; exit 1; fi
mkdir -p -- "$eros_destination"
tar -xzf "$eros_temp/swift.tar.gz" --strip-components=1 -C "$eros_destination"
source "$script_dir/env.sh"
swift --version
