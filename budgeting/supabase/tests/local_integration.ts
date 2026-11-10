import { stripeIntegration } from "./local-stripe-integration.ts";
// Actual local Auth, MFA, PostgREST and Edge Runtime; optional Stripe-only HTTP boundary.
const base = Deno.env.get("LOCAL_SUPABASE_URL") ||
  "http://host.docker.internal:54321";
if (
  !["localhost", "127.0.0.1", "host.docker.internal"].includes(
    new URL(base).hostname,
  )
) throw new Error("Local integration refuses nonlocal targets");
const anon = Deno.env.get("LOCAL_ANON_KEY")!,
  service = Deno.env.get("LOCAL_SERVICE_KEY")!;
if (!anon || !service) throw new Error("Local test keys are required");
const password = "Synthetic-local-only-3859!",
  email = "budget-owner@example.test",
  otherEmail = "budget-other@example.test";
async function call(
  path: string,
  token = anon,
  method = "GET",
  body?: unknown,
  expected = 200,
) {
  const response = await fetch(base + path, {
    method,
    headers: {
      apikey: anon,
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
      Prefer: "return=representation",
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const raw = await response.text();
  let data;
  try {
    data = JSON.parse(raw);
  } catch {
    data = raw;
  }
  if (response.status !== expected) {
    throw new Error(
      `${method} ${path}: expected ${expected}, got ${response.status}; ${
        typeof data === "object"
          ? data?.code || data?.error_code || "response error"
          : String(data).slice(0, 80)
      }`,
    );
  }
  return data;
}
function assert(ok: unknown, message: string) {
  if (!ok) throw new Error(message);
}
async function totp(secret: string) {
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
  let bits = "";
  for (const ch of secret.replace(/=+$/, "")) {
    bits += alphabet.indexOf(ch).toString(2).padStart(5, "0");
  }
  const bytes = new Uint8Array(Math.floor(bits.length / 8));
  for (let i = 0; i < bytes.length; i++) {
    bytes[i] = parseInt(bits.slice(i * 8, i * 8 + 8), 2);
  }
  const counter = new Uint8Array(8);
  new DataView(counter.buffer).setBigUint64(
    0,
    BigInt(Math.floor(Date.now() / 30000)),
  );
  const key = await crypto.subtle.importKey(
    "raw",
    bytes,
    { name: "HMAC", hash: "SHA-1" },
    false,
    ["sign"],
  );
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, counter)),
    offset = mac[19] & 15;
  return ((new DataView(mac.buffer).getUint32(offset) & 0x7fffffff) % 1000000)
    .toString().padStart(6, "0");
}
const create = async (email: string) =>
  await call("/auth/v1/admin/users", service, "POST", {
    email,
    password,
    email_confirm: true,
  });
const owner = await create(email), other = await create(otherEmail);
// Owner mapping must be provisioned through SQL administration, never through browser/RPC first-user-wins.
const provision = new Deno.Command("docker", {
  args: [
    "exec",
    "supabase_db_private-budgeting",
    "psql",
    "-U",
    "postgres",
    "-v",
    "ON_ERROR_STOP=1",
    "-c",
    `insert into private.app_owner(owner_id) values ('${owner.id}');`,
  ],
  stdout: "null",
  stderr: "piped",
});
if (!(await provision.output()).success) {
  throw new Error("Trusted owner provisioning failed");
}
const login = async (email: string) =>
  await call("/auth/v1/token?grant_type=password", anon, "POST", {
    email,
    password,
  });
const low = await login(email), wrong = await login(otherEmail);
await call("/functions/v1/api/api/v1/usage", anon, "GET", undefined, 401);
await call(
  "/functions/v1/api/api/v1/usage",
  low.access_token,
  "GET",
  undefined,
  403,
);
await call(
  "/functions/v1/api/api/v1/usage",
  wrong.access_token,
  "GET",
  undefined,
  403,
);
assert(
  (await call("/rest/v1/accounts?select=*", low.access_token)).length === 0,
  "aal1 leaked financial rows",
);
const factor = await call("/auth/v1/factors", low.access_token, "POST", {
  factor_type: "totp",
  friendly_name: "Local synthetic MFA",
});
const challenge = await call(
  `/auth/v1/factors/${factor.id}/challenge`,
  low.access_token,
  "POST",
  {},
);
const high = await call(
  `/auth/v1/factors/${factor.id}/verify`,
  low.access_token,
  "POST",
  { challenge_id: challenge.id, code: await totp(factor.totp.secret) },
);
const token = high.access_token;
const refreshed = await call(
  "/auth/v1/token?grant_type=refresh_token",
  anon,
  "POST",
  { refresh_token: high.refresh_token },
);
assert(
  typeof refreshed.refresh_token === "string" &&
    refreshed.refresh_token !== high.refresh_token,
  "MFA session refresh did not rotate refresh credentials",
);
assert(
  (await call(
    "/rest/v1/rpc/is_budget_owner",
    refreshed.access_token,
    "POST",
    {},
  )) === true,
  "Refreshed MFA session lost owner/AAL2 authorization",
);
assert(
  (await call("/rest/v1/rpc/is_budget_owner", token, "POST", {})) === true,
  "owner MFA not recognized",
);
const accounts = await call("/rest/v1/accounts", token, "POST", {
    owner_id: owner.id,
    source: "manual",
    name: "Synthetic local cash",
    kind: "cash",
  }, 201),
  account = accounts[0];
await call("/rest/v1/balance_snapshots", token, "POST", {
  owner_id: owner.id,
  account_id: account.id,
  source: "manual",
  current_minor: 120000,
  observed_at: new Date().toISOString(),
}, 201);
const input = {
  accountId: account.id,
  csv:
    "Date,Description,Amount\n2026-11-01,Synthetic purchase,-12.34\n2026-11-02,Synthetic refund,2.34",
  mapping: {
    date: "Date",
    description: "Description",
    amount: "Amount",
    dateFormat: "YYYY-MM-DD",
    sign: "inflow-positive",
  },
};
const preview = await call(
  "/functions/v1/api/api/v1/imports/preview",
  token,
  "POST",
  input,
);
assert(preview.rows.length === 2 && !preview.errors.length, "preview failed");
const committed = await call(
  "/functions/v1/api/api/v1/imports/commit",
  token,
  "POST",
  input,
);
assert(committed.inserted === 2, "commit failed");
const repeat = await call(
  "/functions/v1/api/api/v1/imports/commit",
  token,
  "POST",
  { ...input, confirmOverlap: true },
);
assert(repeat.inserted === 0, "repeat import duplicated rows");
const transactions = await call("/rest/v1/transactions?select=*", token),
  categories = await call("/rest/v1/categories?select=*", token);
await call("/rest/v1/transaction_annotations", token, "POST", {
  owner_id: owner.id,
  transaction_id: transactions[0].id,
  category_id: categories.find((c: any) => c.name === "Food").id,
}, 201);
await call("/rest/v1/monthly_budgets", token, "POST", {
  owner_id: owner.id,
  category_id: categories[0].id,
  month: "2026-11-01",
  amount_minor: 10000,
}, 201);
const usage = await call("/functions/v1/api/api/v1/usage", token);
assert(
  usage.limit === 50 && usage.remainingAttempts === 50 &&
    usage.accounts.length === 0,
  "usage contract wrong",
);
await call("/rest/v1/rpc/backend_state", token, "POST", { op: "owner" }, 403);
const exported = await call("/functions/v1/api/api/v1/export", token);
assert(
  exported.transactions.length === 2 && exported.profiles.length === 1,
  "export incomplete",
);
const undo = await call(
  `/functions/v1/api/api/v1/imports/${committed.batchId}/undo`,
  token,
  "POST",
  {},
);
assert(undo.deleted === 1 && undo.retained === 1, "undo deleted annotation");
assert(
  (await call("/rest/v1/accounts?select=*", wrong.access_token)).length === 0,
  "wrong owner leaked rows",
);
await call("/auth/v1/recover", anon, "POST", { email });
const mailbox = await fetch("http://127.0.0.1:54324/api/v1/messages");
if (!mailbox.ok) throw new Error("Local recovery mailbox unavailable");
const mail = await mailbox.json();
assert(
  mail.messages?.some((m: any) =>
    m.To?.some((to: any) => to.Address === email)
  ),
  "Password recovery email was not captured locally",
);
if (Deno.env.get("BUDGETING_MOCK_STRIPE") === "true") {
  await stripeIntegration(call, token, low.access_token, wrong.access_token);
}
await call("/auth/v1/logout", token, "POST", undefined, 204);
const forged = token.split(".");
const claims = JSON.parse(
  atob(forged[1].replace(/-/g, "+").replace(/_/g, "/")),
);
claims.exp = 1;
forged[1] = btoa(JSON.stringify(claims)).replace(/=/g, "").replace(/\+/g, "-")
  .replace(/\//g, "_");
await call(
  "/functions/v1/api/api/v1/usage",
  forged.join("."),
  "GET",
  undefined,
  401,
);
const encode = (value: unknown) =>
  btoa(JSON.stringify(value)).replace(/=/g, "").replace(/\+/g, "-").replace(
    /\//g,
    "_",
  );
const header = encode({ alg: "HS256", typ: "JWT" }),
  payload = encode({
    ...claims,
    sub: owner.id,
    role: "authenticated",
    aal: "aal2",
    iat: 1,
    exp: 2,
  });
const key = await crypto.subtle.importKey(
  "raw",
  new TextEncoder().encode(Deno.env.get("LOCAL_JWT_SECRET")!),
  { name: "HMAC", hash: "SHA-256" },
  false,
  ["sign"],
);
const signature = new Uint8Array(
  await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(`${header}.${payload}`),
  ),
);
const signedExpired = `${header}.${payload}.${
  btoa(String.fromCharCode(...signature)).replace(/=/g, "").replace(/\+/g, "-")
    .replace(/\//g, "_")
}`;
await call(
  "/functions/v1/api/api/v1/usage",
  signedExpired,
  "GET",
  undefined,
  401,
);
await call("/rest/v1/accounts?select=*", signedExpired, "GET", undefined, 401);
if (
  Deno.env.get("LOCAL_BROWSER_FIXTURE") ===
    "/run/budgeting-browser/fixture.json"
) {
  // Synthetic credentials only, in an ephemeral Docker volume shared with the browser runner.
  // No service-role key, JWT signing key, access token or financial export crosses this boundary.
  await Deno.writeTextFile(
    "/run/budgeting-browser/fixture.json",
    JSON.stringify({
      email,
      password,
      ownerId: owner.id,
      totpSecret: factor.totp.secret,
      supabaseUrl: base,
      publishableKey: anon,
      mockStripe: Deno.env.get("BUDGETING_MOCK_STRIPE") === "true",
    }),
    { mode: 0o600 },
  );
}
console.log(
  "PASS real local Supabase: trusted identities, MFA, refresh rotation preserving AAL2, RLS denial, manual data, CSV preview/commit/reimport/undo, annotations, budgets, usage, export, recovery request, logout and expired/tampered JWT denial",
);
