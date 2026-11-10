import { ApiError, stripeMode } from "../functions/_shared/core.ts";
import { Database, Stripe } from "../functions/_shared/runtime.ts";
import { handle as worker, processJob } from "../functions/worker/handler.ts";
import { handle as webhook } from "../functions/stripe-webhook/handler.ts";

function equal(actual: unknown, expected: unknown) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(
      `Expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`,
    );
  }
}
async function code(action: () => unknown, expected: string) {
  try {
    await action();
  } catch (error) {
    equal(error instanceof ApiError ? error.code : String(error), expected);
    return;
  }
  throw new Error(`Expected ${expected}`);
}
function configure(enabled = true) {
  Deno.env.set("STRIPE_ENABLED", String(enabled));
  Deno.env.set("STRIPE_MODE", "test");
  Deno.env.set("STRIPE_SECRET_KEY", "rk_test_synthetic");
  Deno.env.set("WORKER_SECRET", "synthetic-worker");
  Deno.env.set("STRIPE_WEBHOOK_SECRET", "synthetic-hook");
}
function fixture() {
  const writes: { op: string; payload: any }[] = [];
  const calls: {
    path: string;
    method?: string;
    params?: unknown;
    key?: string;
  }[] = [];
  const mapping = {
    provider_id: "fca_synthetic",
    customer_id: "cus_synthetic",
    livemode: false,
    disconnect_requested_at: null as string | null,
  };
  let provider: any = {
    id: "fca_synthetic",
    livemode: false,
    account_holder: { customer: "cus_synthetic" },
    status: "active",
    permissions: ["balances", "transactions"],
    subscriptions: [],
    transaction_refresh: { status: "succeeded" },
    balance_refresh: { status: "succeeded" },
    balance: { current: { usd: 100 }, as_of: 1793830636 },
  };
  const state = { connection_state: "active" };
  const db = {
    state: async (op: string, payload: any) => {
      writes.push({ op, payload });
      return op === "mapping" ? mapping : {};
    },
    call: async () => [state],
  } as unknown as Database;
  const stripe = {
    live: false,
    requireActivity: () => {},
    call: async (
      path: string,
      method?: string,
      params?: unknown,
      key?: string,
    ) => {
      calls.push({ path, method, params, key });
      if (path.endsWith("/subscribe")) {
        provider = { ...provider, subscriptions: ["transactions"] };
      }
      if (path.endsWith("/unsubscribe")) {
        provider = { ...provider, subscriptions: [] };
      }
      if (path.endsWith("/disconnect")) {
        provider = { ...provider, status: "disconnected" };
      }
      if (path.endsWith("/transactions")) return { data: [], has_more: false };
      return structuredClone(provider);
    },
  } as unknown as Stripe;
  const job = {
    id: "synthetic-job",
    account_id: "synthetic-account",
    kind: "subscribe",
    lease_token: "synthetic-lease",
    dedupe_key: "subscribe:stable",
    created_at: new Date().toISOString(),
  };
  return { writes, calls, mapping, provider, state, db, stripe, job };
}

Deno.test("subscribe reads authoritative state around leased POST with durable key; replay skips POST", async () => {
  const f = fixture();
  await processJob(f.job, f.db, f.stripe, Date.now() + 5000);
  equal(f.calls.map((c) => c.method || "GET"), ["GET", "POST", "GET"]);
  equal(f.calls[1].key, "subscribe:stable");
  equal(f.writes.filter((w) => w.op !== "job_renew").map((w) => w.op), [
    "mapping",
    "subscribe_started",
    "subscribe_finish",
  ]);
  equal(f.writes.find((w) => w.op === "subscribe_started")?.payload, {
    id: f.job.id,
    lease_token: f.job.lease_token,
  });
  f.calls.length = 0;
  await processJob(f.job, f.db, f.stripe, Date.now() + 5000);
  equal(f.calls.map((c) => c.method || "GET"), ["GET"]);
});

Deno.test("subscribe rejects cached POST success until authoritative subscription appears", async () => {
  const f = fixture();
  f.stripe.call = async (_path, method) =>
    method === "POST"
      ? { ...f.provider, subscriptions: ["transactions"] }
      : f.provider;
  await code(
    () => processJob(f.job, f.db, f.stripe, Date.now() + 5000),
    "subscription_pending",
  );
  equal(f.writes.some((w) => w.op === "subscribe_finish"), false);
});

Deno.test("lease rejection prevents subscribe side effects", async () => {
  const f = fixture();
  const original = f.db.state.bind(f.db);
  f.db.state = async (op, payload) => {
    if (op === "subscribe_started") {
      throw new ApiError(409, "lease_lost", "Synthetic lease loss");
    }
    return await original(op, payload);
  };
  await code(
    () => processJob(f.job, f.db, f.stripe, Date.now() + 5000),
    "lease_lost",
  );
  equal(f.calls.some((c) => c.method === "POST"), false);
});

Deno.test("every active worker operation rejects wrong customer, mode, status and permissions", async () => {
  for (const kind of ["subscribe", "sync", "balance"]) {
    for (
      const [patch, error] of [
        [{ account_holder: { customer: "cus_other" } }, "mapping_mismatch"],
        [{ livemode: true }, "mapping_mismatch"],
        [{ status: "inactive" }, "connection_inactive"],
        [{ permissions: ["balances"] }, "connection_inactive"],
        [{ permissions: ["transactions"] }, "connection_inactive"],
      ] as const
    ) {
      const f = fixture();
      Object.assign(f.provider, patch);
      await code(
        () => processJob({ ...f.job, kind }, f.db, f.stripe, Date.now() + 5000),
        error,
      );
      equal(f.calls.some((c) => c.method === "POST"), false);
      equal(
        f.writes.some((w) =>
          ["subscribe_finish", "balance_snapshot", "page", "finish"].includes(
            w.op,
          )
        ),
        false,
      );
    }
  }
});

Deno.test("disconnect intent suppresses queued activity without restoring subscriptions or buying balance", async () => {
  for (const kind of ["subscribe", "sync", "balance"]) {
    const f = fixture();
    f.mapping.disconnect_requested_at = "2026-11-10T00:00:00Z";
    await processJob({ ...f.job, kind }, f.db, f.stripe, Date.now() + 5000);
    equal(f.calls.length, 0);
    equal(f.writes.at(-1)?.op, "finish");
  }
});

Deno.test("lifecycle uses retrieved provider status, not webhook assertion or local status", async () => {
  for (const status of ["active", "inactive", "disconnected"]) {
    const f = fixture();
    f.provider.status = status;
    await processJob(
      { ...f.job, kind: "lifecycle", provider_status: "forged" },
      f.db,
      f.stripe,
      Date.now() + 5000,
    );
    equal(f.writes.at(-1), {
      op: "lifecycle",
      payload: {
        id: f.job.id,
        lease_token: f.job.lease_token,
        provider_status: status,
      },
    });
    equal(f.calls.length, 1);
  }
});

Deno.test("disconnect reads after unsubscribe and revoke; incomplete cleanup cannot mark local disconnected", async () => {
  const f = fixture();
  f.provider.subscriptions = ["transactions"];
  await processJob(
    { ...f.job, kind: "disconnect" },
    f.db,
    f.stripe,
    Date.now() + 5000,
  );
  equal(f.calls.map((c) => c.path.split("/").at(-1)), [
    "fca_synthetic",
    "unsubscribe",
    "disconnect",
    "fca_synthetic",
  ]);
  equal(f.writes.filter((w) => w.op !== "job_renew").map((w) => w.op), [
    "mapping",
    "disconnected",
    "finish",
  ]);
  const bad = fixture();
  bad.stripe.call = async () => ({
    ...bad.provider,
    status: "disconnected",
    subscriptions: ["transactions"],
  });
  await code(
    () =>
      processJob(
        { ...bad.job, kind: "disconnect" },
        bad.db,
        bad.stripe,
        Date.now() + 5000,
      ),
    "provider_unavailable",
  );
  equal(bad.writes.some((w) => w.op === "disconnected"), false);
});

Deno.test("pending and terminal refresh failures remain distinct; missing USD never writes zero", async () => {
  for (
    const [kind, field, status, error] of [
      ["sync", "transaction_refresh", "pending", "transactions_not_ready"],
      ["sync", "transaction_refresh", "failed", "transactions_failed"],
      ["balance", "balance_refresh", "pending", "balance_not_ready"],
      ["balance", "balance_refresh", "failed", "balance_failed"],
    ]
  ) {
    const f = fixture();
    f.provider[field] = { status };
    await code(
      () => processJob({ ...f.job, kind }, f.db, f.stripe, Date.now() + 5000),
      error,
    );
    equal(
      f.writes.some((w) =>
        ["page", "balance_snapshot", "finish"].includes(w.op)
      ),
      false,
    );
  }
  for (const balance of [null, { current: { eur: 100 } }]) {
    const f = fixture();
    f.provider.balance = balance;
    await code(
      () =>
        processJob(
          { ...f.job, kind: "balance" },
          f.db,
          f.stripe,
          Date.now() + 5000,
        ),
      "balance_unavailable",
    );
    equal(f.writes.some((w) => w.op === "balance_snapshot"), false);
  }
});

Deno.test("correlated authoritative balance success recovers accepted refresh despite cached POST failure and expiry", async () => {
  const dispatch = Math.floor(Date.now() / 1000) - 25 * 3600;
  for (const baseline of [dispatch - 60, null]) {
    const f = fixture();
    f.provider.balance = {
      current: { usd: 2300 },
      cash: { available: { usd: 2100 } },
      as_of: dispatch + 1,
    };
    const call = f.stripe.call.bind(f.stripe);
    f.stripe.call = async (path, method, params, key) => {
      if (method === "POST") {
        throw new ApiError(
          503,
          "provider_unavailable",
          "Synthetic cached Stripe 500",
        );
      }
      return await call(path, method, params, key);
    };
    await processJob(
      {
        ...f.job,
        kind: "balance",
        dedupe_key: "refresh:stable",
        paid_started: true,
        balance_baseline: baseline,
        balance_dispatch_at: new Date(dispatch * 1000).toISOString(),
        created_at: new Date((dispatch - 1) * 1000).toISOString(),
      },
      f.db,
      f.stripe,
      Date.now() + 5000,
    );
    equal(f.calls.map((c) => c.method || "GET"), ["GET"]);
    equal(f.writes.some((w) => w.op === "balance_started"), false);
    equal(f.writes.find((w) => w.op === "balance_snapshot")?.payload, {
      id: f.job.id,
      lease_token: f.job.lease_token,
      current_minor: 2300,
      available_minor: 2100,
      observed_at: new Date((dispatch + 1) * 1000).toISOString(),
    });
    equal(f.writes.at(-1)?.op, "finish");
  }
});

Deno.test("uncorrelated balance success must replay stable key within cutoff and expire without writing after cutoff", async () => {
  const dispatch = Math.floor(Date.now() / 1000) - 60;
  const scenarios = [
    {
      balance_dispatch_at: new Date(dispatch * 1000).toISOString(),
      balance_baseline: dispatch,
      as_of: dispatch,
    },
    {
      balance_dispatch_at: new Date(dispatch * 1000).toISOString(),
      balance_baseline: dispatch - 120,
      as_of: dispatch - 1,
    },
    {
      balance_dispatch_at: undefined,
      balance_baseline: dispatch - 120,
      as_of: dispatch + 1,
    },
    {
      balance_dispatch_at: "invalid-date",
      balance_baseline: dispatch - 120,
      as_of: dispatch + 1,
    },
    {
      balance_dispatch_at: new Date(dispatch * 1000).toISOString(),
      balance_baseline: null,
      as_of: dispatch - 1,
    },
  ];
  for (const scenario of scenarios) {
    for (const expired of [false, true]) {
      const f = fixture();
      f.provider.balance.as_of = scenario.as_of;
      const job = {
        ...f.job,
        kind: "balance",
        dedupe_key: "refresh:stable",
        paid_started: true,
        balance_dispatch_at: scenario.balance_dispatch_at,
        balance_baseline: scenario.balance_baseline,
        created_at: new Date(Date.now() - (expired ? 24 : 1) * 3600000)
          .toISOString(),
      };
      if (expired) {
        await code(
          () => processJob(job, f.db, f.stripe, Date.now() + 5000),
          "refresh_expired",
        );
        equal(f.calls.some((c) => c.method === "POST"), false);
        equal(
          f.writes.some((w) =>
            ["balance_started", "balance_snapshot", "finish"].includes(w.op)
          ),
          false,
        );
      } else {
        const call = f.stripe.call.bind(f.stripe);
        f.stripe.call = async (path, method, params, key) => {
          const response = await call(path, method, params, key);
          if (method === "POST") {
            throw new ApiError(
              503,
              "provider_unavailable",
              "Synthetic cached Stripe 500",
            );
          }
          return response;
        };
        await code(
          () => processJob(job, f.db, f.stripe, Date.now() + 5000),
          "provider_unavailable",
        );
        equal(f.calls.map((c) => c.method || "GET"), ["GET", "POST"]);
        equal(f.calls.at(-1)?.key, "refresh:stable");
        equal(f.writes.find((w) => w.op === "balance_started")?.payload, {
          id: f.job.id,
          lease_token: f.job.lease_token,
          baseline_as_of: scenario.as_of,
        });
        equal(f.writes.some((w) => w.op === "balance_snapshot"), false);
      }
    }
  }
});

Deno.test("first paid dispatch records only a valid baseline; fresh timestamp without succeeded status cannot recover", async () => {
  for (const asOf of [1793830636, undefined, "1793830636", 1.5]) {
    const f = fixture();
    f.provider.balance.as_of = asOf;
    f.provider.balance_refresh.next_refresh_available_at = 1;
    const call = f.stripe.call.bind(f.stripe);
    f.stripe.call = async (path, method, params, key) => {
      const response = await call(path, method, params, key);
      if (method === "POST") {
        throw new ApiError(
          503,
          "provider_unavailable",
          "Synthetic uncertain dispatch",
        );
      }
      return response;
    };
    await code(
      () =>
        processJob(
          { ...f.job, kind: "balance", dedupe_key: "refresh:stable" },
          f.db,
          f.stripe,
          Date.now() + 5000,
        ),
      "provider_unavailable",
    );
    equal(f.writes.find((w) => w.op === "balance_started")?.payload, {
      id: f.job.id,
      lease_token: f.job.lease_token,
      baseline_as_of: Number.isSafeInteger(asOf) ? asOf : null,
    });
    equal(f.calls.at(-1)?.key, "refresh:stable");
  }
  for (const status of ["pending", "failed"]) {
    const f = fixture();
    const dispatch = Math.floor(Date.now() / 1000) - 25 * 3600;
    f.provider.balance.as_of = dispatch + 1;
    f.provider.balance_refresh.status = status;
    await code(() =>
      processJob(
        {
          ...f.job,
          kind: "balance",
          dedupe_key: "refresh:stable",
          paid_started: true,
          balance_baseline: dispatch - 1,
          balance_dispatch_at: new Date(dispatch * 1000).toISOString(),
          created_at: new Date(dispatch * 1000).toISOString(),
        },
        f.db,
        f.stripe,
        Date.now() + 5000,
      ), "refresh_expired");
    equal(f.writes.some((w) => w.op === "balance_snapshot"), false);
  }
});

Deno.test("restricted keys support enabled activity and disabled cleanup without relaxing live authorization", async () => {
  for (const prefix of ["sk", "rk"]) {
    const values: Record<string, string> = {
      STRIPE_ENABLED: "true",
      STRIPE_MODE: "test",
      STRIPE_SECRET_KEY: `${prefix}_test_synthetic`,
    };
    equal(stripeMode((key) => values[key]), { enabled: true, live: false });
    values.STRIPE_ENABLED = "false";
    equal(stripeMode((key) => values[key], true).live, false);
    values.STRIPE_MODE = "live";
    values.STRIPE_SECRET_KEY = `${prefix}_live_synthetic`;
    await code(
      () => stripeMode((key) => values[key], true),
      "live_not_authorized",
    );
    values.STRIPE_LIVE_AUTHORIZED = "true";
    equal(stripeMode((key) => values[key], true).live, true);
  }
  configure(false);
  await code(() => stripeMode(() => undefined, true), "stripe_configuration");
  await code(
    () =>
      stripeMode((key) =>
        ({
          STRIPE_MODE: "test",
          STRIPE_SECRET_KEY: "rk_live_synthetic",
        } as Record<string, string>)[key], true),
    "stripe_configuration",
  );
  const stripe = new Stripe(
    async () => new Response('{"livemode":false}'),
    true,
  );
  await code(() => stripe.requireActivity(), "stripe_disabled");
  equal(await stripe.call("synthetic"), { livemode: false });
});

Deno.test("provider retries retain stable headers and classify terminal versus transient failures", async () => {
  configure();
  for (
    const [status, expected, attempts] of [[429, "provider_rate_limited", 3], [
      503,
      "provider_unavailable",
      3,
    ], [403, "provider_rejected", 1]] as const
  ) {
    let calls = 0;
    const stripe = new Stripe(async (_url, init) => {
      calls++;
      const headers = init?.headers as Record<string, string>;
      equal(headers["Idempotency-Key"], "subscribe:durable");
      equal(headers["Stripe-Version"], "2024-06-20");
      equal(headers.Authorization, "Bearer rk_test_synthetic");
      return new Response('{"error":{"message":"synthetic private detail"}}', {
        status,
      });
    });
    await code(
      () =>
        stripe.call(
          "financial_connections/accounts/fca_synthetic/subscribe",
          "POST",
          { "features[]": "transactions" },
          "subscribe:durable",
        ),
      expected,
    );
    equal(calls, attempts);
  }
  let calls = 0;
  const eventual = new Stripe(async () => {
    calls++;
    if (calls === 1) throw new TypeError("Synthetic network interruption");
    return new Response('{"livemode":false,"id":"fca_synthetic"}');
  });
  equal((await eventual.call("synthetic")).id, "fca_synthetic");
  equal(calls, 2);
});

Deno.test("worker persists ApiError codes, not messages, and cleanup remains runnable disabled", async () => {
  configure(false);
  const f = fixture();
  const original = globalThis.fetch;
  const state = f.db.state.bind(f.db);
  let claimed = false;
  f.db.state = async (op, payload) => {
    if (op === "claim") {
      if (claimed) return {};
      claimed = true;
      return { ...f.job, kind: "lifecycle" };
    }
    return await state(op, payload);
  };
  globalThis.fetch = async () =>
    new Response(JSON.stringify({ ...f.provider, livemode: true }));
  try {
    const response = await worker(
      new Request("https://synthetic.test/worker", {
        method: "POST",
        headers: { Authorization: "Bearer synthetic-worker" },
      }),
      f.db,
    );
    equal(await response.json(), { processed: 0, failed: 1 });
    equal(
      f.writes.find((w) => w.op === "retry")?.payload.error,
      "mode_mismatch",
    );
  } finally {
    globalThis.fetch = original;
  }
});

Deno.test("signed disabled-mode lifecycle webhooks enqueue reconciliation for disconnect/deactivate/reactivate", async () => {
  configure(false);
  for (const event of ["disconnected", "deactivated", "reactivated"]) {
    const f = fixture();
    const original = f.db.state.bind(f.db);
    f.db.state = async (op, payload) =>
      op === "mapping"
        ? { account_id: "synthetic-account", livemode: false }
        : await original(op, payload);
    const body = JSON.stringify({
      id: `evt_${event}`,
      livemode: false,
      type: `financial_connections.account.${event}`,
      data: { object: { id: "fca_synthetic", status: "forged" } },
    });
    const timestamp = Math.floor(Date.now() / 1000);
    const key = await crypto.subtle.importKey(
      "raw",
      new TextEncoder().encode("synthetic-hook"),
      { name: "HMAC", hash: "SHA-256" },
      false,
      ["sign"],
    );
    const signature = [
      ...new Uint8Array(
        await crypto.subtle.sign(
          "HMAC",
          key,
          new TextEncoder().encode(`${timestamp}.${body}`),
        ),
      ),
    ].map((b) => b.toString(16).padStart(2, "0")).join("");
    const response = await webhook(
      new Request("https://synthetic.test/hook", {
        method: "POST",
        body,
        headers: { "stripe-signature": `t=${timestamp},v1=${signature}` },
      }),
      f.db,
    );
    equal(response.status, 200);
    equal(f.writes.at(-1)?.payload, {
      id: `evt_${event}`,
      type: `financial_connections.account.${event}`,
      account_id: "synthetic-account",
      kind: "lifecycle",
    });
  }
});
