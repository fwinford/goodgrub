import { IRequest, ISubscriber } from "../models/db.js";
import type { UnsubscribeLinkOptions } from "./emailHelpers.js";
import { sendEmailSafe } from "./emailHelpers.js";
import { escapeHtml } from "./htmlEscape.js";
import {
  PUBLIC_ACTIONS_PAUSED_ENV,
  isPublicActionsPaused,
} from "./publicActionsPause.js";
import { buildUnsubscribeUrl } from "./unsubscribeCredential.js";
import { assertExternalProvidersAllowed } from "./externalProviders.js";
import { assertRequestAlertEmailDeliveryActive } from "./requestAlertEmailDelivery.js";
import { emailSender } from "./emailSender.js";

export async function sendDigestEmail(
  subscriber: ISubscriber,
  requests: IRequest[],
  options: UnsubscribeLinkOptions = {}
) {
  assertExternalProvidersAllowed();
  assertRequestAlertEmailDeliveryActive();
  // The hourly cron already returns before reaching this function while
  // paused. This throws rather than returning quietly so that any other
  // caller fails loudly instead of recording a digest that was never sent.
  if (isPublicActionsPaused()) {
    throw new Error(
      `Refusing to send a digest while ${PUBLIC_ACTIONS_PAUSED_ENV} is on`
    );
  }

  // Signed on demand from the subscriber's own identity: the digest performs
  // no database work to build its unsubscribe link and stores nothing.
  const unsubUrl = buildUnsubscribeUrl(
    subscriber,
    options.unsubscribeSigningSecret
  );
  const htmlList = requests.map(req => `
    <li>
      <strong>${escapeHtml(req.vendor)}</strong> — ${escapeHtml(req.food)}<br>
      <em>${escapeHtml(req.pickupWindowText)}</em><br>
    </li>
  `).join("");
  const html = `
    <h2>${requests.length} new meal requests in the last hour</h2>
    <ul>${htmlList}</ul>
    <hr>
    <p style="font-size:0.9em;">To unsubscribe from these alerts, <a href="${escapeHtml(unsubUrl)}">click here</a>.</p>
  `;
  const textList = requests.map(req => `- ${req.vendor} — ${req.food}\n  ${req.pickupWindowText}`).join("\n\n");
  const text = `${requests.length} new meal requests in the last hour\n\n${textList}\n\nTo unsubscribe: ${unsubUrl}`;
  await sendEmailSafe({
    from: emailSender(),
    to: subscriber.email,
    subject: `${requests.length} new meal requests in the last hour`,
    html,
    text,
  });
}
