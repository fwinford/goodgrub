#!/usr/bin/env bash
set -euo pipefail

readonly release_root=/opt/commonplate/releases
readonly current_link=/opt/commonplate/current
readonly service_name=commonplate.service
readonly readiness_check=/opt/commonplate/current/scripts/check-release-ready.sh
readonly temporary_link="/opt/commonplate/.current.$$.next"

if [[ "$(id -u)" -ne 0 ]]; then
  printf '%s\n' "Run this deployment operation as root" >&2
  exit 1
fi

if [[ $# -ne 1 ]]; then
  printf '%s\n' "Usage: deploy-release.sh /opt/commonplate/releases/<release-id>" >&2
  exit 2
fi

new_release="$(realpath -e -- "$1")"
case "$new_release" in
  "$release_root"/*) ;;
  *)
    printf '%s\n' "Release path must resolve beneath $release_root" >&2
    exit 2
    ;;
esac
if [[ ! -f "$new_release/dist/src/credentialLauncher.js" ]]; then
  printf '%s\n' "Release is missing the compiled credential launcher" >&2
  exit 2
fi

if [[ ! -L "$current_link" ]]; then
  printf '%s\n' "A known-good current release is required before deployment" >&2
  exit 2
fi
previous_release="$(realpath -e -- "$current_link")"
if [[ "$previous_release" == "$new_release" ]]; then
  printf '%s\n' "Requested release is already active" >&2
  exit 2
fi

unit_environment="$(systemctl show --property=Environment --value "$service_name")"
if [[ ! "$unit_environment" =~ (^|[[:space:]])PUBLIC_ACTIONS_PAUSED=true($|[[:space:]]) ]]; then
  printf '%s\n' "Deployment requires PUBLIC_ACTIONS_PAUSED=true in the service unit" >&2
  exit 2
fi
if [[ "$unit_environment" =~ (^|[[:space:]])PUBLIC_ACTIONS_PAUSED=(false|0)($|[[:space:]]) ]]; then
  printf '%s\n' "Deployment refuses a service unit that resumes public actions" >&2
  exit 2
fi
if [[ ! "$unit_environment" =~ (^|[[:space:]])BASE_URL=https://[^[:space:]]+($|[[:space:]]) ]]; then
  printf '%s\n' "Deployment requires an approved HTTPS BASE_URL in the service unit" >&2
  exit 2
fi

switch_release() {
  local release_path="$1"
  rm -f -- "$temporary_link"
  ln -s -- "$release_path" "$temporary_link"
  mv -Tf -- "$temporary_link" "$current_link"
}

rollback() {
  printf '%s\n' "New release failed readiness; restoring the previous release" >&2
  switch_release "$previous_release"
  if ! systemctl restart "$service_name"; then
    printf '%s\n' "Rollback restart failed; inspect the service journal" >&2
    return 1
  fi
  if ! bash "$readiness_check"; then
    printf '%s\n' "Previous release did not become ready; inspect the service journal" >&2
    return 1
  fi
}

trap 'rm -f -- "$temporary_link"' EXIT
switch_release "$new_release"
if ! systemctl restart "$service_name"; then
  rollback
  exit 1
fi
if ! bash "$readiness_check"; then
  rollback
  exit 1
fi

printf '%s\n' "Release became ready; public actions remain paused"
