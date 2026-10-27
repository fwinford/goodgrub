import type { NextFunction, Request, Response } from "express";
import { Fulfillment } from "../models/db.js";

export async function getStats(
  _req: Request,
  res: Response,
  next: NextFunction
): Promise<Response | void> {
  try {
    const totalShared = await Fulfillment.countDocuments();
    return res.json({ totalShared });
  } catch (error) {
    next(error);
  }
}
