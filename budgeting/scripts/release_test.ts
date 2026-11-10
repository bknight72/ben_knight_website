import { strict as assert } from "node:assert";
import {
  allowedOrigin,
  backendHealth,
  checkPublicConfig,
  checkPublicJs,
  manifest,
  preflight,
  publicConfig,
  smoke,
  supabaseTarget,
  target,
  verify,
  writePublicConfig,
} from "./release.ts";
import { stripeMode } from "../supabase/functions/_shared/core.ts";

const env = {
  SUPABASE_URL: "https://abcdefghijklmnopqrst.supabase.co",
  SUPABASE_PUBLISHABLE_KEY: "sb_publishable_abcdefghijklmnopqrstuvwxyz",
  STRIPE_ENABLED: "false",
};
Deno.test("workflow allows only master pushes and manual release events with gated jobs", async () => {
  const workflow = await Deno.readTextFile(
    "../.github/workflows/budgeting-ci.yml",
  );
  const events = workflow.split("permissions:")[0];
  assert.match(events, /push:\s+branches: \[master\]\s+workflow_dispatch:/);
  assert.doesNotMatch(
    events,
    /schedule:|workflow_run:|pull_request_target:|tags:/,
  );
  for (const name of ["release-build", "deploy"]) {
    const job = workflow.split(`\n  ${name}:`)[1].split(/\n  [a-z][a-z-]*:/)[0];
    assert.match(job, /vars\.BUDGETING_DEPLOY_ENABLED == 'true'/);
    assert.match(job, /github\.ref == 'refs\/heads\/master'/);
    assert.match(
      job,
      /github\.event_name == 'push' \|\| github\.event_name == 'workflow_dispatch'/,
    );
    assert.match(job, /needs:/);
    assert.ok(
      job.includes("STRIPE_ENABLED: ${{ vars.STRIPE_ENABLED || 'false' }}"),
    );
    assert.ok(
      job.includes(
        "STRIPE_PUBLISHABLE_KEY: ${{ vars.STRIPE_PUBLISHABLE_KEY || '' }}",
      ),
    );
  }
  assert.match(
    workflow,
    /group: budgeting-production\s+cancel-in-progress: false/,
  );
  assert.match(
    workflow,
    /artifact-ids: \$\{\{ needs.release-build.outputs.artifact-id \}\}/,
  );
  assert.match(workflow, /retention-days: 30/);
  assert.match(workflow, /Hosted bytes|RELEASE_ROOT=/);
  assert.match(
    workflow,
    /-e SUPABASE_URL -e SUPABASE_PUBLISHABLE_KEY -e STRIPE_ENABLED -e STRIPE_PUBLISHABLE_KEY \\\s+denoland\/deno:latest run --allow-env --allow-read \\\s+budgeting\/scripts\/release.ts verify/,
  );
  const validation = workflow.split("\n  release-build:")[0];
  assert.doesNotMatch(validation, /vars\.STRIPE_|secrets\./);
  const backend = workflow.indexOf(
    "name: Validate Supabase target and deploy backend functions",
  );
  const health = workflow.indexOf(
    "name: Verify backend health before frontend publication",
  );
  const publish = workflow.indexOf(
    "name: Validate target and publish prebuilt output",
  );
  assert.ok(
    backend >
        workflow.indexOf("name: Verify Vercel target before backend changes") &&
      health > backend && publish > health,
  );
  assert.match(workflow, /for function in api stripe-webhook worker; do/);
  assert.match(workflow, /--remote="\$2" --use-api --yes/);
  assert.doesNotMatch(
    workflow,
    /supabase (?:db push|migration|secrets set)|docker\.sock|--debug/,
  );
  assert.equal(
    (workflow.match(/secrets\.SUPABASE_ACCESS_TOKEN/g) ?? []).length,
    1,
  );
  assert.ok(workflow.indexOf("secrets.SUPABASE_ACCESS_TOKEN") > backend);
  assert.ok(workflow.indexOf("secrets.SUPABASE_ACCESS_TOKEN") < health);
  for (const action of workflow.matchAll(/uses: (.+)/g)) {
    assert.match(action[1], /@[a-f0-9]{40}(?:\s|$)/);
  }
});
Deno.test("Supabase preflight binds URL to active authenticated project without leaking secrets", async () => {
  const original = globalThis.fetch;
  const settings = {
    ...env,
    SUPABASE_PROJECT_REF: "abcdefghijklmnopqrst",
    SUPABASE_ACCESS_TOKEN: "synthetic-account-token",
  };
  try {
    globalThis.fetch = async (input, init) => {
      assert.equal(
        String(input),
        `https://api.supabase.com/v1/projects/${settings.SUPABASE_PROJECT_REF}`,
      );
      assert.equal(
        new Headers(init?.headers).get("Authorization"),
        `Bearer ${settings.SUPABASE_ACCESS_TOKEN}`,
      );
      assert.equal(init?.redirect, "error");
      return Response.json({
        id: settings.SUPABASE_PROJECT_REF,
        status: "ACTIVE_HEALTHY",
      });
    };
    await supabaseTarget(settings);
    await assert.rejects(
      () =>
        supabaseTarget({
          ...settings,
          SUPABASE_URL: "https://wrong.supabase.co",
        }),
      /matching SUPABASE_URL/,
    );
    await assert.rejects(
      () => supabaseTarget({ ...settings, SUPABASE_ACCESS_TOKEN: "" }),
      /empty or unavailable/,
    );
    for (
      const token of [
        " synthetic-credential",
        "synthetic-credential\n",
        "Bearer synthetic-credential",
        "synthetic credential value",
      ]
    ) {
      await assert.rejects(
        () => supabaseTarget({ ...settings, SUPABASE_ACCESS_TOKEN: token }),
        (error: Error) => {
          assert.match(error.message, /contains whitespace or a line break/);
          assert.ok(!error.message.includes(token));
          return true;
        },
      );
    }
    for (
      const project of [{ id: "wrong", status: "ACTIVE_HEALTHY" }, {
        id: settings.SUPABASE_PROJECT_REF,
        status: "INACTIVE",
      }]
    ) {
      globalThis.fetch = async () => Response.json(project);
      await assert.rejects(
        () => supabaseTarget(settings),
        /identity|ACTIVE_HEALTHY/,
      );
    }
    for (const status of [401, 403, 404, 500]) {
      globalThis.fetch = async () =>
        new Response(settings.SUPABASE_ACCESS_TOKEN, { status });
      await assert.rejects(() => supabaseTarget(settings), (error: Error) => {
        assert.match(error.message, new RegExp(`HTTP ${status}`));
        assert.ok(!error.message.includes(settings.SUPABASE_ACCESS_TOKEN));
        return true;
      });
    }
    globalThis.fetch = async () => {
      throw new Error(settings.SUPABASE_ACCESS_TOKEN);
    };
    await assert.rejects(
      () => supabaseTarget(settings),
      /Cannot reach the Supabase Management API/,
    );
  } finally {
    globalThis.fetch = original;
  }
});
Deno.test("standalone backend gate is anonymous and requires connected JSON readiness", async () => {
  const original = globalThis.fetch;
  try {
    globalThis.fetch = async (input, init) => {
      assert.equal(
        String(input),
        `${env.SUPABASE_URL}/functions/v1/api/health`,
      );
      assert.equal(new Headers(init?.headers).get("Authorization"), null);
      assert.equal(
        new Headers(init?.headers).get("x-vercel-protection-bypass"),
        null,
      );
      return Response.json({ status: "ok", database: "connected" });
    };
    await backendHealth({
      ...env,
      SUPABASE_ACCESS_TOKEN: "must-not-send",
      VERCEL_AUTOMATION_BYPASS_SECRET: "must-not-send",
    });
    globalThis.fetch = async () =>
      Response.json({ status: "ok", database: "disconnected" });
    await assert.rejects(() => backendHealth(env), /database connected/);
    globalThis.fetch = async () => new Response("not-json");
    await assert.rejects(() => backendHealth(env), /valid JSON/);
  } finally {
    globalThis.fetch = original;
  }
});
Deno.test("release preflight preserves disabled defaults and configured CSV release values", () => {
  preflight(env);
  preflight({ ...env, STRIPE_ENABLED: undefined });
  for (
    const patch of [
      { SUPABASE_URL: "" },
      { SUPABASE_URL: "http://localhost:54321" },
      { SUPABASE_URL: `${env.SUPABASE_URL}/path` },
      { SUPABASE_URL: `${env.SUPABASE_URL}?query=true` },
      {
        SUPABASE_URL: "https://user:password@abcdefghijklmnopqrst.supabase.co",
      },
      { SUPABASE_PUBLISHABLE_KEY: "" },
      { SUPABASE_PUBLISHABLE_KEY: "sb_secret_abcdefghijklmnopqrstuvwxyz" },
      {
        SUPABASE_PUBLISHABLE_KEY:
          "eyJhbGciOiJIUzI1NiJ9.eyJyb2xlIjoic2VydmljZV9yb2xlIn0.signature",
      },
      { SUPABASE_PUBLISHABLE_KEY: "sb_publishable_your_placeholder_key_here" },
      { STRIPE_ENABLED: "true" },
      { STRIPE_PUBLISHABLE_KEY: "pk_test_not_allowed" },
    ]
  ) assert.throws(() => preflight({ ...env, ...patch }));
});
Deno.test("live opt-in rejects unsafe keys and flags without credential assertion diffs", () => {
  const live = {
    ...env,
    STRIPE_ENABLED: "true",
    STRIPE_PUBLISHABLE_KEY: "pk_live_abcdefghijklmnopqrstuvwxyz012345",
  };
  preflight(live);
  for (
    const key of [
      "",
      "pk_live_short",
      "pk_test_abcdefghijklmnopqrstuvwxyz",
      // Assemble invalid synthetic credentials so scanners do not mistake fixtures for secrets.
      ["sk", "live", "synthetic"].join("_"),
      ["rk", "live", "synthetic"].join("_"),
      ["pk", "live", "yourplaceholderkey123456789"].join("_"),
      "pk_live_example12345678901234567890",
      "pk_live_abcdefghijklmnopqrst_uvwx",
      "pk_live_abcdefghijklmnopqrstuvwxyz\n",
    ]
  ) {
    assert.throws(
      () => preflight({ ...live, STRIPE_PUBLISHABLE_KEY: key }),
      (error: Error) => {
        assert.equal(
          error.message,
          "Invalid public Stripe release configuration; values withheld.",
        );
        if (key) assert.ok(!error.message.includes(key));
        return true;
      },
    );
  }
  for (const flag of ["TRUE", "1", "", "yes"]) {
    assert.throws(() => preflight({ ...live, STRIPE_ENABLED: flag }));
  }
  assert.throws(() => preflight({ ...live, STRIPE_ENABLED: "false" }));
  checkPublicJs(
    `${live.SUPABASE_URL} ${live.SUPABASE_PUBLISHABLE_KEY} ${live.STRIPE_PUBLISHABLE_KEY}`,
    live,
  );
  assert.throws(() =>
    checkPublicJs(`${env.SUPABASE_URL} ${env.SUPABASE_PUBLISHABLE_KEY}`, live)
  );
  assert.throws(() =>
    checkPublicJs(
      `${env.SUPABASE_URL} ${env.SUPABASE_PUBLISHABLE_KEY} pk_test_unexpected`,
      env,
    )
  );
  assert.throws(
    () => checkPublicConfig(publicConfig(live), env),
    /mismatch; values withheld/,
  );
});
Deno.test("public capability never replaces independent backend live authorization", () => {
  for (const enabled of ["false", "true"]) {
    for (const authorized of ["false", "true"]) {
      const backend = {
        STRIPE_ENABLED: enabled,
        STRIPE_MODE: "live",
        STRIPE_LIVE_AUTHORIZED: authorized,
        STRIPE_SECRET_KEY: "rk_live_synthetic",
      };
      if (enabled === "true" && authorized === "false") {
        assert.throws(() =>
          stripeMode((key) => backend[key as keyof typeof backend])
        );
      } else {
        assert.equal(
          stripeMode((key) => backend[key as keyof typeof backend]).enabled,
          enabled === "true",
        );
      }
    }
  }
});
Deno.test("hosted smoke URL cannot leak bypass credentials to arbitrary origins", () => {
  // The workflow verifies deployment ownership via the authenticated API.
  allowedOrigin(
    "https://ben-knight-website-abc.vercel.app",
    "https://budgeting.benknight.dev",
    "ben_knight_website",
  );
  for (
    const value of [
      "https://budgeting.benknight.dev",
      "https://ledger-abc.vercel.app",
    ]
  ) allowedOrigin(value, "https://budgeting.benknight.dev");
  for (
    const value of [
      "http://ledger.vercel.app",
      "https://evil.test",
      "https://user:pass@ledger.vercel.app",
      "https://ledger.vercel.app/path",
      "https://ledger.vercel.app?query=1",
    ]
  ) {
    assert.throws(() =>
      allowedOrigin(value, "https://budgeting.benknight.dev")
    );
  }
});

Deno.test("deployment target requires authenticated exact project identity", async () => {
  const original = globalThis.fetch;
  const settings = {
    VERCEL_PROJECT_ID: "prj_synthetic",
    VERCEL_ORG_ID: "team_synthetic",
    VERCEL_PROJECT_NAME: "ben_knight_website",
    VERCEL_TOKEN: "synthetic-token",
  };
  try {
    globalThis.fetch = async (url, init) => {
      assert.equal(new URL(String(url)).hostname, "api.vercel.com");
      assert.equal(
        new Headers(init?.headers).get("Authorization"),
        "Bearer synthetic-token",
      );
      return Response.json({
        id: settings.VERCEL_PROJECT_ID,
        accountId: settings.VERCEL_ORG_ID,
        name: settings.VERCEL_PROJECT_NAME,
      });
    };
    await target(settings);
    globalThis.fetch = async () =>
      Response.json({
        id: settings.VERCEL_PROJECT_ID,
        accountId: settings.VERCEL_ORG_ID,
        name: settings.VERCEL_PROJECT_NAME,
        rootDirectory: "budgeting",
      });
    await assert.rejects(
      () => target(settings),
      /Root Directory must be empty/,
    );
    for (const name of Object.keys(settings)) {
      await assert.rejects(
        () => target({ ...settings, [name]: "" }),
        new RegExp(`${name} is missing or malformed`),
      );
    }
    globalThis.fetch = async () => Response.json({ id: "prj_other" });
    await assert.rejects(
      () => target(settings),
      /does not match VERCEL_PROJECT_ID/,
    );
    for (const status of [401, 403, 404, 429, 500]) {
      globalThis.fetch = async () =>
        new Response("synthetic-sensitive-response", { status });
      await assert.rejects(() => target(settings), (error: Error) => {
        assert.match(error.message, new RegExp(`HTTP ${status}`));
        assert.ok(!error.message.includes(settings.VERCEL_TOKEN));
        assert.ok(!error.message.includes("synthetic-sensitive-response"));
        return true;
      });
    }
    globalThis.fetch = async () => {
      throw new Error(settings.VERCEL_TOKEN);
    };
    await assert.rejects(
      () => target(settings),
      /Cannot reach the Vercel project API/,
    );
  } finally {
    globalThis.fetch = original;
  }
});

Deno.test("hosted checks verify headers/configuration and isolate protection bypass from backend", async () => {
  const original = globalThis.fetch;
  const release = await Deno.makeTempDir();
  const headers =
    JSON.parse(await Deno.readTextFile("vercel.json")).headers[0].headers;
  let expectedEnv = { ...env, STRIPE_PUBLISHABLE_KEY: "" };
  try {
    globalThis.fetch = async (input, init) => {
      const url = new URL(String(input));
      const bypass = new Headers(init?.headers).get(
        "x-vercel-protection-bypass",
      );
      assert.equal(init?.redirect, "error");
      if (url.hostname.endsWith(".supabase.co")) {
        assert.equal(bypass, null);
        return Response.json({ status: "ok", database: "connected" });
      }
      assert.equal(bypass, "synthetic-bypass");
      return new Response(
        url.pathname.endsWith(".json")
          ? JSON.stringify(publicConfig(expectedEnv))
          : url.pathname.endsWith(".js")
          ? `${expectedEnv.SUPABASE_URL} ${expectedEnv.SUPABASE_PUBLISHABLE_KEY} ${expectedEnv.STRIPE_PUBLISHABLE_KEY}`
          : "<html>synthetic</html>",
        {
          headers: {
            ...Object.fromEntries(
              headers.map((
                h: { key: string; value: string },
              ) => [h.key, h.value]),
            ),
            "Content-Type": url.pathname.endsWith(".json")
              ? "application/json"
              : url.pathname.endsWith(".js")
              ? "application/javascript"
              : "text/html",
          },
        },
      );
    };
    await smoke("https://ledger-abc.vercel.app", {
      ...env,
      VERCEL_PROJECT_NAME: "ledger",
      VERCEL_AUTOMATION_BYPASS_SECRET: "synthetic-bypass",
    });
    expectedEnv = {
      ...env,
      STRIPE_ENABLED: "true",
      STRIPE_PUBLISHABLE_KEY: "pk_live_abcdefghijklmnopqrstuvwxyz012345",
    };
    await smoke("https://ledger-abc.vercel.app", {
      ...expectedEnv,
      VERCEL_AUTOMATION_BYPASS_SECRET: "synthetic-bypass",
    });
    await assert.rejects(() =>
      smoke("https://ledger-abc.vercel.app", {
        ...env,
        VERCEL_AUTOMATION_BYPASS_SECRET: "synthetic-bypass",
      }), /public release evidence/);
    expectedEnv = { ...env, STRIPE_PUBLISHABLE_KEY: "" };
    await Deno.writeTextFile(
      `${release}/manifest.json`,
      JSON.stringify({
        files: { "static/index.html": "not-the-deployed-digest" },
      }),
    );
    await assert.rejects(() =>
      smoke("https://ledger-abc.vercel.app", {
        ...env,
        RELEASE_ROOT: release,
        VERCEL_AUTOMATION_BYPASS_SECRET: "synthetic-bypass",
      }), /hosted bytes differ/);
    globalThis.fetch = async () =>
      new Response("wrong", { headers: { "Content-Type": "text/html" } });
    await assert.rejects(
      () => smoke("https://ledger-abc.vercel.app", env),
      /Frontend \/: missing or unexpected Cache-Control/,
    );
    globalThis.fetch = async () =>
      new Response("synthetic-sensitive-body", { status: 401 });
    await assert.rejects(
      () =>
        smoke("https://ledger-abc.vercel.app", {
          ...env,
          VERCEL_AUTOMATION_BYPASS_SECRET: "synthetic-bypass",
        }),
      (error: Error) => {
        assert.match(
          error.message,
          /Frontend \/ returned HTTP 401.*automation bypass/,
        );
        assert.ok(!error.message.includes("synthetic-sensitive-body"));
        assert.ok(!error.message.includes("synthetic-bypass"));
        return true;
      },
    );
  } finally {
    globalThis.fetch = original;
    await Deno.remove(release, { recursive: true });
  }
});
Deno.test("release manifest binds tested public config, exact files and source and rejects mutation", async () => {
  const root = await Deno.makeTempDir();
  const sha = "a".repeat(40);
  try {
    await Deno.mkdir(`${root}/.vercel/output/static`, { recursive: true });
    await assert.rejects(() => manifest(root, sha, "synthetic", env));
    await Deno.writeTextFile(
      `${root}/.vercel/output/config.json`,
      JSON.stringify({
        version: 3,
        routes: [{ headers: { "Cache-Control": "no-store" } }, {
          handle: "filesystem",
        }, { dest: "/index.html" }],
      }),
    );
    for (const name of ["index.html", "main.dart.js"]) {
      await Deno.writeTextFile(
        `${root}/.vercel/output/static/${name}`,
        `${env.SUPABASE_URL} ${env.SUPABASE_PUBLISHABLE_KEY}`,
      );
    }
    const staticRoot = `${root}/.vercel/output/static`;
    await Deno.mkdir(`${staticRoot}/assets`);
    await Deno.writeTextFile(
      `${staticRoot}/assets/config.yaml`,
      "stripe_enabled: false\n",
    );
    await assert.rejects(
      () => writePublicConfig(staticRoot, env),
      /capability gate/,
    );
    await Deno.writeTextFile(
      `${staticRoot}/assets/config.yaml`,
      "stripe_enabled: true\n",
    );
    await writePublicConfig(staticRoot, env);
    await manifest(root, sha, "synthetic", env);
    await verify(root, sha, env);
    const live = {
      ...env,
      STRIPE_ENABLED: "true",
      STRIPE_PUBLISHABLE_KEY: "pk_live_abcdefghijklmnopqrstuvwxyz012345",
    };
    await assert.rejects(
      () => verify(root, sha, live),
      /configuration mismatch/,
    );
    await assert.rejects(
      () => manifest(root, sha, "synthetic", live),
      /configuration mismatch/,
    );
    await Deno.writeTextFile(`${root}/vercel.json`, "{}");
    await assert.rejects(() => verify(root, sha, env));
    await Deno.remove(`${root}/vercel.json`);
    await Deno.writeTextFile(`${root}/.vercel/project.json`, "{}");
    await assert.rejects(() => verify(root, sha, env));
    await Deno.remove(`${root}/.vercel/project.json`);
    await assert.rejects(() => verify(root, "b".repeat(40), env));
    await Deno.writeTextFile(
      `${root}/.vercel/output/static/main.dart.js`,
      "changed",
    );
    await assert.rejects(() => verify(root, sha, env));
    await Deno.writeTextFile(
      `${staticRoot}/main.dart.js`,
      `${env.SUPABASE_URL} ${env.SUPABASE_PUBLISHABLE_KEY} ${live.STRIPE_PUBLISHABLE_KEY}`,
    );
    await writePublicConfig(staticRoot, live);
    await manifest(root, sha, "synthetic", live);
    await verify(root, sha, live);
    await assert.rejects(
      () => verify(root, sha, env),
      /configuration mismatch/,
    );
    await Deno.symlink("index.html", `${root}/.vercel/output/static/link`);
    await assert.rejects(() => manifest(root, sha, "synthetic", live));
  } finally {
    await Deno.remove(root, { recursive: true });
  }
});
