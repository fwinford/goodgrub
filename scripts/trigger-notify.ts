// scripts/trigger-notify.ts
// Purpose: trigger the application's notifySubscribersForRequest flow for the
// most-recent request and print SendLogs/subscriber samples. Useful for local
// testing of notification behavior.
import 'dotenv/config';
import mongoose from 'mongoose';
import { Request as MealRequest, SendLog, Subscriber } from '../models/db.js';

(async ()=>{
  try{
    await mongoose.connect(process.env.MONGO_URI!);
    const req = await MealRequest.findOne().sort({ createdAt: -1 }).exec();
    if(!req){ console.log('no req'); await mongoose.disconnect(); return; }
  console.log('Triggering notify for', (req as any)._id.toString());
  const { notifySubscribersForRequest } = await import('../src/notifySubscribers.js');
    await notifySubscribersForRequest(req as any);
  const logs = await SendLog.find({ requestId: (req as any)._id }).lean().exec();
    console.log('SendLogs:', logs);
    const subs = await Subscriber.find({ status: 'confirmed' }).lean().exec();
    console.log('Subscribers sample:', subs.slice(0,5));
    await mongoose.disconnect();
  }catch(e){ console.error(e); process.exit(1); }
})();
