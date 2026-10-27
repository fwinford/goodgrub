#!/usr/bin/env tsx
import mongoose from 'mongoose';
import 'dotenv/config';
// Import models via the project's models entry (use .js specifier so tsx resolves correctly)
const mod = await import('../models/db.js');
const { Request } = mod;
import { formatMealRequestWindow } from '../src/utils/date.js';

async function main() {
  const uri = process.env.MONGO_URI;
  if (!uri) {
    console.error('MONGO_URI is required in env to run this script');
    process.exit(1);
  }

  await mongoose.connect(uri);
  console.log('Connected to DB');

  // Find requests that have a human pickupWindowText or windowStart/windowEnd
  const docs = await Request.find({ pickupWindowText: { $exists: true, $ne: '' } }).lean().exec();
  console.log(`Found ${docs.length} requests with pickupWindowText`);

  let mismatches = 0;
  for (const d of docs) {
    const expected = formatMealRequestWindow(d.windowStart, d.windowEnd, d.pickupWindowText);
    const actual = String(d.pickupWindowText || '').trim();
    if (expected.trim() !== actual) {
      mismatches++;
      console.log('--- MISMATCH ---');
      console.log('id:', String(d._id));
      console.log('pickupWindowText:', actual);
      console.log('windowStart:', d.windowStart);
      console.log('windowEnd:  ', d.windowEnd);
      console.log('formatted:', expected);
    }
  }

  console.log(`Done. Mismatches: ${mismatches}`);
  await mongoose.disconnect();
}

main().catch(err => {
  console.error('Audit failed:', err);
  process.exit(1);
});
