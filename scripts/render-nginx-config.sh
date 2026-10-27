#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  printf '%s\n' "Usage: render-nginx-config.sh <Faith-approved-public-hostname>" >&2
  exit 2
fi

readonly public_hostname="$1"
if [[ ! "$public_hostname" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; then
  printf '%s\n' "A valid, explicitly approved public hostname is required" >&2
  exit 2
fi

readonly template_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../deploy/nginx" && pwd)"
if ! command -v envsubst >/dev/null 2>&1; then
  printf '%s\n' "envsubst is required to render the Nginx template" >&2
  exit 1
fi

PUBLIC_HOSTNAME="$public_hostname" \
  envsubst '${PUBLIC_HOSTNAME}' \
  < "$template_directory/commonplate.conf.template"
