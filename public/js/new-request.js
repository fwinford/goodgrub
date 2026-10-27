// GENERATED FILE — do not edit.
// Built from src/client/*.ts by build-client.mjs (npm run build:client).
// Edit the TypeScript source; edits here are overwritten by the next build.

// src/client/new-request.ts
var WEBSITE_REQUEST_CREATION_UNAVAILABLE_MESSAGE = "Posting a meal request from the web is temporarily unavailable.";
function applyRequestFormUnavailable(root) {
  const notice = root.getElementById("pause-notice");
  const fields = root.getElementById("request-fields");
  const submitBtn = root.getElementById("submit-btn");
  if (notice) {
    notice.textContent = WEBSITE_REQUEST_CREATION_UNAVAILABLE_MESSAGE;
    notice.hidden = false;
  }
  if (fields) {
    fields.disabled = true;
  }
  if (submitBtn) {
    submitBtn.disabled = true;
    submitBtn.setAttribute("aria-disabled", "true");
  }
}
function errorMessage(error) {
  return typeof error === "string" ? error : error?.message;
}
function submissionSuccessText(requestId) {
  const submitted = "Request submitted successfully!";
  return requestId ? `${submitted} Request ID: ${requestId}` : submitted;
}
document.addEventListener("DOMContentLoaded", () => {
  applyRequestFormUnavailable(document);
});
export {
  WEBSITE_REQUEST_CREATION_UNAVAILABLE_MESSAGE,
  applyRequestFormUnavailable,
  errorMessage,
  submissionSuccessText
};
//# sourceMappingURL=new-request.js.map
