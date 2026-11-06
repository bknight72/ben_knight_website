import { strict as assert } from "node:assert";
const vercel = JSON.parse(await Deno.readTextFile("budgeting/vercel.json"));
const nginx = await Deno.readTextFile("budgeting/nginx.conf");
const headers = Object.fromEntries(
  vercel.headers[0].headers.map((
    h: { key: string; value: string },
  ) => [h.key, h.value]),
);
assert.equal(headers["Cache-Control"], "no-store");
assert.equal(headers["X-Frame-Options"], "DENY");
assert.ok(
  headers["Content-Security-Policy"].includes("frame-ancestors 'none'"),
);
assert.ok(nginx.includes(headers["Content-Security-Policy"]));
const kilo = JSON.parse(await Deno.readTextFile("kilo.json"));
assert.equal(kilo.permission.read["**/.env"], "deny");
assert.equal(kilo.permission.read["**/.env.example"], "allow");
assert.equal(kilo.permission.read["**/*.age"], "deny");
console.log("Security header parity and secret guard configuration passed.");
