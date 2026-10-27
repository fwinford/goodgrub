#!/usr/bin/env bash
set -euo pipefail
if [[ $# -ne 2 ]]; then
  printf '%s\n' "Usage: render-review-nginx-config.sh <approved-review-hostname> <approved-production-hostname>" >&2
  exit 2
fi
for hostname in "$@"; do
  if [[ ! "$hostname" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; then
    printf '%s\n' "Distinct approved DNS hostnames are required" >&2
    exit 2
  fi
done
if [[ "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" == "$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')" ]]; then
  printf '%s\n' "Production and review hostnames must differ" >&2
  exit 2
fi
readonly template_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../deploy/nginx" && pwd)"
command -v envsubst >/dev/null
REVIEW_HOSTNAME="$1" envsubst '${REVIEW_HOSTNAME}' < "$template_directory/commonplate-review.conf.template"
