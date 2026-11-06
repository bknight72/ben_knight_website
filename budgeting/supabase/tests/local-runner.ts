import { browserRuntimeReady } from "./local-readiness.ts";

// CLI status contains disposable local keys; consume in memory, never print or persist them.
const status = JSON.parse(await new Response(Deno.stdin.readable).text());
for (
  const [key, value] of Object.entries({
    LOCAL_ANON_KEY: status.ANON_KEY,
    LOCAL_SERVICE_KEY: status.SERVICE_ROLE_KEY,
    LOCAL_SUPABASE_URL: "http://127.0.0.1:54321",
  })
) {
  if (typeof value !== "string" || !value) {
    throw new Error(`Missing local CLI status field for ${key}`);
  }
  Deno.env.set(key, value);
}
if (typeof status.JWT_SECRET !== "string") {
  throw new Error(
    "Local JWT signing secret is required for signed expired-session regression",
  );
}
Deno.env.set("LOCAL_JWT_SECRET", status.JWT_SECRET);
const browserEnabled = Deno.env.get("BUDGETING_BROWSER_INTEGRATION") === "true";
let server: Deno.ChildProcess | undefined;
const browserOrigin = "http://127.0.0.1:58081";
if (browserEnabled) {
  const nginx = (await Deno.readTextFile("nginx.conf"))
    .replace("listen 8080;", "listen 127.0.0.1:58081;")
    .replace("connect-src 'self'", "connect-src 'self' http://127.0.0.1:54321");
  await Deno.writeTextFile("/run/budgeting-browser/nginx.conf", nginx);
  const started = await new Deno.Command("docker", { args: ["run", "-d", "--name", Deno.env.get("LOCAL_BROWSER_SERVER")!, "--network", "host", "--user", "nginx", "--read-only", "--tmpfs", "/tmp/nginx:rw,uid=101,gid=101,mode=0700", "-v", `${Deno.env.get("LOCAL_BROWSER_ARTIFACT")}:/usr/share/nginx/html:ro`, "-v", `${Deno.env.get("LOCAL_BROWSER_VOLUME")}:/run/budgeting-browser:ro`, "--entrypoint", "nginx", "nginx:latest", "-c", "/run/budgeting-browser/nginx.conf", "-g", "daemon off;"], stdout: "null", stderr: "inherit" }).output();
  if (!started.success) throw new Error("Local browser static server failed to start");
  // Keep test-only CORS configuration out of production and out of the repository.
  await Deno.writeTextFile(
    "/run/budgeting-browser/functions.env",
    `ALLOWED_ORIGINS=${browserOrigin}\nSTRIPE_ENABLED=false\nSTRIPE_LIVE_AUTHORIZED=false\n`,
    { mode: 0o600 },
  );
  const installedCli = "/opt/budgeting-cli/node_modules/.bin/supabase";
  const hasInstalledCli = await Deno.stat(installedCli).then(() => true).catch(() => false);
  server = new Deno.Command(hasInstalledCli ? installedCli : "npx", {
    args: [
      ...(hasInstalledCli ? [] : ["--yes", "supabase"]),
      "functions",
      "serve",
      "--env-file",
      "/run/budgeting-browser/functions.env",
    ],
    stdout: "null",
    stderr: "inherit",
  }).spawn();
  let ready = false;
  for (let attempt = 0; attempt < 60; attempt++) {
    try {
      const response = await fetch(
        "http://127.0.0.1:54321/functions/v1/api/health",
        { headers: { Origin: browserOrigin } },
      );
      if (await browserRuntimeReady(response, browserOrigin)) {
        ready = true;
        break;
      }
    } catch { /* Local runtime is still starting. */ }
    await new Promise((resolve) => setTimeout(resolve, 1000));
  }
  if (!ready) {
    server.kill("SIGTERM");
    throw new Error("Local browser CORS function runtime did not become ready");
  }
}
const result = await new Deno.Command(Deno.execPath(), {
  args: [
    "run",
    "--allow-net",
    "--allow-env",
    "--allow-run=docker",
    ...(Deno.env.get("LOCAL_BROWSER_FIXTURE")
      ? ["--allow-write=/run/budgeting-browser/fixture.json"]
      : []),
    "supabase/tests/local_integration.ts",
  ],
  stdin: "null",
  stdout: "inherit",
  stderr: "inherit",
}).output();
let code = result.code;
if (code === 0 && browserEnabled) {
  const browser = await new Deno.Command("docker", {
    args: [
      "run",
      "--rm",
      "--network",
      "host",
      "--read-only",
      "--tmpfs",
      "/tmp:rw,nosuid,mode=1777",
      "-v",
      `${Deno.env.get("LOCAL_BROWSER_VOLUME")}:/run/budgeting-browser:ro`,
      "-v",
      `${Deno.cwd()}/supabase/tests:/tests:ro`,
      "-e",
      `BUDGET_BROWSER_URL=${browserOrigin}`,
      "--entrypoint",
      "node",
      "budgeting-browser:latest",
      "/tests/browser_integration.mjs",
    ],
    stdout: "inherit",
    stderr: "inherit",
  }).output();
  code = browser.code;
}
if (server) {
  server.kill("SIGTERM");
  await server.status;
}
Deno.exit(code);
