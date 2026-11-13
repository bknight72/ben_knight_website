import { strict as assert } from "node:assert";

// Run inside a container that supplies Playwright and a static artifact server.
// Startup only: no login or financial writes. Real service integration is separate.
const { chromium } = await import("playwright");
const base = process.env.BUDGET_BROWSER_URL ?? "http://127.0.0.1:8080";
const target = new URL(base);
const configured = process.env.BUDGET_CONFIGURED_SMOKE === "true";
const hosted = process.env.BUDGET_HOSTED_SMOKE === "true";
const stripeEnabled = process.env.STRIPE_ENABLED ?? "false";
const stripeKey = process.env.STRIPE_PUBLISHABLE_KEY ?? "";
assert.ok(
  ["true", "false"].includes(stripeEnabled),
  "Invalid Stripe enablement; values withheld",
);
assert.ok(
  stripeEnabled === "true"
    ? /^pk_live_[A-Za-z0-9]{20,}$/.test(stripeKey) &&
      !/placeholder|your|example|replace/i.test(stripeKey)
    : stripeKey === "",
  "Invalid public Stripe configuration; values withheld",
);
assert.ok(
  hosted
    ? configured && target.protocol === "https:" &&
      (target.origin === "https://budgeting.benknight.dev" ||
        (/^[a-z0-9-]+\.vercel\.app$/.test(target.hostname) &&
          /^[a-z0-9_-]+$/.test(process.env.VERCEL_PROJECT_NAME ?? ""))) &&
      target.href === `${target.origin}/` && !target.username &&
      !target.password
    : ["127.0.0.1", "localhost", "budgeting-web", "host.docker.internal"]
      .includes(
        target.hostname,
      ),
  "Browser smoke requires an approved local or project deployment origin",
);
const browser = await chromium.launch({
  headless: true,
  args: ["--no-sandbox"],
});
try {
  for (
    const viewport of [{ width: 390, height: 844 }, {
      width: 1440,
      height: 1000,
    }, { width: 1000, height: 500 }]
  ) {
    const context = await browser.newContext({ viewport });
    if (
      hosted && target.hostname.endsWith(".vercel.app") &&
      process.env.VERCEL_AUTOMATION_BYPASS_SECRET
    ) {
      await context.route(`${target.origin}/**`, (route) =>
        route.continue({
          headers: {
            ...route.request().headers(),
            "x-vercel-protection-bypass":
              process.env.VERCEL_AUTOMATION_BYPASS_SECRET,
          },
        }));
    }
    const page = await context.newPage();
    const errors = [];
    const assetErrors = [];
    page.on("pageerror", (error) => errors.push(error.message));
    page.on("response", (response) => {
      if (
        response.url().startsWith(`${target.origin}/`) &&
        response.status() >= 400
      ) assetErrors.push(response.status());
    });
    if (configured) {
      const asset = await context.request.get(`${target.origin}/main.dart.js`, {
        maxRedirects: 0,
        headers: hosted && target.hostname.endsWith(".vercel.app") &&
            process.env.VERCEL_AUTOMATION_BYPASS_SECRET
          ? {
            "x-vercel-protection-bypass":
              process.env.VERCEL_AUTOMATION_BYPASS_SECRET,
          }
          : {},
      });
      assert.equal(asset.status(), 200);
      const js = await asset.text();
      assert.ok(
        process.env.SUPABASE_URL && process.env.SUPABASE_PUBLISHABLE_KEY,
      );
      assert.ok(
        js.includes(process.env.SUPABASE_URL) &&
          js.includes(process.env.SUPABASE_PUBLISHABLE_KEY),
      );
      assert.ok(
        stripeEnabled === "true"
          ? js.includes(stripeKey)
          : !/pk_(?:live|test)_/.test(js),
        "Artifact Stripe key mismatch; values withheld",
      );
      const evidence = await context.request.get(
        `${target.origin}/release-config.json`,
        {
          maxRedirects: 0,
          headers: hosted && target.hostname.endsWith(".vercel.app") &&
              process.env.VERCEL_AUTOMATION_BYPASS_SECRET
            ? {
              "x-vercel-protection-bypass":
                process.env.VERCEL_AUTOMATION_BYPASS_SECRET,
            }
            : {},
        },
      );
      assert.equal(evidence.status(), 200);
      assert.ok(
        JSON.stringify(await evidence.json()) === JSON.stringify({
          supabaseUrl: process.env.SUPABASE_URL,
          supabasePublishableKey: process.env.SUPABASE_PUBLISHABLE_KEY,
          stripeEnabled: stripeEnabled === "true",
          stripePublishableKey: stripeKey,
        }),
        "Artifact public configuration evidence mismatch; values withheld",
      );
    }
    const response = await page.goto(`${target.origin}/private-ledger`, {
      waitUntil: "networkidle",
    });
    assert.equal(response.status(), 200);
    await page.locator("flutter-view").waitFor();
    await page.evaluate(() =>
      document.querySelector("flt-semantics-placeholder")?.click()
    );
    await page.getByText(
      configured
        ? "Sign in to your private workspace."
        : "No account or financial data",
      { exact: false },
    )
      .waitFor({ timeout: 30000 });
    await page.locator("#loading").waitFor({ state: "detached" });
    assert.equal(
      await page.locator("flt-semantics").filter({
        hasText: configured
          ? "Sign in to your private workspace."
          : "No account or financial data",
      }).count() > 0,
      true,
    );
    assert.equal(
      await page.evaluate(() =>
        document.documentElement.scrollWidth > window.innerWidth
      ),
      false,
    );
    assert.deepEqual(await page.evaluate(() => Object.keys(localStorage)), []);
    assert.equal(
      await page.evaluate(async () =>
        (await navigator.serviceWorker.getRegistrations()).length
      ),
      0,
    );
    await page.reload({ waitUntil: "networkidle" });
    await page.evaluate(() =>
      document.querySelector("flt-semantics-placeholder")?.click()
    );
    await page.getByText(
      configured
        ? "Sign in to your private workspace."
        : "No account or financial data",
      { exact: false },
    ).waitFor({ timeout: 30000 });
    await page.locator("#loading").waitFor({ state: "detached" });
    assert.deepEqual(errors, []);
    assert.deepEqual(assetErrors, []);
    await context.close();
  }
} finally {
  await browser.close();
}
