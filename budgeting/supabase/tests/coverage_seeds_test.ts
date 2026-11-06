// Execute production entrypoints with serve intercepted, not excluded from the coverage denominator.
Deno.test("all production Edge entrypoints register a handler", async () => {
  const serve = Deno.serve;
  let registrations = 0;
  Deno.serve = ((handler: unknown) => {
    if (typeof handler !== "function") throw new Error("Missing handler");
    registrations++;
    return {} as Deno.HttpServer;
  }) as typeof Deno.serve;
  try {
    await import("../functions/api/index.ts");
    await import("../functions/stripe-webhook/index.ts");
    await import("../functions/worker/index.ts");
  } finally {
    Deno.serve = serve;
  }
  if (registrations !== 3) {
    throw new Error("Expected all three production entrypoints");
  }
});
