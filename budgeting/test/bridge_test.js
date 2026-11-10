import { strict as assert } from "node:assert";

const source = await Deno.readTextFile("web/bridge.js");
function setup(stripe, documentOverride) {
  const window = { Stripe: stripe };
  const document = {
    head: {
      appendChild(script) {
        script.onload();
      },
    },
    createElement() {
      return {};
    },
  };
  new Function("window", "document", source)(
    window,
    documentOverride ?? document,
  );
  return window.budgetBridge;
}

Deno.test("file picker bounds upload before reading and propagates file read errors", async () => {
  let read = false;
  const bridge = setup(null, {
    createElement() {
      return {
        files: [{
          size: 5242881,
          text() {
            read = true;
          },
        }],
        click() {
          this.onchange();
        },
      };
    },
  });
  await assert.rejects(() => bridge.pickCsv(), /exceeds 5 MB/);
  assert.equal(read, false);
  const failed = setup(null, {
    createElement() {
      return {
        files: [{
          size: 1,
          text() {
            return Promise.reject(new Error("Read failed"));
          },
        }],
        click() {
          this.onchange();
        },
      };
    },
  });
  await assert.rejects(() => failed.pickCsv(), /Read failed/);
});

Deno.test("file picker cancellation returns no financial data", async () => {
  const bridge = setup(null, {
    createElement() {
      return {
        click() {
          this.oncancel();
        },
      };
    },
  });
  assert.equal(await bridge.pickCsv(), null);
});

Deno.test("picker reads selected CSV into memory only", async () => {
  const bridge = setup(null, {
    createElement() {
      return {
        files: [{
          size: 9,
          text() {
            return Promise.resolve("a,b\n1,2");
          },
        }],
        click() {
          this.onchange();
        },
      };
    },
  });
  assert.equal(await bridge.pickCsv(), "a,b\n1,2");
});

Deno.test("Stripe bridge passes only public key and ephemeral client secret", async () => {
  let usedKey, usedOptions;
  const bridge = setup((key) => {
    usedKey = key;
    return {
      collectFinancialConnectionsAccounts(options) {
        usedOptions = options;
        return Promise.resolve({
          financialConnectionsSession: {
            id: "fcsess_test",
            accounts: [{ id: "fca_test" }],
          },
        });
      },
    };
  });
  const status = await bridge.linkStripe(
    "pk_test_synthetic",
    "fcsess_secret_synthetic",
  );
  assert.equal(usedKey, "pk_test_synthetic");
  assert.deepEqual(usedOptions, { clientSecret: "fcsess_secret_synthetic" });
  assert.equal(status, "completed");
});

for (
  const result of [{ error: { message: "Synthetic failure" } }, {
    financialConnectionsSession: { accounts: [] },
  }, {}]
) {
  Deno.test(`Stripe cancellation/error is not treated as a completed link: ${JSON.stringify(result)}`, async () => {
    const bridge = setup(() => ({
      collectFinancialConnectionsAccounts: () => Promise.resolve(result),
    }));
    assert.equal(
      await bridge.linkStripe("pk_test", "secret"),
      result.error ? "failed" : "cancelled",
    );
  });
}

Deno.test("Stripe script failure is sanitized and retryable", async () => {
  const bridge = setup(null, {
    createElement() {
      return { remove() {} };
    },
    head: {
      appendChild(script) {
        script.onerror(new Error("private detail"));
      },
    },
  });
  assert.equal(await bridge.linkStripe("pk_test", "secret"), "load_failed");
});

Deno.test("logout discards a late modal result without returning account attributes", async () => {
  let finish;
  const bridge = setup(() => ({
    collectFinancialConnectionsAccounts() {
      return new Promise((resolve) => {
        finish = resolve;
      });
    },
  }));
  const pending = bridge.linkStripe("pk_test", "secret");
  bridge.clearStripe();
  finish({ financialConnectionsSession: { accounts: [{ id: "private" }] } });
  assert.equal(await pending, "cancelled");
});

Deno.test("provider exceptions never leak messages or secrets", async () => {
  const bridge = setup(() => ({
    collectFinancialConnectionsAccounts() {
      throw new Error("secret financial content");
    },
  }));
  assert.equal(await bridge.linkStripe("pk_test", "secret"), "failed");
});
