import type { ConnectOptions } from "mongoose";

// Atlas Flex allows 500 connections in total. Each process holds at most
// maxPoolSize application connections plus a few driver monitoring
// connections per replica-set member. Default budget: production 20 + review 5
// leaves a wide margin for maintenance scripts and driver overhead.
export const PRODUCTION_MAX_POOL_SIZE = 20;
export const REVIEW_MAX_POOL_SIZE = 5;
export const MAX_POOL_SIZE_CEILING = 50;
export const DEFAULT_WAIT_QUEUE_TIMEOUT_MS = 5_000;

export const MONGO_MAX_POOL_SIZE_ENV = "MONGO_MAX_POOL_SIZE";
export const MONGO_WAIT_QUEUE_TIMEOUT_ENV = "MONGO_WAIT_QUEUE_TIMEOUT_MS";

export type MongoConnectionOptionsResult =
  | { ok: true; options: ConnectOptions }
  | { ok: false; error: string };

function boundedInteger(
  raw: string | undefined,
  fallback: number,
  min: number,
  max: number
): number | null {
  if (raw === undefined || raw.trim() === "") return fallback;
  if (!/^\d+$/.test(raw.trim())) return null;
  const value = Number(raw.trim());
  return value >= min && value <= max ? value : null;
}

/**
 * Bounded pool settings. Waiting for a pooled connection fails fast instead of
 * queueing forever; no socket timeout is set because aborting a write whose
 * outcome is unknown must stay an explicit, never-automatic decision.
 */
export function mongoConnectionOptions(
  environment: NodeJS.ProcessEnv = process.env
): MongoConnectionOptionsResult {
  const defaultPool =
    environment.NODE_ENV === "review"
      ? REVIEW_MAX_POOL_SIZE
      : PRODUCTION_MAX_POOL_SIZE;
  const maxPoolSize = boundedInteger(
    environment[MONGO_MAX_POOL_SIZE_ENV],
    defaultPool,
    1,
    MAX_POOL_SIZE_CEILING
  );
  if (maxPoolSize === null) {
    return {
      ok: false,
      error: `${MONGO_MAX_POOL_SIZE_ENV} must be an integer from 1 to ${MAX_POOL_SIZE_CEILING}`,
    };
  }
  const waitQueueTimeoutMS = boundedInteger(
    environment[MONGO_WAIT_QUEUE_TIMEOUT_ENV],
    DEFAULT_WAIT_QUEUE_TIMEOUT_MS,
    100,
    30_000
  );
  if (waitQueueTimeoutMS === null) {
    return {
      ok: false,
      error: `${MONGO_WAIT_QUEUE_TIMEOUT_ENV} must be an integer from 100 to 30000`,
    };
  }
  return {
    ok: true,
    options: { maxPoolSize, minPoolSize: 0, waitQueueTimeoutMS },
  };
}
