#!/usr/bin/env bash
set -euo pipefail
if [[ $# -ne 0 || "$(id -u)" != 0 ]]; then
  printf '%s\n' "Run as root without arguments; review quarantine only" >&2
  exit 2
fi
exec 9>/run/lock/commonplate-review-maintenance.lock
flock -x 9
install -d -o root -g root -m 0755 /var/lib/commonplate-review
touch /var/lib/commonplate-review/quarantine
chmod 0644 /var/lib/commonplate-review/quarantine
systemctl stop commonplate-review.service
if [[ "$(systemctl show commonplate-review.service --property=MainPID --value)" != 0 ]]; then
  printf '%s\n' "Review did not drain; quarantine remains in place" >&2
  exit 1
fi
printf '%s\n' "Review quarantined and stopped; no data changed and no automatic reopening"
