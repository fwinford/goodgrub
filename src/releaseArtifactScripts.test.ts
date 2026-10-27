import { existsSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const read = (relative: string) =>
  readFileSync(fileURLToPath(new URL(`../${relative}`, import.meta.url)), "utf8");
const builder = read("scripts/build-release-artifact.sh");
const container = read("scripts/release-artifact-container.sh");

describe("release artifact assembly (source wiring)", () => {
  it("builds from a committed revision for linux/amd64, never the working tree", () => {
    expect(builder).toContain('git archive --format=tar "$commit"');
    expect(builder).toContain("--platform linux/amd64");
    expect(builder).toContain('-v "$work/src:/src:ro"');
    expect(builder).not.toMatch(/^[^#\n]*\.env/m);
  });

  it("pins the image by digest, verifies the commit and warns on a dirty tree", () => {
    expect(builder).toMatch(/node:\$\{NODE_VERSION\}-bookworm@sha256:[0-9a-f]{64}/);
    expect(builder).toContain("git status --porcelain");
    expect(builder).toContain("NOT included");
    expect(builder).toContain("--verify --quiet");
    expect(container).toContain("imageId");
    expect(container).toContain("relative specifiers");
  });

  it("stages every runtime file read from the release root, and only those", () => {
    for (const file of [
      "shared/vendors.json",
      "scripts/check-readiness-once.sh",
      "scripts/check-release-ready.sh",
    ]) {
      expect(existsSync(fileURLToPath(new URL(`../${file}`, import.meta.url)))).toBe(true);
      expect(container).toContain(file);
    }
    expect(container).toContain("cp -r dist public package.json package-lock.json");
    expect(container).not.toMatch(/cp .*\.env/);
  });

  it("installs only production dependencies with the lockfile unchanged", () => {
    expect(container).toContain("npm ci --omit=dev --no-audit --no-fund");
    expect(container).toContain("lockfile-unchanged-by-install");
    expect(container).not.toContain("--ignore-scripts");
    expect(container).not.toContain("--legacy-peer-deps");
  });

  it("refuses on missing content, forbidden content, unresolved imports or a non-refusing start", () => {
    for (const marker of [
      "archive-required-entries",
      "archive-excludes-forbidden",
      "runtime-imports-resolve",
      "smoke-startup-refusal",
      "client-bundle-drift",
    ]) {
      expect(container).toContain(marker);
    }
    expect(container).toContain("Atlas connection failed; process will not listen");
  });

  it("keeps the credential launcher compiled path used by the systemd unit", () => {
    expect(container).toContain("./dist/src/credentialLauncher.js");
    expect(read("deploy/systemd/commonplate.service")).toContain(
      "/opt/commonplate/current/dist/src/credentialLauncher.js"
    );
  });
});
