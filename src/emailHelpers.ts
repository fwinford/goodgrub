import { IRequest, ISubscriber } from "../models/db.js";
import { Resend } from "resend";
import { escapeHtml } from "./htmlEscape.js";
import { publicBaseUrl } from "./publicBaseUrl.js";
import { buildUnsubscribeUrl } from "./unsubscribeCredential.js";
import { assertExternalProvidersAllowed, isReviewRuntime } from "./externalProviders.js";
import { assertRequestAlertEmailDeliveryActive } from "./requestAlertEmailDelivery.js";
import { emailSender } from "./emailSender.js";

const resend = new Resend(isReviewRuntime() ? "review-disabled" : process.env.RESEND_API_KEY);

/**
 * Test seam for the emailed unsubscribe link. Production omits it and the
 * credential module reads the configured signing secret; a test supplies a
 * fixed secret instead of mutating the process environment.
 */
export interface UnsubscribeLinkOptions {
  unsubscribeSigningSecret?: Buffer;
}

type EmailRequestOptions = NonNullable<Parameters<typeof resend.emails.send>[1]> & {
	signal?: AbortSignal;
};

/**
 * Opt-in redaction for a send whose own message body is a credential.
 *
 * The default diagnostics below log the provider's error object and re-throw
 * its message. For an ordinary alert or confirmation that is useful and safe:
 * the worst it can quote is a subject line and a link that is already in the
 * recipient's inbox. It is not safe for the participant verification code,
 * whose subject *and* both bodies contain a live six-digit credential, and
 * which a provider may echo back inside an error, a request object, or a
 * response body this module has no way to inspect ahead of time.
 *
 * When a caller passes a label, nothing provider-supplied is logged or
 * re-thrown: the log line and the thrown message are both this fixed label.
 * Callers keep their existing failure handling, because the failure is still an
 * exception at the same point — it simply carries no borrowed text.
 */
export interface RedactedEmailDiagnostics {
	/**
	 * Fixed, allowlisted text. Must be a literal in this codebase, never a
	 * recipient, subject, body, or provider value.
	 */
	redactedLabel: string;
}

export async function sendEmailSafe(
	opts: Parameters<typeof resend.emails.send>[0],
	requestOptions?: EmailRequestOptions,
	diagnostics?: RedactedEmailDiagnostics
): Promise<{ success: boolean; error?: string; }> {
	assertExternalProvidersAllowed();
	const redactedLabel = diagnostics?.redactedLabel;

	try {
		const result = await resend.emails.send(opts, requestOptions);
		if ((result as any).error) {
			const err = (result as any).error;
			// Nothing logged and nothing borrowed from `err`: the catch below owns
			// the single fixed log line and the single fixed thrown message.
			if (redactedLabel) throw new Error(`${redactedLabel} send failed`);
			console.error("[Resend] send returned a provider error");
			// Throw so callers (which expect exceptions) will handle failures consistently
			throw new Error(String(err.message || JSON.stringify(err)));
		}
		return { success: true };
	} catch (err: any) {
		if (redactedLabel) {
			// Deliberately no provider error, request, response, recipient, or
			// exception message: any of them can carry the credential this send
			// exists to deliver. Re-thrown as a new error for the same reason —
			// `err` itself must not travel to a caller that may log it.
			console.error(`[email] ${redactedLabel} send failed`);
			throw new Error(`${redactedLabel} send failed`);
		}
		// Quota, network error, or other failure — throw so calling code can decide how to handle
		console.error("[Resend] provider request failed");
		throw new Error(String(err?.message || err));
	}
}

// Strictly shorter than the subscribe send lease, so a provider that never
// answers releases its lifecycle long before the lease expires.
export const CONFIRMATION_EMAIL_TIMEOUT_MS = 30_000;

export class EmailProviderTimeoutError extends Error {
	constructor(timeoutMs: number) {
		super(`Email provider did not answer within ${timeoutMs}ms`);
		this.name = "EmailProviderTimeoutError";
	}
}

/**
 * Trusted configuration only. The confirmation link carries a bearer token, so
 * it must never be built from `Host`, `X-Forwarded-Host`, or a request
 * protocol: a hostile header would otherwise redirect a real subscriber's
 * confirmation token to an attacker-controlled origin.
 */
export function confirmationBaseUrl(): string {
	return publicBaseUrl();
}

export async function sendSubscriptionConfirmationEmail(
	email: string,
	rawToken: string,
	timeoutMs: number = CONFIRMATION_EMAIL_TIMEOUT_MS
): Promise<void> {
	assertExternalProvidersAllowed();
	assertRequestAlertEmailDeliveryActive();
	const confirmUrl = `${confirmationBaseUrl().replace(/\/+$/, "")}/api/subscribe/confirm?token=${encodeURIComponent(rawToken)}`;
	const htmlConfirmUrl = escapeHtml(confirmUrl);

	// A real abort, not a racing promise: the Resend SDK spreads request
	// options into the underlying fetch `RequestInit`, so this cancels the
	// in-flight HTTP request instead of abandoning it while it holds a lease.
	const deadline = new AbortController();
	const timer = setTimeout(() => deadline.abort(), timeoutMs);

	try {
		await sendEmailSafe({
			from: emailSender(),
			to: email,
			subject: "Confirm your CommonPlate subscription",
			html: `<p>Please confirm your subscription to CommonPlate alerts:</p><p><a href="${htmlConfirmUrl}">${htmlConfirmUrl}</a></p><p>If you didn't request this, you can ignore this email.</p>`,
			text: `Confirm your CommonPlate subscription: ${confirmUrl}\n\nIf you didn't request this, you can ignore this email.`,
		}, { signal: deadline.signal });
	} catch (error) {
		// The SDK reports an aborted fetch as an indistinguishable transport
		// failure, so the deadline we own is what identifies a timeout.
		if (deadline.signal.aborted) throw new EmailProviderTimeoutError(timeoutMs);
		throw error;
	} finally {
		clearTimeout(timer);
	}
}

export async function sendNewRequestAlert(
	subscriber: ISubscriber,
	request: IRequest,
	options: UnsubscribeLinkOptions = {}
) {
	assertExternalProvidersAllowed();
	assertRequestAlertEmailDeliveryActive();
	// Signed here from identity the subscriber already carries, so building an
	// alert reads and writes no database state and stores no raw credential.
	const unsubUrl = buildUnsubscribeUrl(
		subscriber,
		options.unsubscribeSigningSecret
	);
	const htmlVendor = escapeHtml(request.vendor);
	const htmlFood = escapeHtml(request.food);
	const htmlPickupWindow = escapeHtml(request.pickupWindowText);
	// Every shape `POST /api/request` accepts, including the legacy web one,
	// has required an integer 1-5 since W3-C1, so `undefined` here reaches
	// this composer only from a malformed/pre-C1 stored `Request` document —
	// not a supported representation of any accepted submission. The alert
	// degrades by omitting the line rather than fabricating a value for that
	// impossible state.
	const mealSwipesLine =
		request.mealSwipes != null ? `Meal swipes: ${request.mealSwipes}` : null;
	const html = `
			<h2>New meal request: ${htmlVendor} · ${htmlPickupWindow}</h2>
			<ul>
				<li><strong>Vendor:</strong> ${htmlVendor}</li>
				<li><strong>Food:</strong> ${htmlFood}</li>
				<li><strong>Pickup Window:</strong> ${htmlPickupWindow}</li>
				${mealSwipesLine ? `<li><strong>Meal swipes:</strong> ${escapeHtml(String(request.mealSwipes))}</li>` : ""}
			</ul>
		<hr>
		<p style="font-size:0.9em;">To unsubscribe from these alerts, <a href="${escapeHtml(unsubUrl)}">click here</a>.</p>
	`;
	const text = `New meal request: ${request.vendor} · ${request.pickupWindowText}\n\nVendor: ${request.vendor}\nFood: ${request.food}\nPickup Window: ${request.pickupWindowText}${mealSwipesLine ? `\n${mealSwipesLine}` : ""}\n\nTo unsubscribe: ${unsubUrl}`;
	await sendEmailSafe({
		from: emailSender(),
		to: subscriber.email,
		subject: `New meal request: ${request.vendor} · ${request.pickupWindowText}`,
		html,
		text,
	});
}


/**
 * Tells the requester their order was placed.
 *
 * `donorEmail` is the claim-bound helper's verified principal, and since W3-I1
 * it is genuinely optional: a pre-I1 grandfathered claim carries no verified
 * helper identity, and the payload no longer supplies one either. When there is
 * no address, the reply line and the `mailto:` are omitted entirely rather than
 * rendered empty. An empty `mailto:` link is worse than no link — it looks like
 * contact the requester has and does not, and tapping it opens a blank message
 * to nobody. Every other part of the placement email is unaffected: the vendor,
 * pickup name, pickup window, order number, ETA, and the donor's own message
 * are what actually let the requester collect their food.
 */
export async function sendFulfillmentEmail(
	request: IRequest,
	orderNumber: string,
	eta?: string | undefined,
	donorMessage?: string | undefined,
	donorEmail?: string | undefined
) {
	const to = (request as any).email || (request as any).requesterEmail;
	if (!to) throw new Error("Missing requester email on request");

	const replyTo = donorEmail || undefined;
	const subject = "Someone is fulfilling your CommonPlate meal request";

	const html = `
		<h2>Great news! Someone has fulfilled your request from ${escapeHtml(request.vendor)}</h2>

		<h3>Request details</h3>
		<p><strong>Vendor:</strong> ${escapeHtml(request.vendor)}</p>
		<p><strong>Pickup window:</strong> ${escapeHtml(request.pickupWindowText)}</p>

		<h3>Order details</h3>
		<p><strong>Order number:</strong> ${escapeHtml(orderNumber)}</p>
		${eta ? `<p><strong>ETA:</strong> ${escapeHtml(eta)}</p>` : ''}

		${donorMessage ? `<h4>Message from your swipes donor</h4><p>${escapeHtml(donorMessage).replace(/\n/g, '<br>')}</p>` : ''}

		${replyTo ? `<p>You can reply to them at: <a href="mailto:${escapeHtml(replyTo)}">${escapeHtml(replyTo)}</a></p>` : ''}

		<p style="margin-top: 1.5rem;">Thanks for using CommonPlate!</p>
		<p style="color: #6b6b6b; font-size: 0.9rem; margin-top: 1rem;">This is an automated message from CommonPlate @ NYU</p>
	`;

	const textParts = [
		`Great news! Someone has fulfilled your request from ${request.vendor}.`,
		``,
		`Request details:`,
		`Vendor: ${request.vendor}`,
		`Pickup window: ${request.pickupWindowText}`,
		``,
		`Order details:`,
		`Order number: ${orderNumber}`,
	];
	if (eta) textParts.push(`ETA: ${eta}`);
	if (donorMessage) textParts.push(`\nMessage from your swipes donor:\n${donorMessage}`);
	if (replyTo) textParts.push(`\nYou can reply to them at: ${replyTo}`);
	textParts.push('\nThanks for using CommonPlate!');

	const text = textParts.join('\n');

	await sendEmailSafe({
		from: emailSender(),
		to,
		subject,
		html,
		text,
		// `replyTo` is the option name the Resend SDK reads; it maps it to the
		// wire field `reply_to` itself. Passing `reply_to` here is silently
		// dropped, which would send the requester notification with no Reply-To.
		...(replyTo ? { replyTo } : {}),
	});
}

/**
 * The participant verification code (W3-I1).
 *
 * Deliberately not a link. A link is a bearer credential that inbox scanners,
 * prefetchers, and forwarded mail can spend without a person acting — which is
 * exactly why the confirmation and unsubscribe flows above need a GET that only
 * renders a form. A typed code cannot be redeemed by anything that merely
 * *reads* this message, and emailed-link participant verification is deferred
 * to V2 by the accepted contract.
 *
 * The code is interpolated as text into both bodies and never escaped-then-
 * altered: it is six digits by construction. Nothing here logs it, and the
 * caller holds it only long enough to make this call.
 *
 * Bounded by the same provider deadline the confirmation email uses, so a
 * provider that never answers cannot hold the issuing request open.
 */
export const PARTICIPANT_VERIFICATION_SEND_LABEL = "participant verification";

export async function sendParticipantVerificationEmail(
	email: string,
	code: string,
	lifetimeMinutes: number,
	timeoutMs: number = CONFIRMATION_EMAIL_TIMEOUT_MS
): Promise<void> {
	const deadline = new AbortController();
	const timer = setTimeout(() => deadline.abort(), timeoutMs);

	try {
		await sendEmailSafe({
			from: emailSender(),
			to: email,
			subject: `${code} is your CommonPlate verification code`,
			html: `<p>Your CommonPlate verification code is:</p><p style="font-size:1.6rem;font-weight:700;letter-spacing:0.2rem;">${escapeHtml(code)}</p><p>It expires in ${lifetimeMinutes} minutes. Enter it in the CommonPlate app to finish verifying this NYU email.</p><p>If you didn't ask to verify this address, you can ignore this email. Nobody can act as you without this code.</p>`,
			text: `Your CommonPlate verification code is: ${code}\n\nIt expires in ${lifetimeMinutes} minutes. Enter it in the CommonPlate app to finish verifying this NYU email.\n\nIf you didn't ask to verify this address, you can ignore this email. Nobody can act as you without this code.`,
			// Every field of this send — the subject and both bodies — contains a
			// live credential, so no provider-supplied diagnostic may be logged or
			// re-thrown from it.
		}, { signal: deadline.signal }, { redactedLabel: PARTICIPANT_VERIFICATION_SEND_LABEL });
	} catch (error) {
		if (deadline.signal.aborted) throw new EmailProviderTimeoutError(timeoutMs);
		throw error;
	} finally {
		clearTimeout(timer);
	}
}

/**
 * The W4-P2 account-deletion challenge email.
 *
 * Deliberately a separate function with its own redacted label and its own
 * wording, never `sendParticipantVerificationEmail`: the two codes are
 * purpose-bound to different domains server-side (`src/participantDeletionSecurity.ts`
 * vs `src/participantCredentials.ts`), and the copy must say just as plainly
 * that this one code can permanently delete the account, so a person cannot
 * mistake it for an ordinary sign-in/verification code, and so a phished
 * relay of this exact email is distinguishable from the ordinary one. Same
 * "never a link" reasoning as the verification code above, and the same
 * redacted-diagnostics treatment: every field of this send is or contains
 * the live code.
 */
export const PARTICIPANT_DELETION_CHALLENGE_SEND_LABEL = "participant deletion challenge";

export async function sendParticipantDeletionChallengeEmail(
	email: string,
	code: string,
	lifetimeMinutes: number,
	timeoutMs: number = CONFIRMATION_EMAIL_TIMEOUT_MS
): Promise<void> {
	const deadline = new AbortController();
	const timer = setTimeout(() => deadline.abort(), timeoutMs);

	try {
		await sendEmailSafe({
			from: emailSender(),
			to: email,
			subject: `${code} is your CommonPlate account deletion code`,
			html: `<p>Someone requested to permanently delete the CommonPlate account for this NYU email. Your deletion code is:</p><p style="font-size:1.6rem;font-weight:700;letter-spacing:0.2rem;">${escapeHtml(code)}</p><p>It expires in ${lifetimeMinutes} minutes. This code only confirms the request to delete this account — it cannot be used to sign in.</p><p>If you didn't ask to delete your account, do not enter this code, and you can ignore this email.</p>`,
			text: `Someone requested to permanently delete the CommonPlate account for this NYU email. Your deletion code is: ${code}\n\nIt expires in ${lifetimeMinutes} minutes. This code only confirms the request to delete this account — it cannot be used to sign in.\n\nIf you didn't ask to delete your account, do not enter this code, and you can ignore this email.`,
		}, { signal: deadline.signal }, { redactedLabel: PARTICIPANT_DELETION_CHALLENGE_SEND_LABEL });
	} catch (error) {
		if (deadline.signal.aborted) throw new EmailProviderTimeoutError(timeoutMs);
		throw error;
	} finally {
		clearTimeout(timer);
	}
}
