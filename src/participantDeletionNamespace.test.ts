import { describe, expect, it } from "vitest";
import {
  deletionNamespaceBinding,
  isDeletionNamespaceBinding,
} from "./participantDeletionNamespace.js";

describe("deletion namespace projection", () => {
  const first = "15ee8095-c7fd-4793-9b46-0918b88ed766";
  const second = "97d1d21e-a564-4720-8844-255c15d9b46c";

  it("is stable, versioned, opaque and distinct across ledger replacements", () => {
    const binding = deletionNamespaceBinding(first);
    expect(binding).toMatch(/^dn1_[0-9a-f]{64}$/);
    expect(binding).toBe(deletionNamespaceBinding(first));
    expect(binding).not.toContain(first);
    expect(binding).not.toBe(deletionNamespaceBinding(second));
    expect(isDeletionNamespaceBinding(binding)).toBe(true);
  });

  it.each([undefined, null, "", "dn1_bad", "dn1_" + "A".repeat(64), ["dn1_" + "a".repeat(64)]])(
    "rejects a noncanonical public binding (%j)",
    (value) => expect(isDeletionNamespaceBinding(value)).toBe(false)
  );

  it.each(["", "ledger", first.toUpperCase()])("rejects invalid internal authority (%s)", (value) => {
    expect(() => deletionNamespaceBinding(value)).toThrow("namespace is unavailable");
  });
});
