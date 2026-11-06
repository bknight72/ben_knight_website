const config = JSON.parse(await Deno.readTextFile("vercel.json"));
await Deno.stat("build/web/main.dart.js");
await Deno.remove(".vercel/output", { recursive: true }).catch((e) => {
  if (!(e instanceof Deno.errors.NotFound)) throw e;
});
await Deno.mkdir(".vercel/output/static", { recursive: true });
async function copy(from: string, to: string) {
  for await (const entry of Deno.readDir(from)) {
    if (entry.name === "flutter_service_worker.js") continue;
    if (
      entry.isSymlink || entry.name.startsWith(".env") ||
      /\.(?:pem|key|age|dump|csv)$/.test(entry.name)
    ) throw new Error("Refusing sensitive file or symlink in static artifact.");
    const target = `${to}/${entry.name}`;
    if (entry.isDirectory) {
      await Deno.mkdir(target);
      await copy(`${from}/${entry.name}`, target);
    } else await Deno.copyFile(`${from}/${entry.name}`, target);
  }
}
await copy("build/web", ".vercel/output/static");
await Deno.writeTextFile(
  ".vercel/output/config.json",
  JSON.stringify(
    {
      version: 3,
      routes: [
        {
          src: "/.*",
          headers: Object.fromEntries(
            config.headers[0].headers.map((
              h: { key: string; value: string },
            ) => [h.key, h.value]),
          ),
          continue: true,
        },
        { handle: "filesystem" },
        { src: "/.*", dest: "/index.html" },
      ],
    },
    null,
    2,
  ),
);
console.log(
  "Packaged .vercel/output; deployment requires separate authorization.",
);
