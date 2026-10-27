export function isReviewRuntime(
  environment: NodeJS.ProcessEnv = process.env
): boolean {
  return environment.NODE_ENV === "review";
}

export class ExternalProviderDisabledError extends Error {
  constructor() {
    super("External providers are disabled in the review runtime");
    this.name = "ExternalProviderDisabledError";
  }
}

export function assertExternalProvidersAllowed(): void {
  if (isReviewRuntime()) throw new ExternalProviderDisabledError();
}
