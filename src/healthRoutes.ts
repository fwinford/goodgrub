import type { Express, Request, Response } from "express";

export function registerHealthRoutes(
  app: Express,
  isReady: () => boolean
): void {
  app.get("/health", (_req: Request, res: Response) => res.send("ok"));
  app.get("/health/live", (_req: Request, res: Response) => res.send("ok"));
  app.get("/health/ready", (_req: Request, res: Response) => {
    if (!isReady()) {
      res.status(503).json({ status: "not-ready" });
      return;
    }
    res.json({ status: "ready" });
  });
}
