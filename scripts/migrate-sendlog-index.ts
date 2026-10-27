import mongoose from 'mongoose';
import 'dotenv/config';

const { MONGO_URI } = process.env;
if (!MONGO_URI) {
  console.error('Missing MONGO_URI');
  process.exit(1);
}

async function run() {
  try {
    await mongoose.connect(MONGO_URI as string);
  const db: any = mongoose.connection.db;
  const coll = db.collection('sendlogs');
    console.log('Ensuring unique index on sendlogs(requestId, subscriberId) ...');
    const result = await coll.createIndex({ requestId: 1, subscriberId: 1 }, { unique: true, name: 'request_subscriber_unique' });
    console.log('Index ensured:', result);
    await mongoose.disconnect();
    process.exit(0);
  } catch (err) {
    console.error('Migration failed:', err);
    try { await mongoose.disconnect(); } catch (_) {}
    process.exit(2);
  }
}

run();
