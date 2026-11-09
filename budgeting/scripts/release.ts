import { strict as assert } from "node:assert";

type Settings = Record<string, string | undefined>;
export function preflight(env: Settings) {
  const url = new URL(env.SUPABASE_URL ?? "");
  assert.match(url.hostname, /^[a-z0-9]{20}\.supabase\.co$/);
  assert.equal(url.protocol, "https:");
  assert.equal(url.origin + "/", url.href);
  assert.equal(url.username + url.password + url.port, "");
  assert.match(
    env.SUPABASE_PUBLISHABLE_KEY ?? "",
    /^sb_publishable_[A-Za-z0-9_-]{20,}$/,
  );
  assert.ok(
    !/placeholder|your[_-]|example/i.test(env.SUPABASE_PUBLISHABLE_KEY!),
  );
  assert.equal(env.STRIPE_ENABLED, "false");
  assert.equal(env.STRIPE_PUBLISHABLE_KEY ?? "", "");
}

export function allowedOrigin(
  value: string,
  production: string,
  project?: string,
): URL {
  const url = new URL(value);
  const canonical = new URL(production);
  assert.equal(canonical.origin, "https://budgeting.benknight.dev");
  assert.equal(url.protocol, "https:");
  assert.ok(
    url.origin === canonical.origin ||
      /^[a-z0-9-]+\.vercel\.app$/.test(url.hostname),
  );
  assert.equal(url.href, url.origin + "/");
  assert.equal(url.username + url.password + url.port, "");
  if (url.origin !== canonical.origin && project) {
    assert.match(project, /^[a-z0-9-]+$/);
    assert.ok(
      url.hostname.startsWith(`${project}-`),
      "Unexpected deployment project",
    );
  }
  return url;
}

async function inventory(
  root: string,
  prefix = "",
): Promise<Record<string, string>> {
  const files: Record<string, string> = {};
  for await (const entry of Deno.readDir(`${root}/${prefix}`)) {
    assert.ok(!entry.isSymlink, "Release artifact cannot contain symlinks");
    const name = prefix + entry.name;
    if (entry.isDirectory) {
      Object.assign(files, await inventory(root, `${name}/`));
    } else {
      assert.ok(entry.isFile, "Unexpected artifact entry");
      const digest = await crypto.subtle.digest(
        "SHA-256",
        await Deno.readFile(`${root}/${name}`),
      );
      files[name] = Array.from(
        new Uint8Array(digest),
        (b) => b.toString(16).padStart(2, "0"),
      ).join("");
    }
  }
  return Object.fromEntries(
    Object.entries(files).sort(([a], [b]) => a.localeCompare(b)),
  );
}

export async function manifest(root: string, sha: string, versions: string) {
  assert.match(sha, /^[a-f0-9]{40}$/);
  const files = await inventory(`${root}/.vercel/output`);
  for (
    const name of ["config.json", "static/index.html", "static/main.dart.js"]
  ) assert.ok(files[name], "Incomplete release output");
  assert.ok(
    !Object.keys(files).some((name) =>
      /(?:^|\/)(?:\.env[^/]*|flutter_service_worker\.js)$/.test(name)
    ),
  );
  const config = JSON.parse(
    await Deno.readTextFile(`${root}/.vercel/output/config.json`),
  );
  assert.equal(config.version, 3);
  assert.deepEqual(config.routes[1], { handle: "filesystem" });
  assert.equal(config.routes[2].dest, "/index.html");
  assert.equal(config.routes[0].headers["Cache-Control"], "no-store");
  await Deno.writeTextFile(
    `${root}/manifest.json`,
    JSON.stringify(
      {
        source: sha,
        run: Deno.env.get("GITHUB_RUN_ID") ?? "local",
        attempt: Deno.env.get("GITHUB_RUN_ATTEMPT") ?? "local",
        builtAt: new Date().toISOString(),
        versions,
        files,
      },
      null,
      2,
    ),
  );
}

export async function verify(root: string, sha: string) {
  assert.match(sha, /^[a-f0-9]{40}$/);
  for (
    const [path, names] of [[root, [".vercel", "manifest.json"]], [
      `${root}/.vercel`,
      ["output"],
    ]] as const
  ) {
    const entries = [];
    for await (const entry of Deno.readDir(path)) {
      assert.ok(!entry.isSymlink, "Unexpected artifact symlink");
      entries.push(entry.name);
    }
    assert.deepEqual(
      entries.sort(),
      [...names].sort(),
      "Unexpected release metadata",
    );
  }
  const record = JSON.parse(await Deno.readTextFile(`${root}/manifest.json`));
  assert.equal(record.source, sha, "Release source mismatch");
  assert.deepEqual(
    await inventory(`${root}/.vercel/output`),
    record.files,
    "Artifact checksum mismatch",
  );
  for (
    const name of ["config.json", "static/index.html", "static/main.dart.js"]
  ) assert.ok(record.files[name]);
}

async function request(url: string, bypass = "") {
  const headers: Record<string, string> = bypass
    ? { "x-vercel-protection-bypass": bypass }
    : {};
  let last: unknown;
  for (let attempt = 0; attempt < 5; attempt++) {
    try {
      const response = await fetch(url, {
        headers,
        redirect: "error",
        signal: AbortSignal.timeout(20000),
      });
      assert.equal(response.status, 200, "Readiness returned non-200");
      return response;
    } catch (error) {
      last = error;
      if (attempt < 4) {
        await new Promise((resolve) => setTimeout(resolve, 3000));
      }
    }
  }
  throw last;
}

export async function smoke(value: string, env: Settings) {
  preflight(env);
  const url = allowedOrigin(
    value,
    env.BUDGETING_PRODUCTION_URL ?? "https://budgeting.benknight.dev",
    env.VERCEL_PROJECT_NAME,
  );
  const bypass = url.hostname.endsWith(".vercel.app")
    ? env.VERCEL_AUTOMATION_BYPASS_SECRET ?? ""
    : "";
  const expected =
    JSON.parse(await Deno.readTextFile("vercel.json")).headers[0].headers;
  for (const path of ["/", "/launch-check", "/main.dart.js"]) {
    const response = await request(new URL(path, url).href, bypass);
    for (const header of expected) {
      assert.equal(
        response.headers.get(header.key),
        header.value,
        `Missing security header: ${header.key}`,
      );
    }
    assert.match(
      response.headers.get("content-type") ?? "",
      path.endsWith(".js") ? /javascript/ : /text\/html/,
    );
    const body = await response.text();
    assert.ok(body.length > 0);
    if (path.endsWith(".js")) {
      assert.ok(
        body.includes(env.SUPABASE_URL!) &&
          body.includes(env.SUPABASE_PUBLISHABLE_KEY!),
        "Unexpected deployed configuration",
      );
    }
    if (env.RELEASE_ROOT) {
      const record = JSON.parse(
        await Deno.readTextFile(`${env.RELEASE_ROOT}/manifest.json`),
      );
      const name = path.endsWith(".js")
        ? "static/main.dart.js"
        : "static/index.html";
      const digest = await crypto.subtle.digest(
        "SHA-256",
        new TextEncoder().encode(body),
      );
      const hash = Array.from(
        new Uint8Array(digest),
        (b) => b.toString(16).padStart(2, "0"),
      ).join("");
      assert.equal(
        hash,
        record.files[name],
        "Hosted bytes differ from tested release",
      );
    }
  }
  const health = await request(`${env.SUPABASE_URL}/functions/v1/api/health`);
  const readiness = await health.json();
  assert.equal(readiness.status, "ok");
  assert.equal(readiness.database, "connected");
  console.log(
    "HTTPS, routing, security headers, configured assets, and backend health passed.",
  );
}

export async function target(env: Settings) {
  assert.match(env.VERCEL_PROJECT_ID ?? "", /^prj_[A-Za-z0-9]+$/);
  assert.match(env.VERCEL_ORG_ID ?? "", /^(?:team_|user_)?[A-Za-z0-9]+$/);
  assert.ok(env.VERCEL_TOKEN && !/\s/.test(env.VERCEL_TOKEN));
  assert.ok(
    env.VERCEL_PROJECT_NAME && /^[a-z0-9-]+$/.test(env.VERCEL_PROJECT_NAME),
  );
  const response = await fetch(
    `https://api.vercel.com/v9/projects/${env.VERCEL_PROJECT_ID}?teamId=${env.VERCEL_ORG_ID}`,
    {
      headers: { Authorization: `Bearer ${env.VERCEL_TOKEN}` },
      redirect: "error",
      signal: AbortSignal.timeout(20000),
    },
  );
  assert.equal(response.status, 200, "Cannot verify Vercel project");
  const project = await response.json();
  assert.equal(project.id, env.VERCEL_PROJECT_ID);
  assert.equal(project.accountId, env.VERCEL_ORG_ID);
  assert.equal(project.name, env.VERCEL_PROJECT_NAME);
  // The CLI receives an artifact-only directory, not a repository checkout.
  assert.ok(
    !project.rootDirectory,
    "Prebuilt project root directory must be empty",
  );
  console.log("Verified dedicated Vercel project identity.");
}

if (import.meta.main) {
  try {
    const env = Deno.env.toObject();
    switch (Deno.args[0]) {
      case "preflight":
        preflight(env);
        break;
      case "manifest":
        await manifest(
          Deno.args[1],
          env.SOURCE_SHA ?? "",
          env.TOOL_VERSIONS ?? "",
        );
        break;
      case "verify":
        await verify(Deno.args[1], Deno.args[2]);
        break;
      case "target":
        await target(env);
        break;
      case "smoke":
        await smoke(Deno.args[1], env);
        break;
      default:
        throw new Error("Unknown release command");
    }
  } catch {
    console.error(
      "Release check failed. Verify configuration, project identity, artifact integrity, or readiness; values withheld.",
    );
    Deno.exit(1);
  }
}
