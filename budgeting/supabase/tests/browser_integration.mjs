import { strict as assert } from "node:assert";
import { readFile } from "node:fs/promises";
import { createHmac } from "node:crypto";
const { chromium } = await import("/runner/node_modules/playwright/index.mjs");
const fixture = JSON.parse(
  await readFile("/run/budgeting-browser/fixture.json", "utf8"),
);
const base = process.env.BUDGET_BROWSER_URL || "http://127.0.0.1:8080";
for (const url of [base, fixture.supabaseUrl]) {
  assert.ok(
    ["127.0.0.1", "localhost"].includes(new URL(url).hostname),
    "Refusing nonlocal browser integration target",
  );
}
assert.equal(fixture.email, "budget-owner@example.test");
function totp(secret) {
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
  let bits = "";
  for (const ch of secret.replace(/=+$/, "")) {
    bits += alphabet.indexOf(ch).toString(2).padStart(5, "0");
  }
  const key = Buffer.alloc(Math.floor(bits.length / 8));
  for (let i = 0; i < key.length; i++) {
    key[i] = parseInt(bits.slice(i * 8, i * 8 + 8), 2);
  }
  const counter = Buffer.alloc(8);
  counter.writeBigUInt64BE(BigInt(Math.floor(Date.now() / 30000)));
  const mac = createHmac("sha1", key).update(counter).digest(),
    offset = mac[19] & 15;
  return ((mac.readUInt32BE(offset) & 0x7fffffff) % 1000000).toString()
    .padStart(6, "0");
}
const browser = await chromium.launch({
  headless: true,
  args: ["--no-sandbox", "--disable-dev-shm-usage"],
});
const context = await browser.newContext({
  viewport: { width: 1440, height: 1000 },
});
let page = await context.newPage();
const errors = [];
page.on("pageerror", () => errors.push("browser runtime error"));
// Auth, MFA and financial APIs remain real. Only the explicit enabled variant mocks Stripe.js.
await context.route("**/*", (route) => {
  const url = new URL(route.request().url());
  if (fixture.mockStripe && url.href === "https://js.stripe.com/v3/") {
    return route.fulfill({
      contentType: "application/javascript",
      body: `
      window.Stripe = (key) => {
        if (key !== 'pk_test_localSyntheticOnly123') throw new Error('Wrong synthetic public key');
        return {collectFinancialConnectionsAccounts: async ({clientSecret}) => {
          const sessionId = clientSecret.split('_secret_')[0];
          await window.localStripeConsent(sessionId);
          return {financialConnectionsSession:{accounts:[{id:'untrustedBrowserAccount'}]}};
        }};
      };
    `,
    });
  }
  if (
    ["data:", "blob:"].includes(url.protocol) ||
    ["127.0.0.1", "localhost"].includes(url.hostname)
  ) return route.continue();
  return route.abort("blockedbyclient");
});
if (fixture.mockStripe) {
  await page.exposeFunction("localStripeConsent", async (sessionId) => {
    const response = await fetch("http://127.0.0.1:58082/control", {
      method: "POST",
      body: JSON.stringify({ sessionId }),
    });
    assert.equal(response.status, 200);
  });
}
async function semantics() {
  await page.locator("flutter-view").waitFor({ timeout: 60000 });
  await page.evaluate(() =>
    document.querySelector("flt-semantics-placeholder")?.click()
  );
}
async function fill(label, value) {
  const field = page.getByRole("textbox", { name: label, exact: true })
    .or(page.getByLabel(label, { exact: true })).first();
  await field.waitFor();
  await field.click();
  // Flutter attaches editing handlers on a later semantics frame after focus.
  await page.waitForFunction((element) =>
    document.activeElement === element &&
    !element.dispatchEvent(
      new MouseEvent("mousemove", {
        cancelable: true,
        bubbles: false,
      }),
    ), await field.elementHandle());
  await field.fill(value);
  await field.press("Tab");
}
async function click(name) {
  await page.getByRole("button", { name, exact: true }).click();
}
async function authenticate(password) {
  await fill("Email address", fixture.email);
  await fill("Password", password);
  const signedIn = page.waitForResponse((response) =>
    new URL(response.url()).pathname === "/auth/v1/token" &&
    response.request().method() === "POST"
  );
  await click("Sign in");
  const login = await signedIn;
  const submitted = login.request().postDataJSON();
  assert.ok(submitted.email === fixture.email, "Browser submitted wrong email");
  assert.ok(
    submitted.password === password,
    "Browser submitted wrong password",
  );
  assert.equal(login.status(), 200, "Real password login failed");
  await page.getByRole("textbox", { name: "Authenticator code", exact: true })
    .waitFor({ timeout: 30000 });
  // The API harness enrolled MFA immediately before this run. Avoid reusing its current TOTP window.
  const wait = 30000 - (Date.now() % 30000) + 500;
  await new Promise((resolve) => setTimeout(resolve, wait));
  const verified = page.waitForResponse((response) =>
    new URL(response.url()).pathname.includes("/factors/") &&
    new URL(response.url()).pathname.endsWith("/verify") &&
    response.request().method() === "POST"
  );
  await fill("Authenticator code", totp(fixture.totpSecret));
  await click("Verify and continue");
  const response = await verified;
  assert.equal(response.status(), 200, "Real TOTP verification failed");
  return (await response.json()).access_token;
}
async function restoredWorkspace() {
  await semantics();
  await page.getByText("Synthetic local cash", { exact: false }).first()
    .waitFor({ timeout: 30000 });
  assert.equal(
    await page.getByRole("textbox", { name: "Authenticator code", exact: true })
      .count(),
    0,
    "Remembered MFA session required another authenticator challenge",
  );
  assert.equal(
    await page.getByRole("textbox", { name: "Password", exact: true }).count(),
    0,
    "Remembered session required password login",
  );
}
async function authenticationStorageOnly() {
  const key = `sb-${
    new URL(fixture.supabaseUrl).hostname.split(".")[0]
  }-auth-token`;
  const keys = await page.evaluate(() => Object.keys(localStorage));
  assert.deepEqual(keys, [key], "Unexpected persistent browser storage");
  const shape = await page.evaluate((key) => {
    const session = JSON.parse(localStorage.getItem(key));
    return {
      accessToken: typeof session.access_token === "string",
      refreshToken: typeof session.refresh_token === "string",
      containsFinancialData:
        /Browser synthetic cash|Synthetic local cash|fcsess_.*_secret_/
          .test(JSON.stringify(session)),
    };
  }, key);
  assert.deepEqual(shape, {
    accessToken: true,
    refreshToken: true,
    containsFinancialData: false,
  });
}
try {
  await page.goto(base, { waitUntil: "networkidle" });
  await semantics();
  const token = await authenticate(fixture.password);
  // Wait for real fixture data rather than decorative metric text merged by semantics.
  await page.getByText("Synthetic local cash", { exact: false }).first()
    .waitFor({
      timeout: 30000,
    });
  assert.ok(
    await page.getByText("Synthetic local cash", { exact: false }).count() > 0,
    "Real API fixture was not rendered",
  );
  const includedSources = page.waitForResponse((response) =>
    new URL(response.url()).pathname === "/rest/v1/rpc/budgeteer_mutate" &&
    response.request().method() === "POST" &&
    response.request().postDataJSON().p_operation === "sources_include"
  );
  await page.getByText("Budgeteer", { exact: true }).click();
  const included = await includedSources;
  assert.equal(included.status(), 200, "Default transaction inclusion failed");
  const initialPlan = await included.json();
  assert.equal(initialPlan.schema_version, 4);
  assert.equal(typeof initialPlan.groups_revision, "number");
  assert.equal(
    included.request().postDataJSON().p_payload.schema_version,
    4,
  );
  assert.equal(
    typeof included.request().postDataJSON().p_payload.expected_groups_revision,
    "number",
  );
  await page.getByText("Withdrawals", { exact: true }).click();
  await page.getByText("Groups are shared across all months.", { exact: false })
    .waitFor();
  assert.equal(
    await page.getByText("Copy earlier groups", { exact: true }).count(),
    0,
  );
  let automaticEntry = initialPlan.entries.find((entry) =>
    entry.source_transaction_id != null
  );
  assert.ok(automaticEntry, "No bank transactions were included by default");
  await page.getByRole("button", {
    name: `Delete ${automaticEntry.name}`,
    exact: true,
  })
    .first().click();
  const removedSource = page.waitForResponse((response) =>
    new URL(response.url()).pathname === "/rest/v1/rpc/budgeteer_mutate" &&
    response.request().postDataJSON()?.p_operation === "entry_delete"
  );
  await click("Confirm");
  const removal = await removedSource;
  assert.equal(removal.status(), 200, "Source exclusion failed");
  // Descriptions are not unique; identify the clicked entry by its saved ID.
  automaticEntry = initialPlan.entries.find((entry) =>
    entry.id === removal.request().postDataJSON().p_payload.id
  );
  assert.ok(
    automaticEntry?.source_transaction_id,
    "Removed entry has no bank source",
  );
  await page.getByText("Overview", { exact: true }).click();
  const reloadedSources = page.waitForResponse((response) =>
    new URL(response.url()).pathname === "/rest/v1/rpc/budgeteer_mutate" &&
    response.request().postDataJSON()?.p_operation === "sources_include"
  );
  await page.getByText("Budgeteer", { exact: true }).click();
  const reloadedPlan = await (await reloadedSources).json();
  assert.ok(
    !reloadedPlan.entries.some((entry) =>
      entry.source_transaction_id === automaticEntry.source_transaction_id
    ),
    "Excluded source reappeared after navigation",
  );
  assert.equal(reloadedPlan.excluded_source_count, 1);
  await page.getByRole("button", {
    name: "Restore excluded transactions (1)",
    exact: true,
  })
    .click();
  const restoredSources = page.waitForResponse((response) =>
    new URL(response.url()).pathname === "/rest/v1/rpc/budgeteer_mutate" &&
    response.request().postDataJSON()?.p_operation === "sources_restore"
  );
  await click("Confirm");
  const restoredPlan = await (await restoredSources).json();
  assert.ok(
    restoredPlan.entries.some((entry) =>
      entry.source_transaction_id === automaticEntry.source_transaction_id
    ),
    "Restoring excluded sources failed",
  );
  assert.equal(restoredPlan.excluded_source_count, 0);
  await page.getByText("Deposits", { exact: true }).click();
  await click("Add deposit");
  await fill("Name", "Browser Budgeteer funding");
  await fill("Amount (USD)", "1200.00");
  const planSaved = page.waitForResponse((response) =>
    new URL(response.url()).pathname === "/rest/v1/rpc/budgeteer_mutate" &&
    response.request().method() === "POST" &&
    response.request().postDataJSON().p_operation === "entry_save"
  );
  await click("Save deposit");
  const savedPlan = await planSaved;
  assert.equal(savedPlan.status(), 200, "Budgeteer deposit save failed");
  const funding = (await savedPlan.json()).entries.find((entry) =>
    entry.name === "Browser Budgeteer funding" && entry.amount_minor === 120000
  );
  assert.ok(funding, "Saved deposit missing from canonical plan");
  async function reopenBudgeteer() {
    const loaded = page.waitForResponse((response) =>
      new URL(response.url()).pathname === "/rest/v1/rpc/budgeteer_mutate" &&
      response.request().method() === "POST" &&
      response.request().postDataJSON().p_operation === "sources_include"
    );
    await page.getByText("Budgeteer", { exact: true }).click();
    const response = await loaded;
    assert.equal(response.status(), 200, "Budgeteer reload failed");
    assert.ok(
      (await response.json()).entries.some((entry) =>
        entry.id === funding.id && entry.name === funding.name &&
        entry.amount_minor === funding.amount_minor
      ),
      "Saved deposit did not persist across navigation/reload",
    );
  }
  await page.getByText("Overview", { exact: true }).click();
  await reopenBudgeteer();
  await page.reload({ waitUntil: "networkidle" });
  await restoredWorkspace();
  await reopenBudgeteer();
  await page.setViewportSize({ width: 390, height: 844 });
  assert.equal(
    await page.evaluate(() =>
      document.documentElement.scrollWidth > window.innerWidth
    ),
    false,
    "Budgeteer overflows narrow viewport",
  );
  await page.setViewportSize({ width: 1440, height: 1000 });
  await page.getByText("Accounts", { exact: true }).click();
  await click("Add manual account");
  await fill("Account name", "Browser synthetic cash");
  const saved = page.waitForResponse((response) =>
    response.url().includes("/rest/v1/accounts") &&
    response.request().method() === "POST"
  );
  await click("Save");
  const accountWrite = await saved;
  assert.ok(
    accountWrite.request().postDataJSON().name === "Browser synthetic cash",
    "Browser submitted wrong account name",
  );
  assert.equal(accountWrite.status(), 201, "Browser account write failed");
  // Account cards merge their text into the accessible group name.
  await page.getByRole("group", { name: /^Browser synthetic cash\s/ })
    .waitFor();
  const check = await fetch(
    `${fixture.supabaseUrl}/rest/v1/accounts?name=eq.Browser%20synthetic%20cash&select=id,owner_id`,
    {
      headers: {
        apikey: fixture.publishableKey,
        authorization: `Bearer ${token}`,
      },
    },
  );
  assert.equal(check.status, 200);
  const rows = await check.json();
  assert.equal(rows.length, 1);
  assert.equal(rows[0].owner_id, fixture.ownerId);
  await page.reload({ waitUntil: "networkidle" });
  await restoredWorkspace();
  // Reopening a page in the same browser context retains origin storage, not Dart memory.
  await page.close();
  page = await context.newPage();
  page.on("pageerror", () => errors.push("browser runtime error"));
  if (fixture.mockStripe) {
    await page.exposeFunction("localStripeConsent", async (sessionId) => {
      const response = await fetch("http://127.0.0.1:58082/control", {
        method: "POST",
        body: JSON.stringify({ sessionId }),
      });
      assert.equal(response.status, 200);
    });
  }
  await page.goto(base, { waitUntil: "networkidle" });
  await restoredWorkspace();
  await authenticationStorageOnly();
  // Synthetic expired JWT is never accepted by the server; real refresh must replace it first.
  await page.evaluate(() => {
    const key = Object.keys(localStorage).find((key) =>
      key.endsWith("-auth-token")
    );
    const session = JSON.parse(localStorage.getItem(key));
    const segments = session.access_token.split(".");
    const claims = JSON.parse(
      atob(segments[1].replace(/-/g, "+").replace(/_/g, "/")),
    );
    claims.exp = Math.floor(Date.now() / 1000) - 60;
    segments[1] = btoa(JSON.stringify(claims)).replace(/=/g, "").replace(
      /\+/g,
      "-",
    ).replace(/\//g, "_");
    session.access_token = segments.join(".");
    localStorage.setItem(key, JSON.stringify(session));
  });
  const refreshResponse = page.waitForResponse((response) =>
    new URL(response.url()).pathname === "/auth/v1/token" &&
    new URL(response.url()).searchParams.get("grant_type") ===
      "refresh_token" &&
    response.request().method() === "POST"
  );
  await page.reload({ waitUntil: "networkidle" });
  assert.equal(
    (await refreshResponse).status(),
    200,
    "Remembered session refresh failed",
  );
  await restoredWorkspace();
  await authenticationStorageOnly();
  await page.getByText("Accounts", { exact: true }).click();
  if (fixture.mockStripe) {
    // Interrupt only browser completion dispatch, after synthetic bank consent.
    // Reload must recover the server's pending session without another Stripe modal.
    let interrupted = false;
    await page.route("**/connections/complete", (route) => {
      interrupted = true;
      return route.abort("failed");
    });
    await click("Connect bank");
    await click("Confirm");
    await page.waitForResponse((response) =>
      response.url().endsWith("/connections/pending") &&
      response.status() === 200
    );
    await page.getByRole("button", { name: "Retry completion", exact: true })
      .waitFor();
    assert.ok(interrupted, "Completion interruption was not exercised");
    await page.unroute("**/connections/complete");
    await page.reload({ waitUntil: "networkidle" });
    await restoredWorkspace();
    await page.getByText("Accounts", { exact: true }).click();
    await page.getByRole("button", { name: "Retry completion", exact: true })
      .waitFor();
    const accepted = page.waitForResponse((response) =>
      response.url().endsWith("/connections/complete")
    );
    await click("Retry completion");
    await click("Confirm");
    const completion = await accepted;
    assert.equal(completion.status(), 200);
    const completed = await completion.json();
    assert.equal(completed.status, "queued");
    assert.equal(completed.accountIds.length, 1);
    const linked = await fetch(
      `${fixture.supabaseUrl}/rest/v1/accounts?id=eq.${
        completed.accountIds[0]
      }&select=sync_error`,
      {
        headers: {
          apikey: fixture.publishableKey,
          authorization: `Bearer ${
            (await completion.request().allHeaders()).authorization.split(
              " ",
            )[1]
          }`,
        },
      },
    );
    assert.equal(linked.status, 200);
    assert.equal((await linked.json())[0].sync_error, "subscription_pending");
    const inspect = await (await fetch("http://127.0.0.1:58082/inspect"))
      .json();
    assert.equal(inspect.customerCount, 1, "Browser resume recreated customer");
    assert.ok(
      !inspect.requests.some((r) => r.path.endsWith("/refresh")),
      "Browser linking bought a balance",
    );
    assert.equal(
      await page.evaluate(() =>
        JSON.stringify(localStorage).includes("secret")
      ),
      false,
    );
    console.log(
      "PASS enabled Chromium + real local MFA/functions/Postgres: mocked Stripe.js consent, interrupted completion, remembered MFA on reload, pending-session resume, queued response and persisted subscription status, no paid balance request",
    );
  }
  const otherTab = await context.newPage();
  otherTab.on("pageerror", () => errors.push("browser runtime error"));
  await otherTab.goto(base, { waitUntil: "networkidle" });
  await otherTab.locator("flutter-view").waitFor({ timeout: 60000 });
  await otherTab.evaluate(() =>
    document.querySelector("flt-semantics-placeholder")?.click()
  );
  await otherTab.getByText("Synthetic local cash", { exact: false }).first()
    .waitFor({ timeout: 30000 });
  const rememberedSession = await page.evaluate(() => {
    const key = Object.keys(localStorage).find((key) =>
      key.endsWith("-auth-token")
    );
    return { key, session: JSON.parse(localStorage.getItem(key)) };
  });
  await page.getByText("Sign out", { exact: true }).click();
  await page.getByText("Welcome to Ben's Budgeteering.", { exact: true })
    .waitFor();
  await otherTab.getByText("Welcome to Ben's Budgeteering.", { exact: true })
    .waitFor({ timeout: 30000 });
  await otherTab.close();
  assert.equal(
    await page.getByRole("group", { name: /^Browser synthetic cash\s/ })
      .count(),
    0,
    "Logout retained financial UI",
  );
  assert.deepEqual(await page.evaluate(() => Object.keys(localStorage)), []);
  await page.reload({ waitUntil: "networkidle" });
  await semantics();
  await page.getByText("Welcome to Ben's Budgeteering.", { exact: true })
    .waitFor();
  await page.evaluate(({ key, session }) => {
    const segments = session.access_token.split(".");
    const claims = JSON.parse(
      atob(segments[1].replace(/-/g, "+").replace(/_/g, "/")),
    );
    claims.exp = Math.floor(Date.now() / 1000) - 60;
    segments[1] = btoa(JSON.stringify(claims)).replace(/=/g, "").replace(
      /\+/g,
      "-",
    ).replace(/\//g, "_");
    session.access_token = segments.join(".");
    session.refresh_token = "invalid-synthetic-refresh-token";
    localStorage.setItem(key, JSON.stringify(session));
  }, rememberedSession);
  await page.reload({ waitUntil: "networkidle" });
  await semantics();
  await page.getByText("Welcome to Ben's Budgeteering.", { exact: true })
    .waitFor();
  assert.deepEqual(await page.evaluate(() => Object.keys(localStorage)), []);
  assert.equal(
    await page.getByText("Synthetic local cash", { exact: false }).count(),
    0,
    "Invalid refresh credentials exposed financial data",
  );
  assert.equal(
    await page.evaluate(async () =>
      (await navigator.serviceWorker.getRegistrations()).length
    ),
    0,
  );
  assert.deepEqual(errors, []);
  console.log(
    "PASS actual signed-in Chromium: password login, TOTP once, reload/reopen session continuity and refresh, real dashboard, owned PostgREST write, cross-tab sign-out clearing, invalid refresh denial, no financial cache/service worker",
  );
} finally {
  await context.close();
  await browser.close();
}
