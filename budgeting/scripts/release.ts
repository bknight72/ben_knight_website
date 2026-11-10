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
    assert.match(project, /^[a-z0-9_-]+$/);
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

class ReleaseSmokeError extends Error {}

async function request(url: string, bypass = "", label = "Readiness") {
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
      if (response.status !== 200) {
        const status = response.status;
        await response.body?.cancel();
        const guidance = (status === 401 || status === 403) && bypass
          ? "Verify the automation bypass secret and Deployment Protection settings."
          : (status === 401 || status === 403)
          ? "Check Deployment Protection for frontend requests, or anonymous health access for backend requests."
          : status >= 300 && status < 400
          ? "Unexpected redirect; check canonical domain and routing settings."
          : "Check deployment routing or backend readiness.";
        throw new ReleaseSmokeError(
          `${label} returned HTTP ${status}. ${guidance}`,
        );
      }
      return response;
    } catch (error) {
      last = error instanceof ReleaseSmokeError ? error : new ReleaseSmokeError(
        `${label} request failed (network, TLS, redirect, or timeout). Response details withheld.`,
      );
      if (attempt < 4) {
        await new Promise((resolve) => setTimeout(resolve, 3000));
      }
    }
  }
  throw last;
}

export async function smoke(value: string, env: Settings) {
  try {
    preflight(env);
  } catch {
    throw new ReleaseSmokeError(
      "Public release configuration is missing or invalid in the deploy job.",
    );
  }
  let url: URL;
  try {
    url = allowedOrigin(
      value,
      env.BUDGETING_PRODUCTION_URL ?? "https://budgeting.benknight.dev",
      env.VERCEL_PROJECT_NAME,
    );
  } catch {
    throw new ReleaseSmokeError(
      "Smoke URL is not an approved HTTPS deployment origin.",
    );
  }
  const bypass = url.hostname.endsWith(".vercel.app")
    ? env.VERCEL_AUTOMATION_BYPASS_SECRET ?? ""
    : "";
  const expected =
    JSON.parse(await Deno.readTextFile("vercel.json")).headers[0].headers;
  for (const path of ["/", "/launch-check", "/main.dart.js"]) {
    console.log(`Checking frontend ${path}`);
    const response = await request(
      new URL(path, url).href,
      bypass,
      `Frontend ${path}`,
    );
    for (const header of expected) {
      if (response.headers.get(header.key) !== header.value) {
        throw new ReleaseSmokeError(
          `Frontend ${path}: missing or unexpected ${header.key} header. Check the packaged Vercel routes/headers and platform overrides.`,
        );
      }
    }
    if (
      !(path.endsWith(".js") ? /javascript/ : /text\/html/).test(
        response.headers.get("content-type") ?? "",
      )
    ) {
      throw new ReleaseSmokeError(
        `Frontend ${path}: unexpected content type. Check static-file precedence and SPA fallback.`,
      );
    }
    const body = await response.text();
    if (!body.length) {
      throw new ReleaseSmokeError(`Frontend ${path}: empty response body.`);
    }
    if (path.endsWith(".js")) {
      if (
        !body.includes(env.SUPABASE_URL!) ||
        !body.includes(env.SUPABASE_PUBLISHABLE_KEY!)
      ) {
        throw new ReleaseSmokeError(
          "Frontend /main.dart.js: deployed public configuration does not match this release. Check the deployed artifact and build variables.",
        );
      }
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
      if (hash !== record.files[name]) {
        throw new ReleaseSmokeError(
          `Frontend ${path}: hosted bytes differ from the tested release. Check stale deployment/aliasing or platform content transformation.`,
        );
      }
    }
  }
  await backendHealth(env);
  console.log(
    "HTTPS, routing, security headers, configured assets, and backend health passed.",
  );
}

export async function backendHealth(env: Settings) {
  try {
    preflight(env);
  } catch {
    throw new ReleaseSmokeError(
      "Public backend configuration is missing or invalid.",
    );
  }
  console.log("Checking anonymous backend health");
  const health = await request(
    `${env.SUPABASE_URL}/functions/v1/api/health`,
    "",
    "Backend /health",
  );
  let readiness;
  try {
    readiness = await health.json();
  } catch {
    throw new ReleaseSmokeError("Backend /health did not return valid JSON.");
  }
  if (readiness?.status !== "ok" || readiness?.database !== "connected") {
    throw new ReleaseSmokeError(
      "Backend /health is not reporting status ok and database connected. Check the Supabase API function and database readiness.",
    );
  }
  console.log("Anonymous backend health passed.");
}

class ReleaseTargetError extends Error {}

export async function supabaseTarget(env: Settings) {
  const ref = env.SUPABASE_PROJECT_REF ?? "";
  if (
    !/^[a-z]{20}$/.test(ref) ||
    env.SUPABASE_URL !== `https://${ref}.supabase.co`
  ) {
    throw new ReleaseTargetError(
      "SUPABASE_PROJECT_REF must be a 20-letter project ref matching SUPABASE_URL exactly (without trailing slash). Check budgeting-production variables.",
    );
  }
  if (!env.SUPABASE_ACCESS_TOKEN) {
    throw new ReleaseTargetError(
      "SUPABASE_ACCESS_TOKEN is empty or unavailable to this job. Add it under Secrets (not Variables) in this repository's budgeting-production GitHub environment, then start a new workflow run.",
    );
  }
  if (/\s/.test(env.SUPABASE_ACCESS_TOKEN)) {
    throw new ReleaseTargetError(
      "SUPABASE_ACCESS_TOKEN contains whitespace or a line break. Replace the GitHub environment secret with only the raw account access token, on one line, without a Bearer prefix or an environment-file assignment.",
    );
  }
  let response: Response;
  try {
    response = await fetch(`https://api.supabase.com/v1/projects/${ref}`, {
      headers: { Authorization: `Bearer ${env.SUPABASE_ACCESS_TOKEN}` },
      redirect: "error",
      signal: AbortSignal.timeout(20000),
    });
  } catch {
    throw new ReleaseTargetError(
      "Cannot reach the Supabase Management API. Check network/TLS connectivity.",
    );
  }
  if (response.status !== 200) {
    throw new ReleaseTargetError(
      `Supabase project lookup returned HTTP ${response.status}. Check project ref, account token permissions, and Supabase availability.`,
    );
  }
  let project;
  try {
    project = await response.json();
  } catch {
    throw new ReleaseTargetError(
      "Supabase project lookup returned invalid JSON.",
    );
  }
  if ((project?.ref ?? project?.id) !== ref) {
    throw new ReleaseTargetError(
      "Supabase project lookup returned an unexpected project identity.",
    );
  }
  if (project?.status !== "ACTIVE_HEALTHY") {
    throw new ReleaseTargetError(
      "Supabase project is not ACTIVE_HEALTHY. Verify it is not paused, restoring, or unhealthy before deploying.",
    );
  }
  console.log("Verified active Supabase backend project identity.");
}

export async function target(env: Settings) {
  for (
    const [name, pattern] of [
      ["VERCEL_PROJECT_ID", /^prj_[A-Za-z0-9]+$/],
      ["VERCEL_ORG_ID", /^(?:team_|user_)?[A-Za-z0-9]+$/],
      ["VERCEL_PROJECT_NAME", /^[a-z0-9_-]+$/],
      ["VERCEL_TOKEN", /^\S+$/],
    ] as const
  ) {
    if (!pattern.test(env[name] ?? "")) {
      throw new ReleaseTargetError(
        `${name} is missing or malformed. Check the budgeting-production GitHub environment settings.`,
      );
    }
  }
  let response: Response;
  try {
    response = await fetch(
      `https://api.vercel.com/v9/projects/${env.VERCEL_PROJECT_ID}?teamId=${env.VERCEL_ORG_ID}`,
      {
        headers: { Authorization: `Bearer ${env.VERCEL_TOKEN}` },
        redirect: "error",
        signal: AbortSignal.timeout(20000),
      },
    );
  } catch {
    throw new ReleaseTargetError(
      "Cannot reach the Vercel project API. Check network/TLS connectivity and retry.",
    );
  }
  if (response.status !== 200) {
    const guidance = response.status === 401 || response.status === 403
      ? "Check VERCEL_TOKEN validity, scope, and access to the configured account/team."
      : response.status === 404
      ? "Check VERCEL_PROJECT_ID and VERCEL_ORG_ID; the token must have access to that project."
      : "Check Vercel API availability and account settings.";
    throw new ReleaseTargetError(
      `Vercel project lookup returned HTTP ${response.status}. ${guidance}`,
    );
  }
  let project;
  try {
    project = await response.json();
  } catch {
    throw new ReleaseTargetError(
      "Vercel project lookup returned invalid JSON.",
    );
  }
  for (
    const [field, setting] of [["id", "VERCEL_PROJECT_ID"], [
      "accountId",
      "VERCEL_ORG_ID",
    ], ["name", "VERCEL_PROJECT_NAME"]] as const
  ) {
    if (project?.[field] !== env[setting]) {
      throw new ReleaseTargetError(
        `Vercel project identity does not match ${setting}. Verify the dedicated project's GitHub environment variable.`,
      );
    }
  }
  // The CLI receives an artifact-only directory, not a repository checkout.
  if (project.rootDirectory) {
    throw new ReleaseTargetError(
      "Vercel Root Directory must be empty for this prebuilt pipeline. Clear it in the dedicated project's Build and Deployment settings (do not use budgeting).",
    );
  }
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
      case "supabase-target":
        await supabaseTarget(env);
        break;
      case "backend-health":
        await backendHealth(env);
        break;
      case "smoke":
        await smoke(Deno.args[1], env);
        break;
      default:
        throw new Error("Unknown release command");
    }
  } catch (error) {
    console.error(
      error instanceof ReleaseTargetError
        ? `Release target check failed: ${error.message}`
        : error instanceof ReleaseSmokeError
        ? `Release smoke check failed: ${error.message}`
        : "Release check failed. Verify configuration, project identity, artifact integrity, or readiness; values withheld.",
    );
    Deno.exit(1);
  }
}
