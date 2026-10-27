import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

const repositoryRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  ".."
);

function readRepositoryFile(relativePath: string): string {
  return readFileSync(path.join(repositoryRoot, relativePath), "utf8");
}

interface AtlasRole {
  roleName: string;
  actions: Array<{
    action: string;
    resources: Array<{ db: string; collection: string }>;
  }>;
  inheritedRoles: unknown[];
}

function readAtlasRole(relativePath: string): AtlasRole {
  return JSON.parse(readRepositoryFile(relativePath)) as AtlasRole;
}

describe("production infrastructure templates", () => {
  it("starts one production scheduler with public actions paused and secrets file-backed", () => {
    const service = readRepositoryFile("deploy/systemd/commonplate.service");
    const reviewService = readRepositoryFile(
      "deploy/systemd/commonplate-review.service.example"
    );

    expect(service).toContain("Environment=PUBLIC_ACTIONS_PAUSED=true");
    expect(service).toContain("Environment=SCHEDULER_ENABLED=true");
    expect(service).toContain("Environment=HOST=127.0.0.1");
    expect(service).toContain("Environment=BASE_URL=https://api.goodgrubapp.com");
    expect(service).toContain(
      'Environment="FROM_EMAIL=GoodGrub <noreply@goodgrubapp.com>"'
    );
    expect(service).toContain("KillMode=control-group");
    expect(service).toContain("Restart=on-failure");
    expect(service).toContain(
      "LoadCredentialEncrypted=MONGO_URI:/etc/credstore.encrypted/commonplate-production/MONGO_URI"
    );
    expect(service).not.toContain("EnvironmentFile=");
    expect(service).not.toContain("MONGO_URI=");
    expect(service).not.toContain("RESEND_API_KEY=");
    expect(service).toContain("LimitCORE=0");
    expect(reviewService).toContain("Environment=SCHEDULER_ENABLED=false");
    expect(reviewService).toContain(
      "Environment=BASE_URL=https://review-api.goodgrubapp.com"
    );
    expect(reviewService).toContain(
      "Environment=PRODUCTION_BASE_URL=https://api.goodgrubapp.com"
    );
  });

  it("documents activation-only injection for optional production credentials", () => {
    const activationCredentials = readRepositoryFile(
      "deploy/systemd/commonplate-activation-credentials.conf.example"
    );

    for (const name of [
      "PARTICIPATION_HMAC_KEYRING",
      "BLOCK_SAFETY_HMAC_KEYRING",
      "PARTICIPANT_DELETION_SIGNING_SECRET",
      "UNSUBSCRIBE_SIGNING_SECRET",
      "PARTICIPANT_SIGNING_SECRET",
      "APNS_TEAM_ID",
      "APNS_KEY_ID",
      "APNS_BUNDLE_ID",
      "APNS_AUTH_KEY_P8",
      "OPENAI_API_KEY",
    ]) {
      expect(activationCredentials).toContain(
        `# LoadCredentialEncrypted=${name}:/etc/credstore.encrypted/commonplate-production/${name}`
      );
    }
    expect(activationCredentials).toContain(
      "only after the corresponding"
    );
  });

  it("keeps the reviewer environment isolated, paused, and scheduler-free", () => {
    const service = readRepositoryFile(
      "deploy/systemd/commonplate-review.service.example"
    );
    const role = readAtlasRole("deploy/atlas/review-runtime-role.json");

    expect(service).toContain("User=commonplate-review");
    expect(service).toContain("PORT=3001");
    expect(service).toContain("NODE_ENV=review");
    expect(service).toContain("PUBLIC_ACTIONS_PAUSED=true");
    expect(service).toContain("SCHEDULER_ENABLED=false");
    expect(service).toContain("EXTERNAL_PROVIDERS=disabled");
    expect(service).toContain("ConditionPathExists=!/var/lib/commonplate-review/quarantine");
    expect(service).toContain("Requires=commonplate-review-egress.service");
    expect(service).not.toContain("LoadCredentialEncrypted=RESEND_API_KEY");
    expect(service).toContain(
      "/etc/credstore.encrypted/commonplate-review/MONGO_URI"
    );
    expect(service).not.toContain("commonplate-production");
    expect(role.actions.every((entry) =>
      entry.resources.every((resource) => resource.db === "commonplate_review")
    )).toBe(true);
    expect(role.inheritedRoles).toEqual([]);
  });

  it("contains review egress by dedicated UID, including loopback, metadata and DNS", () => {
    const policy = readRepositoryFile("deploy/nftables/review-egress.nft.template");
    expect(policy).toContain("meta skuid ${REVIEW_UID} reject");
    expect(policy).toContain("ct state established,related accept");
    expect(policy).toContain("ip daddr @atlas4 tcp dport 27017 accept");
    expect(policy).toContain("ip6 daddr @atlas6 tcp dport 27017 accept");
    expect(policy).not.toContain("dport 443 accept");
    expect(policy).not.toContain("dport 53 accept");
    const unit = readRepositoryFile("deploy/systemd/commonplate-review-egress.service");
    expect(unit).toContain("ExecStart=/usr/sbin/nft -f /etc/commonplate-review/egress.nft");
    expect(unit).not.toContain("ExecStop=");
  });

  it("routes review TLS only to the review process and fences maintenance outside release state", () => {
    const nginx = readRepositoryFile("deploy/nginx/commonplate-review.conf.template");
    expect(nginx).toContain("server_name ${REVIEW_HOSTNAME}");
    expect(nginx).toContain("proxy_pass http://127.0.0.1:3001");
    expect(nginx).not.toContain(":3000");
    expect(nginx).toContain("if (-f /var/lib/commonplate-review/quarantine)");
    expect(nginx).toContain("proxy_set_header X-Forwarded-For $remote_addr");
    expect(nginx).toContain("access_log off");
    const quarantine = readRepositoryFile("scripts/quarantine-review.sh");
    expect(quarantine.indexOf("touch /var/lib/commonplate-review/quarantine"))
      .toBeLessThan(quarantine.indexOf("systemctl stop commonplate-review.service"));
    expect(quarantine).toContain("flock -x 9");
    expect(quarantine).not.toContain("rm ");
    expect(quarantine).not.toContain("commonplate.service");
  });

  it("limits production database privileges to the application database", () => {
    const role = readAtlasRole("deploy/atlas/runtime-role.json");
    const actions = new Set(role.actions.map((entry) => entry.action));

    expect(role.roleName).toBe("commonplateRuntime");
    expect(
      role.actions.every((entry) =>
        entry.resources.every(
          (resource) =>
            resource.db === "commonplate_production" &&
            resource.collection === ""
        )
      )
    ).toBe(true);
    expect(role.inheritedRoles).toEqual([]);
    expect(actions).toEqual(
      new Set([
        "FIND",
        "INSERT",
        "UPDATE",
        "REMOVE",
        "CREATE_COLLECTION",
        "CREATE_INDEX",
        "LIST_INDEXES",
      ])
    );
    expect(actions.has("DROP_DATABASE")).toBe(false);
    expect(actions.has("CREATE_USER")).toBe(false);
  });

  it("keeps the approved hostname configurable and supports bounded long-lived requests", () => {
    const nginx = readRepositoryFile(
      "deploy/nginx/commonplate.conf.template"
    );

    expect(nginx).toContain("${PUBLIC_HOSTNAME}");
    expect(nginx).toContain("client_max_body_size 35m");
    expect(nginx).toContain("proxy_set_header Upgrade $http_upgrade");
    expect(nginx).toContain("proxy_set_header Connection $connection_upgrade");
    expect(nginx).toContain("proxy_read_timeout 3600s");
    expect(nginx).toContain("proxy_buffering off");
    expect(nginx).toContain("proxy_pass http://127.0.0.1:3000");
    expect(
      readRepositoryFile("scripts/render-nginx-config.sh")
    ).toContain("Faith-approved-public-hostname");
  });

  it("monitors readiness without restarting or resuming the application", () => {
    const timer = readRepositoryFile(
      "deploy/systemd/commonplate-readiness.timer"
    );
    const service = readRepositoryFile(
      "deploy/systemd/commonplate-readiness.service"
    );
    const check = readRepositoryFile("scripts/check-readiness-once.sh");

    expect(timer).toContain("OnUnitActiveSec=1min");
    expect(service).toContain(
      "ExecStart=/opt/commonplate/current/scripts/check-readiness-once.sh"
    );
    expect(check).toContain("http://127.0.0.1:3000/health/ready");
    expect(service).not.toContain("Restart=");
    expect(service).not.toContain("PUBLIC_ACTIONS_PAUSED=");
  });

  it("routes recurring retention work through the environment-gated scheduler", () => {
    for (const relativePath of [
      "src/moderationRetentionSweep.ts",
      "src/participantDeletionReceiptSweep.ts",
    ]) {
      const source = readRepositoryFile(relativePath);
      expect(source).toContain("registerScheduledJob(");
      expect(source).not.toContain("cron.schedule(");
    }
  });

  it("does not include credentials or Atlas URIs in the approved hostname configuration", () => {
    for (const relativePath of [
      "deploy/systemd/commonplate.service",
      "deploy/systemd/commonplate-activation-credentials.conf.example",
      "deploy/systemd/commonplate-review.service.example",
      "deploy/systemd/commonplate-readiness.service",
      "deploy/systemd/commonplate-readiness.timer",
      "scripts/render-nginx-config.sh",
      "deploy/nginx/commonplate.conf.template",
      "deploy/atlas/runtime-role.json",
      "deploy/atlas/review-runtime-role.json",
    ]) {
      const content = readRepositoryFile(relativePath);
      expect(content).not.toMatch(/mongodb(?:\+srv)?:\/\//);
      expect(content).not.toMatch(/(?:sk|re)_[A-Za-z0-9]{16,}/);
    }
    expect(readRepositoryFile("deploy/systemd/commonplate.service")).toContain(
      "https://api.goodgrubapp.com"
    );
    expect(readRepositoryFile("deploy/systemd/commonplate-review.service.example"))
      .toContain("https://review-api.goodgrubapp.com");
  });
});
