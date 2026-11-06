import { handle } from "../functions/api/handler.ts";
import { Database } from "../functions/_shared/runtime.ts";
const owner = "00000000-0000-4000-8000-000000000001";
function equal(a: unknown, b: unknown) {
  if (JSON.stringify(a) !== JSON.stringify(b)) {
    throw new Error(`Expected ${JSON.stringify(b)} got ${JSON.stringify(a)}`);
  }
}
function request(aal = "aal2", sub = owner) {
  const payload = btoa(JSON.stringify({ sub, aal })).replace(/=/g, "");
  return new Request("https://test/functions/v1/api/api/v1/usage", {
    headers: { authorization: `Bearer header.${payload}.signature` },
  });
}
Deno.test("usage endpoint uses verified caller JWT, denies aal1/wrong owner and has no provider calls", async () => {
  const usage = {
    month: "2026-11",
    reservedAttempts: 2,
    limit: 50,
    remainingAttempts: 48,
    accounts: [],
  };
  const calls: string[] = [];
  const db = new Database("synthetic", async (url, init) => {
    calls.push(String(url));
    if (String(url).endsWith("/auth/v1/user")) {
      return new Response(JSON.stringify({ id: owner }));
    }
    if (String(url).endsWith("/rpc/budget_refresh_usage")) {
      equal(
        (init!.headers as Record<string, string>).Authorization,
        request().headers.get("authorization"),
      );
      return new Response(JSON.stringify(usage));
    }
    return new Response("{}");
  });
  db.state = async (op) => op === "owner" ? { owner_id: owner } : {};
  const response = await handle(request(), db);
  equal(response.status, 200);
  equal(await response.json(), usage);
  equal((await handle(request("aal1"), db)).status, 403);
  equal(
    (await handle(request("aal2", "00000000-0000-4000-8000-000000000002"), db))
      .status,
    403,
  );
  equal(
    (await handle(
      new Request("https://test/functions/v1/api/api/v1/usage"),
      db,
    )).status,
    401,
  );
  equal(calls.some((url) => url.includes("stripe")), false);
});
