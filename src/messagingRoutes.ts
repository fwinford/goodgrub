import type { Request, Response } from "express";
import { z } from "zod";
import {
  PARTICIPANT_AUTHORITY_HEADER,
  resolveParticipantAuthority,
  sendParticipantAuthorityRefusal,
} from "./participantAuthorityGate.js";
import { sendDay4Error } from "./day4Errors.js";
import { createMessagingService, MessagingError, type MessagingPolicy, type MessagingObserver } from "./messaging.js";

export const CONVERSATION_ROUTE_PATH = "/api/request/:id/conversation";
export const MESSAGE_ROUTE_PATH = `${CONVERSATION_ROUTE_PATH}/:conversationId/messages`;
export const MESSAGE_RECONCILIATION_PATH = `${MESSAGE_ROUTE_PATH}/:clientMessageId`;
export const MESSAGE_READ_ACK_ROUTE_PATH = `${CONVERSATION_ROUTE_PATH}/:conversationId/read`;
export const MESSAGE_UNREAD_COUNT_ROUTE_PATH = "/api/participant/messaging/unread-count";

const bodySchema = z.object({
  clientMessageId: z.string(),
  text: z.string(),
}).strict();
const querySchema = z.object({
  after: z.string().regex(/^(0|[1-9][0-9]*)$/).optional(),
  limit: z.string().regex(/^[1-9][0-9]*$/).optional(),
  direction: z.literal("backward").optional(),
  before: z.string().regex(/^[1-9][0-9]*$/).optional(),
}).strict();
const readAcknowledgementSchema = z.object({
  displayedSequences: z.array(z.number().int().positive().safe()).max(100),
}).strict();

// Intentionally not imported or mounted by app.ts. A policy is not an
// activation flag: its production implementation and registration need review.
export function createMessagingHandlers(policy?: MessagingPolicy, observer?: MessagingObserver) {
  const service = createMessagingService(policy, observer);
  function handler(operation: (req: Request, credential: string) => Promise<{ status: number; body: unknown }>) {
    return async (req: Request, res: Response): Promise<Response> => {
      res.setHeader("Cache-Control", "private, no-store");
      res.setHeader("Vary", PARTICIPANT_AUTHORITY_HEADER);
      const authority = await resolveParticipantAuthority(req);
      if (!authority.ok) return sendParticipantAuthorityRefusal(res, authority.refusal);
      const credential = req.headers[PARTICIPANT_AUTHORITY_HEADER];
      if (typeof credential !== "string") return sendParticipantAuthorityRefusal(res, "invalid");
      try {
        const result = await operation(req, credential);
        return res.status(result.status).json(result.body);
      } catch (error) {
        if (error instanceof MessagingError) {
          switch (error.code) {
            case "unavailable":
              return sendDay4Error(res, 404, "CONVERSATION_UNAVAILABLE", "This conversation is unavailable.");
            case "invalid":
              return sendDay4Error(res, 400, "INVALID_MESSAGE", "The message request is invalid.");
            case "conflict":
              return sendDay4Error(res, 409, "MESSAGE_IDENTITY_CONFLICT", "This message identity was already used.");
            case "filtered":
              return sendDay4Error(res, 400, "MESSAGE_TEXT_NOT_ALLOWED", "Please revise your message.");
          }
        }
        console.error("[messaging] Protected message operation unavailable");
        return sendDay4Error(res, 503, "MESSAGING_UNAVAILABLE", "Messaging is unavailable.");
      }
    };
  }
  return {
    open: handler(async (req, credential) => ({
      status: 200,
      body: await service.open(credential, String(req.params.id)),
    })),
    send: handler(async (req, credential) => {
      const body = bodySchema.safeParse(req.body);
      if (!body.success) throw new MessagingError("invalid");
      const result = await service.send(credential, String(req.params.id), { conversationId: String(req.params.conversationId) },
        body.data.clientMessageId, body.data.text);
      return { status: result.created ? 201 : 200, body: { message: result.message } };
    }),
    read: handler(async (req, credential) => {
      const query = querySchema.safeParse(req.query);
      if (!query.success) throw new MessagingError("invalid");
      const target = { conversationId: String(req.params.conversationId) };
      if (query.data.direction === "backward") {
        if (query.data.after !== undefined) throw new MessagingError("invalid");
        return {
          status: 200,
          body: await service.history(credential, String(req.params.id), target,
            query.data.before === undefined ? undefined : Number(query.data.before),
            query.data.limit === undefined ? undefined : Number(query.data.limit)),
        };
      }
      if (query.data.before !== undefined) throw new MessagingError("invalid");
      const result = await service.read(credential, String(req.params.id), { conversationId: String(req.params.conversationId) },
        query.data.after === undefined ? 0 : Number(query.data.after),
        query.data.limit === undefined ? 100 : Number(query.data.limit));
      return { status: 200, body: result };
    }),
    reconcile: handler(async (req, credential) => ({
      status: 200,
      body: await service.reconcile(credential, String(req.params.id), { conversationId: String(req.params.conversationId) },
        String(req.params.clientMessageId)),
    })),
    acknowledgeDisplayed: handler(async (req, credential) => {
      const body = readAcknowledgementSchema.safeParse(req.body);
      if (!body.success) throw new MessagingError("invalid");
      return {
        status: 200,
        body: await service.acknowledgeDisplayed(
          credential,
          String(req.params.id),
          { conversationId: String(req.params.conversationId) },
          body.data.displayedSequences
        ),
      };
    }),
    unreadCounts: handler(async (_req, credential) => ({
      status: 200,
      body: await service.unreadCounts(credential),
    })),
  };
}
