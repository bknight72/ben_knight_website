export async function browserRuntimeReady(response: Response, origin: string) {
  const allowed = response.headers.get("access-control-allow-origin");
  const body = await response.json().catch(() => null);
  // The local Kong gateway replaces the function's CORS header with a wildcard.
  return response.status === 200 && (allowed === origin || allowed === "*") &&
    body?.status === "ok" && body?.database === "connected";
}
