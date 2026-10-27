export const APPROVED_PRODUCTION_EMAIL_SENDER =
  "GoodGrub <noreply@goodgrubapp.com>";
export const DEVELOPMENT_EMAIL_SENDER =
  "CommonPlate <onboarding@resend.dev>";

export function emailSender(
  environment: NodeJS.ProcessEnv = process.env
): string {
  const configured = environment.FROM_EMAIL?.trim();
  if (environment.NODE_ENV === "production") {
    if (configured !== APPROVED_PRODUCTION_EMAIL_SENDER) {
      throw new Error("Approved production email sender is unavailable");
    }
    return configured;
  }
  return configured || DEVELOPMENT_EMAIL_SENDER;
}
