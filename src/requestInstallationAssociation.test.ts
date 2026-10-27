import mongoose from "mongoose";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { Installation } from "../models/db.js";
import { digestInstallationCredential } from "./installationCredential.js";
import { resolveRequestInstallationAssociation } from "./requestInstallationAssociation.js";

const rawCredential = Buffer.alloc(32, 7).toString("base64url");
const installationId = new mongoose.Types.ObjectId("64d000000000000000000001");

let findOneAndUpdate: ReturnType<typeof vi.spyOn>;

beforeEach(() => {
  findOneAndUpdate = vi
    .spyOn(Installation, "findOneAndUpdate")
    .mockReturnValue({
      select: () => ({
        lean: () => ({
          exec: async () => ({ _id: installationId }),
        }),
      }),
    } as never) as ReturnType<typeof vi.spyOn>;
});

afterEach(() => {
  vi.restoreAllMocks();
});

describe("resolveRequestInstallationAssociation", () => {
  it("resolves to undefined and touches nothing when no credential is supplied", async () => {
    const result = await resolveRequestInstallationAssociation(undefined);

    expect(result).toBeUndefined();
    expect(findOneAndUpdate).not.toHaveBeenCalled();
  });

  it("upserts by the credential's digest, never the raw credential", async () => {
    await resolveRequestInstallationAssociation(rawCredential);

    expect(findOneAndUpdate).toHaveBeenCalledWith(
      { installationCredentialDigest: digestInstallationCredential(rawCredential) },
      { $setOnInsert: { pushEnabled: false } },
      { upsert: true, new: true }
    );
    const serializedCall = JSON.stringify(findOneAndUpdate.mock.calls[0]);
    expect(serializedCall).not.toContain(rawCredential);
  });

  it("creates a disabled installation on first association, never enabling push", async () => {
    await resolveRequestInstallationAssociation(rawCredential);

    const update = findOneAndUpdate.mock.calls[0][1] as Record<string, unknown>;
    expect(update).toEqual({ $setOnInsert: { pushEnabled: false } });
  });

  it("never sets pushEnabled on an installation that already exists", async () => {
    // `$setOnInsert` only applies on insert; an existing document's
    // `pushEnabled` (on or off) is left exactly as found.
    await resolveRequestInstallationAssociation(rawCredential);

    const update = findOneAndUpdate.mock.calls[0][1] as Record<string, unknown>;
    expect(Object.keys(update)).toEqual(["$setOnInsert"]);
    expect(update).not.toHaveProperty("$set");
  });

  it("returns the resolved installation's id", async () => {
    const result = await resolveRequestInstallationAssociation(rawCredential);

    expect(result).toEqual(installationId);
  });

  it("returns undefined when the upsert itself somehow yields no document", async () => {
    findOneAndUpdate.mockReturnValue({
      select: () => ({
        lean: () => ({
          exec: async () => null,
        }),
      }),
    } as never);

    const result = await resolveRequestInstallationAssociation(rawCredential);

    expect(result).toBeUndefined();
  });

  it("propagates a database failure rather than swallowing it silently", async () => {
    findOneAndUpdate.mockReturnValue({
      select: () => ({
        lean: () => ({
          exec: async () => {
            throw new Error("database unavailable");
          },
        }),
      }),
    } as never);

    await expect(
      resolveRequestInstallationAssociation(rawCredential)
    ).rejects.toThrow("database unavailable");
  });
});
