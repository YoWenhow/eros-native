#!/usr/bin/env bash
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$script_dir/env.sh"
# Public CI requires no xtool, SDK, developer credentials, phone, or auth queries.
if (( $# == 0 )); then set -- core persistence; fi
for eros_package in "$@"; do
  case "$eros_package" in
    core) eros_name=ErosCore ;;
    persistence) eros_name=ErosPersistence ;;
    networking) eros_name=ErosNetworking ;;
    services) eros_name=ErosServices ;;
    session) eros_name=ErosSession ;;
    *) echo 'Unknown package; choose core persistence networking services session' >&2; exit 64 ;;
  esac
  swift test --package-path "$script_dir/../Packages/$eros_name" --force-resolved-versions
 done
