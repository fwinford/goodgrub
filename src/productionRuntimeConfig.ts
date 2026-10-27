import { SCHEDULER_ENABLED_ENV } from "./scheduledJobs.js";
import { mongo } from "mongoose";
import { APPROVED_PRODUCTION_EMAIL_SENDER } from "./emailSender.js";

export function validateProductionRuntime(
  environment: NodeJS.ProcessEnv = process.env
): string | null {
  if (environment.NODE_ENV === "review") {
    if (environment.HOST !== "127.0.0.1") {
      return "Review HOST must be 127.0.0.1";
    }
    if (environment.PORT !== "3001") {
      return "Review PORT must be 3001";
    }
    if (environment[SCHEDULER_ENABLED_ENV] !== "false") {
      return `${SCHEDULER_ENABLED_ENV} must be false in the review environment`;
    }
    if (environment.PUBLIC_ACTIONS_PAUSED !== "true") {
      return "PUBLIC_ACTIONS_PAUSED must be true in the review environment";
    }
    if (environment.CRON_ENABLED !== "false") {
      return "CRON_ENABLED must be false in the review environment";
    }
    if (environment.EXTERNAL_PROVIDERS !== "disabled") {
      return "Review EXTERNAL_PROVIDERS must be disabled";
    }
    if ([
      "RESEND_API_KEY",
      "OPENAI_API_KEY",
      "APNS_TEAM_ID",
      "APNS_KEY_ID",
      "APNS_BUNDLE_ID",
      "APNS_AUTH_KEY_P8",
      "MONITOR_EMAILS",
      "PARTICIPANT_SIGNING_SECRET",
      "UNSUBSCRIBE_SIGNING_SECRET",
      "PARTICIPATION_HMAC_KEYRING",
      "BLOCK_SAFETY_HMAC_KEYRING",
      "PARTICIPANT_DELETION_SIGNING_SECRET",
    ].some((name) => environment[name]?.trim())) {
      return "Review provider and production participant credentials must be absent";
    }
    if (!usesDatabase(environment.MONGO_URI, "commonplate_review")) {
      return "Review MONGO_URI must target the isolated review database";
    }
    const reviewOrigin = httpsOrigin(environment.BASE_URL);
    const productionOrigin = httpsOrigin(environment.PRODUCTION_BASE_URL);
    if (!reviewOrigin || !productionOrigin ||
        reviewOrigin.hostname === productionOrigin.hostname) {
      return "Review BASE_URL and PRODUCTION_BASE_URL must be distinct HTTPS origins";
    }
    return null;
  }

  if (environment.NODE_ENV !== "production") return null;

  if (!isValidPort(environment.PORT)) {
    return "PORT must be a valid TCP port";
  }

  if (environment.HOST !== "127.0.0.1") {
    return "Production HOST must be 127.0.0.1";
  }
  if (environment[SCHEDULER_ENABLED_ENV] !== "true") {
    return `${SCHEDULER_ENABLED_ENV} must be true in production`;
  }
  if (!usesDatabase(environment.MONGO_URI, "commonplate_production")) {
    return "Production MONGO_URI must target the production database";
  }

  const configuredBaseUrl = environment.BASE_URL?.trim();
  if (!configuredBaseUrl) {
    return "Production BASE_URL must be configured";
  }

  let baseUrl: URL;
  try {
    baseUrl = new URL(configuredBaseUrl);
  } catch {
    return "Production BASE_URL must be a valid HTTPS origin";
  }

  if (
    baseUrl.protocol !== "https:" ||
    baseUrl.username !== "" ||
    baseUrl.password !== "" ||
    baseUrl.pathname !== "/" ||
    baseUrl.search !== "" ||
    baseUrl.hash !== ""
  ) {
    return "Production BASE_URL must be a valid HTTPS origin";
  }

  if (environment.FROM_EMAIL?.trim() !== APPROVED_PRODUCTION_EMAIL_SENDER) {
    return "Production FROM_EMAIL must be the approved GoodGrub sender";
  }

  return null;
}

function httpsOrigin(value: string | undefined): URL | null {
  if (!value?.trim()) return null;
  try {
    const url = new URL(value);
    if (url.protocol !== "https:" || url.username !== "" ||
        url.password !== "" || url.pathname !== "/" ||
        url.search !== "" || url.hash !== "" || url.port !== "") return null;
    return url;
  } catch {
    return null;
  }
}

function isValidPort(portValue: string | undefined): boolean {
  const configuredPort = portValue?.trim() || "3000";
  const port = Number(configuredPort);
  return (
    /^\d+$/.test(configuredPort) &&
    Number.isInteger(port) &&
    port >= 1 &&
    port <= 65535
  );
}

function usesDatabase(
  mongoUri: string | undefined,
  requiredDatabase: string
): boolean {
  if (!mongoUri?.trim()) return false;
  try {
    // The driver's parser supports replica-set seed lists; WHATWG URL does not.
    // Construction parses options only and never connects.
    return new mongo.MongoClient(mongoUri).options.dbName === requiredDatabase;
  } catch {
    return false;
  }
}
