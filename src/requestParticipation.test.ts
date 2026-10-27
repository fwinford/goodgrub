// Focused coverage for the W3-H2 marketplace-presentation helpers: resolving
// an optional (never-refusing) participant identity for a browse-only read,
// and finding the exact set of request ids a verified participant has ever
// successfully held.
import type { Request } from "express";
import mongoose from "mongoose";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  ParticipantIdentityKeyVersion,
  RequestParticipation,
} from "../models/db.js";
import {
  BLOCK_SAFETY_HMAC_KEYRING_ENV,
  PARTICIPANT_IDENTITY_QUERY_TIMEOUT_MS,
  PARTICIPATION_HMAC_KEYRING_ENV,
} from "./participantIdentityKeys.js";
import { PARTICIPANT_AUTHORITY_HEADER } from "./participantAuthorityGate.js";
import {
  PARTICIPANT_SIGNING_SECRET_ENV,
  signParticipantAuthority,
} from "./participantCredentials.js";
import {
  filterRequestListForParticipant,
  findParticipatedRequestIds,
  ParticipantParticipationReadCancelled,
  resolveOptionalParticipantAuthority,
} from "./requestParticipation.js";

const participantId = new mongoose.Types.ObjectId(
  "64f0000000000000000000a9"
);
const participantSecretText = "request-participation-unit-test-secret";
const participantSecret = Buffer.from(participantSecretText);
const authority = signParticipantAuthority(participantId, 1, participantSecret);

function reqWithHeaders(headers: Record<string, string> = {}): Request {
  return { headers } as unknown as Request;
}

function mockParticipationRows(
  rows: Array<{ requestId: mongoose.Types.ObjectId }>
): void {
  vi.spyOn(RequestParticipation, "find").mockImplementation((() => {
    let selected: string | undefined;
    const query = {
      maxTimeMS() {
        return query;
      },
      select(value: string) {
        selected = value;
        return query;
      },
      limit() {
        return query;
      },
      lean() {
        return query;
      },
      exec: vi.fn(async () => (selected === "_id" ? [] : rows)),
    };
    return query;
  }) as unknown as typeof RequestParticipation.find);
}

beforeEach(() => {
  vi.stubEnv(PARTICIPANT_SIGNING_SECRET_ENV, participantSecretText);
  vi.stubEnv(
    PARTICIPATION_HMAC_KEYRING_ENV,
    JSON.stringify({
      currentVersion: 1,
      keys: { "1": Buffer.alloc(32, 1).toString("base64") },
    })
  );
  vi.stubEnv(
    BLOCK_SAFETY_HMAC_KEYRING_ENV,
    JSON.stringify({
      currentVersion: 1,
      keys: { "1": Buffer.alloc(32, 2).toString("base64") },
    })
  );
  vi.spyOn(ParticipantIdentityKeyVersion, "find").mockReturnValue({
    maxTimeMS: () => ({
      select: () => ({
        lean: () => ({
          exec: vi.fn().mockResolvedValue([
            {
              purpose: "participation",
              version: 1,
              normalizationVersion: 1,
            },
          ]),
        }),
      }),
    }),
  } as unknown as ReturnType<typeof ParticipantIdentityKeyVersion.find>);
});

afterEach(() => {
  vi.restoreAllMocks();
  vi.unstubAllEnvs();
});

describe("resolveOptionalParticipantAuthority", () => {
  it("resolves the verified participant when a usable credential is presented", async () => {
    const ParticipantModel = (
      await import("../models/db.js")
    ).Participant;
    vi.spyOn(ParticipantModel, "findOne").mockReturnValue({
      select: () => ({
        lean: () => ({
          exec: vi.fn().mockResolvedValue({
            _id: participantId,
            email: "already-participated@nyu.edu",
            authorityVersion: 1,
          }),
        }),
      }),
    } as unknown as ReturnType<typeof ParticipantModel.findOne>);

    const result = await resolveOptionalParticipantAuthority(
      reqWithHeaders({ [PARTICIPANT_AUTHORITY_HEADER]: authority })
    );

    expect(result).toEqual({
      participantId: String(participantId),
      principal: "already-participated@nyu.edu",
      authorityVersion: 1,
    });
  });

  it("resolves null, never a refusal, when no credential is presented", async () => {
    const result = await resolveOptionalParticipantAuthority(
      reqWithHeaders({})
    );

    expect(result).toBeNull();
  });

  it("resolves null, never a refusal, when the presented credential cannot be verified", async () => {
    const result = await resolveOptionalParticipantAuthority(
      reqWithHeaders({ [PARTICIPANT_AUTHORITY_HEADER]: "not-a-real-credential" })
    );

    expect(result).toBeNull();
  });
});

describe("findParticipatedRequestIds", () => {
  it("returns an empty set without querying when no candidates are supplied", async () => {
    const query = vi.spyOn(RequestParticipation, "find");

    const result = await findParticipatedRequestIds(
      String(participantId),
      "already-participated@nyu.edu",
      []
    );

    expect(result.size).toBe(0);
    expect(query).not.toHaveBeenCalled();
  });

  it("returns only the candidate ids this exact participant has participated in", async () => {
    const participatedId = new mongoose.Types.ObjectId();
    mockParticipationRows([{ requestId: participatedId }]);

    const result = await findParticipatedRequestIds(
      String(participantId),
      "already-participated@nyu.edu",
      [participatedId, new mongoose.Types.ObjectId()]
    );

    expect(result).toEqual(new Set([String(participatedId)]));
  });

  it("does not propagate a database error containing a keyed identity filter", async () => {
    const privateDigest = "a".repeat(64);
    let executions = 0;
    vi.spyOn(RequestParticipation, "find").mockImplementation((() => {
      const query = {
        maxTimeMS: () => query,
        select: () => query,
        limit: () => query,
        lean: () => query,
        exec: vi.fn(async () => {
          executions += 1;
          if (executions === 1) return [];
          throw new Error(`database diagnostic included ${privateDigest}`);
        }),
      };
      return query;
    }) as unknown as typeof RequestParticipation.find);

    await expect(
      findParticipatedRequestIds(
        String(participantId),
        "already-participated@nyu.edu",
        [new mongoose.Types.ObjectId()]
      )
    ).rejects.toMatchObject({
      message: "Request participation identity data is unavailable",
    });
  });

  it("applies finite deadlines to each identity query and stops after cancellation", async () => {
    const candidate = new mongoose.Types.ObjectId();
    const identityQueries: Array<ReturnType<typeof vi.fn>> = [];
    vi.spyOn(ParticipantIdentityKeyVersion, "find").mockReturnValue({
      maxTimeMS: vi.fn((timeout: number) => {
        expect(timeout).toBe(PARTICIPANT_IDENTITY_QUERY_TIMEOUT_MS);
        return {
          select: () => ({
            lean: () => ({
              exec: vi.fn().mockResolvedValue([
                {
                  purpose: "participation",
                  version: 1,
                  normalizationVersion: 1,
                },
              ]),
            }),
          }),
        };
      }),
    } as unknown as ReturnType<typeof ParticipantIdentityKeyVersion.find>);
    vi.spyOn(RequestParticipation, "find").mockImplementation((() => {
      const maxTimeMS = vi.fn((timeout: number) => {
        expect(timeout).toBe(PARTICIPANT_IDENTITY_QUERY_TIMEOUT_MS);
        return query;
      });
      const query = {
        maxTimeMS,
        select: (selection: string) => ({
          limit: () => ({
            lean: () => ({
              exec: vi.fn().mockResolvedValue(
                selection === "_id" ? [] : [{ requestId: candidate }]
              ),
            }),
          }),
          lean: () => ({
            exec: vi.fn().mockResolvedValue([{ requestId: candidate }]),
          }),
        }),
      };
      identityQueries.push(maxTimeMS);
      return query;
    }) as unknown as typeof RequestParticipation.find);

    await expect(
      findParticipatedRequestIds(
        String(participantId),
        "already-participated@nyu.edu",
        [candidate]
      )
    ).resolves.toEqual(new Set([String(candidate)]));
    expect(identityQueries).toHaveLength(2);
    expect(identityQueries[0]).toHaveBeenCalledWith(
      PARTICIPANT_IDENTITY_QUERY_TIMEOUT_MS
    );
    expect(identityQueries[1]).toHaveBeenCalledWith(
      PARTICIPANT_IDENTITY_QUERY_TIMEOUT_MS
    );

    let cancellationChecks = 0;
    const participationLookup = vi.spyOn(RequestParticipation, "find");
    participationLookup.mockClear();
    await expect(
      findParticipatedRequestIds(
        String(participantId),
        "already-participated@nyu.edu",
        [candidate],
        undefined,
        () => {
          cancellationChecks += 1;
          return cancellationChecks === 2;
        }
      )
    ).rejects.toBeInstanceOf(ParticipantParticipationReadCancelled);
    expect(participationLookup).not.toHaveBeenCalled();
  });
});

describe("filterRequestListForParticipant", () => {
  it("returns docs unfiltered, without querying, when no participant is resolved", async () => {
    const query = vi.spyOn(RequestParticipation, "find");
    const docs = [{ _id: new mongoose.Types.ObjectId() }];

    const result = await filterRequestListForParticipant(docs, null);

    expect(result).toBe(docs);
    expect(query).not.toHaveBeenCalled();
  });

  it("returns docs unfiltered, without querying, when the candidate list is empty", async () => {
    const query = vi.spyOn(RequestParticipation, "find");

    const result = await filterRequestListForParticipant([], {
      participantId: String(participantId),
      principal: "already-participated@nyu.edu",
      authorityVersion: 1,
    });

    expect(result).toEqual([]);
    expect(query).not.toHaveBeenCalled();
  });

  it("removes only the requests this exact participant has previously held", async () => {
    const participatedId = new mongoose.Types.ObjectId();
    const untouchedId = new mongoose.Types.ObjectId();
    mockParticipationRows([{ requestId: participatedId }]);
    const docs = [{ _id: participatedId }, { _id: untouchedId }];

    const result = await filterRequestListForParticipant(docs, {
      participantId: String(participantId),
      principal: "already-participated@nyu.edu",
      authorityVersion: 1,
    });

    expect(result).toEqual([{ _id: untouchedId }]);
  });

  it("returns the original array reference when this participant has never participated in any candidate", async () => {
    mockParticipationRows([]);
    const docs = [{ _id: new mongoose.Types.ObjectId() }];

    const result = await filterRequestListForParticipant(docs, {
      participantId: String(participantId),
      principal: "already-participated@nyu.edu",
      authorityVersion: 1,
    });

    expect(result).toBe(docs);
  });
});
