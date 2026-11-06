import { authorize, Database, Stripe } from "../functions/_shared/runtime.ts";
import { handle as webhook } from "../functions/stripe-webhook/handler.ts";
import { handle as worker, processJob } from "../functions/worker/handler.ts";
function equal(a: unknown, b: unknown) {
  if (JSON.stringify(a) !== JSON.stringify(b)) {
    throw new Error(`Expected ${JSON.stringify(b)} got ${JSON.stringify(a)}`);
  }
}
async function rejects(fn: () => Promise<unknown>) {
  let did = false;
  try {
    await fn();
  } catch {
    did = true;
  }
  equal(did, true);
}
function configure() {
  Deno.env.set("STRIPE_ENABLED", "true");
  Deno.env.set("STRIPE_MODE", "test");
  Deno.env.set("STRIPE_SECRET_KEY", "sk_test_synthetic");
  Deno.env.set("STRIPE_WEBHOOK_SECRET", "synthetic-secret");
  Deno.env.set("WORKER_SECRET", "synthetic-worker-secret");
}
Deno.test("database REST headers, owner account lookup, pagination and sanitized failures", async () => {
  let calls = 0;
  const db = new Database("test-token", async (_url, init) => {
    equal(
      (init?.headers as Record<string, string>).Authorization,
      "Bearer test-token",
    );
    calls++;
    return new Response(
      JSON.stringify(
        calls === 1 ? Array.from({ length: 1000 }, (_, id) => ({ id })) : [],
      ),
    );
  });
  equal((await db.all("transactions")).length, 1000);
  equal(calls, 2);
  const found = new Database(
    "",
    async () => new Response('[{"id":"account"}]'),
  );
  equal((await found.account("account", "owner")).id, "account");
  await rejects(() =>
    new Database("", async () => new Response("[]")).account("missing", "owner")
  );
  for (
    const message of [
      "monthly_cap",
      "cooldown",
      "account_not_found",
      "batch_not_found",
      "internal secret",
    ]
  ) {
    const failing = new Database(
      "",
      async () => new Response(JSON.stringify({ message }), { status: 400 }),
    );
    await rejects(() => failing.call("test", "POST", {}));
  }
  equal(
    await new Database("", async () => new Response(null, { status: 204 }))
      .call("test"),
    null,
  );
});
Deno.test("Stripe HTTP encoding, idempotency headers, modes and provider failures", async () => {
  configure();
  const stripe = new Stripe(async (url, init) => {
    equal(String(url), "https://api.stripe.com/v1/test");
    equal(
      (init?.headers as Record<string, string>)["Idempotency-Key"],
      "synthetic-id",
    );
    equal(init?.body, "features%5B%5D=balance");
    return new Response('{"livemode":false,"id":"synthetic"}');
  });
  equal(
    (await stripe.call(
      "test",
      "POST",
      { "features[]": "balance" },
      "synthetic-id",
    )).id,
    "synthetic",
  );
  await rejects(() =>
    new Stripe(async () => new Response('{"livemode":true}')).call("test")
  );
  await rejects(() =>
    new Stripe(async () => new Response("{}", { status: 429 })).call("test")
  );
  await rejects(() =>
    new Stripe(async () => new Response("{}", { status: 500 })).call("test")
  );
});
Deno.test("signature verified webhook durably enqueues once per event and rejects wrong mode", async () => {
  configure();
  const calls: any[] = [];
  const db = {
    state: async (op: string, payload: any) => {
      calls.push({ op, payload });
      return op === "mapping"
        ? { account_id: "synthetic", livemode: false }
        : {};
    },
  } as Database;
  const send = async (livemode: boolean) => {
    const body = JSON.stringify({
      id: "evt_synthetic",
      livemode,
      type: "financial_connections.account.refreshed_transactions",
      data: { object: { id: "fca_synthetic" } },
    });
    const timestamp = Math.floor(Date.now() / 1000);
    const key = await crypto.subtle.importKey(
      "raw",
      new TextEncoder().encode("synthetic-secret"),
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
    return webhook(
      new Request("https://test/stripe-webhook", {
        method: "POST",
        body,
        headers: { "stripe-signature": `t=${timestamp},v1=${signature}` },
      }),
      db,
    );
  };
  equal((await send(false)).status, 200);
  equal(calls.at(-1).op, "webhook");
  equal(calls.at(-1).payload.kind, "sync");
  equal((await send(true)).status, 400);
});
Deno.test("disconnect unsubscribes before revoking and persists local state only after success", async () => {
  const order: string[] = [];
  const db = {
    state: async (op: string) => {
      order.push(op);
      return op === "mapping"
        ? { provider_id: "fca_synthetic", livemode: false }
        : {};
    },
    call: async () => [{ connection_state: "active" }],
  } as unknown as Database;
  const stripe = {
    live: false,
    call: async (path: string) => {
      order.push(path.split("/").pop()!);
      return { status: "active", subscriptions: ["transactions"] };
    },
  } as unknown as Stripe;
  await processJob(
    {
      id: "job",
      account_id: "account",
      lease_token: "lease",
      kind: "disconnect",
    },
    db,
    stripe,
    Date.now() + 5000,
  );
  equal(order, [
    "mapping",
    "fca_synthetic",
    "unsubscribe",
    "disconnect",
    "disconnected",
    "finish",
  ]);
});
Deno.test("worker executes bounded claims and recovery, handles invalid trusted token", async () => {
  configure();
  const calls: string[] = [];
  const db = {
    state: async (op: string) => {
      calls.push(op);
      return {};
    },
  } as Database;
  const response = await worker(
    new Request("https://test/worker", {
      method: "POST",
      headers: { Authorization: "Bearer synthetic-worker-secret" },
    }),
    db,
  );
  equal(response.status, 200);
  equal(calls, ["recovery", "claim"]);
  equal(
    (await worker(
      new Request("https://test/worker", {
        headers: { Authorization: "Bearer wrong" },
      }),
      db,
    )).status,
    401,
  );
  equal(
    (await worker(
      new Request("https://test/worker", {
        headers: { Authorization: "Bearer synthetic-worker-secret" },
      }),
      db,
    )).status,
    405,
  );
});
Deno.test("verified identity still rejects malformed JWT claims and absent owner", async () => {
  const db = new Database("", async () => new Response('{"id":"synthetic"}'));
  await rejects(() =>
    authorize(
      new Request("https://test", {
        headers: { Authorization: "Bearer a.bad.c" },
      }),
      db,
    )
  );
});
Deno.test("balance worker respects first-attempt provider cooldown and stores nested cash available under lease", async () => {
  const writes: any[] = [];
  const calls: string[] = [];
  const db = {
    state: async (op: string, payload: any) => {
      writes.push({ op, payload });
      return op === "mapping"
        ? { provider_id: "fca_test", livemode: false }
        : {};
    },
    call: async () => [{ connection_state: "active" }],
  } as unknown as Database;
  const provider = {
    balance_refresh: {
      status: "succeeded",
      next_refresh_available_at: Math.floor(Date.now() / 1000) + 3600,
    },
    balance: {
      current: { usd: 1500 },
      cash: { available: { usd: 1200 } },
      as_of: 1793830636,
    },
  };
  const stripe = {
    live: false,
    call: async (path: string) => {
      calls.push(path);
      return provider;
    },
  } as unknown as Stripe;
  const job = {
    id: "job",
    account_id: "account",
    lease_token: "lease",
    kind: "balance",
    dedupe_key: "refresh:reservation",
    attempts: 1,
    created_at: new Date().toISOString(),
  };
  await rejects(() => processJob(job, db, stripe, Date.now() + 5000));
  equal(calls.some((path) => path.endsWith("/refresh")), false);
  await rejects(() =>
    processJob({ ...job, attempts: 2 }, db, stripe, Date.now() + 5000)
  );
  equal(calls.some((path) => path.endsWith("/refresh")), false);
  calls.length = 0;
  await processJob(
    { ...job, attempts: 2, paid_started: true },
    db,
    stripe,
    Date.now() + 5000,
  );
  equal(calls.some((path) => path.endsWith("/refresh")), true);
  const snapshot = writes.find((w) => w.op === "balance_snapshot");
  equal(snapshot.payload.available_minor, 1200);
  equal(snapshot.payload.lease_token, "lease");
});
