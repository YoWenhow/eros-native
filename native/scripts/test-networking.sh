#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$script_dir/env.sh"
exec swift test --package-path "$script_dir/../Packages/ErosNetworking" "$@"
