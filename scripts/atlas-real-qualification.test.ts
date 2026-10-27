import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import {
  CONFIRM_ENV,
  EXPECTED_HOST_ENV,
  QUAL_ROLE,
  RealQualSafetyError,
  assertAtlasTarget,
  classifyAttempt,
  evaluateSession,
  expectedActions,
  expectedConfirmation,
  formatReport,
  qualRoleDefinition,
  redact,
  summarizeLatency,
  type ConnectionStatusReply,
  type RoleDefinition,
} from "./atlas-real-qualification-guards.js";
import { parseOnly, runStage } from "./atlas-real-qualification.js";

const HOST = "goodgrub-prod-01.abc123.mongodb.net";
const QUAL_DB = "cpq_qual_20261022";
const SECRET = "s3cr3t-value";
const uriFor = (user: string, database: string, query = "retryWrites=true&w=majority") =>
  `mongodb+srv://${user}:${SECRET}@${HOST}/${database}?${query}`;
const confirmFor = (stage: "qual" | "runtime" | "review", database: string) => ({
  [CONFIRM_ENV]: expectedConfirmation(stage, database),
  [EXPECTED_HOST_ENV]: HOST,
});
const refusal = (run: () => unknown) => {
  try {
    run();
  } catch (error) {
    expect(error).toBeInstanceOf(RealQualSafetyError);
    expect(String((error as Error).message)).not.toContain(SECRET);
    return (error as Error).message;
  }
  throw new Error("expected a refusal");
};

describe("assertAtlasTarget", () => {
  it("accepts the pinned cluster, exact user and database with confirmation", () => {
    expect(assertAtlasTarget(uriFor("goodgrub_qual", QUAL_DB), "qual", confirmFor("qual", QUAL_DB))).toEqual({
      srvHost: HOST,
      username: "goodgrub_qual",
      database: QUAL_DB,
    });
    expect(
      assertAtlasTarget(uriFor("goodgrub_runtime", "commonplate_production"), "runtime", confirmFor("runtime", "commonplate_production")).database
    ).toBe("commonplate_production");
    expect(
      assertAtlasTarget(uriFor("goodgrub-review", "commonplate_review"), "review", confirmFor("review", "commonplate_review")).username
    ).toBe("goodgrub-review");
  });

  it.each([
    ["loopback mongodb://", `mongodb://goodgrub_qual:${SECRET}@127.0.0.1:27017/${QUAL_DB}?replicaSet=rs0`],
    ["another cluster", `mongodb+srv://goodgrub_qual:${SECRET}@other-cluster.abc123.mongodb.net/${QUAL_DB}`],
    ["same cluster name, different Atlas id", `mongodb+srv://goodgrub_qual:${SECRET}@goodgrub-prod-01.zzz999.mongodb.net/${QUAL_DB}`],
    ["lookalike suffix", `mongodb+srv://goodgrub_qual:${SECRET}@${HOST}.evil.example/${QUAL_DB}`],
    ["lookalike prefix", `mongodb+srv://goodgrub_qual:${SECRET}@evil.${HOST}/${QUAL_DB}`],
    ["different user", uriFor("goodgrub_runtime", QUAL_DB)],
    ["no password", `mongodb+srv://goodgrub_qual@${HOST}/${QUAL_DB}`],
    ["production database for the qual user", uriFor("goodgrub_qual", "commonplate_production")],
    ["admin database", uriFor("goodgrub_qual", "admin")],
    ["no database", `mongodb+srv://goodgrub_qual:${SECRET}@${HOST}/`],
    ["tls disabled", uriFor("goodgrub_qual", QUAL_DB, "tls=false")],
    ["alternative auth source", uriFor("goodgrub_qual", QUAL_DB, "authSource=$external")],
    ["unknown option", uriFor("goodgrub_qual", QUAL_DB, "proxyHost=127.0.0.1")],
    ["direct connection", uriFor("goodgrub_qual", QUAL_DB, "directConnection=true")],
  ])("refuses %s", (_label, uri) => {
    refusal(() => assertAtlasTarget(uri, "qual", confirmFor("qual", QUAL_DB)));
  });

  it("refuses real users on any database but their own, and the qual user on real databases", () => {
    refusal(() => assertAtlasTarget(uriFor("goodgrub_runtime", "commonplate_review"), "runtime", confirmFor("runtime", "commonplate_review")));
    refusal(() => assertAtlasTarget(uriFor("goodgrub-review", "commonplate_production"), "review", confirmFor("review", "commonplate_production")));
    refusal(() => assertAtlasTarget(uriFor("goodgrub_runtime", QUAL_DB), "runtime", confirmFor("runtime", QUAL_DB)));
  });

  it("requires the operator-recorded exact SRV host", () => {
    const uri = uriFor("goodgrub_qual", QUAL_DB);
    const { [EXPECTED_HOST_ENV]: _omit, ...withoutHost } = confirmFor("qual", QUAL_DB);
    expect(refusal(() => assertAtlasTarget(uri, "qual", withoutHost))).toContain(EXPECTED_HOST_ENV);
    refusal(() => assertAtlasTarget(uri, "qual", { ...withoutHost, [EXPECTED_HOST_ENV]: "goodgrub-prod-01.zzz999.mongodb.net" }));
    refusal(() => assertAtlasTarget(uri, "qual", { ...withoutHost, [EXPECTED_HOST_ENV]: "evil.example" }));
  });

  it("requires the exact confirmation and never echoes the URI", () => {
    const uri = uriFor("goodgrub_qual", QUAL_DB);
    expect(refusal(() => assertAtlasTarget(uri, "qual", { [EXPECTED_HOST_ENV]: HOST }))).toContain(CONFIRM_ENV);
    refusal(() => assertAtlasTarget(uri, "qual", { [EXPECTED_HOST_ENV]: HOST, [CONFIRM_ENV]: "goodgrub-prod-01:cpq_qual_20991231" }));
    refusal(() => assertAtlasTarget(uri, "qual", confirmFor("runtime", "commonplate_production")));
  });
});

const goodPrivileges = (database: string, actions: string[]) =>
  actions.length === 0 ? [] : [{ resource: { db: database, collection: "" }, actions }];
const status = (overrides: Partial<NonNullable<ConnectionStatusReply["authInfo"]>> = {}): ConnectionStatusReply => ({
  authInfo: {
    authenticatedUsers: [{ user: "goodgrub_qual", db: "admin" }],
    authenticatedUserRoles: [{ role: QUAL_ROLE, db: "admin" }],
    authenticatedUserPrivileges: goodPrivileges(QUAL_DB, expectedActions("qual")),
    ...overrides,
  },
});
const atlasHello = { setName: "atlas-xyz-shard-0", hosts: [`ac-1.${HOST.split(".").slice(1).join(".")}:27017`], me: "ac-1.abc123.mongodb.net:27017" };
const qualExpectation = { stage: "qual" as const, database: QUAL_DB, actions: expectedActions("qual") };

describe("evaluateSession (server-side gate)", () => {
  it("accepts exactly the stage user, role, database and closed action set", () => {
    expect(evaluateSession(status(), atlasHello, qualExpectation)).toEqual([]);
  });

  it("rejects extra or missing actions, other databases, cluster privileges and wrong roles", () => {
    expect(evaluateSession(status({ authenticatedUserPrivileges: goodPrivileges(QUAL_DB, [...expectedActions("qual"), "dropDatabase"]) }), atlasHello, qualExpectation).join()).toContain("extra privilege action dropDatabase");
    expect(evaluateSession(status({ authenticatedUserPrivileges: goodPrivileges(QUAL_DB, ["find"]) }), atlasHello, qualExpectation).join()).toContain("missing privilege action");
    expect(evaluateSession(status({ authenticatedUserPrivileges: [...goodPrivileges(QUAL_DB, expectedActions("qual")), { resource: { db: "commonplate_production", collection: "" }, actions: ["find"] }] }), atlasHello, qualExpectation).join()).toContain("not scoped");
    expect(evaluateSession(status({ authenticatedUserPrivileges: [...goodPrivileges(QUAL_DB, expectedActions("qual")), { resource: { cluster: true }, actions: ["find"] }] }), atlasHello, qualExpectation).join()).toContain("not scoped");
    expect(evaluateSession(status({ authenticatedUserRoles: [{ role: "atlasAdmin", db: "admin" }] }), atlasHello, qualExpectation).join()).toContain("role");
    expect(evaluateSession(status({ authenticatedUsers: [{ user: "goodgrub_qual", db: "admin" }, { user: "x", db: "admin" }] }), atlasHello, qualExpectation).join()).toContain("user");
  });

  it("requires Atlas, non-loopback replica-set members", () => {
    expect(evaluateSession(status(), { setName: "rs0", hosts: ["127.0.0.1:27017"], me: "127.0.0.1:27017" }, qualExpectation).join()).toContain("Atlas");
    expect(evaluateSession(status(), { hosts: [] }, qualExpectation).join()).toContain("replica set");
  });

  it("holds real users to their one database and the runtime action set only", () => {
    const runtime = {
      authInfo: {
        authenticatedUsers: [{ user: "goodgrub_runtime", db: "admin" }],
        authenticatedUserRoles: [{ role: "commonplateRuntime", db: "admin" }],
        authenticatedUserPrivileges: goodPrivileges("commonplate_production", expectedActions("runtime")),
      },
    };
    expect(evaluateSession(runtime, atlasHello, { stage: "runtime", database: "commonplate_production", actions: expectedActions("runtime") })).toEqual([]);
    expect(expectedActions("runtime")).not.toContain("dropCollection");
    expect(evaluateSession(runtime, atlasHello, { stage: "review", database: "commonplate_review", actions: expectedActions("review") }).length).toBeGreaterThan(0);
  });
});

describe("classification and helpers", () => {
  it("counts only Unauthorized as a denial", () => {
    expect(classifyAttempt({ code: 13 })).toBe("denied");
    expect(classifyAttempt(undefined)).toBe("authorized");
    expect(classifyAttempt({ code: 26 })).toBe("authorized");
    expect(classifyAttempt({ code: 8000 })).toBe("inconclusive");
    expect(classifyAttempt({ code: 8000, message: "Unauthorized: not authorized on db to execute command" })).toBe("denied");
    expect(classifyAttempt({ code: 8000, message: "user is not allowed to do action [dropIndex] on [cpq.x]" })).toBe("denied");
    expect(classifyAttempt({ code: 8000, message: "command not supported in Flex clusters" })).toBe("inconclusive");
    expect(classifyAttempt({ code: 8000, message: "quota exceeded" })).toBe("inconclusive");
    expect(classifyAttempt({ code: 1, message: "not authorized" })).toBe("inconclusive");
    expect(classifyAttempt({ message: "Unauthorized" })).toBe("inconclusive");
    expect(classifyAttempt(new Error("network"))).toBe("inconclusive");
  });

  it("derives the qualification role from the committed runtime role, scoped to one disposable database", () => {
    const runtime = JSON.parse(readFileSync("deploy/atlas/runtime-role.json", "utf8")) as RoleDefinition;
    const role = qualRoleDefinition(runtime, "20261022");
    expect(role.roleName).toBe(QUAL_ROLE);
    expect(role.actions.map((entry) => entry.action)).toEqual([...runtime.actions.map((entry) => entry.action), "DROP_COLLECTION"]);
    for (const entry of role.actions) expect(entry.resources).toEqual([{ db: QUAL_DB, collection: "" }]);
    expect(role.inheritedRoles).toEqual([]);
    expect(() => qualRoleDefinition(runtime, "../x")).toThrow(RealQualSafetyError);
    const widened = { ...runtime, actions: [...runtime.actions, { action: "DROP_DATABASE", resources: [{ db: "x", collection: "" }] }] };
    expect(() => qualRoleDefinition(widened, "20261022")).toThrow(RealQualSafetyError);
    expect(() => qualRoleDefinition({ ...runtime, actions: runtime.actions.slice(1) }, "20261022")).toThrow(RealQualSafetyError);
    expect(() => qualRoleDefinition({ ...runtime, inheritedRoles: [{ role: "x" }] }, "20261022")).toThrow(RealQualSafetyError);
    expect(JSON.stringify(role)).not.toContain("commonplate_");
  });

  it("summarizes latency and redacts secrets in reports", () => {
    expect(summarizeLatency([10, 20, 30, 40, 100])).toEqual({ samples: 5, medianMs: 30, p95Ms: 100 });
    const text = formatReport("qual", null, [{ name: "x", status: "fail", detail: `mongodb+srv://u:${SECRET}@h/db password=${SECRET}` }]);
    expect(text).not.toContain(SECRET);
    expect(redact("mongodb://a:b@c/d")).toBe("mongodb://[redacted]");
    expect(text).toContain("NOT COVERED");
  });
});

describe("runStage ordering", () => {
  const recorder = (privileges: ReturnType<typeof goodPrivileges>, hello: Record<string, unknown> = atlasHello) => {
    const commands: string[] = [];
    let created = false;
    const client = {
      connect: async () => undefined,
      close: async () => undefined,
      startSession: () => {
        commands.push("startSession");
        throw new Error("no session expected");
      },
      db: (name: string) => ({
        command: async (command: Record<string, unknown>) => {
          commands.push(`${name}:${Object.keys(command)[0]}`);
          if ("connectionStatus" in command) return status({ authenticatedUserPrivileges: privileges });
          if ("hello" in command) return hello;
          return {};
        },
        listCollections: (_filter: unknown, options: Record<string, unknown>) => ({
          toArray: async () => {
            if (options?.nameOnly !== true || options?.authorizedCollections !== true) {
              throw Object.assign(new Error("unauthorized listCollections"), { code: 8000 });
            }
            commands.push(`${name}:listCollections`);
            return [];
          },
        }),
        collection: () => ({}),
        createCollection: async () => {
          created = true;
          commands.push("createCollection");
        },
        dropCollection: async () => {
          commands.push("dropCollection");
        },
      }),
    };
    return { client: client as never, commands, wasCreated: () => created };
  };

  it("never builds a client for a refused target", async () => {
    let built = 0;
    const outcome = await runStage({
      stage: "qual",
      uri: `mongodb://goodgrub_qual:${SECRET}@127.0.0.1:27017/${QUAL_DB}?replicaSet=rs0`,
      environment: confirmFor("qual", QUAL_DB),
      repositoryRoot: process.cwd(),
      createClient: () => {
        built += 1;
        return undefined as never;
      },
    });
    expect(built).toBe(0);
    expect(outcome.results[0]?.status).toBe("fail");
    expect(JSON.stringify(outcome)).not.toContain(SECRET);
  });

  it("stops at the session gate, before any write or cleanup, when privileges are broader than expected", async () => {
    const fake = recorder(goodPrivileges(QUAL_DB, [...expectedActions("qual"), "dropDatabase", "anyAction"]));
    const outcome = await runStage({
      stage: "qual",
      uri: uriFor("goodgrub_qual", QUAL_DB),
      environment: confirmFor("qual", QUAL_DB),
      repositoryRoot: process.cwd(),
      createClient: () => fake.client,
    });
    expect(outcome.results.some((result) => result.name === "stage aborted" && result.status === "fail")).toBe(true);
    expect(fake.wasCreated()).toBe(false);
    expect(fake.commands).toEqual(["admin:connectionStatus", "admin:hello"]);
  });

  it("stops at the session gate for loopback members even with correct privileges", async () => {
    const fake = recorder(goodPrivileges(QUAL_DB, expectedActions("qual")), { setName: "rs0", hosts: ["127.0.0.1:27017"] });
    const outcome = await runStage({
      stage: "qual",
      uri: uriFor("goodgrub_qual", QUAL_DB),
      environment: confirmFor("qual", QUAL_DB),
      repositoryRoot: process.cwd(),
      createClient: () => fake.client,
    });
    expect(outcome.results.at(-1)?.detail).toContain("Atlas");
    expect(fake.commands).toEqual(["admin:connectionStatus", "admin:hello"]);
  });
});

describe("runStage for the real runtime user", () => {
  const runtimeStatus: ConnectionStatusReply = {
    authInfo: {
      authenticatedUsers: [{ user: "goodgrub_runtime", db: "admin" }],
      authenticatedUserRoles: [{ role: "commonplateRuntime", db: "admin" }],
      authenticatedUserPrivileges: goodPrivileges("commonplate_production", expectedActions("runtime")),
    },
  };
  const make = (listIndexesBehavior: () => Promise<unknown[]>, listDatabases: () => Promise<unknown>) => {
    const sent: string[] = [];
    const collection = (db: string, name: string) => ({
      findOne: async () => {
        if (db !== "commonplate_production") throw Object.assign(new Error("unauthorized"), { code: 13 });
        sent.push(`${db}.${name}:find`);
        return null;
      },
      listIndexes: () => ({ toArray: listIndexesBehavior }),
      dropIndexes: async () => {
        sent.push(`${db}.${name}:dropIndexes`);
        throw Object.assign(new Error("unauthorized"), { code: 13 });
      },
    });
    const client = {
      connect: async () => undefined,
      close: async () => undefined,
      db: (name: string) => ({
        command: async (command: Record<string, unknown>) => {
          const key = Object.keys(command)[0] as string;
          if (key === "connectionStatus") return runtimeStatus;
          if (key === "hello") return atlasHello;
          if (key === "ping") return {};
          if (key === "listDatabases") return listDatabases();
          sent.push(`${name}:${key}`);
          throw Object.assign(new Error("unauthorized"), { code: 13 });
        },
        collection: (collectionName: string) => collection(name, collectionName),
        dropCollection: async () => {
          sent.push(`${name}:dropCollection`);
          throw Object.assign(new Error("unauthorized"), { code: 13 });
        },
      }),
    };
    return { client: client as never, sent };
  };
  const input = (client: never) => ({
    stage: "runtime" as const,
    uri: uriFor("goodgrub_runtime", "commonplate_production"),
    environment: confirmFor("runtime", "commonplate_production"),
    repositoryRoot: process.cwd(),
    createClient: () => client,
  });
  const notFound = async () => {
    throw Object.assign(new Error("ns not found"), { code: 26 });
  };

  it("accepts refused listDatabases (13) and sends only reads and denied probes", async () => {
    const fake = make(notFound, async () => {
      throw Object.assign(new Error("unauthorized"), { code: 13 });
    });
    const outcome = await runStage(input(fake.client));
    expect(outcome.results.filter((r) => r.status === "fail")).toEqual([]);
    expect(fake.sent.every((entry) => /:find$|dropIndexes$|dropCollection$|collMod$|renameCollection$|createUser$/.test(entry))).toBe(true);
    expect(fake.sent.some((entry) => /insert|update|delete|drop(Database)/i.test(entry))).toBe(false);
  });

  it("sends no destructive probe when the probe namespace cannot be proven absent", async () => {
    const fake = make(async () => [], async () => ({ databases: [{ name: "commonplate_production" }] }));
    const outcome = await runStage(input(fake.client));
    expect(outcome.results.some((r) => r.status === "fail" && r.detail.includes("unexpectedly exists"))).toBe(true);
    expect(fake.sent.some((entry) => /dropIndexes|dropCollection|collMod|renameCollection|createUser/.test(entry))).toBe(false);
  });

  it("fails when listDatabases exposes another database", async () => {
    const fake = make(notFound, async () => ({ databases: [{ name: "commonplate_production" }, { name: "commonplate_review" }] }));
    const outcome = await runStage(input(fake.client));
    expect(outcome.results.some((r) => r.status === "fail" && r.detail.includes("listDatabases exposed"))).toBe(true);
  });
});

describe("targeted qual checks with server-state verification", () => {
  const denied = () => Object.assign(new Error("not authorized"), { code: 13, codeName: "Unauthorized" });
  const make = (opts: { dropIndexesWorks?: boolean; renameWorks?: boolean; pingMs?: number; findMode?: "timeouts" | "unrelated" | "none" }) => {
    const state = { collections: new Set<string>(), indexes: ["_id_", "key_1"] };
    let finds = 0;
    const named = (name: string, message: string) => Object.assign(new Error(message), { name });
    const collection = (db: string, name: string) => ({
      createIndex: async () => "key_1",
      insertOne: async () => {
        if (db !== QUAL_DB) throw denied();
        return {};
      },
      listIndexes: () => ({ toArray: async () => state.indexes.map((indexName) => ({ name: indexName })) }),
      dropIndexes: async () => {
        if (!opts.dropIndexesWorks) throw denied();
        state.indexes = ["_id_"];
      },
      findOne: async () => {
        if (name === "probe_items" && db === QUAL_DB) {
          finds += 1;
          if (opts.findMode === "timeouts" && finds > 1) {
            await new Promise((resolve) => setTimeout(resolve, 5));
            throw named("MongoWaitQueueTimeoutError", "Timed out while checking out a connection from connection pool");
          }
          if (opts.findMode === "unrelated" && finds > 1) throw named("MongoNetworkError", "socket closed");
          return null;
        }
        throw denied();
      },
    });
    const client = {
      connect: async () => undefined,
      close: async () => undefined,
      db: (db: string) => ({
        command: async (command: Record<string, unknown>) => {
          const key = Object.keys(command)[0] as string;
          if (key === "connectionStatus") return status({ authenticatedUserPrivileges: goodPrivileges(QUAL_DB, expectedActions("qual")) });
          if (key === "hello") return atlasHello;
          if (key === "ping") {
            await new Promise((resolve) => setTimeout(resolve, opts.pingMs ?? 0));
            return {};
          }
          if (key === "listDatabases") return { databases: [{ name: QUAL_DB }] };
          if (key === "dropIndexes") {
            if (!opts.dropIndexesWorks) throw denied();
            state.indexes = state.indexes.filter((indexName) => indexName !== command.index);
            return { ok: 1, nIndexesWas: 2 };
          }
          if (key === "renameCollection") {
            if (!opts.renameWorks) throw denied();
            state.collections.delete("probe_rename_src");
            state.collections.add("probe_rename_dst");
            return {};
          }
          throw denied();
        },
        listCollections: () => ({ toArray: async () => [...state.collections].map((name) => ({ name })) }),
        createCollection: async (name: string) => {
          state.collections.add(name);
        },
        dropCollection: async (name: string) => {
          state.collections.delete(name);
        },
        dropDatabase: async () => {
          throw denied();
        },
        collection: (name: string) => collection(db, name),
      }),
    };
    return client as never;
  };
  const run = (client: never, only: string) =>
    runStage({
      stage: "qual",
      uri: uriFor("goodgrub_qual", QUAL_DB),
      environment: { ...confirmFor("qual", QUAL_DB), ATLAS_QUAL_ONLY: only },
      repositoryRoot: process.cwd(),
      createClient: () => client,
    });
  const find = (outcome: Awaited<ReturnType<typeof runStage>>, fragment: string) => outcome.results.find((r) => r.name.includes(fragment));

  it("refuses unknown groups", () => {
    expect(() => parseOnly("denials,bogus")).toThrow(RealQualSafetyError);
    expect(parseOnly(undefined)).toBeNull();
  });

  it("passes the denial check only when dropIndexes is denied and the index survives", async () => {
    const outcome = await run(make({}), "denials");
    const result = find(outcome, "expected denials");
    expect(result?.status).toBe("pass");
    expect(result?.detail).toContain("error code 13");
  });

  it("fails when dropIndexes actually removes the index", async () => {
    const outcome = await run(make({ dropIndexesWorks: true }), "denials");
    const result = find(outcome, "expected denials");
    expect(result?.status).toBe("fail");
    expect(result?.detail).toContain("_id_,key_1 -> _id_");
    expect(result?.detail).toContain("nIndexesWas=2");
  });

  it("reports a permitted rename as informational with verified state", async () => {
    const outcome = await run(make({ renameWorks: true }), "rename");
    const result = find(outcome, "renameCollection");
    expect(result?.status).toBe("informational");
    expect(result?.detail).toContain("state verified");
  });

  it("passes the pool deadline check only for MongoWaitQueueTimeoutError", async () => {
    const ok = find(await run(make({ pingMs: 12, findMode: "timeouts" }), "failfast"), "checkout deadline");
    expect(ok?.status).toBe("pass");
    expect(ok?.detail).toContain("op0: ok");
    const wrong = find(await run(make({ pingMs: 12, findMode: "unrelated" }), "failfast"), "checkout deadline");
    expect(wrong?.status).toBe("fail");
    const none = find(await run(make({ pingMs: 12, findMode: "none" }), "failfast"), "checkout deadline");
    expect(none?.status).toBe("fail");
    const tiny = find(await run(make({ pingMs: 0, findMode: "none" }), "failfast"), "checkout deadline");
    expect(tiny?.status).toBe("informational");
  });
});
