import { randomUUID } from "node:crypto";
import type { Request, Response } from "express";
import type { FilterQuery, UpdateQuery } from "mongoose";
import { z } from "zod";
import { Subscriber, type ISubscriber } from "../models/db.js";
import {
  NYU_EMAIL_REQUIRED_MESSAGE,
  hasAllowedEmailDomain,
} from "./allowedEmailDomains.js";
import { sendDay4Error } from "./day4Errors.js";
import { sendSubscriptionConfirmationEmail } from "./emailHelpers.js";
import {
  isRequestAlertEmailDeliveryActive,
  REQUEST_ALERT_EMAIL_UNAVAILABLE_MESSAGE,
} from "./requestAlertEmailDelivery.js";
import {
  SUBSCRIPTION_TOKEN_BYTES,
  digestSubscriptionToken,
  generateSubscriptionToken,
} from "./subscriptionTokens.js";

export const SUBSCRIBE_ACCEPTED_RESPONSE = {
  message: "If confirmation is needed, check your email for the next step.",
} as const;

export const CONFIRMATION_TOKEN_BYTES = SUBSCRIPTION_TOKEN_BYTES;
export const CONFIRMATION_LIFETIME_MS = 24 * 60 * 60 * 1000;
/**
 * How long one attempt may own provider submission. Ownership blocks rotation,
 * so it cannot be permanent: a process killed between winning the write and
 * clearing the owner would otherwise leave the address unable to ever receive
 * another confirmation link. Provider submission is bounded well below this by
 * `CONFIRMATION_EMAIL_TIMEOUT_MS`, so a still-present owner past the lease
 * belongs to an attempt that died rather than one that is still working.
 */
export const CONFIRMATION_SEND_LEASE_MS = 2 * 60 * 1000;

// The allowlist is part of the body schema rather than a later check, so a
// non-NYU address is refused in the same place and at the same point as a
// malformed one: before any Subscriber lookup or mutation.
const subscribeBodySchema = z
  .object({
    email: z
      .string()
      .trim()
      .toLowerCase()
      .email()
      .refine(hasAllowedEmailDomain),
  })
  .strict();

type LifecycleField =
  | "status"
  | "confirmationTokenDigest"
  | "confirmationExpiresAt"
  | "confirmToken"
  | "confirmationSendAttemptId"
  | "confirmationSendAttemptAt";

// Every field the conditional rotation compares and the rollback restores.
// Ownership is included so a takeover matches the exact stale owner it saw and
// a rollback puts that owner back exactly as it was.
const LIFECYCLE_FIELDS: readonly LifecycleField[] = [
  "status",
  "confirmationTokenDigest",
  "confirmationExpiresAt",
  "confirmToken",
  "confirmationSendAttemptId",
  "confirmationSendAttemptAt",
];

interface FieldState {
  present: boolean;
  value?: unknown;
}

interface SubscriberSnapshot {
  _id: ISubscriber["_id"];
  email: string;
  status?: ISubscriber["status"];
  confirmationTokenDigest?: string | null;
  confirmationExpiresAt?: Date | null;
  confirmationSendAttemptId?: string | null;
  confirmationSendAttemptAt?: Date | null;
  confirmToken?: string | null;
}

interface ProviderResult {
  error?: unknown;
}

export interface SubscribeDependencies {
  now: () => Date;
  generateRawToken: () => string;
  generateAttemptId: () => string;
  // Deliberately no base-URL parameter: the confirmation link carries a bearer
  // token and is built from trusted configuration inside the email helper.
  sendConfirmationEmail: (
    email: string,
    rawToken: string
  ) => Promise<void | ProviderResult>;
}

const defaultDependencies: SubscribeDependencies = {
  now: () => new Date(),
  generateRawToken: generateConfirmationToken,
  generateAttemptId: () => randomUUID(),
  sendConfirmationEmail: sendSubscriptionConfirmationEmail,
};

// Signup issues the confirmation token and redemption verifies it, so both
// slices delegate to one shared shape and hash rather than repeating them.
export function generateConfirmationToken(): string {
  return generateSubscriptionToken();
}

export function digestConfirmationToken(rawToken: string): string {
  return digestSubscriptionToken(rawToken);
}

function hasOwn(value: object, field: string): boolean {
  return Object.prototype.hasOwnProperty.call(value, field);
}

function captureLifecycle(snapshot: SubscriberSnapshot): Record<LifecycleField, FieldState> {
  const captured = {} as Record<LifecycleField, FieldState>;
  for (const field of LIFECYCLE_FIELDS) {
    captured[field] = {
      present: hasOwn(snapshot, field),
      value: snapshot[field],
    };
  }
  return captured;
}

function exactFieldClauses(
  fields: Record<LifecycleField, FieldState>
): FilterQuery<ISubscriber>[] {
  return LIFECYCLE_FIELDS.flatMap((field) => {
    const state = fields[field];
    // `{field: null}` also matches a missing field, so presence is asserted
    // separately: absent must stay absent and explicit null must stay null.
    return state.present
      ? [{ [field]: { $exists: true } }, { [field]: state.value }]
      : [{ [field]: { $exists: false } }];
  });
}

function rollbackUpdate(
  fields: Record<LifecycleField, FieldState>
): UpdateQuery<ISubscriber> {
  const $set: Record<string, unknown> = {};
  const $unset: Record<string, ""> = {};

  for (const field of LIFECYCLE_FIELDS) {
    const state = fields[field];
    if (state.present) {
      $set[field] = state.value;
    } else {
      $unset[field] = "";
    }
  }

  const update: UpdateQuery<ISubscriber> = {};
  if (Object.keys($set).length > 0) update.$set = $set;
  if (Object.keys($unset).length > 0) update.$unset = $unset;
  return update;
}

/**
 * Ownership counts only inside its lease. A missing timestamp, or one at or
 * before the cutoff, belongs to an attempt that can no longer be running, so
 * its lifecycle is takeover-eligible rather than permanently blocked.
 */
function hasActiveSendOwner(
  snapshot: SubscriberSnapshot,
  leaseCutoff: Date
): boolean {
  if (!snapshot.confirmationSendAttemptId) return false;
  const startedAt = snapshot.confirmationSendAttemptAt;
  if (!(startedAt instanceof Date)) return false;
  return startedAt.getTime() > leaseCutoff.getTime();
}

function errorReason(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function isDuplicateEmail(error: unknown): boolean {
  return (
    typeof error === "object" &&
    error !== null &&
    "code" in error &&
    (error as { code?: unknown }).code === 11000
  );
}

async function readSubscriber(email: string): Promise<SubscriberSnapshot | null> {
  return Subscriber.findOne({ email })
    .select(
      "+confirmationTokenDigest +confirmationExpiresAt +confirmationSendAttemptId +confirmationSendAttemptAt +confirmToken"
    )
    .lean<SubscriberSnapshot>()
    .exec();
}

function accepted(res: Response): Response {
  return res.status(202).json(SUBSCRIBE_ACCEPTED_RESPONSE);
}

export function createSubscribeHandler(
  overrides: Partial<SubscribeDependencies> = {}
) {
  const dependencies = { ...defaultDependencies, ...overrides };

  return async function subscribe(req: Request, res: Response): Promise<Response> {
    if (!isRequestAlertEmailDeliveryActive()) {
      return sendDay4Error(res, 410, "REQUEST_ALERT_EMAIL_UNAVAILABLE", REQUEST_ALERT_EMAIL_UNAVAILABLE_MESSAGE);
    }
    const validated = subscribeBodySchema.safeParse(req.body);
    if (!validated.success) {
      // Malformed and non-allowlisted addresses share one code and one
      // message. Both mean the same thing to the person typing — this is not
      // an address alerts can be sent to — and separating them would add a
      // public error code the client contract does not define.
      return sendDay4Error(
        res,
        400,
        "INVALID_EMAIL",
        NYU_EMAIL_REQUIRED_MESSAGE
      );
    }

    const { email } = validated.data;
    // One captured backend clock decides expiry, this attempt's lease stamp,
    // and the lease cutoff, so they cannot disagree within a request.
    const now = dependencies.now();
    const leaseCutoff = new Date(now.getTime() - CONFIRMATION_SEND_LEASE_MS);

    const existing = await readSubscriber(email);
    if (existing?.status === "confirmed") return accepted(res);

    // A live request owns provider submission for the current lifecycle. This
    // attempt is a privacy-preserving loser and must not generate or send a token.
    if (existing && hasActiveSendOwner(existing, leaseCutoff)) {
      await readSubscriber(email);
      return accepted(res);
    }

    const rawToken = dependencies.generateRawToken();
    const confirmationTokenDigest = digestConfirmationToken(rawToken);
    const attemptId = dependencies.generateAttemptId();
    const confirmationExpiresAt = new Date(
      now.getTime() + CONFIRMATION_LIFETIME_MS
    );

    let subscriberId: ISubscriber["_id"];
    let created = false;
    let previousLifecycle: Record<LifecycleField, FieldState> | undefined;

    if (!existing) {
      try {
        const subscriber = await Subscriber.create({
          email,
          status: "pending",
          confirmationTokenDigest,
          confirmationExpiresAt,
          confirmationSendAttemptId: attemptId,
          confirmationSendAttemptAt: now,
        });
        subscriberId = subscriber._id;
        created = true;
      } catch (error) {
        if (!isDuplicateEmail(error)) throw error;
        await readSubscriber(email);
        return accepted(res);
      }
    } else {
      previousLifecycle = captureLifecycle(existing);
      // One conditional mutation. `exactFieldClauses` now covers both
      // ownership fields, so this both rejects a rotation under a live owner
      // and lets a takeover match the exact stale owner it observed.
      const rotated = await Subscriber.findOneAndUpdate(
        {
          _id: existing._id,
          email,
          $and: exactFieldClauses(previousLifecycle),
        },
        {
          $set: {
            status: "pending",
            confirmationTokenDigest,
            confirmationExpiresAt,
            confirmationSendAttemptId: attemptId,
            confirmationSendAttemptAt: now,
          },
          $unset: { confirmToken: "" },
        },
        { new: true }
      )
        .select("_id")
        .lean()
        .exec();

      if (!rotated) {
        await readSubscriber(email);
        return accepted(res);
      }
      subscriberId = existing._id;
    }

    const stillOwned = await Subscriber.exists({
      _id: subscriberId,
      confirmationTokenDigest,
      confirmationSendAttemptId: attemptId,
    });
    if (!stillOwned) return accepted(res);

    try {
      const result = await dependencies.sendConfirmationEmail(email, rawToken);
      if (result && result.error) throw new Error("Provider returned an error");

      try {
        await Subscriber.updateOne(
          {
            _id: subscriberId,
            confirmationTokenDigest,
            confirmationSendAttemptId: attemptId,
          },
          {
            $unset: {
              confirmationSendAttemptId: "",
              confirmationSendAttemptAt: "",
            },
          }
        );
      } catch (clearError) {
        // Provider acceptance means this lifecycle must remain valid, so a
        // failed owner clear must never trigger rollback after the email was
        // submitted. The lease bounds any owner that remains; this records
        // the unverified outcome.
        console.error(
          "[subscribe] Confirmation send-owner clear outcome is unknown; the database operation could not be verified.",
          {
            subscriberId: String(subscriberId),
            attemptId,
            reason: errorReason(clearError),
          }
        );
      }
      return accepted(res);
    } catch {
      try {
        if (created) {
          await Subscriber.deleteOne({
            _id: subscriberId,
            confirmationTokenDigest,
            confirmationSendAttemptId: attemptId,
          });
        } else if (previousLifecycle) {
          await Subscriber.updateOne(
            {
              _id: subscriberId,
              confirmationTokenDigest,
              confirmationSendAttemptId: attemptId,
            },
            rollbackUpdate(previousLifecycle)
          );
        }
      } catch (compensationError) {
        // Compensation is best-effort. Keep the lifecycle recoverable by a
        // later explicit signup without exposing this provider outcome.
        console.error(
          created
            ? "[subscribe] Confirmation cleanup outcome is unknown; new-record deletion could not be verified."
            : "[subscribe] Confirmation rollback outcome is unknown; restoration of the previous lifecycle could not be verified.",
          {
            subscriberId: String(subscriberId),
            attemptId,
            reason: errorReason(compensationError),
          }
        );
      }
      // Provider submission failure is operational truth, not public
      // Subscriber-lifecycle truth. The generic wording does not claim that
      // a confirmation email was submitted, delivered, or received.
      return accepted(res);
    }
  };
}

export const subscribe = createSubscribeHandler();
