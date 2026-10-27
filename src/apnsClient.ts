import http2 from "node:http2";
import { assertExternalProvidersAllowed } from "./externalProviders.js";

/**
 * HTTP/2 submission to APNs and the classification of what came back.
 *
 * The classification boundary is a safety boundary, not a convenience. Only
 * the two reasons Apple defines as "this token is dead" may retire an
 * installation's token; a topic or environment misconfiguration answers with a
 * different `400` and must retire nothing, or one misconfigured deployment
 * would disable every installation in a single dispatch.
 *
 * A `200` means APNs accepted the submission. It is not delivery, display,
 * opening, or reading, and nothing here may record or log it as any of those.
 */
export type ApnsClassification =
  /** APNs accepted the submission. Nothing more than that. */
  | "accepted"
  /** Apple says this exact token is dead: `410` Unregistered, `400` BadDeviceToken. */
  | "token-rejected"
  /** `401`/`403`: the provider token cannot succeed for any submission. */
  | "provider-auth"
  /** Another `400`-class refusal: topic, environment, or payload configuration. */
  | "configuration"
  /** `429`, `5xx`, connection failure, timeout. No retry in V1. */
  | "transient";

export interface ApnsOutcome {
  classification: ApnsClassification;
  /** HTTP status, when a response was actually read. */
  status?: number;
  /**
   * A bounded, sanitized classification token — either Apple's documented
   * `reason` word or a fixed network label. Never a raw provider or error
   * object: those can carry headers, tokens, URLs, and request bodies.
   */
  reason: string;
  /** Provider correlation id, when APNs returned one. */
  apnsId?: string;
}

/** Apple's reasons are short alphabetic words; anything else is not echoed. */
const REASON_PATTERN = /^[A-Za-z]{1,64}$/;
const APNS_ID_PATTERN = /^[A-Za-z0-9-]{1,64}$/;
const ERROR_CODE_PATTERN = /^[A-Z][A-Z0-9_]{1,31}$/;

const UNREGISTERED_REASON = "Unregistered";
const BAD_DEVICE_TOKEN_REASON = "BadDeviceToken";
const UNKNOWN_REASON = "Unknown";

/** Response bodies are tiny; a hostile one is not accumulated without bound. */
const MAXIMUM_BODY_BYTES = 2048;

function sanitizedReason(body: string): string {
  let parsed: unknown;
  try {
    parsed = JSON.parse(body);
  } catch {
    return UNKNOWN_REASON;
  }
  if (typeof parsed !== "object" || parsed === null) return UNKNOWN_REASON;
  const reason = (parsed as { reason?: unknown }).reason;
  return typeof reason === "string" && REASON_PATTERN.test(reason)
    ? reason
    : UNKNOWN_REASON;
}

export function sanitizedApnsId(value: unknown): string | undefined {
  return typeof value === "string" && APNS_ID_PATTERN.test(value)
    ? value
    : undefined;
}

export function classifyApnsResponse(
  status: number,
  body = "",
  apnsId?: string
): ApnsOutcome {
  const identity = sanitizedApnsId(apnsId);

  if (status === 200) {
    return { classification: "accepted", status, reason: "Accepted", apnsId: identity };
  }

  const reason = sanitizedReason(body);

  if (status === 410) {
    // `410` is only ever Unregistered, whatever the body says.
    return {
      classification: "token-rejected",
      status,
      reason: reason === UNKNOWN_REASON ? UNREGISTERED_REASON : reason,
      apnsId: identity,
    };
  }

  if (status === 400) {
    return {
      classification:
        reason === BAD_DEVICE_TOKEN_REASON ? "token-rejected" : "configuration",
      status,
      reason,
      apnsId: identity,
    };
  }

  if (status === 401 || status === 403) {
    return { classification: "provider-auth", status, reason, apnsId: identity };
  }

  if (status === 404 || status === 405 || status === 413) {
    return { classification: "configuration", status, reason, apnsId: identity };
  }

  // `429`, every `5xx`, and any status this contract does not enumerate. An
  // unrecognized refusal must never retire a token or abandon a dispatch.
  return { classification: "transient", status, reason, apnsId: identity };
}

/**
 * Network and stream failures. The caught value is inspected for a short
 * error code only; no message, stack, or provider object reaches the outcome.
 */
export function classifyApnsError(error: unknown): ApnsOutcome {
  const code = (error as { code?: unknown } | null)?.code;
  return {
    classification: "transient",
    reason:
      typeof code === "string" && ERROR_CODE_PATTERN.test(code)
        ? code
        : "NetworkError",
  };
}

export const APNS_TIMEOUT_OUTCOME: ApnsOutcome = {
  classification: "transient",
  reason: "Timeout",
};

export interface ApnsSubmission {
  /** Hex device token, used only to build `:path`. Never logged. */
  deviceToken: string;
  /** Request headers, including `authorization`. Never logged. */
  headers: Record<string, string>;
  /** Serialized JSON payload. */
  payload: string;
}

export interface ApnsConnection {
  submit(submission: ApnsSubmission, timeoutMs: number): Promise<ApnsOutcome>;
  close(): void;
}

export interface ApnsConnectionOptions {
  connect?: typeof http2.connect;
}

/**
 * One session per host per dispatch. Long-lived session reuse is a deferred
 * optimization under the accepted contract.
 *
 * `submit` never rejects: every failure becomes a classified outcome, so the
 * dispatcher's per-installation bookkeeping has exactly one shape to record.
 */
export function openApnsConnection(
  origin: string,
  options: ApnsConnectionOptions = {}
): ApnsConnection {
  assertExternalProvidersAllowed();
  const connect = options.connect ?? http2.connect;
  let sessionFailure: ApnsOutcome | null = null;
  let session: http2.ClientHttp2Session | null = null;

  try {
    session = connect(origin);
    // Attached immediately: an unhandled session `error` would otherwise be
    // thrown into the process rather than becoming this outcome.
    session.on("error", (error: unknown) => {
      sessionFailure = classifyApnsError(error);
    });
  } catch (error) {
    sessionFailure = classifyApnsError(error);
  }

  return {
    submit(submission: ApnsSubmission, timeoutMs: number): Promise<ApnsOutcome> {
      assertExternalProvidersAllowed();
      return new Promise<ApnsOutcome>((resolve) => {
        if (sessionFailure !== null || session === null) {
          resolve(sessionFailure ?? classifyApnsError(null));
          return;
        }

        let settled = false;
        const finish = (outcome: ApnsOutcome) => {
          if (settled) return;
          settled = true;
          resolve(outcome);
        };

        let stream: http2.ClientHttp2Stream;
        try {
          stream = session.request({
            ":method": "POST",
            ":path": `/3/device/${submission.deviceToken}`,
            ...submission.headers,
          });
        } catch (error) {
          finish(classifyApnsError(error));
          return;
        }

        let status = 0;
        let apnsId: string | undefined;
        let body = "";

        stream.setTimeout(timeoutMs, () => {
          stream.close(http2.constants.NGHTTP2_CANCEL);
          finish(APNS_TIMEOUT_OUTCOME);
        });
        stream.setEncoding("utf8");
        stream.on("response", (headers) => {
          status = Number(headers[":status"] ?? 0);
          apnsId = sanitizedApnsId(headers["apns-id"]);
        });
        stream.on("data", (chunk: string) => {
          if (body.length < MAXIMUM_BODY_BYTES) body += chunk;
        });
        stream.on("end", () => {
          finish(classifyApnsResponse(status, body, apnsId));
        });
        stream.on("error", (error: unknown) => {
          finish(classifyApnsError(error));
        });

        stream.end(submission.payload);
      });
    },

    close(): void {
      try {
        session?.close();
      } catch {
        // An already-destroyed session needs no closing.
      }
    },
  };
}
