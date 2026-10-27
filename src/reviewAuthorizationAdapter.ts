import type { Request } from "express";
import type { ReviewActor } from "./reviewAuthority.js";
import type { ReviewAuthority } from "./reviewAuthority.js";
import { isReviewSession } from "./reviewCredentials.js";

export const REVIEW_SESSION_HEADER = "x-goodgrub-review-session";

export function readReviewSession(req: Request): string | undefined {
  const value = req.headers[REVIEW_SESSION_HEADER];
  return isReviewSession(value) ? value : undefined;
}

export interface ReviewLifecycleBinding {
  isReady(): boolean;
  // Must bind the synthetic actor to the actual lifecycle repositories and
  // enforce request ownership. No student credential may be minted here.
  authorize(req: Request, actor: Readonly<ReviewActor>): Promise<boolean>;
}

function permittedRole(req: Request, actor: ReviewActor): boolean {
  const path = `${req.method} ${req.path}`;
  if (/^GET \/api\/(?:requests|stats|request-operation\/authority)$/.test(path) ||
      /^GET \/api\/request\/[a-fA-F0-9]{24}(?:\/eligibility)?$/.test(path) ||
      /^GET \/api\/participant\/(?:requests|active-reservation|request-eligibility|blocks)$/.test(path) ||
      /^GET \/api\/participant\/request\/[a-fA-F0-9]{24}$/.test(path) ||
      /^POST \/api\/request\/[a-fA-F0-9]{24}\/block$/.test(path) ||
      /^DELETE \/api\/participant\/blocks\/[a-fA-F0-9]{24}$/.test(path)) return true;
  if (actor.role === "requester") {
    return /^POST \/api\/(?:request|request-operation\/terminal)$/.test(path) ||
      /^POST \/api\/request\/[a-fA-F0-9]{24}\/(?:edit|withdraw)$/.test(path);
  }
  return /^POST \/api\/request\/[a-fA-F0-9]{24}\/(?:claim(?:\/extend|\/release)?|fulfill)$/.test(path);
}

// Structurally implements INF1's ReviewAuthorizationAdapter without importing
// or duplicating its uncommitted runtime/perimeter module.
export function createReviewAuthorizationAdapter(
  authority: Pick<ReviewAuthority, "isReady" | "authenticate">,
  binding?: ReviewLifecycleBinding
) {
  const actors = new WeakMap<Request, Readonly<ReviewActor>>();
  const isReady = () => process.env.NODE_ENV === "review" &&
    authority.isReady() && binding?.isReady() === true;
  return {
    isReady,
    async authorize(req: Request): Promise<boolean> {
      actors.delete(req);
      if (!isReady() || !binding || req.headers["x-commonplate-participant"] !== undefined) {
        return false;
      }
      const actor = await authority.authenticate(readReviewSession(req));
      if (!actor || !permittedRole(req, actor)) return false;
      const frozen = Object.freeze(actor);
      if (!(await binding.authorize(req, frozen))) return false;
      actors.set(req, frozen);
      return true;
    },
    actorForRequest(req: Request): Readonly<ReviewActor> | undefined {
      return process.env.NODE_ENV === "review" ? actors.get(req) : undefined;
    },
  };
}
