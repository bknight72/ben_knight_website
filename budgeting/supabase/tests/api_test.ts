import { handle, routeName } from "../functions/api/handler.ts";
import { authorize, Database, Stripe } from "../functions/_shared/runtime.ts";
import { processJob } from "../functions/worker/handler.ts";
import { handle as webhook } from "../functions/stripe-webhook/handler.ts";
import { handle as worker } from "../functions/worker/handler.ts";
const owner = "00000000-0000-4000-8000-000000000001",
  account = "10000000-0000-4000-8000-000000000001";
function equal(a: unknown, b: unknown) {
  if (JSON.stringify(a) !== JSON.stringify(b)) {
    throw new Error(`Expected ${JSON.stringify(b)} got ${JSON.stringify(a)}`);
  }
}
function token(aal = "aal2", sub = owner) {
  return `header.${
    btoa(JSON.stringify({ sub, aal })).replace(/=/g, "").replace(/\+/g, "-")
      .replace(/\//g, "_")
  }.signature`;
}
function request(path: string, body?: unknown, auth = true) {
  return new Request(`https://example.test/functions/v1/api${path}`, {
    method: body === undefined ? "GET" : "POST",
    headers: auth ? { Authorization: `Bearer ${token()}` } : {},
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}
class MockDB extends Database {
  calls: { op: string; payload: any }[] = [];
  claimsOwner = owner;
  accountSource = "manual";
  rows: any[] = [];
  constructor() {
    super("synthetic", async () => new Response(JSON.stringify({ id: owner })));
  }
  override async state(op: string, payload: any = {}) {
    this.calls.push({ op, payload });
    if (op === "owner") return { owner_id: this.claimsOwner };
    if (op === "metrics") return [];
    if (op === "mapping") {
      return {
        provider_id: "fca_synthetic",
        owner_id: owner,
        account_id: account,
        livemode: false,
        customer_id: "cus_synthetic",
      };
    }
    if (op === "import") {
      return { batchId: "batch", inserted: payload.rows.length, duplicates: 0 };
    }
    return {};
  }
  override async account(a: string, o: string) {
    if (a !== account || o !== owner) throw new Error("not found");
    return {
      id: account,
      owner_id: owner,
      source: this.accountSource,
      connection_state: "active",
    };
  }
  override async call(path: string, _method = "GET", _body?: unknown) {
    if (path.startsWith("accounts?")) {
      return [{ id: account, connection_state: "active" }];
    }
    if (path.startsWith("transactions?")) return this.rows;
    return [];
  }
}
Deno.test("API anonymous observability and route normalization do not expose identifiers", async () => {
  const db = new MockDB();
  for (const path of ["/health", "/metrics", "/openapi.json", "/docs"]) {
    equal((await handle(request(path, undefined, false), db)).status, 200);
  }
  equal(
    routeName(`/api/v1/accounts/${account}/balance-refresh`),
    "/api/v1/accounts/:id/balance-refresh",
  );
  equal(routeName("/unexpected/financial-name"), "unmatched");
  equal(
    (await handle(request("/api/v1/export", undefined, false), db)).status,
    401,
  );
  equal(
    (await handle(
      new Request("https://test/api/api/v1/export", {
        headers: { origin: "https://evil.test" },
      }),
      db,
    )).status,
    403,
  );
});
Deno.test("API owner and aal2 required after verified GoTrue identity", async () => {
  const db = new MockDB();
  for (
    const [aal, sub, status] of [["aal1", owner, 403], ["aal2", "other", 403], [
      "aal2",
      owner,
      200,
    ]] as const
  ) {
    const req = new Request("https://test/api/api/v1/imports/preview", {
      method: "POST",
      headers: { Authorization: `Bearer ${token(aal, sub)}` },
      body: JSON.stringify({
        accountId: account,
        csv: "Date,Description,Amount\n2026-01-01,Test,-1",
        mapping: {
          date: "Date",
          description: "Description",
          amount: "Amount",
          dateFormat: "YYYY-MM-DD",
          sign: "inflow-positive",
        },
      }),
    });
    equal((await handle(req, db)).status, status);
  }
  const expired = new Database(
    "",
    async () => new Response("{}", { status: 401 }),
  );
  let denied = false;
  try {
    await authorize(request("/api/v1/export"), expired);
  } catch {
    denied = true;
  }
  equal(denied, true);
});
Deno.test("portable export includes owner-scoped source exclusions and unchanged financial tables", async () => {
  const db = new MockDB();
  const tables: string[] = [];
  const exclusion = {
    id: "30000000-0000-4000-8000-000000000001",
    owner_id: owner,
    month: "2026-11-01",
    source_transaction_id: "20000000-0000-4000-8000-000000000001",
  };
  db.all = async (table, query) => {
    equal(query, `&owner_id=eq.${owner}`);
    tables.push(table);
    return table === "budgeteer_source_exclusions" ? [exclusion] : [];
  };
  const response = await handle(request("/api/v1/export"), db);
  equal(response.status, 200);
  const data = await response.json();
  equal(data.version, 1);
  equal(data.budgeteer_source_exclusions, [exclusion]);
  equal(tables, [
    "profiles",
    "accounts",
    "balance_snapshots",
    "transactions",
    "transaction_annotations",
    "categories",
    "monthly_budgets",
    "import_batches",
    "budgeteer_plans",
    "budgeteer_groups",
    "budgeteer_entries",
    "budgeteer_labels",
    "budgeteer_entry_labels",
    "budgeteer_source_exclusions",
  ]);
  const schema =
    await (await handle(request("/openapi.json", undefined, false), db)).json();
  equal(
    schema.components.schemas.BudgeteerState.properties.excluded_source_count
      .minimum,
    0,
  );
  equal(
    schema.components.schemas.BudgeteerMutation.properties.p_operation.enum
      .includes("sources_include"),
    true,
  );
  equal(
    schema.components.schemas.BudgeteerMutation.properties.p_operation.enum
      .includes("sources_restore"),
    true,
  );
  equal(
    schema.paths["/api/v1/export"].get.responses["200"]
      .content["application/json"].schema.properties.budgeteer_source_exclusions
      .items.$ref,
    "#/components/schemas/BudgeteerSourceExclusion",
  );
});
Deno.test("commit revalidates CSV, requires overlap confirmation, rejects provider overlap", async () => {
  const db = new MockDB();
  const payload = {
    accountId: account,
    csv: "Date,Description,Amount\n2026-01-01,Test,-1",
    mapping: {
      date: "Date",
      description: "Description",
      amount: "Amount",
      dateFormat: "YYYY-MM-DD",
      sign: "inflow-positive",
    },
  };
  equal(
    (await handle(request("/api/v1/imports/commit", payload), db)).status,
    200,
  );
  equal(
    db.calls.some((c) =>
      c.op === "import" && c.payload.rows[0].amount_minor === -100
    ),
    true,
  );
  equal(
    (await handle(
      request("/api/v1/imports/commit", {
        ...payload,
        csv: "Date,Description,Amount\n2026-02-30,Test,-1",
      }),
      db,
    )).status,
    422,
  );
  db.accountSource = "stripe";
  db.rows = [{
    source: "stripe",
    source_id: "fctxn_x",
    transaction_date: "2026-01-01",
  }];
  equal(
    (await handle(request("/api/v1/imports/commit", payload), db)).status,
    422,
  );
  equal(
    (await handle(
      request("/api/v1/imports/commit", { ...payload, confirmOverlap: true }),
      db,
    )).status,
    422,
  );
  equal(
    (await handle(request("/api/v1/imports/bad/undo", {}), db)).status,
    422,
  );
});
Deno.test("Stripe defaults disabled and worker requires independent trusted secret", async () => {
  Deno.env.delete("STRIPE_ENABLED");
  Deno.env.delete("WORKER_SECRET");
  equal(
    (await handle(request("/api/v1/connections/session", {}), new MockDB()))
      .status,
    503,
  );
  equal(
    (await webhook(request("/stripe-webhook", {}, false), new MockDB())).status,
    503,
  );
  equal(
    (await worker(request("/worker", {}, false), new MockDB())).status,
    401,
  );
});
Deno.test("worker persists every page and resumes from cursor without replaying paid calls", async () => {
  const db = new MockDB();
  let count = 0;
  const params: any[] = [];
  const stripe = {
    live: false,
    call: async (_path: string, _method: string, p: any) => {
      if (_path.startsWith("financial_connections/accounts/")) {
        return {
          livemode: false,
          status: "active",
          account_holder: { customer: "cus_synthetic" },
          permissions: ["balances", "transactions"],
          transaction_refresh: { status: "succeeded" },
        };
      }
      params.push(p);
      count++;
      return {
        data: [{
          id: `fctxn_${count}`,
          account: "fca_synthetic",
          livemode: false,
          amount: -100,
          currency: "usd",
          description: "Synthetic",
          transacted_at: 1793491200,
          updated: count,
          status: "posted",
        }],
        has_more: count < 2,
      };
    },
  } as unknown as Stripe;
  await processJob(
    {
      id: "job",
      account_id: account,
      kind: "sync",
      lease_token: "lease",
      cursor: "fctxn_previous",
    },
    db,
    stripe,
    Date.now() + 5000,
  );
  equal(params[0].starting_after, "fctxn_previous");
  equal(params[1].starting_after, "fctxn_1");
  equal(db.calls.filter((c) => c.op === "page").length, 2);
  equal(db.calls.at(-1)?.op, "finish");
});
Deno.test("worker pagination yields without exhausting failure attempts and retains persisted cursor", async () => {
  const db = new MockDB();
  const stripe = {
    live: false,
    call: async () => ({
      livemode: false,
      status: "active",
      account_holder: { customer: "cus_synthetic" },
      permissions: ["balances", "transactions"],
      data: [],
      has_more: false,
      transaction_refresh: { status: "succeeded" },
    }),
  } as unknown as Stripe;
  await processJob(
    { id: "job", account_id: account, kind: "sync", lease_token: "lease" },
    db,
    stripe,
    Date.now() - 1,
  );
  equal(db.calls.at(-1)?.op, "yield");
});
Deno.test("balance webhook worker only reads, reserved paid refresh uses permanent idempotency key", async () => {
  const db = new MockDB();
  const calls: any[] = [];
  const stripe = {
    live: false,
    requireActivity: () => {},
    call: async (...args: any[]) => {
      calls.push(args);
      return {
        status: "active",
        livemode: false,
        account_holder: { customer: "cus_synthetic" },
        permissions: ["balances", "transactions"],
        balance: { current: { usd: 100 }, as_of: 1793830636 },
        balance_refresh: { status: "succeeded", next_refresh_available_at: 1 },
      };
    },
  } as unknown as Stripe;
  await processJob(
    {
      id: "job",
      account_id: account,
      kind: "balance",
      lease_token: "lease",
      dedupe_key: "event:evt_test",
    },
    db,
    stripe,
    Date.now() + 5000,
  );
  equal(calls.length, 1);
  equal(calls[0][1], undefined);
  calls.length = 0;
  await processJob(
    {
      id: "job",
      account_id: account,
      kind: "balance",
      lease_token: "lease",
      dedupe_key: "refresh:reservation",
      created_at: new Date().toISOString(),
    },
    db,
    stripe,
    Date.now() + 5000,
  );
  equal(calls.length, 3);
  equal(calls[1][3], "refresh:reservation");
});
