import mongoose, { Schema, type InferSchemaType } from "mongoose";

const conversationSchema = new Schema({
  requestId: { type: Schema.Types.ObjectId, required: true },
  helperParticipantId: { type: Schema.Types.ObjectId, required: true },
  requesterParticipantId: { type: Schema.Types.ObjectId, required: true },
  sequence: { type: Number, required: true, default: 0 },
  lastAuthorizedAt: { type: Date, required: true },
  checkedAt: { type: Date, required: true },
  closedAt: Date,
  cleanupDueAt: Date,
  cleanedAt: Date,
  // Bounded report-only cleanup protection; grants no chat access.
  reportLeaseHolderId: Schema.Types.ObjectId,
  reportLeaseUntil: Date,
  reportLeaseConsumedAt: Date,
});
conversationSchema.index(
  { requestId: 1, helperParticipantId: 1 },
  { unique: true, name: "conversation_relationship_unique" }
);
conversationSchema.index({ cleanedAt: 1, checkedAt: 1 });
conversationSchema.index({ requesterParticipantId: 1, closedAt: 1 });
conversationSchema.index({ helperParticipantId: 1, closedAt: 1 });

const messageSchema = new Schema({
  conversationId: { type: Schema.Types.ObjectId, required: true },
  clientMessageId: { type: String, required: true },
  senderParticipantId: { type: Schema.Types.ObjectId, required: true },
  sequence: { type: Number, required: true },
  text: { type: String, required: true, maxlength: 2000, select: false },
  readAt: { type: Date, select: false },
  createdAt: { type: Date, required: true },
});
messageSchema.index(
  { conversationId: 1, sequence: 1 },
  { unique: true, name: "message_sequence_unique" }
);
messageSchema.index(
  { conversationId: 1, senderParticipantId: 1, readAt: 1 },
  { name: "message_unread_by_conversation_recipient" }
);
messageSchema.index(
  { senderParticipantId: 1, clientMessageId: 1 },
  { unique: true, name: "message_sender_identity_unique" }
);

// No TTL: deleting content must never free an operation identity for reuse.
const receiptSchema = new Schema({
  conversationId: { type: Schema.Types.ObjectId, required: true },
  senderParticipantId: { type: Schema.Types.ObjectId, required: true },
  clientMessageId: { type: String, required: true },
  payloadDigest: { type: String, required: true, select: false },
  sequence: { type: Number, required: true },
  createdAt: { type: Date, required: true },
});
receiptSchema.index(
  { senderParticipantId: 1, clientMessageId: 1 },
  { unique: true, name: "message_operation_identity_unique" }
);

export type Conversation = InferSchemaType<typeof conversationSchema>;
export type Message = InferSchemaType<typeof messageSchema>;
export const MessageConversation =
  (mongoose.models.MessageConversation as mongoose.Model<Conversation>) ||
  mongoose.model("MessageConversation", conversationSchema);
export const ConversationMessage =
  (mongoose.models.ConversationMessage as mongoose.Model<Message>) ||
  mongoose.model("ConversationMessage", messageSchema);
export const MessageReceipt =
  (mongoose.models.MessageReceipt as mongoose.Model<InferSchemaType<typeof receiptSchema>>) ||
  mongoose.model("MessageReceipt", receiptSchema);

export async function initializeMessagingIndexes(): Promise<void> {
  await MessageConversation.createIndexes();
  await ConversationMessage.createIndexes();
  await MessageReceipt.createIndexes();
}
