#!/usr/bin/env bash
# Runs inside the pinned linux/amd64 Node container (see
# build-release-artifact.sh). /src is a read-only `git archive` of one commit.
set -euo pipefail

: "${RELEASE_COMMIT:?}" "${RELEASE_NAME:?}" "${RELEASE_EPOCH:?}"
: "${RELEASE_NPM_VERSION:?}" "${RELEASE_NODE_VERSION:?}" "${RELEASE_IMAGE:?}"
: "${RELEASE_IMAGE_ID:?}" "${RELEASE_REF:?}"

pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }

[[ "$(uname -m)" == "x86_64" ]] || fail "arch-is-x86_64"
[[ "$(node -v)" == "v${RELEASE_NODE_VERSION}" ]] || fail "node-version-pinned"
npm install -g "npm@${RELEASE_NPM_VERSION}" >/dev/null 2>&1
[[ "$(npm -v)" == "${RELEASE_NPM_VERSION}" ]] || fail "npm-version-pinned"
pass "toolchain node=$(node -v) npm=$(npm -v) arch=$(uname -m)"

export HOME=/tmp/home NPM_CONFIG_CACHE=/tmp/npm-cache
mkdir -p "$HOME"
cp -r /src /work
cd /work

npm ci --no-audit --no-fund >/tmp/ci.log 2>&1 || { tail -20 /tmp/ci.log; fail "full-npm-ci"; }
pass "full-npm-ci"
npm run typecheck >/tmp/tc.log 2>&1 || { tail -20 /tmp/tc.log; fail "typecheck"; }
pass "typecheck"
npx tsc >/tmp/tsc.log 2>&1 || { tail -20 /tmp/tsc.log; fail "tsc-build"; }
pass "tsc-build"

# Committed client bundles are authoritative; refuse a stale generated bundle.
cp -r public/js /tmp/tracked-js
npm run build:client >/tmp/client.log 2>&1 || { tail -20 /tmp/client.log; fail "build-client"; }
for f in public/js/*.js; do
  cmp -s "$f" "/tmp/tracked-js/$(basename "$f")" || fail "client-bundle-drift:$f"
done
pass "client-bundles-match-committed"

stage=/stage
mkdir -p "$stage/shared" "$stage/scripts"
cp -r dist public package.json package-lock.json "$stage/"
cp shared/vendors.json "$stage/shared/"
cp scripts/check-readiness-once.sh scripts/check-release-ready.sh "$stage/scripts/"
find "$stage/public" -name '*.map' -delete
rm -rf "$stage/dist/scripts"

lock_sha="$(sha256sum package-lock.json | cut -d' ' -f1)"
(cd "$stage" && npm ci --omit=dev --no-audit --no-fund >/tmp/ci-prod.log 2>&1) \
  || { tail -20 /tmp/ci-prod.log; fail "production-npm-ci"; }
[[ "$(sha256sum "$stage/package-lock.json" | cut -d' ' -f1)" == "$lock_sha" ]] \
  || fail "lockfile-unchanged-by-install"
pass "production-npm-ci-lockfile-stable"

# Tests are never shipped; dist is built with tests excluded by tsconfig.
if find "$stage/dist" "$stage/public" "$stage/scripts" -name '*.test.js' | grep -q .; then
  fail "no-test-files"
fi

cat >"$stage/RELEASE.json" <<EOF
{
  "commit": "${RELEASE_COMMIT}",
  "name": "${RELEASE_NAME}",
  "node": "$(node -v)",
  "npm": "$(npm -v)",
  "platform": "linux-x64",
  "image": "${RELEASE_IMAGE}",
  "imageId": "${RELEASE_IMAGE_ID}",
  "lockfileSha256": "${lock_sha}",
  "sourceDateEpoch": ${RELEASE_EPOCH}
}
EOF

archive="/out/${RELEASE_NAME}.tgz"
tar --sort=name --owner=0 --group=0 --numeric-owner \
  --mtime="@${RELEASE_EPOCH}" --format=gnu \
  -cf - -C "$stage" . | gzip -n -9 >"$archive"
(cd /out && sha256sum "${RELEASE_NAME}.tgz" >"${RELEASE_NAME}.sha256")
digest="$(cut -d' ' -f1 "/out/${RELEASE_NAME}.sha256")"
size="$(wc -c <"$archive" | tr -d ' ')"

# ---- verify the archive itself, from a fresh extraction ----
names=/tmp/names
tar -tzf "$archive" >"$names"
entries="$(wc -l <"$names" | tr -d ' ')"
for required in ./RELEASE.json ./package.json ./package-lock.json \
  ./shared/vendors.json ./dist/app.js ./dist/src/credentialLauncher.js \
  ./public/home.html ./public/js/home.js ./scripts/check-readiness-once.sh \
  ./scripts/check-release-ready.sh ./node_modules/express/package.json \
  ./node_modules/mongoose/package.json; do
  grep -qx "$required" "$names" || fail "archive-contains:$required"
done
pass "archive-required-entries"

forbidden='^\./(src|docs|ios|eval|models|planning|\.git|\.github)(/|$)|(^|/)\.env[^/]*$|(^|/)\.DS_Store$|\.(map|p8|pem|key)$|\.test\.(js|ts)$'
if grep -vE '^\./node_modules/' "$names" | grep -E "$forbidden" | grep -q .; then
  grep -vE '^\./node_modules/' "$names" | grep -E "$forbidden" | head >&2
  fail "archive-excludes-forbidden"
fi
if grep -E '^\./node_modules/[^/]+/(\.env[^/]*|\.git)(/|$)' "$names" | grep -q .; then
  fail "dependencies-exclude-env-and-git"
fi
pass "archive-excludes-credentials-dev-and-planning-content"

verify=/tmp/verify
mkdir "$verify"
tar -xzf "$archive" -C "$verify"
[[ "$(find "$verify" -mindepth 1 | wc -l | tr -d ' ')" == "$((entries - 1))" ]] || fail "extracted-entry-count"
[[ ! -e "$verify/node_modules/typescript" && ! -e "$verify/node_modules/vitest" && ! -e "$verify/node_modules/esbuild" ]] \
  || fail "no-development-dependencies"
pass "extraction-and-no-dev-dependencies"

# Every bare and relative import in shipped JS must resolve from the extracted release.
(cd "$verify" && node --input-type=module -e '
import { readdirSync, readFileSync, statSync } from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";
const require = createRequire(path.join(process.cwd(), "package.json"));
const files = [];
const walk = (d) => { for (const e of readdirSync(d)) { const p = path.join(d, e); statSync(p).isDirectory() ? walk(p) : p.endsWith(".js") && files.push(p); } };
walk("dist");
const specs = new Set();
const re = /^(?:import|export)\b[^;"\x27]*?\bfrom\s*["\x27]([^"\x27]+)["\x27]|^import\s*["\x27]([^"\x27]+)["\x27]|\bimport\(\s*["\x27]([^"\x27]+)["\x27]\s*\)/gm;
for (const f of files) for (const m of readFileSync(f, "utf8").matchAll(re)) {
  const s = m[1] ?? m[2] ?? m[3];
  if (!s.startsWith(".") && !s.startsWith("node:") && !s.startsWith("/")) specs.add(s);
}
const bad = [];
const rel = new Set();
for (const f of files) for (const m of readFileSync(f, "utf8").matchAll(re)) {
  const s = m[1] ?? m[2] ?? m[3];
  if (s.startsWith(".")) rel.add(path.resolve(path.dirname(f), s));
}
for (const t of rel) {
  try { if (!statSync(t).isFile()) bad.push(t); } catch { bad.push(t); }
}
for (const s of specs) {
  try { import.meta.resolve(s); } catch { try { require.resolve(s); } catch { bad.push(s); } }
}
if (bad.length) { console.error("unresolved:", bad.join(",")); process.exit(1); }
console.log("resolved " + specs.size + " bare and " + rel.size + " relative specifiers across " + files.length + " files");
') || fail "runtime-imports-resolve"
pass "runtime-imports-resolve"

(cd "$verify" && node -e 'import("./dist/src/credentialLauncher.js").then(()=>console.log("launcher import ok"))') \
  || fail "launcher-imports"
pass "launcher-imports"

# Fail-closed smoke: unreachable database, dummy credentials, clean env.
set +e
(cd "$verify" && env -i PATH="$PATH" NODE_ENV=production HOST=127.0.0.1 PORT=3000 \
  PUBLIC_ACTIONS_PAUSED=true SCHEDULER_ENABLED=true CRON_ENABLED=true \
  BASE_URL=https://artifact-smoke.invalid RESEND_API_KEY=dummy \
  MONGO_URI='mongodb://127.0.0.1:1/commonplate_production?serverSelectionTimeoutMS=3000' \
  CLAIM_TOKEN_HMAC_SECRET=0123456789abcdef0123456789abcdef0123456789abcdef \
  timeout 30 node dist/app.js >/tmp/smoke.out 2>&1)
rc=$?
set -e
[[ "$rc" == 1 ]] || { cut -c1-200 /tmp/smoke.out | head >&2; fail "smoke-exit-1 (rc=$rc)"; }
grep -q 'Atlas connection failed; process will not listen' /tmp/smoke.out || fail "smoke-refusal-message"
! grep -q ENOENT /tmp/smoke.out || fail "smoke-no-ENOENT"
! grep -q 'ready on' /tmp/smoke.out || fail "smoke-not-ready"
pass "smoke-startup-refusal"

cat >"/out/${RELEASE_NAME}.provenance.json" <<EOF
{
  "name": "${RELEASE_NAME}",
  "commit": "${RELEASE_COMMIT}",
  "sha256": "${digest}",
  "sizeBytes": ${size},
  "archiveEntries": ${entries},
  "node": "$(node -v)",
  "npm": "$(npm -v)",
  "platform": "linux-x64",
  "sourceRef": "${RELEASE_REF}",
  "image": "${RELEASE_IMAGE}",
  "imageId": "${RELEASE_IMAGE_ID}",
  "toolchain": {"node": "$(node -v)", "npm": "$(npm -v)", "tsc": "$(npx tsc -v)", "arch": "$(uname -m)"},
  "lockfileSha256": "${lock_sha}",
  "sourceDateEpoch": ${RELEASE_EPOCH},
  "verification": "build-release-artifact.sh container checks passed; deployment-host qualification not performed"
}
EOF
printf 'DONE %s sha256=%s entries=%s size=%s\n' "$RELEASE_NAME" "$digest" "$entries" "$size"
