#!/usr/bin/env bash
set -euo pipefail

curl --silent --show-error --max-time 5 --fail \
  --output /dev/null \
  http://127.0.0.1:3000/health/ready
