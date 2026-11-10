import { handle } from "../functions/api/handler.ts";
import { Database } from "../functions/_shared/runtime.ts";
import { ApiError } from "../functions/_shared/core.ts";
const owner = "00000000-0000-4000-8000-000000000001",
  account = "10000000-0000-4000-8000-000000000001";
function equal(a: unknown, b: unknown) {
  if (JSON.stringify(a) !== JSON.stringify(b)) {
    throw new Error(`Expected ${JSON.stringify(b)} got ${JSON.stringify(a)}`);
  }
}
function request(path: string, body?: unknown) {
  const token = `header.${
    btoa(JSON.stringify({ sub: owner, aal: "aal2" })).replace(/=/g, "")
  }.signature`;
  return new Request(`https://test/api/api/v1/${path}`, {
    method: body === undefined ? "GET" : "POST",
    headers: { Authorization: `Bearer ${token}` },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}
class DB extends Database {
  calls: any[] = [];
  customer: any = {};
  session: any = {};
  acceptError = false;
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
    if (op === "session_claim") {
      return { ...this.session, claim_token: "synthetic-claim" };
    }
    if (op === "session_accept") {
      if (this.acceptError) {
        throw new ApiError(503, "provider_unavailable", "Synthetic failure");
      }
      this.session.completion_result = {
        accountIds: [account],
        status: "queued",
      };
      return this.session.completion_result;
    }
    if (op === "session_pending") {
      return {
        sessions: this.session.id && !this.session.completion_result
          ? [{
            sessionId: this.session.id,
            createdAt: "2026-11-10T00:00:00Z",
            status: "pending",
          }]
          : [],
      };
    }
    if (op === "map_account" || op === "mapping") {
      return {
        owner_id: owner,
        account_id: account,
        provider_id: "fca_synthetic",
        livemode: false,
        customer_id: "cus_synthetic",
        subscribed: false,
      };
    }
    if (
      op === "reserve" || op === "disconnect_request" ||
      op === "subscription_retry"
    ) {
      return { requestId: "reservation", status: "queued" };
    }
    return {};
  }
  override async account() {
    return { source: "stripe", connection_state: "active" };
  }
}
Deno.test("session creation and paginated completion atomically queue subscriptions; replay never calls provider", async () => {
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
    const completed = await handle(
      request("connections/complete", { sessionId: "fcsess_synthetic" }),
      db,
    );
    equal(completed.status, 200);
    equal(await completed.json(), { accountIds: [account], status: "queued" });
    equal(db.calls.find((c) => c.op === "session_claim").payload, {
      id: "fcsess_synthetic",
      owner_id: owner,
    });
    equal(db.calls.find((c) => c.op === "session_accept").payload, {
      id: "fcsess_synthetic",
      owner_id: owner,
      claim_token: "synthetic-claim",
      accounts: [{
        provider_id: provider.id,
        name: "Synthetic",
        institution: "Test",
        last_four: "1234",
        kind: "cash",
        livemode: false,
      }],
    });
    equal(
      db.calls.some((c) =>
        ["subscribed", "enqueue", "map_account"].includes(c.op)
      ),
      false,
    );
    equal(calls.some((c) => c.path.endsWith("/subscribe")), false);
    const beforeReplay = calls.length;
    equal(
      await (await handle(
        request("connections/complete", { sessionId: "fcsess_synthetic" }),
        db,
      )).json(),
      { accountIds: [account], status: "queued" },
    );
    equal(calls.length, beforeReplay);
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

Deno.test("pending sessions are owner scoped and completion failure remains resumable without partial mapping", async () => {
  Deno.env.set("STRIPE_ENABLED", "true");
  Deno.env.set("STRIPE_MODE", "test");
  Deno.env.set("STRIPE_SECRET_KEY", "rk_test_synthetic");
  const original = globalThis.fetch;
  const provider = {
    id: "fca_first",
    livemode: false,
    account_holder: { customer: "cus_synthetic" },
    status: "active",
    category: "cash",
    permissions: ["balances", "transactions"],
  };
  try {
    for (
      const scenario of [
        "empty",
        "wrong_customer",
        "wrong_mode",
        "inactive",
        "category",
        "permission",
        "identity",
        "later_page",
        "accept_failure",
      ]
    ) {
      const db = new DB();
      db.session = { id: "fcsess_synthetic", customer_id: "cus_synthetic" };
      db.acceptError = scenario === "accept_failure";
      const paths: string[] = [];
      globalThis.fetch = async (url) => {
        const parsed = new URL(String(url));
        const path = parsed.pathname;
        paths.push(path);
        let result: any = provider;
        if (path.includes("/sessions/")) {
          result = {
            livemode: scenario === "wrong_mode",
            account_holder: {
              customer: scenario === "wrong_customer"
                ? "cus_other"
                : "cus_synthetic",
            },
            accounts: {
              data: scenario === "empty" ? [] : [{ id: "fca_first" }],
              has_more: scenario === "later_page",
            },
          };
        } else if (path.endsWith("/accounts")) {
          equal(parsed.searchParams.get("session"), "fcsess_synthetic");
          equal(parsed.searchParams.get("starting_after"), "fca_first");
          result = { data: [{ id: "fca_second" }], has_more: false };
        } else {
          result = {
            ...provider,
            id: scenario === "identity" ? "fca_other" : path.split("/").at(-1),
            status: scenario === "inactive" || path.endsWith("fca_second")
              ? "inactive"
              : "active",
            category: scenario === "category" ? "investment" : "cash",
            permissions: scenario === "permission"
              ? ["transactions"]
              : provider.permissions,
          };
        }
        return new Response(JSON.stringify(result));
      };
      const pending = await handle(request("connections/pending"), db);
      equal(pending.status, 200);
      equal(await pending.json(), {
        sessions: [{
          sessionId: "fcsess_synthetic",
          createdAt: "2026-11-10T00:00:00Z",
          status: "pending",
        }],
      });
      equal(db.calls.find((c) => c.op === "session_pending").payload, {
        owner_id: owner,
      });
      const failed = await handle(
        request("connections/complete", { sessionId: "fcsess_synthetic" }),
        db,
      );
      equal(failed.status >= 400, true);
      equal(
        db.calls.filter((c) => c.op === "session_accept").length,
        scenario === "accept_failure" ? 1 : 0,
      );
      equal(
        db.calls.some((c) =>
          ["map_account", "enqueue", "subscribed"].includes(c.op)
        ),
        false,
      );
      equal(db.session.completion_result, undefined);
      equal(db.calls.findLast((c) => c.op === "session_release")?.payload, {
        id: "fcsess_synthetic",
        owner_id: owner,
        claim_token: "synthetic-claim",
      });
      equal(paths.some((path) => path.endsWith("/subscribe")), false);
      equal(
        (await (await handle(request("connections/pending"), db)).json())
          .sessions.length,
        1,
      );
    }
  } finally {
    globalThis.fetch = original;
  }
});

Deno.test("session lease conflicts are sanitized and release failures cannot hide durable acceptance", async () => {
  Deno.env.set("STRIPE_ENABLED", "true");
  Deno.env.set("STRIPE_MODE", "test");
  Deno.env.set("STRIPE_SECRET_KEY", "sk_test_synthetic");
  let caught: any;
  // Exercise the database error boundary directly without exposing raw database messages.
  const conflict = new Database(
    "",
    async () => new Response('{"message":"session_busy"}', { status: 400 }),
  );
  try {
    await conflict.state("session_claim", {});
  } catch (error) {
    caught = error;
  }
  equal(caught instanceof ApiError, true);
  equal(caught.code, "completion_busy");
  equal(caught.status, 409);
  const db = new DB();
  db.session = { id: "fcsess_synthetic", customer_id: "cus_synthetic" };
  const state = db.state.bind(db);
  db.state = async (op, payload) => {
    if (op === "session_release") throw new Error("Synthetic response loss");
    return await state(op, payload);
  };
  const original = globalThis.fetch;
  globalThis.fetch = async (url) =>
    new Response(
      JSON.stringify(
        String(url).includes("/sessions/")
          ? {
            livemode: false,
            account_holder: { customer: "cus_synthetic" },
            accounts: { data: [{ id: "fca_synthetic" }], has_more: false },
          }
          : {
            id: "fca_synthetic",
            livemode: false,
            account_holder: { customer: "cus_synthetic" },
            status: "active",
            permissions: ["balances", "transactions"],
            category: "credit",
          },
      ),
    );
  try {
    const response = await handle(
      request("connections/complete", { sessionId: "fcsess_synthetic" }),
      db,
    );
    equal(response.status, 200);
    equal(await response.json(), { accountIds: [account], status: "queued" });
    equal(
      db.calls.find((c) => c.op === "session_accept").payload.accounts[0].kind,
      "credit",
    );
  } finally {
    globalThis.fetch = original;
  }
});

Deno.test("subscription retry requires owner MFA, cost confirmation and enabled activity; no provider dispatch", async () => {
  Deno.env.set("STRIPE_ENABLED", "true");
  Deno.env.set("STRIPE_MODE", "test");
  Deno.env.set("STRIPE_SECRET_KEY", "rk_test_synthetic");
  const db = new DB();
  const original = globalThis.fetch;
  globalThis.fetch = async () => {
    throw new Error(
      "Subscription retry must not dispatch provider calls inline",
    );
  };
  try {
    equal(
      (await handle(request(`accounts/${account}/subscription-retry`, {}), db))
        .status,
      422,
    );
    equal(db.calls.some((c) => c.op === "subscription_retry"), false);
    const response = await handle(
      request(`accounts/${account}/subscription-retry`, { confirmCost: true }),
      db,
    );
    equal(response.status, 202);
    equal(await response.json(), {
      requestId: "reservation",
      status: "queued",
    });
    equal(db.calls.find((c) => c.op === "subscription_retry").payload, {
      account_id: account,
    });
    for (
      const claims of [{ sub: owner, aal: "aal1" }, {
        sub: "other",
        aal: "aal2",
      }]
    ) {
      const req = request(`accounts/${account}/subscription-retry`, {
        confirmCost: true,
      });
      req.headers.set(
        "authorization",
        `Bearer a.${
          btoa(JSON.stringify(claims)).replace(/=/g, "").replace(/\+/g, "-")
            .replace(/\//g, "_")
        }.c`,
      );
      equal((await handle(req, db)).status, 403);
    }
    const anonymous = request(`accounts/${account}/subscription-retry`, {
      confirmCost: true,
    });
    anonymous.headers.delete("authorization");
    equal((await handle(anonymous, db)).status, 401);
    Deno.env.set("STRIPE_ENABLED", "false");
    equal(
      (await handle(
        request(`accounts/${account}/subscription-retry`, {
          confirmCost: true,
        }),
        db,
      )).status,
      503,
    );
    equal(db.calls.filter((c) => c.op === "subscription_retry").length, 1);
  } finally {
    globalThis.fetch = original;
  }
});

Deno.test("all account pages are validated before a single acceptance and failed completion can resume", async () => {
  Deno.env.set("STRIPE_ENABLED", "true");
  Deno.env.set("STRIPE_MODE", "test");
  Deno.env.set("STRIPE_SECRET_KEY", "sk_test_synthetic");
  const db = new DB();
  db.session = { id: "fcsess_synthetic", customer_id: "cus_synthetic" };
  let failSecond = true;
  const original = globalThis.fetch;
  globalThis.fetch = async (url) => {
    const path = new URL(String(url)).pathname;
    let result: any;
    if (path.includes("/sessions/")) {
      result = {
        livemode: false,
        account_holder: { customer: "cus_synthetic" },
        accounts: { data: [{ id: "fca_cash" }], has_more: true },
      };
    } else if (path.endsWith("/accounts")) {
      result = { data: [{ id: "fca_credit" }], has_more: false };
    } else {result = {
        id: path.split("/").at(-1),
        livemode: false,
        account_holder: { customer: "cus_synthetic" },
        status: failSecond && path.endsWith("fca_credit")
          ? "inactive"
          : "active",
        category: path.endsWith("fca_credit") ? "credit" : "cash",
        permissions: ["balances", "transactions"],
        display_name: "x".repeat(140),
        institution_name: "y".repeat(140),
        last4: "invalid",
      };}
    return new Response(JSON.stringify(result));
  };
  try {
    equal(
      (await handle(
        request("connections/complete", { sessionId: "fcsess_synthetic" }),
        db,
      )).status,
      422,
    );
    equal(db.calls.some((c) => c.op === "session_accept"), false);
    failSecond = false;
    equal(
      (await handle(
        request("connections/complete", { sessionId: "fcsess_synthetic" }),
        db,
      )).status,
      200,
    );
    const accepts = db.calls.filter((c) => c.op === "session_accept");
    equal(accepts.length, 1);
    equal(
      accepts[0].payload.accounts.map((
        a: any,
      ) => [
        a.provider_id,
        a.kind,
        a.last_four,
        a.name.length,
        a.institution.length,
      ]),
      [["fca_cash", "cash", null, 120, 120], [
        "fca_credit",
        "credit",
        null,
        120,
        120,
      ]],
    );
    equal(
      (await (await handle(request("connections/pending"), db)).json())
        .sessions,
      [],
    );
  } finally {
    globalThis.fetch = original;
  }
});
