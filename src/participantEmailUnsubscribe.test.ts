import { afterEach, describe, expect, it, vi } from "vitest";
import type { ClientSession } from "mongoose";
import { Subscriber } from "../models/db.js";
import { UNSUBSCRIBE_CLEARED_CONFIRMATION_FIELDS } from "./confirmSubscription.js";
import { unsubscribeSubscriberByPrincipal } from "./participantEmailUnsubscribe.js";

const PRINCIPAL = "helper@nyu.edu";
const backendNow = new Date("2026-08-10T18:30:00.000Z");
const session = {} as ClientSession;

function queryResult(value: unknown) {
  return { exec: vi.fn().mockResolvedValue(value) } as never;
}

function mockUpdate(matchedCount = 1) {
  return vi
    .spyOn(Subscriber, "updateOne")
    .mockReturnValue(queryResult({ acknowledged: true, matchedCount }));
}

function updateArguments(update: ReturnType<typeof mockUpdate>) {
  const call = update.mock.calls[0] as unknown[];
  const stages = call[1] as Array<Record<string, unknown>>;
  return {
    filter: call[0] as Record<string, unknown>,
    stages,
    set: (stages.find((stage) => "$set" in stage)?.$set ?? {}) as Record<
      string,
      unknown
    >,
    unset: stages.find((stage) => "$unset" in stage)?.$unset as string[],
  };
}

afterEach(() => {
  vi.restoreAllMocks();
});

describe("unsubscribeSubscriberByPrincipal", () => {
  it("always reports the declarative unsubscribed outcome", async () => {
    mockUpdate(1);
    expect(
      await unsubscribeSubscriberByPrincipal(PRINCIPAL, backendNow, session)
    ).toEqual({ outcome: "unsubscribed" });
  });

  it("reports the same outcome when no Subscriber matched the principal", async () => {
    // Absent Subscriber: the conditional update matches nothing, and the
    // declarative result is already true, so the caller learns nothing about
    // whether a row existed.
    mockUpdate(0);
    expect(
      await unsubscribeSubscriberByPrincipal(PRINCIPAL, backendNow, session)
    ).toEqual({ outcome: "unsubscribed" });
  });

  it("is one atomic update filtered only by the exact principal", async () => {
    const update = mockUpdate();

    await unsubscribeSubscriberByPrincipal(PRINCIPAL, backendNow, session);

    expect(update).toHaveBeenCalledOnce();
    expect(updateArguments(update).filter).toEqual({ email: PRINCIPAL });
    expect((update.mock.calls[0] as unknown[])[2]).toEqual({ session });
  });

  it("sets unsubscribed status and preserves an existing unsubscribe timestamp", async () => {
    const update = mockUpdate();

    await unsubscribeSubscriberByPrincipal(PRINCIPAL, backendNow, session);

    const { set } = updateArguments(update);
    expect(set.status).toBe("unsubscribed");
    expect(set.unsubscribedAt).toEqual({
      $ifNull: ["$unsubscribedAt", backendNow],
    });
  });

  it("clears active confirmation credentials, matching the emailed-link redemption shape", async () => {
    const update = mockUpdate();

    await unsubscribeSubscriberByPrincipal(PRINCIPAL, backendNow, session);

    const { unset } = updateArguments(update);
    expect(unset).toEqual([...UNSUBSCRIBE_CLEARED_CONFIRMATION_FIELDS]);
  });

  it("never writes a Participant ID, a Subscriber ID, or the credential version", async () => {
    const update = mockUpdate();

    await unsubscribeSubscriberByPrincipal(PRINCIPAL, backendNow, session);

    const { stages } = updateArguments(update);
    const written = JSON.stringify(stages);
    expect(written).not.toContain("participant");
    expect(written).not.toContain("unsubscribeCredentialVersion");
    expect(written).not.toContain("_id");
  });

  it("never deletes or reads back the Subscriber", async () => {
    const update = mockUpdate();
    const deleteOne = vi.spyOn(Subscriber, "deleteOne");
    const findOne = vi.spyOn(Subscriber, "findOne");

    await unsubscribeSubscriberByPrincipal(PRINCIPAL, backendNow, session);

    expect(update).toHaveBeenCalledOnce();
    expect(deleteOne).not.toHaveBeenCalled();
    expect(findOne).not.toHaveBeenCalled();
  });
});
