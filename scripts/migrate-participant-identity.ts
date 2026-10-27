import "dotenv/config";
import mongoose from "mongoose";
import {
  Participant,
  ParticipantBlock,
  ParticipantDeletionOperation,
  ParticipantIdentityKeyVersion,
  RequestOperation,
  RequestParticipation,
  RequestUpdateOperation,
} from "../models/db.js";
import { normalizeParticipantPrincipal } from "../src/participantIdentity.js";
import {
  deriveParticipantIdentityAlias,
  loadParticipantIdentityManifest,
  PARTICIPANT_IDENTITY_NORMALIZATION_VERSION,
} from "../src/participantIdentityKeys.js";

const mongoUri = process.env.MONGO_URI;
if (!mongoUri) throw new Error("MONGO_URI is required");
if (process.env.P2_IDENTITY_MIGRATION_DRAIN_CONFIRMED !== "true") {
  throw new Error("P2 identity migration requires all affected writers to be drained");
}

type StoredIdentityRow = {
  _id: mongoose.Types.ObjectId;
  participantId?: mongoose.Types.ObjectId;
  requestId?: mongoose.Types.ObjectId;
  participationKeyVersion?: number;
  participationHmac?: string;
  blockerParticipantId?: mongoose.Types.ObjectId;
  blockedParticipantId?: mongoose.Types.ObjectId;
  blockedSafetyKeyVersion?: number;
  blockedSafetyHmac?: string;
};

function validHexDigest(value: unknown): value is string {
  return typeof value === "string" && /^[0-9a-f]{64}$/.test(value);
}

async function registeredVersions(
  purpose: "participation" | "block-safety"
): Promise<Set<number>> {
  const rows = await ParticipantIdentityKeyVersion.find({ purpose })
    .select("version normalizationVersion")
    .lean<Array<{ version: number; normalizationVersion: number }>>()
    .exec();
  if (rows.length === 0) {
    throw new Error("P2 identity key-version manifest is empty");
  }
  for (const row of rows) {
    if (
      row.normalizationVersion !==
      PARTICIPANT_IDENTITY_NORMALIZATION_VERSION
    ) {
      throw new Error("P2 identity normalization version is unsupported");
    }
  }
  return new Set(rows.map((row) => row.version));
}

async function backfillParticipation(): Promise<void> {
  const manifest = await loadParticipantIdentityManifest("participation");
  const versions = await registeredVersions("participation");
  const currentKey = manifest.ring.keys.get(manifest.ring.currentVersion);
  if (!currentKey || !versions.has(manifest.ring.currentVersion)) {
    throw new Error("P2 participation current key is not registered");
  }
  const cursor = RequestParticipation.collection.find(
    {},
    {
      projection: {
        _id: 1,
        requestId: 1,
        participantId: 1,
        participationKeyVersion: 1,
        participationHmac: 1,
      },
      batchSize: 200,
    }
  );
  try {
    for await (const row of cursor as AsyncIterable<StoredIdentityRow>) {
      if (!row.participantId || !row.requestId) {
        throw new Error("P2 participation migration found an orphaned row");
      }
      const participant = await Participant.findById(row.participantId)
        .select("email")
        .lean<{ email: string } | null>()
        .exec();
      const principal = participant
        ? normalizeParticipantPrincipal(participant.email)
        : null;
      if (!principal) {
        throw new Error("P2 participation migration cannot derive a live principal");
      }
      if (row.participationKeyVersion != null || row.participationHmac != null) {
        if (
          !Number.isSafeInteger(row.participationKeyVersion) ||
          !versions.has(row.participationKeyVersion!) ||
          !validHexDigest(row.participationHmac)
        ) {
          throw new Error("P2 participation migration found incomplete or unknown identity data");
        }
        const key = manifest.ring.keys.get(row.participationKeyVersion!);
        if (!key) throw new Error("P2 participation historical key is unavailable");
        const expected = deriveParticipantIdentityAlias(
          "participation",
          row.participationKeyVersion!,
          key,
          String(row.requestId),
          principal
        );
        if (expected.digest !== row.participationHmac) {
          throw new Error("P2 participation migration found an unverifiable identity");
        }
        continue;
      }
      const alias = deriveParticipantIdentityAlias(
        "participation",
        manifest.ring.currentVersion,
        currentKey,
        String(row.requestId),
        principal
      );
      const result = await RequestParticipation.updateOne(
        {
          _id: row._id,
          participantId: row.participantId,
          participationKeyVersion: { $exists: false },
          participationHmac: { $exists: false },
        },
        {
          $set: {
            participationKeyVersion: alias.version,
            participationHmac: alias.digest,
          },
        },
        { timestamps: false }
      ).exec();
      if (result.modifiedCount !== 1) {
        const current = await RequestParticipation.collection.findOne(
          { _id: row._id },
          {
            projection: {
              participationKeyVersion: 1,
              participationHmac: 1,
            },
          }
        );
        if (
          current?.participationKeyVersion !== alias.version ||
          current?.participationHmac !== alias.digest
        ) {
          throw new Error("P2 participation set-once backfill did not converge");
        }
      }
    }
  } finally {
    await cursor.close();
  }
}

async function backfillBlocks(): Promise<void> {
  const manifest = await loadParticipantIdentityManifest("block-safety");
  const versions = await registeredVersions("block-safety");
  const currentKey = manifest.ring.keys.get(manifest.ring.currentVersion);
  if (!currentKey || !versions.has(manifest.ring.currentVersion)) {
    throw new Error("P2 block-safety current key is not registered");
  }
  const cursor = ParticipantBlock.collection.find(
    {},
    {
      projection: {
        _id: 1,
        blockerParticipantId: 1,
        blockedParticipantId: 1,
        blockedSafetyKeyVersion: 1,
        blockedSafetyHmac: 1,
      },
      batchSize: 200,
    }
  );
  try {
    for await (const row of cursor as AsyncIterable<StoredIdentityRow>) {
      if (!row.blockerParticipantId) {
        throw new Error("P2 block migration found a row without its owner");
      }
      const blocker = await Participant.exists({ _id: row.blockerParticipantId });
      if (!blocker) {
        throw new Error("P2 block migration found an orphaned owner");
      }
      if (row.blockedSafetyKeyVersion != null || row.blockedSafetyHmac != null) {
        if (
          !Number.isSafeInteger(row.blockedSafetyKeyVersion) ||
          !versions.has(row.blockedSafetyKeyVersion!) ||
          !validHexDigest(row.blockedSafetyHmac)
        ) {
          throw new Error("P2 block migration found incomplete or unknown identity data");
        }
        if (row.blockedParticipantId) {
          const target = await Participant.findById(row.blockedParticipantId)
            .select("email")
            .lean<{ email: string } | null>()
            .exec();
          const principal = target
            ? normalizeParticipantPrincipal(target.email)
            : null;
          const key = manifest.ring.keys.get(row.blockedSafetyKeyVersion!);
          if (!principal || !key) {
            throw new Error("P2 block migration cannot verify a live target");
          }
          const expected = deriveParticipantIdentityAlias(
            "block-safety",
            row.blockedSafetyKeyVersion!,
            key,
            null,
            principal
          );
          if (expected.digest !== row.blockedSafetyHmac) {
            throw new Error("P2 block migration found an unverifiable identity");
          }
        }
        continue;
      }
      if (!row.blockedParticipantId) {
        throw new Error("P2 block migration found an unlinked row without retained identity");
      }
      const target = await Participant.findById(row.blockedParticipantId)
        .select("email")
        .lean<{ email: string } | null>()
        .exec();
      const principal = target
        ? normalizeParticipantPrincipal(target.email)
        : null;
      if (!principal) {
        throw new Error("P2 block migration cannot derive a live target principal");
      }
      const alias = deriveParticipantIdentityAlias(
        "block-safety",
        manifest.ring.currentVersion,
        currentKey,
        null,
        principal
      );
      const result = await ParticipantBlock.updateOne(
        {
          _id: row._id,
          blockedParticipantId: row.blockedParticipantId,
          blockedSafetyKeyVersion: { $exists: false },
          blockedSafetyHmac: { $exists: false },
        },
        {
          $set: {
            blockedSafetyKeyVersion: alias.version,
            blockedSafetyHmac: alias.digest,
          },
        },
        { timestamps: false }
      ).exec();
      if (result.modifiedCount !== 1) {
        const current = await ParticipantBlock.collection.findOne(
          { _id: row._id },
          {
            projection: {
              blockedSafetyKeyVersion: 1,
              blockedSafetyHmac: 1,
            },
          }
        );
        if (
          current?.blockedSafetyKeyVersion !== alias.version ||
          current?.blockedSafetyHmac !== alias.digest
        ) {
          throw new Error("P2 block set-once backfill did not converge");
        }
      }
    }
  } finally {
    await cursor.close();
  }
}

function indexOptions(
  keys: Record<string, 1>,
  name: string,
  unique = false,
  partialFilterExpression?: Record<string, unknown>
) {
  return {
    keys,
    options: {
      name,
      ...(unique ? { unique: true } : {}),
      ...(partialFilterExpression ? { partialFilterExpression } : {}),
    },
  };
}

function replacementIndexKeys(
  definition: ReturnType<typeof indexOptions>
): Record<string, 1> {
  const entries = Object.entries(definition.keys) as Array<[string, 1]>;
  if (entries.length > 1) {
    return Object.fromEntries(entries.reverse()) as Record<string, 1>;
  }
  if (definition.options.unique || entries[0]?.[0] === "_id") {
    throw new Error(
      `P2 identity index ${definition.options.name} cannot be staged safely`
    );
  }
  return { ...definition.keys, _id: 1 };
}

async function ensureIndex(
  collection: mongoose.mongo.Collection,
  definition: ReturnType<typeof indexOptions>
): Promise<void> {
  const indexes = await collection.listIndexes().toArray();
  const existing = indexes.find((index) => index.name === definition.options.name);
  if (
    existing &&
    JSON.stringify(existing.key) === JSON.stringify(definition.keys) &&
    Boolean(existing.unique) === Boolean(definition.options.unique) &&
    JSON.stringify(existing.partialFilterExpression ?? {}) ===
      JSON.stringify(definition.options.partialFilterExpression ?? {})
  ) {
    return;
  }
  if (existing) {
    throw new Error(`P2 identity index ${definition.options.name} has an unexpected definition`);
  }
  await collection.createIndex(definition.keys, definition.options);
}

async function replaceLegacyIndex(
  collection: mongoose.mongo.Collection,
  oldName: string,
  next: ReturnType<typeof indexOptions>
): Promise<void> {
  const indexes = await collection.listIndexes().toArray();
  const current = indexes.find((index) => index.name === next.options.name);
  const temporaryName = `${next.options.name}_migration`;
  const temporaryKeys = replacementIndexKeys(next);
  const matchesDefinition = (
    index: (typeof indexes)[number] | undefined,
    keys: Record<string, 1>,
    options: typeof next.options
  ): boolean =>
    Boolean(
      index &&
        JSON.stringify(index.key) === JSON.stringify(keys) &&
        Boolean(index.unique) === Boolean(options.unique) &&
        JSON.stringify(index.partialFilterExpression ?? {}) ===
          JSON.stringify(options.partialFilterExpression ?? {})
    );
  const temporary = indexes.find((index) => index.name === temporaryName);
  if (temporary && !matchesDefinition(temporary, temporaryKeys, next.options)) {
    throw new Error(`P2 identity replacement index ${temporaryName} has an unexpected definition`);
  }

  if (matchesDefinition(current, next.keys, next.options)) {
    if (oldName !== next.options.name && indexes.some((index) => index.name === oldName)) {
      await collection.dropIndex(oldName);
    }
    if (temporary) await collection.dropIndex(temporaryName);
    return;
  }
  if (current && oldName !== next.options.name) {
    throw new Error(`P2 identity index ${next.options.name} has an unexpected definition`);
  }
  const legacy = indexes.find((index) => index.name === oldName);
  if (
    (legacy &&
      (JSON.stringify(legacy.key) !== JSON.stringify(next.keys) ||
        Boolean(legacy.unique) !== Boolean(next.options.unique))) ||
    (!legacy && current && next.options.unique)
  ) {
    throw new Error(`P2 identity legacy index ${oldName} has an unexpected definition`);
  }
  if (!legacy && !current && !temporary) {
    await collection.createIndex(next.keys, next.options);
    return;
  }
  if (!temporary) {
    const temporaryOptions = { ...next.options, name: temporaryName };
    await collection.createIndex(temporaryKeys, temporaryOptions);
  }
  const staged = await collection.listIndexes().toArray();
  if (
    !matchesDefinition(
      staged.find((index) => index.name === temporaryName),
      temporaryKeys,
      next.options
    )
  ) {
    throw new Error("P2 identity replacement index was not established");
  }
  if (legacy && oldName !== next.options.name) {
    await collection.dropIndex(oldName);
  }
  if (legacy && oldName === next.options.name) {
    if (next.options.unique) {
      throw new Error("P2 identity cannot replace a same-name unique index safely");
    }
    await collection.dropIndex(oldName);
  }
  await collection.createIndex(next.keys, next.options);
  await collection.dropIndex(temporaryName);
}

function jsonSchema(validator: Record<string, unknown>) {
  return { $jsonSchema: validator };
}

const mongooseVersionKeyProperty = {
  __v: { bsonType: ["int", "long", "double"], minimum: 0, multipleOf: 1 },
};

async function installValidator(
  collection: mongoose.mongo.Collection,
  validator: Record<string, unknown>
): Promise<void> {
  const database = mongoose.connection.db;
  if (!database) throw new Error("P2 identity migration database is unavailable");
  const collectionInfo = await database
    .listCollections({ name: collection.collectionName })
    .next();
  const existing =
    collectionInfo && "options" in collectionInfo
      ? (collectionInfo.options?.validator as
          | Record<string, unknown>
          | undefined)
      : undefined;
  const combined = existing
    ? { $and: [existing, validator] }
    : validator;
  await database.command({
    collMod: collection.collectionName,
    validator: combined,
    validationLevel: "strict",
    validationAction: "error",
  });
}

async function installValidators(): Promise<void> {
  await installValidator(
    RequestParticipation.collection,
    jsonSchema({
      bsonType: "object",
      required: [
        "requestId",
        "participationKeyVersion",
        "participationHmac",
        "createdAt",
        "updatedAt",
      ],
      properties: {
        requestId: { bsonType: "objectId" },
        participantId: { bsonType: "objectId" },
        participationKeyVersion: {
          bsonType: ["int", "long", "double"],
          minimum: 1,
          multipleOf: 1,
        },
        participationHmac: { bsonType: "string", pattern: "^[0-9a-f]{64}$" },
        createdAt: { bsonType: "date" },
        updatedAt: { bsonType: "date" },
      },
    })
  );
  await installValidator(
    ParticipantBlock.collection,
    jsonSchema({
      bsonType: "object",
      required: [
        "blockerParticipantId",
        "blockedRole",
        "diningLocation",
        "interactionAt",
        "blockedSafetyKeyVersion",
        "blockedSafetyHmac",
        "createdAt",
        "updatedAt",
      ],
      properties: {
        blockerParticipantId: { bsonType: "objectId" },
        blockedParticipantId: { bsonType: "objectId" },
        blockedRole: { enum: ["requester", "helper"] },
        diningLocation: { bsonType: "string" },
        interactionAt: { bsonType: "date" },
        blockedSafetyKeyVersion: {
          bsonType: ["int", "long", "double"],
          minimum: 1,
          multipleOf: 1,
        },
        blockedSafetyHmac: { bsonType: "string", pattern: "^[0-9a-f]{64}$" },
        createdAt: { bsonType: "date" },
        updatedAt: { bsonType: "date" },
      },
    })
  );
  await installValidator(
    RequestOperation.collection,
    jsonSchema({
      oneOf: [
        {
          bsonType: "object",
          required: [
            "_id",
            "operationId",
            "ownerDeleted",
            "outcome",
            "createdAt",
            "updatedAt",
          ],
          properties: {
            ...mongooseVersionKeyProperty,
            _id: { bsonType: "objectId" },
            operationId: { bsonType: "string" },
            ownerDeleted: { enum: [true] },
            outcome: { enum: ["created", "no-create"] },
            createdAt: { bsonType: "date" },
            updatedAt: { bsonType: "date" },
          },
          additionalProperties: false,
        },
        {
          bsonType: "object",
          required: [
            "_id",
            "operationId",
            "participantId",
            "requestId",
            "outcome",
            "createdAt",
            "updatedAt",
          ],
          properties: {
            ...mongooseVersionKeyProperty,
            _id: { bsonType: "objectId" },
            operationId: { bsonType: "string" },
            participantId: { bsonType: "objectId" },
            requestId: { bsonType: "objectId" },
            outcome: { enum: ["created"] },
            createdAt: { bsonType: "date" },
            updatedAt: { bsonType: "date" },
          },
          additionalProperties: false,
        },
        {
          bsonType: "object",
          required: [
            "_id",
            "operationId",
            "participantId",
            "requestId",
            "createdAt",
            "updatedAt",
          ],
          properties: {
            ...mongooseVersionKeyProperty,
            _id: { bsonType: "objectId" },
            operationId: { bsonType: "string" },
            participantId: { bsonType: "objectId" },
            requestId: { bsonType: "objectId" },
            createdAt: { bsonType: "date" },
            updatedAt: { bsonType: "date" },
          },
          additionalProperties: false,
        },
        {
          bsonType: "object",
          required: [
            "_id",
            "operationId",
            "participantId",
            "outcome",
            "createdAt",
            "updatedAt",
          ],
          properties: {
            ...mongooseVersionKeyProperty,
            _id: { bsonType: "objectId" },
            operationId: { bsonType: "string" },
            participantId: { bsonType: "objectId" },
            outcome: { enum: ["no-create"] },
            createdAt: { bsonType: "date" },
            updatedAt: { bsonType: "date" },
          },
          additionalProperties: false,
        },
      ],
    })
  );
  await installValidator(
    RequestUpdateOperation.collection,
    jsonSchema({
      oneOf: [
        {
          bsonType: "object",
          required: [
            "_id",
            "operationId",
            "ownerDeleted",
            "createdAt",
            "updatedAt",
          ],
          properties: {
            ...mongooseVersionKeyProperty,
            _id: { bsonType: "objectId" },
            operationId: { bsonType: "string" },
            ownerDeleted: { enum: [true] },
            createdAt: { bsonType: "date" },
            updatedAt: { bsonType: "date" },
          },
          additionalProperties: false,
        },
        {
          bsonType: "object",
          required: [
            "_id",
            "operationId",
            "participantId",
            "requestId",
            "kind",
            "resultingRevision",
            "payloadDigest",
            "createdAt",
            "updatedAt",
          ],
          properties: {
            ...mongooseVersionKeyProperty,
            _id: { bsonType: "objectId" },
            operationId: { bsonType: "string" },
            participantId: { bsonType: "objectId" },
            requestId: { bsonType: "objectId" },
            kind: { enum: ["edit"] },
            resultingRevision: {
              bsonType: ["int", "long", "double"],
              minimum: 1,
              multipleOf: 1,
            },
            payloadDigest: { bsonType: "string", pattern: "^[0-9a-f]{64}$" },
            createdAt: { bsonType: "date" },
            updatedAt: { bsonType: "date" },
          },
          additionalProperties: false,
        },
        {
          bsonType: "object",
          required: [
            "_id",
            "operationId",
            "participantId",
            "requestId",
            "kind",
            "resultingRevision",
            "createdAt",
            "updatedAt",
          ],
          properties: {
            ...mongooseVersionKeyProperty,
            _id: { bsonType: "objectId" },
            operationId: { bsonType: "string" },
            participantId: { bsonType: "objectId" },
            requestId: { bsonType: "objectId" },
            kind: { enum: ["withdraw"] },
            resultingRevision: {
              bsonType: ["int", "long", "double"],
              minimum: 1,
              multipleOf: 1,
            },
            createdAt: { bsonType: "date" },
            updatedAt: { bsonType: "date" },
          },
          additionalProperties: false,
        },
      ],
    })
  );
  const deletionFieldRules: Record<string, unknown> = {
    _id: { bsonType: "objectId" },
    operationId: { bsonType: "string" },
    participantId: { bsonType: "objectId" },
    emailBinding: { bsonType: "string", pattern: "^[0-9a-f]{64}$" },
    authorityVersion: {
      bsonType: ["int", "long", "double"],
      minimum: 1,
      multipleOf: 1,
    },
    phase: {
      enum: [
        "waiting",
        "ready",
        "challengeIssued",
        "authorized",
        "completed",
        "canceled",
      ],
    },
    readinessGeneration: {
      bsonType: ["int", "long", "double"],
      minimum: 0,
      multipleOf: 1,
    },
    challengeGeneration: {
      bsonType: ["int", "long", "double"],
      minimum: 0,
      multipleOf: 1,
    },
    readyAt: { bsonType: "date" },
    challengeDigest: { bsonType: "string", pattern: "^[0-9a-f]{64}$" },
    challengeIssuedAt: { bsonType: "date" },
    challengeCooldownEndsAt: { bsonType: "date" },
    challengeExpiresAt: { bsonType: "date" },
    challengeAttemptsRemaining: {
      bsonType: ["int", "long", "double"],
      minimum: 1,
      multipleOf: 1,
    },
    authorizedAt: { bsonType: "date" },
    authorizationExpiresAt: { bsonType: "date" },
    canceledAt: { bsonType: "date" },
    completedAt: { bsonType: "date" },
    recoveryExpiresAt: { bsonType: "date" },
    recoveryCapabilityDigest: {
      bsonType: "string",
      pattern: "^[0-9a-f]{64}$",
    },
    createdAt: { bsonType: "date" },
    updatedAt: { bsonType: "date" },
  };
  const deletionRowShape = (
    allowedFields: string[],
    requiredFields: string[],
    phase?: string
  ) => ({
    bsonType: "object",
    required: requiredFields,
    properties: Object.fromEntries(
      allowedFields.map((field) => [
        field,
        field === "phase" && phase
          ? { enum: [phase] }
          : deletionFieldRules[field],
      ])
    ),
    additionalProperties: false,
  });
  const liveRequired = [
    "operationId",
    "participantId",
    "emailBinding",
    "authorityVersion",
    "phase",
    "readinessGeneration",
    "challengeGeneration",
    "createdAt",
    "updatedAt",
  ];
  const liveBaseFields = [
    "_id",
    "operationId",
    "participantId",
    "emailBinding",
    "authorityVersion",
    "phase",
    "readinessGeneration",
    "challengeGeneration",
    "createdAt",
    "updatedAt",
  ];
  await installValidator(
    ParticipantDeletionOperation.collection,
    jsonSchema({
      oneOf: [
        deletionRowShape(
          [
            "_id",
            "operationId",
            "phase",
            "completedAt",
            "recoveryExpiresAt",
            "recoveryCapabilityDigest",
          ],
          [
            "_id",
            "operationId",
            "phase",
            "completedAt",
            "recoveryExpiresAt",
            "recoveryCapabilityDigest",
          ],
          "completed"
        ),
        deletionRowShape(
          [
            ...liveBaseFields,
            "readyAt",
            "challengeCooldownEndsAt",
          ],
          liveRequired,
          "waiting"
        ),
        deletionRowShape(
          [...liveBaseFields, "readyAt", "challengeCooldownEndsAt"],
          [...liveRequired, "readyAt"],
          "ready"
        ),
        deletionRowShape(
          [
            ...liveBaseFields,
            "readyAt",
            "challengeDigest",
            "challengeIssuedAt",
            "challengeCooldownEndsAt",
            "challengeExpiresAt",
            "challengeAttemptsRemaining",
          ],
          [
            ...liveRequired,
            "readyAt",
            "challengeDigest",
            "challengeIssuedAt",
            "challengeCooldownEndsAt",
            "challengeExpiresAt",
            "challengeAttemptsRemaining",
          ],
          "challengeIssued"
        ),
        deletionRowShape(
          [
            ...liveBaseFields,
            "readyAt",
            "challengeCooldownEndsAt",
            "authorizedAt",
            "authorizationExpiresAt",
            "recoveryCapabilityDigest",
          ],
          [
            ...liveRequired,
            "readyAt",
            "authorizedAt",
            "authorizationExpiresAt",
            "recoveryCapabilityDigest",
          ],
          "authorized"
        ),
        deletionRowShape(
          [...liveBaseFields, "readyAt", "canceledAt"],
          [...liveRequired, "canceledAt"],
          "canceled"
        ),
        deletionRowShape(
          ["_id", "operationId"],
          ["_id", "operationId"]
        ),
      ],
    })
  );
}

try {
  await mongoose.connect(mongoUri);
  await Promise.all([
    RequestParticipation.createCollection(),
    ParticipantBlock.createCollection(),
    ParticipantIdentityKeyVersion.createCollection(),
    RequestOperation.createCollection(),
    RequestUpdateOperation.createCollection(),
    ParticipantDeletionOperation.createCollection(),
  ]);
  await ParticipantIdentityKeyVersion.createIndexes();
  const participationManifest = await loadParticipantIdentityManifest("participation");
  const blockManifest = await loadParticipantIdentityManifest("block-safety");
  if (
    !participationManifest.entries.length ||
    !blockManifest.entries.length
  ) {
    throw new Error("P2 identity key-version manifest is incomplete");
  }

  await backfillParticipation();
  await backfillBlocks();

  const requestParticipationIndexes = RequestParticipation.collection;
  await ensureIndex(
    requestParticipationIndexes,
    indexOptions(
      { requestId: 1, participationKeyVersion: 1, participationHmac: 1 },
      "request_participation_hmac_unique",
      true,
      { participationHmac: { $type: "string" } }
    )
  );
  await replaceLegacyIndex(
    requestParticipationIndexes,
    "request_participation_identity_unique",
    indexOptions(
      { requestId: 1, participantId: 1 },
      "request_participation_identity_live_unique",
      true,
      { participantId: { $type: "objectId" } }
    )
  );

  const blockCollection = ParticipantBlock.collection;
  await ensureIndex(
    blockCollection,
    indexOptions(
      {
        blockerParticipantId: 1,
        blockedSafetyKeyVersion: 1,
        blockedSafetyHmac: 1,
      },
      "participant_block_owner_safety_unique",
      true,
      { blockedSafetyHmac: { $type: "string" } }
    )
  );
  await ensureIndex(
    blockCollection,
    indexOptions(
      { blockedSafetyKeyVersion: 1, blockedSafetyHmac: 1 },
      "participant_block_safety_lookup",
      false,
      { blockedSafetyHmac: { $type: "string" } }
    )
  );
  await replaceLegacyIndex(
    blockCollection,
    "participant_block_owner_target_unique",
    indexOptions(
      { blockerParticipantId: 1, blockedParticipantId: 1 },
      "participant_block_owner_target_live_unique",
      true,
      { blockedParticipantId: { $type: "objectId" } }
    )
  );
  await replaceLegacyIndex(
    blockCollection,
    "participant_block_blocked_lookup",
    indexOptions(
      { blockedParticipantId: 1 },
      "participant_block_blocked_lookup",
      false,
      { blockedParticipantId: { $type: "objectId" } }
    )
  );

  await installValidators();
} finally {
  await mongoose.disconnect();
}
