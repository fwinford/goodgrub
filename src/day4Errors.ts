import type { Response } from "express";

export interface Day4Error {
  error: {
    code: string;
    message: string;
    fields: null;
  };
}

export function day4Error(code: string, message: string): Day4Error {
  return {
    error: {
      code,
      message,
      fields: null,
    },
  };
}

export function sendDay4Error(
  res: Response,
  status: number,
  code: string,
  message: string
): Response {
  return res.status(status).json(day4Error(code, message));
}

