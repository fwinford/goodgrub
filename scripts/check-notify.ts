import 'dotenv/config';
import mongoose from 'mongoose';
import { Request as MealRequest, SendLog, Subscriber } from '../models/db.js';

(async function(){
  try{
    await mongoose.connect(process.env.MONGO_URI!);
    const req = await MealRequest.findOne().sort({ createdAt: -1 }).lean().exec();
    if(!req){
      console.log('No requests found');
      await mongoose.disconnect();
      return;
    }
    console.log('Latest request:');
    console.log({ id: String(req._id), vendor: req.vendor, food: req.food, email: req.email, createdAt: req.createdAt, status: req.status });

    const logs = await SendLog.find({ requestId: req._id }).lean().exec();
    console.log('\nSendLogs for this request:');
    if(!logs.length) console.log('  (none)');
    for(const l of logs){
      console.log({ subscriberId: String(l.subscriberId), status: l.status, error: l.error, sentAt: l.sentAt });
    }

    const subs = await Subscriber.find({ status: 'confirmed' }).lean().limit(50).exec();
    console.log('\nSample confirmed subscribers (first 20):');
    for(const s of subs.slice(0,20)){
      console.log({ id: String(s._id), email: s.email, lastSentAt: s.lastSentAt, dailyCount: s.dailyCount, bounced: s.bounced });
    }

    await mongoose.disconnect();
  }catch(e){
    console.error(e);
    process.exit(1);
  }
})();
