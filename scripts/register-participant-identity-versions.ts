import "dotenv/config";
import mongoose from "mongoose";
import {
  ParticipantIdentityKeyVersion,
} from "../models/db.js";
import {
  PARTICIPANT_IDENTITY_NORMALIZATION_VERSION,
  readParticipantIdentityKeyRing,
} from "../src/participantIdentityKeys.js";

const mongoUri = process.env.MONGO_URI;
if (!mongoUri) throw new Error("MONGO_URI is required");
if (process.env.P2_IDENTITY_VERSION_REGISTRATION_CONFIRMED !== "true") {
  throw new Error("P2 identity key-version registration was not confirmed");
}

try {
  await mongoose.connect(mongoUri);
  await ParticipantIdentityKeyVersion.createIndexes();
  for (const purpose of ["participation", "block-safety"] as const) {
    const ring = readParticipantIdentityKeyRing(purpose);
    for (const version of ring.keys.keys()) {
      const existing = await ParticipantIdentityKeyVersion.findOne({
        purpose,
        version,
      })
        .select("normalizationVersion")
        .lean<{ normalizationVersion: number } | null>()
        .exec();
      if (
        existing &&
        existing.normalizationVersion !==
          PARTICIPANT_IDENTITY_NORMALIZATION_VERSION
      ) {
        throw new Error("P2 identity key-version manifest conflicts with normalization");
      }
      await ParticipantIdentityKeyVersion.updateOne(
        { purpose, version },
        {
          $setOnInsert: {
            purpose,
            version,
            normalizationVersion:
              PARTICIPANT_IDENTITY_NORMALIZATION_VERSION,
          },
        },
        { upsert: true, runValidators: true }
      ).exec();
    }
  }
} finally {
  await mongoose.disconnect();
}
