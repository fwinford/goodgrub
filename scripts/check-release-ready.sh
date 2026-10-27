#!/usr/bin/env bash
set -euo pipefail

for attempt in {1..60}; do
  status="$(
    curl --silent --show-error --max-time 2 \
      --output /dev/null --write-out '%{http_code}' \
      http://127.0.0.1:3000/health/ready || true
  )"
  if [[ "$status" == "200" ]]; then
    exit 0
  fi
  sleep 1
done

printf '%s\n' "CommonPlate did not become ready on loopback port 3000" >&2
exit 1
