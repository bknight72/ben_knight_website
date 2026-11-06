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
const page = await context.newPage();
const errors = [];
page.on("pageerror", () => errors.push("browser runtime error"));
// Refuse remote traffic rather than mock Auth, financial APIs or Stripe. All requests below are real.
await context.route("**/*", (route) => {
  const url = new URL(route.request().url());
  if (
    ["data:", "blob:"].includes(url.protocol) ||
    ["127.0.0.1", "localhost"].includes(url.hostname)
  ) return route.continue();
  return route.abort("blockedbyclient");
});
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
  await page.getByText("Sign out", { exact: true }).click();
  await page.getByText("Welcome to your ledger.", { exact: true }).waitFor();
  assert.equal(
    await page.getByRole("group", { name: /^Browser synthetic cash\s/ })
      .count(),
    0,
    "Logout retained financial UI",
  );
  assert.deepEqual(await page.evaluate(() => Object.keys(localStorage)), []);
  assert.equal(
    await page.evaluate(async () =>
      (await navigator.serviceWorker.getRegistrations()).length
    ),
    0,
  );
  assert.deepEqual(errors, []);
  console.log(
    "PASS actual signed-in Chromium: password login, TOTP, real dashboard, manual account persisted through PostgREST, sign-out financial clearing, no persistent storage/service worker",
  );
} finally {
  await context.close();
  await browser.close();
}
