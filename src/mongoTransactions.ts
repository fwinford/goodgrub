import type { Connection } from "mongoose";

interface MongoHelloResponse {
  setName?: string;
  msg?: string;
}

export function isTransactionCapableMongo(
  hello: MongoHelloResponse
): boolean {
  return Boolean(hello.setName) || hello.msg === "isdbgrid";
}

/**
 * Fulfillment cannot safely run against a standalone mongod because its Request
 * transition and durable counting record must commit together. Fail startup
 * explicitly instead of discovering this after a helper has placed an order.
 */
export async function assertMongoTransactionsSupported(
  connection: Connection
): Promise<void> {
  if (!connection.db) {
    throw new Error("MongoDB connection is not ready for transaction checks");
  }
  const hello = (await connection.db.admin().command({
    hello: 1,
  })) as MongoHelloResponse;
  if (!isTransactionCapableMongo(hello)) {
    throw new Error(
      "MongoDB transactions require a replica set or sharded cluster; standalone mongod is unsupported"
    );
  }
}
