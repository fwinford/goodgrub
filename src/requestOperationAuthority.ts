import { randomUUID } from "node:crypto";
import type { Request, Response } from "express";
import {
  RequestOperation,
  RequestOperationAuthority,
} from "../models/db.js";
import { sendDay4Error } from "./day4Errors.js";

/**
 * W4-D2 request-operation ledger authority.
 *
 * Two startup obligations and one per-request check, all about the same
 * question: is the database this process talks to the operation authority a
 * client's pending create was sent to?
 *
 * - The unique operation-identity index is what makes created vs NO-CREATE
 *   one-winner. It must exist before any request-create or terminalization
 *   traffic is accepted, so startup creates it explicitly and then confirms
 *   its exact definition rather than trusting Mongoose's asynchronous
 *   auto-indexing (which a deployment may disable, and which never blocks
 *   `listen`).
 * - The ledger authority identity is a random, non-secret identifier stored
 *   beside the ledger. A client records it with a pending create; a URL alone
 *   cannot say whether the ledger behind it was reset or replaced.
 * - A request that names an authority (`x-commonplate-operation-authority`)
 *   is served only by the database holding exactly that identifier.
 *
 * The identifier is read from the database on every check rather than cached
 * in memory, so a database emptied under a running process stops matching
 * immediately instead of answering for a ledger that no longer exists.
 */
export const OPERATION_AUTHORITY_HEADER = "x-commonplate-operation-authority";

export const REQUEST_OPERATION_AUTHORITY_ROUTE_PATH =
  "/api/request-operation/authority";

/** The named authority is not this database's ledger. Nothing was read or written. */
export const OPERATION_AUTHORITY_MISMATCH_CODE = "OPERATION_AUTHORITY_MISMATCH";
export const OPERATION_AUTHORITY_MISMATCH_MESSAGE =
  "This request was sent to a different CommonPlate service.";

/** This database's ledger identity could not be read. Nothing was read or written. */
export const OPERATION_AUTHORITY_UNAVAILABLE_CODE =
  "OPERATION_AUTHORITY_UNAVAILABLE";
export const OPERATION_AUTHORITY_UNAVAILABLE_MESSAGE =
  "We couldn't check this request right now. Please try again in a moment.";

export const REQUEST_OPERATION_IDENTITY_INDEX_NAME =
  "request_operation_ledger_identity_unique";

const LEDGER_AUTHORITY_ROW_ID = "request-operation-ledger";

const AUTHORITY_ID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

export function isValidOperationAuthorityId(value: unknown): value is string {
  return typeof value === "string" && AUTHORITY_ID_PATTERN.test(value);
}

function isDuplicateKeyError(error: unknown): boolean {
  return (
    typeof error === "object" &&
    error !== null &&
    "code" in error &&
    (error as { code?: unknown }).code === 11000
  );
}

/**
 * Throws unless the ledger's operation-identity index exists exactly as
 * `models/db.ts` defines it: unique, on `{ operationId: 1 }` alone, and
 * neither sparse nor partial — any of those would let two rows share an
 * identity.
 */
async function assertOperationIdentityIndex(): Promise<void> {
  const indexes = await RequestOperation.collection.indexes();
  const identity = indexes.find(
    (index) => index.name === REQUEST_OPERATION_IDENTITY_INDEX_NAME
  );
  const keys = identity ? Object.entries(identity.key) : [];
  if (
    !identity ||
    identity.unique !== true ||
    identity.sparse === true ||
    identity.partialFilterExpression !== undefined ||
    keys.length !== 1 ||
    keys[0][0] !== "operationId" ||
    keys[0][1] !== 1
  ) {
    throw new Error(
      "The request operation identity index is missing or not unique"
    );
  }
}

/** This database's ledger identity, or `null` when none is established. */
export async function readRequestOperationAuthority(): Promise<string | null> {
  const row = await RequestOperationAuthority.findById(
    LEDGER_AUTHORITY_ROW_ID
  ).lean();
  return row && isValidOperationAuthorityId(row.authorityId)
    ? row.authorityId
    : null;
}

/**
 * The startup barrier. Resolves only once the unique operation-identity index
 * is confirmed and this database carries a ledger identity; otherwise it
 * rejects, and startup stops before listening. Minting is insert-only
 * (`$setOnInsert` on a fixed `_id`), so concurrent first starts converge on
 * one identifier and an existing one is never replaced.
 */
export async function establishRequestOperationLedger(): Promise<string> {
  await RequestOperation.createIndexes();
  await assertOperationIdentityIndex();

  try {
    await RequestOperationAuthority.updateOne(
      { _id: LEDGER_AUTHORITY_ROW_ID },
      { $setOnInsert: { authorityId: randomUUID(), createdAt: new Date() } },
      { upsert: true }
    );
  } catch (error) {
    // A concurrent first start inserted the row; read theirs.
    if (!isDuplicateKeyError(error)) throw error;
  }

  const authorityId = await readRequestOperationAuthority();
  if (authorityId === null) {
    throw new Error("The request operation ledger authority is not readable");
  }
  return authorityId;
}

export type OperationAuthorityCheck =
  | "absent"
  | "matched"
  | "mismatched"
  | "unavailable";

/**
 * Compares the authority a request names with this database's ledger
 * identity. A malformed or repeated header can name no ledger, so it is a
 * mismatch. Reads only the authority row — never the ledger.
 */
export async function checkOperationAuthority(
  req: Request
): Promise<OperationAuthorityCheck> {
  const header = req.headers?.[OPERATION_AUTHORITY_HEADER];
  if (header === undefined) return "absent";
  if (!isValidOperationAuthorityId(header)) return "mismatched";

  let current: string | null;
  try {
    current = await readRequestOperationAuthority();
  } catch {
    console.error("[route] Failed to read request operation authority");
    return "unavailable";
  }
  if (current === null) return "unavailable";
  return current === header ? "matched" : "mismatched";
}

/** The refusal for every check result except `"matched"` and `"absent"`. */
export function sendOperationAuthorityRefusal(
  res: Response,
  check: "mismatched" | "unavailable"
): Response {
  return check === "mismatched"
    ? sendDay4Error(
        res,
        409,
        OPERATION_AUTHORITY_MISMATCH_CODE,
        OPERATION_AUTHORITY_MISMATCH_MESSAGE
      )
    : sendDay4Error(
        res,
        503,
        OPERATION_AUTHORITY_UNAVAILABLE_CODE,
        OPERATION_AUTHORITY_UNAVAILABLE_MESSAGE
      );
}

/**
 * `GET /api/request-operation/authority`: this deployment's ledger identity,
 * which a client records before sending a create. Not participant-specific
 * and not secret, but never cached, so a replaced ledger is seen at once.
 * Not paused: it is not a public action and changes nothing.
 */
export async function sendRequestOperationAuthority(
  _req: Request,
  res: Response
): Promise<Response> {
  res.setHeader("Cache-Control", "no-store");
  let authorityId: string | null;
  try {
    authorityId = await readRequestOperationAuthority();
  } catch {
    console.error("[route] Failed to read request operation authority");
    authorityId = null;
  }
  if (authorityId === null) {
    return sendOperationAuthorityRefusal(res, "unavailable");
  }
  return res.status(200).json({ operationAuthority: authorityId });
}
