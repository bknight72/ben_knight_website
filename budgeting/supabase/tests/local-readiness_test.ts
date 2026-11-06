import { browserRuntimeReady } from "./local-readiness.ts";

const origin = "http://127.0.0.1:58081";
for (
  const [name, status, allowed, body, expected] of [
    ["exact function origin", 200, origin, {
      status: "ok",
      database: "connected",
    }, true],
    ["local gateway wildcard", 200, "*", {
      status: "ok",
      database: "connected",
    }, true],
    ["missing CORS", 200, null, { status: "ok", database: "connected" }, false],
    ["wrong origin", 200, "http://localhost:58081", {
      status: "ok",
      database: "connected",
    }, false],
    ["origin denied", 403, "*", { code: "origin_denied" }, false],
    [
      "unhealthy database",
      503,
      "*",
      { status: "ok", database: "connected" },
      false,
    ],
    ["disconnected database", 200, "*", {
      status: "ok",
      database: "disconnected",
    }, false],
    ["degraded service", 200, "*", {
      status: "degraded",
      database: "connected",
    }, false],
    ["missing health contract", 200, "*", {}, false],
    ["non-JSON response", 200, "*", "not JSON", false],
  ] as const
) {
  Deno.test(`browser runtime readiness: ${name}`, async () => {
    const response = new Response(
      typeof body === "string" ? body : JSON.stringify(body),
      {
        status,
        headers: allowed ? { "access-control-allow-origin": allowed } : {},
      },
    );
    if (await browserRuntimeReady(response, origin) !== expected) {
      throw new Error(`Unexpected readiness result for ${name}`);
    }
    if (!response.bodyUsed) {
      throw new Error("Readiness left response body unread");
    }
  });
}
