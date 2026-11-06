import { strict as assert } from "node:assert";

// Run inside a container that supplies Playwright and a static artifact server.
// No test talks to banks or hosted Supabase. Real service integration is separate.
const { chromium } = await import("playwright");
const base = process.env.BUDGET_BROWSER_URL ?? "http://127.0.0.1:8080";
const target = new URL(base);
assert.ok(
  ["127.0.0.1", "localhost", "budgeting-web", "host.docker.internal"].includes(
    target.hostname,
  ),
  "Browser tests require a local artifact server",
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
    const page = await context.newPage();
    const errors = [];
    page.on("pageerror", (error) => errors.push(error.message));
    const response = await page.goto(`${base}/private-ledger`, {
      waitUntil: "networkidle",
    });
    assert.equal(response.status(), 200);
    await page.locator("flutter-view").waitFor();
    await page.evaluate(() =>
      document.querySelector("flt-semantics-placeholder")?.click()
    );
    await page.getByText("No account or financial data", { exact: false })
      .waitFor({ timeout: 30000 });
    assert.equal(
      await page.locator("flt-semantics").filter({
        hasText: "No account or financial data",
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
    assert.deepEqual(errors, []);
    await context.close();
  }
} finally {
  await browser.close();
}
