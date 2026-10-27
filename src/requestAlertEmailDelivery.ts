export function isRequestAlertEmailDeliveryActive(): boolean {
  return false;
}

export const REQUEST_ALERT_EMAIL_UNAVAILABLE_MESSAGE =
  "Email Request Alerts are not available.";

export function assertRequestAlertEmailDeliveryActive(): void {
  if (!isRequestAlertEmailDeliveryActive()) {
    throw new Error(REQUEST_ALERT_EMAIL_UNAVAILABLE_MESSAGE);
  }
}
