import { strict as assert } from "node:assert";

Deno.test("prebuilt packaging keeps routes, assets, and security headers without offline worker", async () => {
  const fixture = await Deno.makeTempDir();
  const source = new URL("./package-vercel.ts", import.meta.url);
  const previous = Deno.cwd();
  try {
    await Deno.mkdir(`${fixture}/build/web/assets`, { recursive: true });
    await Deno.writeTextFile(
      `${fixture}/build/web/main.dart.js`,
      "/* synthetic */",
    );
    await Deno.writeTextFile(
      `${fixture}/build/web/assets/config.yaml`,
      "currency: USD",
    );
    await Deno.writeTextFile(
      `${fixture}/build/web/flutter_service_worker.js`,
      "/* no offline */",
    );
    await Deno.writeTextFile(
      `${fixture}/vercel.json`,
      JSON.stringify({
        headers: [{ headers: [{ key: "Cache-Control", value: "no-store" }] }],
      }),
    );
    Deno.chdir(fixture);
    await import(`${source.href}?fixture=${crypto.randomUUID()}`);
    const output = JSON.parse(
      await Deno.readTextFile(".vercel/output/config.json"),
    );
    assert.equal(output.version, 3);
    assert.equal(output.routes[0].headers["Cache-Control"], "no-store");
    assert.deepEqual(output.routes[1], { handle: "filesystem" });
    assert.equal(output.routes[2].dest, "/index.html");
    assert.equal(
      await Deno.readTextFile(".vercel/output/static/assets/config.yaml"),
      "currency: USD",
    );
    await assert.rejects(
      () => Deno.stat(".vercel/output/static/flutter_service_worker.js"),
      Deno.errors.NotFound,
    );
    await Deno.writeTextFile("build/web/.env", "SYNTHETIC=true");
    await assert.rejects(
      () => import(`${source.href}?fixture=${crypto.randomUUID()}`),
      /sensitive file/,
    );
  } finally {
    Deno.chdir(previous);
    await Deno.remove(fixture, { recursive: true });
  }
});
