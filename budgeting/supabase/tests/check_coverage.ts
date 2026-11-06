// Fixed production scope includes entrypoints, auth, CSV, API, webhook and worker.
const root = new URL("../functions/", import.meta.url);
const production: string[] = [];
async function walk(url: URL) {
  for await (const entry of Deno.readDir(url)) {
    const child = new URL(entry.name + (entry.isDirectory ? "/" : ""), url);
    if (entry.isDirectory) await walk(child);
    else if (entry.name.endsWith(".ts")) {
      production.push(decodeURIComponent(child.pathname));
    }
  }
}
await walk(root);
const text = await Deno.readTextFile(Deno.args[0] || "/tmp/coverage/lcov.info");
const records = new Map<string, { found: number; hit: number }>();
for (const block of text.split("end_of_record")) {
  const file = block.match(/^SF:(.+)$/m)?.[1];
  if (!file) continue;
  const lines = [...block.matchAll(/^DA:\d+,(\d+)/gm)];
  records.set(file.replace(/^file:\/\//, ""), {
    found: lines.length,
    hit: lines.filter((m) => Number(m[1]) > 0).length,
  });
}
let found = 0, hit = 0;
for (const file of production) {
  const record = records.get(file);
  if (!record || !record.found) {
    throw new Error(`Missing or empty production coverage: ${file}`);
  }
  found += record.found;
  hit += record.hit;
}
if (!found || hit / found < 0.7) {
  throw new Error(`Production coverage below 70%: ${hit}/${found}`);
}
console.log(
  `Fixed-scope production coverage: ${hit}/${found} (${
    (hit / found * 100).toFixed(2)
  }%), ${production.length} files`,
);
