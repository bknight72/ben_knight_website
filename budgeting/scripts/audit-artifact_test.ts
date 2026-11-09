import { strict as assert } from "node:assert";

Deno.test("artifact audit permits public keys but refuses backend secrets and empty artifacts", async () => {
  const fixture = await Deno.makeTempDir();
  const source = new URL("./audit-artifact.ts", import.meta.url);
  const previous = Deno.cwd();
  try {
    await Deno.mkdir(`${fixture}/build/web`, { recursive: true });
    Deno.chdir(fixture);
    await assert.rejects(
      () => import(`${source.href}?case=${crypto.randomUUID()}`),
      /empty/,
    );
    await Deno.writeTextFile(
      "build/web/main.dart.js",
      "pk_test_synthetic_public_key sb_publishable_synthetic_public_key",
    );
    await import(`${source.href}?case=${crypto.randomUUID()}`);
    await Deno.writeTextFile(
      "build/web/main.dart.js",
      "sb_secret_synthetic_for_test_only_123456",
    );
    await assert.rejects(
      () => import(`${source.href}?case=${crypto.randomUUID()}`),
      /credential/,
    );
    await Deno.writeTextFile(
      "build/web/main.dart.js",
      "sk_test_synthetic_for_test_only_123456",
    );
    await assert.rejects(
      () => import(`${source.href}?case=${crypto.randomUUID()}`),
      /credential/,
    );
    const encoded = btoa(JSON.stringify({ role: "service_role" })).replaceAll(
      "=",
      "",
    ).replaceAll("+", "-").replaceAll("/", "_");
    await Deno.writeTextFile(
      "build/web/main.dart.js",
      `eyJhbGciOiJIUzI1NiJ9.${encoded}.syntheticSignature`,
    );
    await assert.rejects(
      () => import(`${source.href}?case=${crypto.randomUUID()}`),
      /Privileged JWT/,
    );
  } finally {
    Deno.chdir(previous);
    await Deno.remove(fixture, { recursive: true });
  }
});
