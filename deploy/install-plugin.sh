#!/usr/bin/env bash
set -euo pipefail

commit=${1:-}
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || { echo 'A full release commit is required' >&2; exit 1; }
release="/shared/isbf-calendar-releases/$commit/isbf-calendar"
plugin=/var/www/discourse/plugins/isbf-calendar
[[ -d "$release" && ! -L "$release" ]] || { echo 'Release directory is missing' >&2; exit 1; }
[[ "$(cat "$release/.release-commit")" == "$commit" ]] || { echo 'Release stamp mismatch' >&2; exit 1; }
[[ "$(readlink -f "$(dirname "$0")/..")" == "$release" ]] || { echo 'Unexpected installer path' >&2; exit 1; }
if [[ -L "$plugin" ]]; then
  previous=$(readlink "$plugin")
  [[ "$previous" == "$release" ]] && exit 0
  [[ "$previous" =~ ^/shared/isbf-calendar-releases/[0-9a-f]{40}/isbf-calendar$ ]] || { echo 'Unexpected existing plugin link' >&2; exit 1; }
elif [[ -e "$plugin" && ! -d "$plugin" ]]; then
  echo 'Unexpected plugin path type' >&2
  exit 1
fi

backup_root=/var/www/discourse/tmp/isbf-calendar-baselines
mkdir -p "$backup_root"
backup=$(mktemp -d "$backup_root/replaced-XXXXXXXX")
if [[ -e "$plugin" || -L "$plugin" ]]; then
  mv -T "$plugin" "$backup/isbf-calendar"
fi
if ! ln -s "$release" "$plugin"; then
  if [[ -e "$backup/isbf-calendar" || -L "$backup/isbf-calendar" ]]; then
    mv -T "$backup/isbf-calendar" "$plugin"
  fi
  exit 1
fi
