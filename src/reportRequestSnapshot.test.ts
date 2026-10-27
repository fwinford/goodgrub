import mongoose from "mongoose";
import { describe, expect, it } from "vitest";
import { ReportEvidence } from "../models/moderation.js";
import { buildReportRequestSnapshot } from "./reportRequestSnapshot.js";

const requestId = new mongoose.Types.ObjectId();

const fullRequest = {
  _id: requestId,
  status: "placed" as const,
  vendor: "Third North",
  food: "2 swipes: turkey wrap",
  pickupWindowText: "ASAP",
  menuPath: "meal-exchange",
  mealSwipes: 2,
  mealItems: [{ name: "Turkey wrap", details: "no onions" }, { name: "Fries" }, { name: "" }],
  orderDetails: "extra napkins",
  estimatedDiningDollarsCents: 450,
  // Everything below must never reach a snapshot.
  email: "requester@nyu.edu",
  fulfillerEmail: "helper@nyu.edu",
  requesterParticipantId: new mongoose.Types.ObjectId(),
  helperParticipantId: new mongoose.Types.ObjectId(),
  orderNumber: "GH-123456",
  eta: new Date(),
  etaText: "5 minutes",
  claimTokenDigest: "digest",
  installationId: new mongoose.Types.ObjectId(),
  externalOrderAffirmed: true,
  contactMessage: "hi, it's me",
};

describe("report request snapshot allowlist (Decision 7)", () => {
  it("keeps request content and interaction context only", () => {
    const snapshot = buildReportRequestSnapshot(fullRequest, "helper");
    expect(snapshot).toEqual({
      requestId,
      reportedRole: "helper",
      requestStatus: "placed",
      vendor: "Third North",
      food: "2 swipes: turkey wrap",
      pickupWindowText: "ASAP",
      menuPath: "meal-exchange",
      mealSwipes: 2,
      mealItems: [{ name: "Turkey wrap", details: "no onions" }, { name: "Fries" }],
      orderDetails: "extra napkins",
      estimatedDiningDollarsCents: 450,
    });
  });

  it("drops every identifying, credential, order and Message field", () => {
    const serialized = JSON.stringify(buildReportRequestSnapshot(fullRequest, "requester"));
    for (const forbidden of [
      "requester@nyu.edu",
      "helper@nyu.edu",
      "GH-123456",
      "digest",
      "5 minutes",
      "hi, it's me",
      "externalOrderAffirmed",
      "ParticipantId",
    ]) {
      expect(serialized).not.toContain(forbidden);
    }
  });

  it("persists only allowlisted fields even if a caller smuggles extras", async () => {
    const evidence = new ReportEvidence({
      reportId: new mongoose.Types.ObjectId(),
      kind: "request-snapshot",
      snapshot: { ...buildReportRequestSnapshot(fullRequest, "helper"), email: "leak@nyu.edu" },
    });
    await evidence.validate();
    expect(JSON.stringify(evidence.toObject())).not.toContain("leak@nyu.edu");
  });

  it("omits unset optional content instead of inventing it", () => {
    const snapshot = buildReportRequestSnapshot(
      { _id: requestId, status: "open", food: "soup" },
      "requester"
    );
    expect(snapshot).toEqual({
      requestId,
      reportedRole: "requester",
      requestStatus: "open",
      food: "soup",
    });
  });
});
