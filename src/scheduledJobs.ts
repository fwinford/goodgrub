import cron from "node-cron";
import { isReviewRuntime } from "./externalProviders.js";

export const SCHEDULER_ENABLED_ENV = "SCHEDULER_ENABLED";

export function isSchedulerEnabled(
  environment: NodeJS.ProcessEnv = process.env
): boolean {
  return !isReviewRuntime(environment) && environment[SCHEDULER_ENABLED_ENV] === "true";
}

export function registerScheduledJob(
  expression: string,
  job: () => void | Promise<void>,
  options: {
    enabled?: boolean;
    isReady?: () => boolean;
  } = {}
) {
  const enabled = options.enabled ?? isSchedulerEnabled();
  if (!enabled || isReviewRuntime()) return undefined;

  const isReady = options.isReady ?? (() => true);
  return cron.schedule(
    expression,
    async () => {
      if (isReviewRuntime() || !isReady()) return;
      await job();
    },
    { noOverlap: true }
  );
}
