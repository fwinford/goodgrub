// src/client/new-request.ts
// Form submission handling for new meal requests

/**
 * W3-I1 (cross-client boundary): `POST /api/request` now requires verified
 * participant authority, and the website has no participant-verification UX
 * to supply it — that remains Week 6 scope. Presenting an actionable form
 * whose every submission is guaranteed to fail would be worse than not
 * presenting one, so posting from the web is unconditionally non-actionable
 * until Week 6 ships, regardless of `PUBLIC_ACTIONS_PAUSED`. Unlike the
 * earlier pause notice this reused, this state does not lift when public
 * actions resume.
 */
export const WEBSITE_REQUEST_CREATION_UNAVAILABLE_MESSAGE =
  "Posting a meal request from the web is temporarily unavailable.";

/**
 * Presents the non-actionable state before any data entry and disables the
 * whole field set, not only the submit button, so nobody can fill the form
 * out only to have it refused at the end.
 */
export function applyRequestFormUnavailable(root: Document): void {
  const notice = root.getElementById('pause-notice');
  const fields = root.getElementById('request-fields') as HTMLFieldSetElement | null;
  const submitBtn = root.getElementById('submit-btn') as HTMLButtonElement | null;

  if (notice) {
    notice.textContent = WEBSITE_REQUEST_CREATION_UNAVAILABLE_MESSAGE;
    notice.hidden = false;
  }
  if (fields) {
    fields.disabled = true;
  }
  if (submitBtn) {
    submitBtn.disabled = true;
    submitBtn.setAttribute('aria-disabled', 'true');
  }
}

/// Decodes both the structured create-error envelope and a flat error string.
interface RequestResponse {
  request?: { id: string };
  error?: string | { code: string; message: string };
}

export function errorMessage(error: RequestResponse['error']): string | undefined {
  return typeof error === 'string' ? error : error?.message;
}

/// States only what the `201` proves: the request was validated and persisted.
/// It deliberately does not mention email. Requester confirmation is now sent
/// after persistence and cannot undo it (`src/createRequestRoute.ts`), so a
/// send that fails still returns `201` — promising a message here would tell
/// the student to wait for something that may never arrive.
export function submissionSuccessText(requestId?: string): string {
  const submitted = 'Request submitted successfully!';
  return requestId ? `${submitted} Request ID: ${requestId}` : submitted;
}

document.addEventListener('DOMContentLoaded', () => {
  // Website request creation is unconditionally non-actionable pending Week 6
  // participant verification (see `applyRequestFormUnavailable`). No probe, no
  // submit wiring: there is nothing this page can do that would not be
  // guaranteed to fail at the backend's participant gate.
  applyRequestFormUnavailable(document);
});
