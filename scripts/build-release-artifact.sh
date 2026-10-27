#!/usr/bin/env bash
# Builds the production release artifact for the Linux x86_64 / Node 24 host
# from one committed source revision, inside a pinned container. It never
# reads the working tree, `.env`, planning files, or the host's node_modules.
#
# Usage: scripts/build-release-artifact.sh [commit-ish]   (default: HEAD)
# Output: release-artifacts/<name>.tgz, .sha256, .provenance.json
set -euo pipefail

readonly NODE_VERSION="${RELEASE_NODE_VERSION:-24.22.0}"
readonly NPM_VERSION="${RELEASE_NPM_VERSION:-11.6.2}"
# Immutable index digest of node:24.22.0-bookworm (resolved 2026-10-21). A digest
# pins the base image content only; apt/npm registry state and the npm install
# of the pinned npm version are still external inputs.
readonly IMAGE="${RELEASE_NODE_IMAGE:-node:${NODE_VERSION}-bookworm@sha256:925de64a85319052d6971ae81ef2417da956e8a3a2c4a0fac732327970f017f5}"

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

ref="${1:-HEAD}"
commit="$(git rev-parse --verify --quiet "${ref}^{commit}")" || {
  printf 'Commit-ish not found in this repository: %s\n' "$ref" >&2
  exit 1
}
branches="$(git branch --format='%(refname:short)' --contains "$commit" | paste -sd, -)"
if [[ -n "$(git status --porcelain)" ]]; then
  printf '%s\n' "WARNING: working tree has uncommitted or untracked changes." \
    "They are NOT included: only committed content of ${commit} is built." >&2
  if [[ "$commit" == "$(git rev-parse HEAD)" ]]; then
    printf '%s\n' "WARNING: building HEAD while the tree is dirty; the artifact will not contain your local edits." >&2
  fi
fi
printf 'source ref: %s\nsource commit: %s\nlocal branches containing it: %s\n' \
  "$ref" "$commit" "${branches:-<none>}"
short="$(git rev-parse --short=12 "$commit")"
commit_epoch="$(git show -s --format=%ct "$commit")"
name="commonplate-${short}-linux-x64-node${NODE_VERSION}"
out_dir="${RELEASE_OUT_DIR:-$repo_root/release-artifacts}"

if ! command -v docker >/dev/null 2>&1; then
  printf '%s\n' "docker is required to build for linux/amd64" >&2
  exit 1
fi

docker pull --platform linux/amd64 --quiet "$IMAGE" >/dev/null
image_id="$(docker image inspect --platform linux/amd64 "$IMAGE" --format '{{.Id}}')"
printf 'image: %s\nimage id: %s\n' "$IMAGE" "$image_id"

work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/src" "$work/out" "$out_dir"
git archive --format=tar "$commit" | tar -xf - -C "$work/src"

docker run --rm --platform linux/amd64 \
  --network bridge \
  -e RELEASE_COMMIT="$commit" \
  -e RELEASE_NAME="$name" \
  -e RELEASE_EPOCH="$commit_epoch" \
  -e RELEASE_NPM_VERSION="$NPM_VERSION" \
  -e RELEASE_NODE_VERSION="$NODE_VERSION" \
  -e RELEASE_IMAGE="$IMAGE" \
  -e RELEASE_IMAGE_ID="$image_id" \
  -e RELEASE_REF="$ref" \
  -v "$work/src:/src:ro" \
  -v "$work/out:/out" \
  "$IMAGE" \
  bash /src/scripts/release-artifact-container.sh

for suffix in tgz sha256 provenance.json; do
  [[ -s "$work/out/$name.$suffix" ]] || {
    printf '%s\n' "Missing build output: $name.$suffix" >&2
    exit 1
  }
  cp -- "$work/out/$name.$suffix" "$out_dir/"
done

# Re-verify the digest outside the container against the copied file.
(cd "$out_dir" && shasum -a 256 -c "$name.sha256")
printf 'artifact: %s\n' "$out_dir/$name.tgz"
