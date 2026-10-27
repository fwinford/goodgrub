import type { Express, NextFunction, Request, Response } from "express";
import { createDay4MutationRateLimiter } from "./claimRoute.js";
import {
  INVALID_OPERATION_ID_CODE,
  INVALID_OPERATION_ID_MESSAGE,
  isValidOperationId,
  OPERATION_EXPIRED_CODE,
  REQUEST_CREATED_UNAVAILABLE_CODE,
  REQUEST_CREATED_UNAVAILABLE_MESSAGE,
  OPERATION_EXPIRED_MESSAGE,
  OPERATION_UNAUTHORIZED_CODE,
  OPERATION_UNAUTHORIZED_MESSAGE,
  readOperationIdentity,
  terminalizeOperation,
} from "./createRequestRoute.js";
import { sendDay4Error } from "./day4Errors.js";
import {
  PARTICIPANT_AUTHORITY_HEADER,
  resolveParticipantAuthority,
  sendParticipantAuthorityRefusal,
  PARTICIPANT_VERIFICATION_UNAVAILABLE_CODE,
  PARTICIPANT_VERIFICATION_UNAVAILABLE_MESSAGE,
} from "./participantAuthorityGate.js";
import { ParticipantAccountFenceUnavailable } from "./participantAccountFence.js";
import {
  CREATE_UNAVAILABLE_MESSAGE,
} from "./publicActionsPause.js";
import { pauseRequestAction } from "./reviewRuntime.js";
import {
  checkOperationAuthority,
  REQUEST_OPERATION_AUTHORITY_ROUTE_PATH,
  sendOperationAuthorityRefusal,
  sendRequestOperationAuthority,
} from "./requestOperationAuthority.js";
import { buildPublicRequestDetailResponse } from "./requestListResponse.js";

/**
 * `POST /api/request-operation/terminal` (W4-D2).
 *
 * Exact-operation terminal reconciliation for one already-issued W3-D1
 * request-create operation, named only by the same
 * `x-commonplate-operation-id` header `POST /api/request` reads, and only
 * against the ledger authority named by `x-commonplate-operation-authority`
 * (`requestOperationAuthority.ts`): a missing, malformed, or different
 * authority is refused before the ledger is touched, because no answer from
 * another ledger — not even NO-CREATE written into it — says anything about
 * the operation. Takes no body and never reads request content: it exists for
 * recovery that cannot, or must not, resend the original payload.
 *
 * For the verified participant, it answers exactly one terminal outcome:
 *
 * - `200 { outcome: "created", request }` — this identity created that
 *   Request, the same projection replay returns;
 * - `200 { outcome: "not-created" }` — terminal NO-CREATE, established now
 *   or earlier; this identity never created and never will;
 * - `410 OPERATION_EXPIRED` — it created a Request that is gone;
 * - `403 OPERATION_UNAUTHORIZED` — the identity belongs to someone else,
 *   refused with the same generic answer replay gives.
 *
 * Anything else (participant or ledger-authority refusal, malformed
 * identity, pause, rate limit, database failure) is not a terminal answer
 * about the operation. The only
 * write this route can perform is the NO-CREATE ledger row: no quota is
 * counted or consumed, no email or push is sent, and no Request is created.
 */
export const REQUEST_OPERATION_TERMINAL_ROUTE_PATH =
  "/api/request-operation/terminal";

export const REQUEST_OPERATION_CREATED_OUTCOME = "created";
export const REQUEST_OPERATION_NOT_CREATED_OUTCOME = "not-created";

export const REQUEST_OPERATION_RECONCILIATION_FAILED_CODE =
  "OPERATION_RECONCILIATION_FAILED";
export const REQUEST_OPERATION_RECONCILIATION_FAILED_MESSAGE =
  "We couldn't check this request right now. Please try again in a moment.";

// Its own bucket, so recovery never spends `POST /api/request`'s create
// allowance and an ordinary create never spends recovery's.
export const requestOperationTerminalRateLimiter =
  createDay4MutationRateLimiter(10);

/**
 * The answer is specific to whichever participant the presented credential
 * resolves to, so it must never be cached or reused for another credential.
 * Mounted ahead of everything that can end the request — the pause guard and
 * the limiter write their own bodies without these headers — following the
 * W4-Q1 `requestEligibilityCacheIsolation` precedent. The handler sets them
 * again so a direct call is isolated too.
 */
export function requestOperationTerminalCacheIsolation(
  _req: Request,
  res: Response,
  next: NextFunction
): void {
  setCacheIsolation(res);
  next();
}

function setCacheIsolation(res: Response): void {
  res.setHeader("Cache-Control", "private, no-store");
  res.setHeader("Vary", PARTICIPANT_AUTHORITY_HEADER);
}

/**
 * The single source of the mounted order: cache isolation, then the pause
 * (a paused deployment performs no terminalization write), then the limiter,
 * then the handler. Generic so the mounted test can substitute a cheap
 * limiter and still prove the production order.
 */
export function buildRequestOperationTerminalMiddlewareChain<
  Limiter extends (...args: any[]) => any,
  Handler extends (...args: any[]) => any
>(limiter: Limiter, handler: Handler) {
  return [
    requestOperationTerminalCacheIsolation,
    pauseRequestAction(CREATE_UNAVAILABLE_MESSAGE, "PUBLIC_ACTIONS_PAUSED"),
    limiter,
    handler,
  ] as const;
}

export async function resolveRequestOperationTerminal(
  req: Request,
  res: Response
): Promise<Response> {
  setCacheIsolation(res);
  const now = new Date();

  // Participant authority first, exactly as `POST /api/request`: an
  // unverified caller reaches no ledger read or write.
  const authority = await resolveParticipantAuthority(req);
  if (!authority.ok) {
    return sendParticipantAuthorityRefusal(res, authority.refusal);
  }
  const { participantId, authorityVersion } = authority.participant;

  const operationId = readOperationIdentity(req);
  if (typeof operationId !== "string" || !isValidOperationId(operationId)) {
    return sendDay4Error(
      res,
      400,
      INVALID_OPERATION_ID_CODE,
      INVALID_OPERATION_ID_MESSAGE
    );
  }

  // Required here, unlike on `POST /api/request`: terminalization writes, and
  // it may only ever write into the ledger the create was sent to.
  const authorityCheck = await checkOperationAuthority(req);
  if (authorityCheck !== "matched") {
    return sendOperationAuthorityRefusal(
      res,
      authorityCheck === "unavailable" ? "unavailable" : "mismatched"
    );
  }

  let outcome: Awaited<ReturnType<typeof terminalizeOperation>>;
  try {
    outcome = await terminalizeOperation(
      operationId,
      participantId,
      authorityVersion
    );
  } catch (error) {
    if (error instanceof ParticipantAccountFenceUnavailable) {
      return sendDay4Error(
        res,
        503,
        PARTICIPANT_VERIFICATION_UNAVAILABLE_CODE,
        PARTICIPANT_VERIFICATION_UNAVAILABLE_MESSAGE
      );
    }
    console.error("[route] Request operation terminal reconciliation failed");
    return sendDay4Error(
      res,
      500,
      REQUEST_OPERATION_RECONCILIATION_FAILED_CODE,
      REQUEST_OPERATION_RECONCILIATION_FAILED_MESSAGE
    );
  }

  switch (outcome.outcome) {
    case "created":
      return res.status(200).json({
        outcome: REQUEST_OPERATION_CREATED_OUTCOME,
        ...buildPublicRequestDetailResponse(outcome.document, now),
      });
    case "not-created":
      return res
        .status(200)
        .json({ outcome: REQUEST_OPERATION_NOT_CREATED_OUTCOME });
    case "expired":
      return sendDay4Error(
        res,
        410,
        OPERATION_EXPIRED_CODE,
        OPERATION_EXPIRED_MESSAGE
      );
    case "created-unavailable":
      return sendDay4Error(
        res,
        410,
        REQUEST_CREATED_UNAVAILABLE_CODE,
        REQUEST_CREATED_UNAVAILABLE_MESSAGE
      );
    case "unauthorized":
      return sendDay4Error(
        res,
        403,
        OPERATION_UNAUTHORIZED_CODE,
        OPERATION_UNAUTHORIZED_MESSAGE
      );
  }
}

/**
 * Registers both W4-D2 recovery routes. `app.ts` calls this ahead of the
 * global body parsers: the terminal route takes no body, and a malformed or
 * oversized one must not let the generic parser and error handler answer
 * before cache isolation, pause, the limiter, and participant authority.
 */
export function registerRequestOperationTerminalRoute(app: Express): void {
  app.get(REQUEST_OPERATION_AUTHORITY_ROUTE_PATH, sendRequestOperationAuthority);
  app.post(
    REQUEST_OPERATION_TERMINAL_ROUTE_PATH,
    ...buildRequestOperationTerminalMiddlewareChain(
      requestOperationTerminalRateLimiter,
      resolveRequestOperationTerminal
    )
  );
}
