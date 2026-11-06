import {
  ApiError,
  boundedBody,
  constantTimeEqual,
  csvParse,
  dateValue,
  minorUnits,
  parseImport,
  safeExport,
  stripeMode,
  stripeTransaction,
  verifyWebhook,
} from "../functions/_shared/core.ts";
function equal(a: unknown, b: unknown) {
  if (JSON.stringify(a) !== JSON.stringify(b)) {
    throw new Error(`Expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`);
  }
}
function throws(fn: () => unknown) {
  let did = false;
  try {
    fn();
  } catch {
    did = true;
  }
  if (!did) throw new Error("Expected exception");
}
async function rejects(fn: () => Promise<unknown>) {
  let did = false;
  try {
    await fn();
  } catch {
    did = true;
  }
  if (!did) throw new Error("Expected rejection");
}
const mapping = {
  date: "Date",
  description: "Description",
  amount: "Amount",
  sign: "inflow-positive",
  dateFormat: "YYYY-MM-DD",
} as const;
Deno.test("decimal money exact cents, signs and malformed locale rejection", () => {
  equal(["0", "0.01", "-12.34", "123456.7"].map(minorUnits), [
    0,
    1,
    -1234,
    12345670,
  ]);
  for (
    const value of [
      "1,234.56",
      "$1.00",
      "1.001",
      "NaN",
      "1e2",
      "--1",
      "01",
      "90000000001",
    ]
  ) throws(() => minorUnits(value));
});
Deno.test("CSV quoted commas, escaped quotes, embedded newline, CRLF and bounds", () => {
  equal(csvParse('a,b\r\n"one,two","three""four"\r\n"line\nbreak",x'), [
    ["a", "b"],
    ["one,two", 'three"four'],
    ["line\nbreak", "x"],
  ]);
  for (const value of ['a\n"bad', 'a\n"x"junk', 'a\nx"', "a\n\0"]) {
    throws(() => csvParse(value));
  }
  throws(() => csvParse("x".repeat(2001)));
  throws(() => csvParse("a\n" + "x\n".repeat(10001)));
  throws(() => csvParse("x".repeat(5 * 1024 * 1024 + 1)));
});
Deno.test("date format explicit with impossible dates and leap years", () => {
  equal(dateValue("02/29/2024", "MM/DD/YYYY"), "2024-02-29");
  equal(dateValue("31/01/2026", "DD/MM/YYYY"), "2026-01-31");
  for (const d of ["2026-02-29", "2026-04-31", "2026-13-01", "1899-12-31"]) {
    throws(() => dateValue(d, "YYYY-MM-DD"));
  }
});
Deno.test("import occurrences preserve identical legitimate purchases; deterministic fingerprint", async () => {
  const csv =
    "Date,Description,Amount\n2026-11-01,Shop,-1.23\n2026-11-01,Shop,-1.23";
  const result = await parseImport(csv, mapping);
  equal(result.errors, []);
  equal(result.rows.length, 2);
  equal(result.rows[0].source_id.endsWith(":1"), true);
  equal(result.rows[1].source_id.endsWith(":2"), true);
  equal((await parseImport(csv, mapping)).fingerprint, result.fingerprint);
  equal(
    (await parseImport(csv, { ...mapping, sign: "outflow-positive" })).rows[0]
      .amount_minor,
    123,
  );
  equal(
    (await parseImport(csv, { ...mapping, sign: "outflow-positive" }))
      .fingerprint === result.fingerprint,
    false,
  );
});
Deno.test("debit credit, bank IDs, unsupported currency and row validation", async () => {
  const m = {
    date: "Date",
    description: "Text",
    debit: "Debit",
    credit: "Credit",
    transactionId: "ID",
    currency: "Currency",
    dateFormat: "YYYY-MM-DD",
    sign: "inflow-positive",
  } as const;
  const result = await parseImport(
    "Date,Text,Debit,Credit,ID,Currency\n2026-01-01,Purchase,1.25,,a,USD\n2026-01-02,Income,,4.50,b,USD\n2026-02-30,Bad,1,,c,USD\n2026-01-03,EUR,1,,d,EUR\n2026-01-04,Both,1,2,e,USD",
    m,
  );
  equal(result.rows.map((r) => r.amount_minor), [-125, 450]);
  equal(result.rows[0].source_id, "bank:a");
  equal(result.errors.length, 3);
  await rejects(() => parseImport("Date,Date,Amount\n2026-01-01,x,1", mapping));
  await rejects(() =>
    parseImport(
      "Date,Description,Amount\n2026-01-01,x,1",
      { ...mapping, dateFormat: "bad" } as any,
    )
  );
  equal(
    (await parseImport(
      "Date,Description,Amount\n2026-01-01,x,1,extra",
      mapping,
    )).errors.length,
    1,
  );
});
Deno.test("Stripe disabled by default, explicit safe mode and live authorization", () => {
  const mode = (values: Record<string, string>) =>
    stripeMode((key) => values[key]);
  equal(mode({}), { enabled: false, live: false });
  equal(
    mode({
      STRIPE_ENABLED: "true",
      STRIPE_MODE: "test",
      STRIPE_SECRET_KEY: "sk_test_synthetic",
    }),
    { enabled: true, live: false },
  );
  throws(() => mode({ STRIPE_ENABLED: "true" }));
  throws(() =>
    mode({
      STRIPE_ENABLED: "true",
      STRIPE_MODE: "test",
      STRIPE_SECRET_KEY: "sk_live_synthetic",
    })
  );
  throws(() =>
    mode({
      STRIPE_ENABLED: "true",
      STRIPE_MODE: "live",
      STRIPE_SECRET_KEY: "sk_live_synthetic",
    })
  );
  equal(
    mode({
      STRIPE_ENABLED: "true",
      STRIPE_MODE: "live",
      STRIPE_SECRET_KEY: "sk_live_synthetic",
      STRIPE_LIVE_AUTHORIZED: "true",
    }).live,
    true,
  );
});
Deno.test("webhook raw body HMAC tolerance, rotation signatures and tampering", async () => {
  const secret = "synthetic-test-secret",
    body = '{"id":"evt_test"}',
    time = 1793830636;
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = [
    ...new Uint8Array(
      await crypto.subtle.sign(
        "HMAC",
        key,
        new TextEncoder().encode(`${time}.${body}`),
      ),
    ),
  ].map((b) => b.toString(16).padStart(2, "0")).join("");
  await verifyWebhook(
    body,
    `t=${time},v1=bad,v1=${signature}`,
    secret,
    time * 1000,
  );
  await rejects(() =>
    verifyWebhook(body + " ", `t=${time},v1=${signature}`, secret, time * 1000)
  );
  await rejects(() =>
    verifyWebhook(
      body,
      `t=${time},v1=${signature}`,
      secret,
      (time + 301) * 1000,
    )
  );
  await rejects(() => verifyWebhook(body, "", secret, time * 1000));
  equal(constantTimeEqual("abc", "abc"), true);
  equal(constantTimeEqual("abc", "abcd"), false);
});
Deno.test("provider pending posted void signed transaction normalization", () => {
  for (const status of ["pending", "posted", "void"]) {
    const result = stripeTransaction({
      id: "fctxn_test",
      currency: "usd",
      amount: -123,
      status,
      transacted_at: 1793491200,
      updated: 1793491200,
      status_transitions: {
        posted_at: status === "posted" ? 1793491200 : null,
      },
    });
    equal(result.amount_minor, -123);
    equal(result.status, status);
    equal(result.posted_date, status === "posted" ? "2026-10-31" : null);
  }
  throws(() =>
    stripeTransaction({ currency: "eur", amount: 1, status: "posted" })
  );
});
Deno.test("export neutralizes spreadsheet formulas without corrupting numeric values", () => {
  equal(safeExport({ a: "=SUM(A1)", b: " @test", c: -123, d: "Ordinary" }), {
    a: "'=SUM(A1)",
    b: "' @test",
    c: -123,
    d: "Ordinary",
  });
});
Deno.test("bounded body rejects streams and content lengths before unbounded allocation", async () => {
  equal(
    await boundedBody(
      new Request("https://test", { method: "POST", body: "hello" }),
      5,
    ),
    "hello",
  );
  await rejects(() =>
    boundedBody(
      new Request("https://test", { method: "POST", body: "hello" }),
      4,
    )
  );
  await rejects(() =>
    boundedBody(
      new Request("https://test", {
        method: "POST",
        body: "x",
        headers: { "content-length": "100" },
      }),
      4,
    )
  );
  equal(new ApiError(403, "forbidden", "Forbidden").status, 403);
});
