import { handle } from "../functions/api/handler.ts";
import { Database } from "../functions/_shared/runtime.ts";
const owner = "00000000-0000-4000-8000-000000000001",
  account = "10000000-0000-4000-8000-000000000001";
function equal(a: unknown, b: unknown) {
  if (JSON.stringify(a) !== JSON.stringify(b)) {
    throw new Error(`Expected ${JSON.stringify(b)} got ${JSON.stringify(a)}`);
  }
}
function request(path: string, body: unknown) {
  const token = `header.${
    btoa(JSON.stringify({ sub: owner, aal: "aal2" })).replace(/=/g, "")
  }.signature`;
  return new Request(`https://test/api/api/v1/${path}`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}` },
    body: JSON.stringify(body),
  });
}
class DB extends Database {
  calls: any[] = [];
  customer: any = {};
  session: any = {};
  constructor() {
    super("synthetic", async () => new Response(JSON.stringify({ id: owner })));
  }
  override async state(op: string, payload: any = {}) {
    this.calls.push({ op, payload });
    if (op === "owner") return { owner_id: owner };
    if (op === "customer_get") return this.customer;
    if (op === "customer_put") {
      this.customer = payload;
      return payload;
    }
    if (op === "session_put") {
      this.session = payload;
      return {};
    }
    if (op === "session_get") return this.session;
    if (op === "map_account" || op === "mapping") {
      return {
        owner_id: owner,
        account_id: account,
        provider_id: "fca_synthetic",
        livemode: false,
        subscribed: false,
      };
    }
    if (op === "reserve" || op === "disconnect_request") {
      return { requestId: "reservation", status: "queued" };
    }
    return {};
  }
  override async account() {
    return { source: "stripe", connection_state: "active" };
  }
}
Deno.test("session creation, owned completion pagination, subscription and capped refresh contracts", async () => {
  Deno.env.set("STRIPE_ENABLED", "true");
  Deno.env.set("STRIPE_MODE", "test");
  Deno.env.set("STRIPE_SECRET_KEY", "sk_test_synthetic");
  const original = globalThis.fetch;
  const calls: { path: string; body: string }[] = [];
  const db = new DB();
  const provider = {
    id: "fca_synthetic",
    livemode: false,
    account_holder: { customer: "cus_synthetic" },
    status: "active",
    permissions: ["balances", "transactions"],
    category: "cash",
    last4: "1234",
    display_name: "Synthetic",
    institution_name: "Test",
    balance_refresh: { next_refresh_available_at: 1 },
  };
  globalThis.fetch = async (url, init) => {
    const path = new URL(String(url)).pathname;
    calls.push({ path, body: String(init?.body || "") });
    let result: any = {};
    if (path === "/v1/customers") {
      result = { id: "cus_synthetic", livemode: false };
    } else if (path === "/v1/financial_connections/sessions") {
      result = {
        id: "fcsess_synthetic",
        client_secret: "synthetic-client-secret",
        livemode: false,
      };
    } else if (path === "/v1/financial_connections/sessions/fcsess_synthetic") {
      result = {
        livemode: false,
        account_holder: { customer: "cus_synthetic" },
        accounts: { data: [{ id: "fca_synthetic" }], has_more: true },
      };
    } else if (path === "/v1/financial_connections/accounts") {
      result = { data: [], has_more: false };
    } else result = provider;
    return new Response(JSON.stringify(result));
  };
  try {
    const session = await handle(request("connections/session", {}), db);
    equal(session.status, 200);
    equal((await session.json()).clientSecret, "synthetic-client-secret");
    equal(calls[1].body.includes("prefetch"), false);
    equal(calls[1].body.includes("payment"), false);
    equal(
      (await handle(
        request("connections/complete", { sessionId: "fcsess_synthetic" }),
        db,
      )).status,
      200,
    );
    equal(db.calls.some((c) => c.op === "subscribed"), true);
    equal(db.calls.some((c) => c.op === "enqueue"), true);
    equal(
      (await handle(
        request(`accounts/${account}/balance-refresh`, { confirmCost: true }),
        db,
      )).status,
      202,
    );
    equal(db.calls.some((c) => c.op === "reserve"), true);
    equal(calls.some((c) => c.path.endsWith("/refresh")), false);
    equal(
      (await handle(request(`accounts/${account}/balance-refresh`, {}), db))
        .status,
      422,
    );
    equal(
      (await handle(request(`accounts/${account}/disconnect`, {}), db)).status,
      202,
    );
    equal(
      (await handle(
        request(`accounts/${account}/delete`, { confirmDelete: true }),
        db,
      )).status,
      202,
    );
    equal(db.calls.at(-2).payload.delete_local, true);
    db.session = {};
    equal(
      (await handle(
        request("connections/complete", { sessionId: "fcsess_guessed" }),
        db,
      )).status,
      404,
    );
  } finally {
    globalThis.fetch = original;
    Deno.env.delete("STRIPE_ENABLED");
  }
});
