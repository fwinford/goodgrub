import { Subscriber } from "../models/db.js";

/**
 * W4-N0 participant-authorized Email Request Alert state read.
 *
 * A third path onto the same Subscriber lifecycle `participantEmailUnsubscribe.ts`
 * mutates: this one only reads whether the exact backend-resolved participant
 * principal is currently an active/confirmed Subscriber (system-contract
 * section 9). N0 intentionally treats exact-principal `status: "confirmed"`
 * alone as authoritative Email-alert On; it does not evaluate `bounced` or
 * any other delivery/provider signal, so it is not the same condition the
 * real-time alert and digest queries use to decide send eligibility
 * (`src/notifySubscribers.ts` additionally requires `bounced: false`).
 * Bounce/provider delivery eligibility is separate and stays outside N0,
 * left to later N1 behavior. `email` must already be the exact normalized
 * principal `resolveParticipantAuthority` resolved — this function performs
 * no normalization or eligibility check of its own.
 *
 * `Subscriber.exists` resolves to only `{ _id }` or `null`, never any other
 * document field, so no private Subscriber field can leak through this read
 * regardless of future schema additions.
 */
export interface EmailAlertState {
  active: boolean;
}

export async function readEmailAlertState(
  email: string
): Promise<EmailAlertState> {
  const match = await Subscriber.exists({ email, status: "confirmed" });
  return { active: match !== null };
}
