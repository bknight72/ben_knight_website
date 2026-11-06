# Private Budgeting

Standalone, single-owner Flutter web budgeting application for `https://budgeting.benknight.dev`. Built at Novacoast. This package is independent of the portfolio Flutter application and its GitHub Pages deployment.

The CSV-backed workflow is the default: manual cash/card accounts, dated balance snapshots, CSV preview/import/undo, transaction annotations, categories, monthly budgets, and portable JSON export. Optional Stripe Financial Connections supplies read-only transactions and balances, not payments. Stripe is disabled by default.

This is a repository handoff, not evidence of a production deployment. Consult the final coordinator validation report and CI logs for actual results against the final tree. Commands below describe checks to run; their presence does not mean they passed. Hosted Supabase/Vercel behavior, SMTP delivery, DNS/TLS, and live bank access require separate owner-approved verification. No hosted projects, remote migrations, DNS changes, deployments, or paid subscriptions are authorized by these instructions alone.

## Architecture

| Component | Responsibility |
| --- | --- |
| `lib/`, `web/` | Flutter UI, validated public configuration, in-memory Supabase session, browser CSV/download and Stripe.js bridge |
| `config.yaml` | Public defaults loaded before rendering; USD, America/Denver, no rollover, bounded imports, Stripe opt-in |
| Supabase Auth | Manually provisioned owner, email/password and TOTP MFA; public signup disabled |
| `supabase/migrations/` | PostgreSQL financial tables, RLS, owner checks, aggregates, durable private jobs and refresh accounting |
| `supabase/functions/api` | Owner + `aal2` financial API, validated CSV, export, connection controls, usage; anonymous operational endpoints |
| `supabase/functions/stripe-webhook` | Signed raw-body webhook validation and durable deduplicated enqueue |
| `supabase/functions/worker` | Secret-authenticated bounded job processing, pagination, retries and lease recovery |
| Vercel / nginx | Static frontend only; no financial backend or database credentials |
| `recovery/`, `scripts/` | Containerized validation, artifact packaging, encrypted backup and guarded restore |

Amounts are integer USD cents. Cash inflows are positive; credit balances are interpreted as debt. Posted transactions drive reporting, refunds offset their selected category, and marked transfers/card payments are excluded from budget income/spending. Tracked net position is cash less tracked card debt, not full net worth. Snapshots, not incomplete transaction sums, establish balances; missing and stale balances remain visible.

The `private` schema stores the immutable owner mapping, provider mapping, jobs, webhook deduplication and refresh reservations. Browser roles cannot access it. Financial tables and RPCs require the provisioned owner and verified MFA, including direct PostgREST calls. Service-role credentials bypass RLS and must remain backend-only. Auth uses the explicitly approved personal-app email/password + TOTP exception, not Novacoast OIDC.

## Prerequisites

- Git, a POSIX shell and Bash for recovery scripts, plus a running Docker engine with BuildKit and adequate disk for Flutter, browser and Supabase images.
- Run validation from a non-root checkout owner. The tooling image builder UID matches that user so Linux CI bind-mounted build files remain writable; root inside a short setup step updates certificate trust before dropping to the builder.
- Internet access to official image registries, Flutter, pub.dev and package registries. All dependency installation happens inside containers. Do not run host `flutter pub get`, `npm install`, `deno install`, or similar package installation for this app.
- Optional trusted corporate/public CA PEM file when network TLS inspection requires it. Never supply a private key, disable certificate verification, or commit a machine certificate.
- For hosted setup only: owner-controlled Supabase and Vercel projects, `benknight.dev` DNS access, SMTP delivery, and secure secret/backup storage. Stripe eligibility and live approval are separate gates.
- Use synthetic data in local tests and screenshots. Never provide bank credentials through this repository, chat, or a CSV fixture.

Run commands from the repository root unless a block explicitly changes the working directory. The scripts locate their own package directory. Images use `latest` and dependencies are unpinned where supported; repeat validation after rebuilds because upstream changes can alter results. Do not change root portfolio dependencies to resolve budgeting dependencies.

## Environment Variables

`budgeting/.env.example` is a placeholder inventory, not a file to load wholesale into a build. Create private environment files outside the checkout with restrictive permissions, and inject only the variables each operation needs. Never commit `.env`, exported finances, backups, database URLs, access tokens, or age identities. Docker environment values are visible to trusted Docker administrators; protect the host and CI runner accordingly.

### Public Build Values

| Variable | Meaning |
| --- | --- |
| `SUPABASE_URL` | Public HTTPS project URL; also used by the backend runtime |
| `SUPABASE_PUBLISHABLE_KEY` | Browser-safe Supabase publishable key, or compatible legacy anon key; never a service-role/secret key |
| `STRIPE_PUBLISHABLE_KEY` | Optional browser-safe Stripe test/live publishable key matching the backend mode |
| `STRIPE_ENABLED` | Public build opt-in; defaults to `false` |

These values are embedded in public JavaScript. Anyone can read them. `scripts/build.sh` passes only these four values as Docker build arguments. Public `config.yaml` is also shipped in the artifact; it is not a secret store. Frontend Stripe controls require `stripe_enabled: true` in that YAML, `STRIPE_ENABLED=true` at build time, and a publishable key. Backend authorization and enablement remain authoritative; editing public YAML cannot grant access.

### Backend And Administration

| Variable | Meaning |
| --- | --- |
| `SUPABASE_ANON_KEY` | Backend compatibility name used for authenticated Supabase requests; use the project's compatible public/anon key, not a service-role key |
| `SUPABASE_SERVICE_ROLE_KEY` | Backend/admin key for narrow privileged operations; never sent to Flutter |
| `ALLOWED_ORIGINS` | Comma-separated exact frontend origins; production default is `https://budgeting.benknight.dev`; explicitly allow a chosen local/preview origin when needed |
| `STRIPE_ENABLED` | Independent backend enablement; defaults to `false`; a public build flag does not enable it |
| `STRIPE_MODE` | `test` by default; test and live projects/keys/data must remain isolated |
| `STRIPE_LIVE_AUTHORIZED` | Defaults to `false`; explicit additional live authorization gate |
| `STRIPE_SECRET_KEY` | Private Stripe API key, required only for approved Stripe functionality |
| `STRIPE_WEBHOOK_SECRET` | Private signing secret for this environment's webhook endpoint |
| `WORKER_SECRET` | Independent high-entropy bearer secret for the trusted scheduler, not an owner JWT |
| `DATABASE_URL` | Private PostgreSQL URL for trusted admin/recovery tooling, `postgresql://user:password@host:5432/database?sslmode=verify-full`; remote recovery requires certificate and hostname validation |
| `VERCEL_TOKEN` | Private deployment token, never a build argument |
| `VERCEL_ORG_ID` | Deployment organization identifier, not application configuration |
| `VERCEL_PROJECT_ID` | Deployment project identifier, not application configuration |
| `BUILD_CA_FILE` | Optional absolute host path to a public PEM CA certificate for container builds/validation; tooling input, not application config |
| `BUDGETING_CA_CERT` | Optional absolute host path to a public CA for the separate local Supabase harness build and Node runtime trust; not a database TLS setting |
| `RECOVERY_LOCAL_SYNTHETIC` | Recovery-only opt-out, exactly `true`, permitting explicit `sslmode=disable` only for synthetic loopback/Unix-socket databases; never for remote/hosted use |

Hosted Supabase injects reserved variables such as `SUPABASE_URL`, `SUPABASE_ANON_KEY` and `SUPABASE_SERVICE_ROLE_KEY`. Do not blindly upload the combined example with `secrets set`, overwrite reserved names, or invent a different project URL. Configure only the application secrets the hosted runtime needs; local harnesses provide isolated equivalents. SMTP credentials belong in Supabase Auth's SMTP configuration, not in Flutter or this public YAML.

## Local Setup

### VS Code Diagnostics

Container-generated `.dart_tool/package_config.json` references `/home/builder/.pub-cache` and `/opt/flutter`. A macOS VS Code analyzer cannot resolve these container-only paths; this produces missing imports and cascading Dart errors even when container analysis passes. Do not hide errors or run host package installation to work around it.

Build `budgeting-flutter:latest` using the validation/tooling instructions, then open the repository in VS Code and run **Dev Containers: Reopen in Container**. The root `.devcontainer/devcontainer.json` uses that local image, installs editor extensions, and resolves both Flutter packages inside the container. The setup script does not load financial secrets. If package downloads require corporate trust, supply the approved public CA to the container system trust store before rerunning setup; never disable TLS. Until VS Code is reopened in the container, the host analyzer's container-path diagnostics are expected to remain.

The editor and container must share the same package cache path. Do not edit or commit `.dart_tool/package_config.json`; it is generated and gitignored. The devcontainer intentionally does not mount the Docker socket or load backend environment files. It is an editing environment, not permission to access live finances or deploy.

### Validate And Build

```sh
sh budgeting/scripts/validate.sh
```

The validation entrypoint builds the Flutter tooling image, resolves packages in Docker, checks formatting, analyzes Flutter, runs unit/widget coverage and its gate, and builds an unconfigured release web app. It then runs browser-bridge tests, packager/artifact-audit tests, the exact backend `supabase/tests/run-deno.sh` runner, disposable PostgreSQL checks, browser-artifact checks, non-root static runtime health/graceful-stop checks, and the offline encrypted recovery drill. It stops at the first failure; later checks are not evidence of execution if Flutter or an earlier step fails. The actual local Supabase stack harness remains separately invokable below and is a separate CI step. It does not contact live banks. The Tests section records completed local verification; hosted acceptance remains a separate gate.

For a TLS-inspecting network, use an absolute path to the operator-approved public CA:

```sh
BUILD_CA_FILE=/absolute/path/to/public-ca.crt sh budgeting/scripts/validate.sh
```

The CA is supplied using a BuildKit secret and a read-only runtime mount for validation. Host TLS verification remains enabled. Build failures should be diagnosed from the issuer/hostname and trusted chain, not bypassed with insecure curl/Dart settings. The CA is not an app secret and must not be added to Git.

Build a public-configured release artifact separately:

```sh
SUPABASE_URL=https://your-project.supabase.co \
SUPABASE_PUBLISHABLE_KEY=your-public-key \
STRIPE_ENABLED=false \
sh budgeting/scripts/build.sh
```

Add `BUILD_CA_FILE=/absolute/path/to/public-ca.crt` to this invocation if required. Do not pass a backend environment file to `docker build`. Output is `budgeting/build/web/`, then the script packages `budgeting/.vercel/output/`. A build with empty public values intentionally shows an unconfigured screen and must not be mistaken for a configured production app.

Repackage an already-built artifact without recompilation:

```sh
sh budgeting/scripts/package-vercel.sh
```

The packager copies only static web assets, omits `flutter_service_worker.js`, and generates Vercel Build Output API version 3 routes: security headers, filesystem precedence, then SPA fallback. Financial data is never an offline cache. Sessions and financial responses must not be persisted in browser storage; sign-in is required again after session loss.

### Local Runtime

The Dockerfile also has a non-root nginx runtime on port 8080. Build it with the same public values (and optional BuildKit CA secret) when a standalone server is needed:

```sh
docker build --target runtime -t budgeting-runtime:latest \
  --build-arg SUPABASE_URL=https://your-project.supabase.co \
  --build-arg SUPABASE_PUBLISHABLE_KEY=your-public-key \
  --build-arg STRIPE_ENABLED=false budgeting
docker run --rm --name budgeting-local -p 8080:8080 budgeting-runtime:latest
```

The static `/health` endpoint reports frontend liveness only, not database availability. nginx uses `SIGQUIT` for graceful shutdown; stop it with `docker stop --time 30 budgeting-local`. Local nginx is not proof of Vercel edge headers or redirects. If testing real Auth locally, allow the exact local origin in backend CORS and Auth redirects and use an isolated test backend.

## Tests

Latest local verification: Flutter analysis passed, 57 Flutter tests passed with 89.0% conservative whole-library coverage, 27 backend tests passed with 88.15% fixed-production coverage, and 7 browser bridge tests passed. Release compilation, Chromium artifact smoke checks at three viewports under CSP, non-root runtime liveness/graceful stop, static credential audit, and Vercel packaging passed. Database authorization/concurrency/usage/lease tests and the offline encrypted recovery drill passed. These are local results, not hosted deployment or live-bank verification; rerun the commands against changes and consult the final handoff for remaining integration limits.

The final signed-in Chromium-to-Supabase acceptance attempt did not pass: a test-port conflict was corrected, then npm connection resets, BuildKit errors, and Docker daemon unavailability prevented execution. It is not a frontend success or established frontend defect. Rerun that phase when Docker is stable; the owned test runner `quizzical_satoshi` may need removal after confirming it is no longer in use. The editor devcontainer configuration also remains unverified in the VS Code client until reopened in the container.

```sh
sh budgeting/scripts/validate.sh
sh budgeting/scripts/test-database.sh
sh budgeting/scripts/test-browser.sh
sh budgeting/scripts/test-runtime.sh
sh budgeting/supabase/tests/run-local.sh
docker run --rm -v "$PWD/budgeting/supabase:/work" -w /work \
  denoland/deno:latest sh tests/run-deno.sh
```

`test-database.sh` creates disposable plain PostgreSQL, bootstraps synthetic Auth roles, applies migrations in filename order, then runs `authorization.sql`, `concurrency.sql` and `usage_and_leases.sql`. These cover owner/MFA authorization, cap concurrency, UTC usage boundaries/cooldowns and worker lease fencing. `supabase/tests/bootstrap.sql` is **only** for disposable plain PostgreSQL; never apply it to managed Supabase. Local-stack tests must use the real Supabase Auth/PostgREST/Edge services rather than that bootstrap as a substitute.

`test-browser.sh` requires existing `build/web/` output. It builds container-only Playwright tooling and serves that output in a disposable nginx container, exercising mobile/desktop/landscape layouts, deep-link reloads and browser-storage/service-worker/error checks. Artifact smoke tests do not by themselves verify signed-in financial flows, real SMTP, live Stripe, or Vercel's production CSP.

`test-runtime.sh` validates the non-root, read-only nginx configuration with writable temporary directories, static health and a clean stop within 30 seconds. It is not a database health test or proof of Vercel deployment behavior.

`supabase/tests/run-local.sh` orchestrates the actual local Supabase Auth/PostgREST/Edge stack using a containerized CLI and synthetic admin-created identities/TOTP. Host requirements are a shell and Docker, not `rg` or host-installed npm/Deno. It refuses a pre-existing `private-budgeting` stack to avoid overwriting operator data, and stops its disposable stack with `--no-backup` afterward. It needs a Docker socket at `/var/run/docker.sock`, host-network support and free local Supabase ports (gateway 54321, Mailpit 54324). Docker Desktop may require host networking to be enabled. **The Supabase CLI publishes ports on all interfaces (`0.0.0.0`), despite the harness accepting only local target URLs. Run only on an isolated CI/test machine with network access restricted; do not leave these services running.** Docker socket access is privileged; run only trusted code. It never loads operator environment files or enables live Stripe. Its generated local keys are test-only and must not be reused for hosting.

For optional additional corporate trust in this separate harness:

```sh
BUDGETING_CA_CERT=/absolute/path/to/public-ca.crt \
sh budgeting/supabase/tests/run-local.sh
```

For the actual signed-in Chromium acceptance phase, first build a separate local-only artifact, then opt into the isolated stack/browser run:

```sh
BUILD_CA_FILE=/absolute/path/to/public-ca.crt sh budgeting/scripts/build-local-browser.sh
BUDGETING_BROWSER_INTEGRATION=true \
BUDGETING_BROWSER_ARTIFACT="$PWD/budgeting/build/local-browser" \
sh budgeting/supabase/tests/run-local.sh
```

Omit `BUILD_CA_FILE` on standard-trust networks. This artifact embeds the disposable Supabase CLI public key and localhost URL and must never be deployed. It leaves `build/web` and the Vercel package unchanged. Both CI definitions run this additional phase after the unconfigured artifact checks. A passing local API harness alone is not a passing signed-in browser test.

The harness uses a `corporate_ca` BuildKit secret for image trust and mounts the public certificate read-only for runtime `NODE_EXTRA_CA_CERTS`. This is separate from Flutter/browser `BUILD_CA_FILE` and recovery database TLS roots; no TLS bypass is used.

The network harness covers real MFA/owner/RLS denial, manual records, CSV operations, annotations/budgets, usage and export. It checks recovery-email receipt in Mailpit, rejects a correctly HMAC-signed but expired JWT at both Edge and PostgREST, and separately rejects a tampered JWT. This does **not** complete browser recovery-link navigation, password replacement, post-recovery MFA or hosted SMTP delivery. `integration_test/local_supabase_test.dart` additionally expects explicitly supplied synthetic `TEST_SUPABASE_URL`, `TEST_SUPABASE_KEY`, `TEST_OWNER_EMAIL`, `TEST_OWNER_PASSWORD` and `TEST_OWNER_TOTP_SECRET` build defines and a prepared local fixture; it is not equivalent to running the standalone Deno harness. Complete signed-in Flutter browser and Stripe-boundary acceptance remain subject to final orchestrated results.

The required coverage threshold is at least 70% executable lines separately for first-party Flutter and Deno backend code. Flutter output is `budgeting/coverage/lcov.info`; the root checker is `scripts/check_coverage.dart`. Validation explicitly requires app, domain, config, repository, and main records. Any omitted production Dart library, including the browser-only adapter, contributes every nonblank/non-comment line as uncovered: a conservative denominator rather than silently excluded source. The measured final VM report is 1,084/1,218 lines (89.0%) with this conservative adjustment; browser behavior is separately tested, not credited as instrumented adapter coverage.

The backend command above is the authoritative fixed-production-scope runner. `supabase/tests/run-deno.sh` type-checks all three entrypoints, runs the Deno tests with coverage, writes `/tmp/budgeting-coverage/lcov.info` inside its container, and invokes `supabase/tests/check_coverage.ts`. That checker discovers **every** `functions/**/*.ts` file and counts only their executable LCOV lines, excluding test source. The current nine files are `_shared/core.ts`, `_shared/runtime.ts`, `_shared/openapi.ts`, and `handler.ts` plus `index.ts` under each of `api/`, `worker/` and `stripe-webhook/`. Entrypoint tests execute actual registration with `Deno.serve` intercepted rather than excluding those modules. Missing/empty production records or aggregate coverage below 70% fail. `validate.sh` also copies the backend LCOV to `budgeting/coverage/backend.lcov` and runs the root checker. Standalone `docker run --rm` discards its temporary report unless explicitly copied out. Browser bridge checks are behavioral tests, not a claim of instrumented JS coverage. Do not improve reported coverage by excluding difficult UI/auth/worker code or unexecuted production modules.

GitHub validation is in `.github/workflows/budgeting-ci.yml`, scoped to budgeting/security/workflow changes on pull requests and pushes to `master`, with manual runs. Its unconfigured artifact is not a production deployment. The portfolio workflow remains separate. For GitLab, select `budgeting/.gitlab-ci.yml` as the CI configuration path, enable the instance runner under Settings > CI/CD > Runners, and provide a trusted shell runner with local Docker tagged `shared`; rules cover merge requests and `main`/`master`. A remote Docker-in-Docker daemon cannot resolve the scripts' checkout bind paths. Creating a mirror, enabling runners, and protected secrets are operator tasks, not actions performed by this README.

Launch follow-up on 2026-11-06:

- Public GitHub job metadata confirms Pages run `42156567756` failed at root analysis and Budgeting Validation run `42156567708` passed validation/packaging but failed isolated Supabase integration.
- Root analysis scanning this independent package was reproduced locally; root analyzer exclusions now keep budgeting under its dedicated validation. Portfolio analysis/release build pass locally, while an additional portfolio widget-test run has unresolved failures outside that workflow. The existing portfolio returned HTTP 200.
- Budgeting analysis, 57 Flutter tests (89.0%), 27 backend tests (88.15%), disposable database checks, static browser checks, runtime checks, package/audit tests, 7 bridge tests, and the offline encrypted restore drill passed again locally.
- The complete `scripts/validate.sh` entrypoint then passed with the existing public build CA, including a fresh tooling-image build, release compilation, and 37 Deno tests (27 existing tests plus 10 local-readiness regressions). Fixed-scope production coverage remains 88.15%; test helpers are not credited toward that gate. The packaged artifact remains unconfigured and must not be deployed as production.
- Isolated-stack testing reproduced a local readiness bug: Kong replaces the function's CORS header with `*`. The test-only probe now accepts that header only with HTTP 200 and healthy database JSON; production CORS and financial authorization are unchanged. The real API acceptance harness then passed. Signed-in Chromium acceptance remains incomplete and must pass before launch; extended investigation was deferred to prioritize a pushable repository.
- Dev Container setup resolved both packages with the existing public CA, but actual VS Code client use and signed-in Supabase acceptance remain separate gates. No hosted deployment or successful final GitHub rerun is established by these results.

## Supabase Setup

Perform this only for an owner-approved isolated hosted environment first, using the Supabase dashboard or CLI installed/run inside a container. Apply every SQL migration in lexical order through trusted administration. Preserve deployed migration history; use forward corrective migrations. Never load `tests/bootstrap.sql` into a hosted project.

1. Disable public signup in hosted Auth settings, not just `supabase/config.toml`. Enable TOTP enrollment/challenge. Keep the database's exposed API schemas limited to `public`; do not expose `private`.
2. Create the single confirmed owner through trusted Auth administration. Verify that person's identity and email, record their actual `auth.users.id`, then provision that UUID using trusted SQL:

```sql
insert into private.app_owner (owner_id)
values ('REPLACE-WITH-THE-TRUSTED-AUTH-USER-UUID'::uuid);
```

The owner insert initializes the profile and categories. This is not first-user-wins; the singleton constraint deliberately rejects a second owner. Do not grant browser writes to this mapping or replace it to bypass a login problem.

3. Set the hosted Auth Site URL to `https://budgeting.benknight.dev`. Allow the exact recovery return URL `https://budgeting.benknight.dev/` and only explicitly chosen isolated local/preview equivalents. Do not add wildcard production redirects. The Flutter recovery link returns to the app origin root; there is no OIDC `/api/v1/auth/callback` handler in this approved authentication exception.
4. Configure custom SMTP in Supabase Auth with a verified sender/domain, provider credentials and delivery limits. Test password-reset delivery, expiration, single-use behavior and redirects with the owner before real imports. Local email capture is not proof of production deliverability.
5. Deploy `api`, `stripe-webhook`, and `worker` from `budgeting/supabase/functions/` with the checked-in function settings. Gateway JWT verification is disabled deliberately: `api` validates the bearer session plus owner/MFA itself, webhook verifies Stripe signatures, and worker checks its independent secret. Disabling gateway JWT checks does not make financial routes anonymous.
6. Inject backend secrets, exact `ALLOWED_ORIGINS`, and initially `STRIPE_ENABLED=false`, `STRIPE_MODE=test`, `STRIPE_LIVE_AUTHORIZED=false`. Verify direct anonymous, wrong-owner, `aal1` and expired-session denial on both Edge API and PostgREST, not just UI hiding.
7. Enroll and challenge the owner's TOTP. Verify logout/session loss clears open financial dialogs and data, a new browser session needs sign-in, and no tokens/financial responses remain in local storage or service workers.

### MFA Recovery

Keep the TOTP seed in the owner's secure authenticator/key custody process. Password recovery resets a password; it does not satisfy or remove MFA. The app clears recovery tokens from the URL and requires MFA before financial access.

For a lost factor, a trusted Supabase administrator must independently verify the owner's identity before using supported Auth administration to remove the lost factor and revoke existing sessions. Reconfirm the same Auth UUID and immutable owner mapping, recover the password if needed, then require enrollment and successful challenge of a replacement factor. Until `aal2` is restored, financial access must remain denied. Do not edit `aal` claims, disable RLS, copy production credentials into test, or let an unauthenticated client reset MFA. Rehearse this recovery process before live use and record only non-sensitive operational evidence.

## API Reference

Let `SUPABASE_URL` be `https://your-project.supabase.co`. The Edge API base is **`$SUPABASE_URL/functions/v1/api`**, not the frontend domain. Anonymous endpoints are:

| Method / Path Under Edge Base | Purpose |
| --- | --- |
| `GET /health` | JSON health including database connectivity; unhealthy dependencies return 503 |
| `GET /metrics` | Anonymized request/error counts, latency buckets, cold-start uptime and domain counters; no owner IDs, amounts or IP labels |
| `GET /docs` | Swagger UI |
| `GET /openapi.json` | Request/response schemas, descriptions, examples and errors |

Swagger loads browser resources, so verify it against hosted CSP/network policy. It does not replace the Supabase Auth/PostgREST reference. A static host `/health` is not the database-aware Edge health check.

Financial routes include a second `/api/v1` segment, for example `$SUPABASE_URL/functions/v1/api/api/v1/usage`. Send the project's public `apikey` header and the signed-in owner's `Authorization: Bearer <access-token>` with verified `aal2`; never use a service-role key from the browser.

| Method / Path Under Edge Base | Request / Result |
| --- | --- |
| `GET /api/v1/usage` | UTC month, reserved attempts, fixed limit 50, remaining attempts, owned account IDs and next app-eligible refresh timestamps |
| `POST /api/v1/imports/preview` | `{accountId,csv,mapping}`; normalized rows, row count/errors, fingerprint and duplicate/overlap review |
| `POST /api/v1/imports/commit` | Same input, optional `confirmOverlap` after review; server revalidates and returns batch ID/inserted/duplicate counts |
| `POST /api/v1/imports/{id}/undo` | Undo that owner's batch; annotated rows are retained rather than silently losing edits |
| `GET /api/v1/export` | Sensitive portable JSON export; not a complete database backup |
| `POST /api/v1/connections/session` | Server-chosen data-only connection session ID/client secret |
| `POST /api/v1/connections/complete` | `{sessionId}`; server verifies owner/customer/session before linking/subscribing |
| `POST /api/v1/accounts/{id}/balance-refresh` | `{confirmCost:true}`; 202 durable request ID/status, subject to cap/cooldown/provider checks |
| `POST /api/v1/accounts/{id}/disconnect` | Durable provider cleanup, retaining local history |
| `POST /api/v1/accounts/{id}/delete` | `{confirmDelete:true}`; provider cleanup before local cascading deletion |

CSV mapping names exact headers: `date`, `description`, either signed `amount` or `debit`/`credit`, optional `transactionId`/`currency`, explicit `dateFormat` (`YYYY-MM-DD`, `MM/DD/YYYY`, `DD/MM/YYYY`) and `sign` (`inflow-positive` or `outflow-positive`). Imports are bounded to 5 MiB/10,000 rows; raw CSV is not retained. Same-source ambiguous repeats require review. Cross-source overlapping dates are refused even with confirmation; reconcile/remove overlapping history manually rather than double-counting.

Profiles, manual accounts/snapshots, categories, annotations and budgets use owner/MFA-protected PostgREST tables/RPCs. Provider writes remain backend-only. Errors are sanitized `{code,message,requestId,retryAt?}`, with 401 unauthenticated/expired, 403 owner/MFA required, 422 validation, 429 cooldown/cap/throttling and 503 unavailable/disabled. See OpenAPI for exact current success/error schemas.

### Worker Operations

The webhook URL is `$SUPABASE_URL/functions/v1/stripe-webhook`, requiring the environment's Stripe raw-body signature and expected test/live mode. The worker is `POST $SUPABASE_URL/functions/v1/worker` with `Authorization: Bearer <WORKER_SECRET>`. An approved scheduler must invoke it every minute; never expose that secret in a public cron URL or frontend. Use the platform's private secret facilities. No schedule is created by a static deploy.

Jobs are durable, leased, bounded and retried with backoff. Lease expiry allows recovery; after eight failed attempts a trusted operator must investigate the sanitized error, provider/account state and overlap before a narrowly scoped retry. Do not reset all jobs, replay old webhooks, refund uncertain paid reservations, or enqueue fresh balance purchases as a recovery shortcut. Daily transaction recovery is not a paid balance refresh and cannot prove that every missed event was recovered without checking sync state.

To pause safely, disable new frontend/backend linking and refresh, then stop the external worker schedule. This alone does not cancel Stripe recurring subscriptions. When abandoning sync, allow authenticated disconnect/delete cleanup to complete while a worker is available, verify subscriptions/provider access are stopped, then disable the schedule and backend Stripe integration. Retain financial history/backups as intended. Investigate exhausted disconnect jobs before assuming charges stopped.

## Deployment

### Manual Prebuilt Vercel Deploy

Build and validate a release for the intended isolated backend first. Review `budgeting/.vercel/output/config.json` and static assets for correct public configuration and absence of privileged keys. Keep a prior artifact for rollback. `vercel.json` no-op install/build settings are not a source-build deployment pipeline; do not connect an automatic source deployment that publishes an empty/stale artifact.

After separate deployment authorization, use a private deployment-only environment file containing `VERCEL_TOKEN`, `VERCEL_ORG_ID`, and `VERCEL_PROJECT_ID`. The CLI and its dependencies are installed only in the disposable container:

```sh
docker run --rm \
  --env-file /absolute/private/path/vercel.env \
  -v "$PWD/budgeting:/workspace" -w /workspace \
  node:latest sh -ec 'npx --yes vercel deploy --prebuilt --prod --token "$VERCEL_TOKEN"'
```

This is a remote production action, not a validation command. Omit `--prod` for an explicitly approved isolated preview. The mounted directory must already contain `.vercel/output/`; do not run `vercel build` on the host or upload source/backend secrets. Use protected/manual CI environments if automating this command later, and never expose production credentials to fork pull requests. Verify the deployed artifact's static-file precedence, deep-link/recovery reloads, no-store/noindex headers, CanvasKit/workers, TOTP QR, Stripe frames/scripts and absence of service-worker financial caching on the real Vercel edge.

### DNS And External Gates

1. The owner approves and creates separate Supabase/Vercel resources, selects regions/terms and confirms quotas, secrets, SMTP and recovery. Repository completion does not create them.
2. Add **only `budgeting.benknight.dev`** to the intended Vercel project. At the authoritative DNS zone for `benknight.dev`, create/update the **`budgeting` CNAME** to the **exact target Vercel displays for that project/domain**. No target has been allocated or verified in this repository; do not assume a generic CNAME value. Add only the exact domain-verification TXT record if Vercel requests it. Resolve conflicting records for this subdomain deliberately, never the apex, `www`, portfolio records, nameservers or unrelated mail records.
3. Wait for authoritative DNS verification and Vercel-issued TLS, then verify HTTPS, actual response headers and recovery redirects at `https://budgeting.benknight.dev`. Match this exact origin in Auth/CORS. DNS/TLS and hosted edge behavior are external gates, not local-test results.
4. Run owner/MFA denial, SMTP/reset, backup/restore and CSV-only smoke checks with synthetic data before importing real finances. Deploy CSV-only while Stripe remains disabled.
5. Separately approve Stripe eligibility, registration/live transaction access, current pricing, backups/MFA recovery and each exact account/card. Link one account at a time only after that approval. No paid calls, live registrations or subscriptions are authorized here.

### Rollback

Redeploy the last known-good static artifact without overwriting financial data. Pause new linking/refresh work and scheduler as appropriate, but explicitly stop recurring subscriptions/disconnect when abandoning syncing. Use forward corrective SQL migrations rather than deleting migration history. Database restore is a separately controlled recovery event, not an automatic deployment rollback.

## Backup And Recovery

Portable JSON export contains sensitive data and formula-escapes strings for safer spreadsheet handling, but is not a full backup or supported database restore format. Application backup tooling streams PostgreSQL output directly into age encryption; no plaintext dump should be left on disk. Store ciphertext outside Git/public hosting and keep decryption identities separately in secure custody with a second recoverable copy.

Create a private Docker `--env-file` format file (not a shell-sourced script) with `DATABASE_URL` for the source, a native age recipients file containing public recipient lines, and an existing private output directory. The restore identity is a native age identity file kept separately. Never include the private age identity in the source environment file or build context. Remote URLs must explicitly use `sslmode=verify-full`, for example `postgresql://user:password@db.example.test:5432/database?sslmode=verify-full`. System trust is the default, mapped explicitly to `/etc/ssl/certs/ca-certificates.crt`; `sslrootcert=system` is also accepted. Example invocations use absolute private paths:

```sh
bash budgeting/scripts/backup.sh \
  /absolute/private/source.env \
  /absolute/private/age-recipients.txt \
  /absolute/private/backups/budgeting-YYYYMMDD.age

bash budgeting/scripts/restore.sh \
  /absolute/private/disposable-target.env \
  /absolute/private/age-identity.txt \
  /absolute/private/backups/budgeting-YYYYMMDD.age \
  disposable_budgeting_restore 'RESTORE disposable_budgeting_restore'

docker build --pull -t budgeting-recovery:latest budgeting/recovery
docker run --rm --network none --read-only \
  --tmpfs /tmp:rw,nosuid,mode=1777 --tmpfs /run:rw,nosuid,mode=1777 \
  -v "$PWD/budgeting:/workspace:ro" \
  --entrypoint bash budgeting-recovery:latest /workspace/recovery/test.sh
```

For a database requiring a custom public CA, add `&sslrootcert=/run/database-ca.crt` to the private URL and pass the host certificate as the optional **fourth** backup argument or **sixth** restore argument:

```sh
bash budgeting/scripts/backup.sh \
  /absolute/private/source.env /absolute/private/age-recipients.txt \
  /absolute/private/backups/budgeting-YYYYMMDD.age /absolute/path/to/database-ca.crt
bash budgeting/scripts/restore.sh \
  /absolute/private/disposable-target.env /absolute/private/age-identity.txt \
  /absolute/private/backups/budgeting-YYYYMMDD.age \
  disposable_budgeting_restore 'RESTORE disposable_budgeting_restore' \
  /absolute/path/to/database-ca.crt
```

The public database CA is mounted read-only, never copied through build arguments/context. Remote connections reject missing TLS mode and `disable`, `allow`, `prefer`, `require` or `verify-ca`; certificate and hostname verification are mandatory. Inherited `PG*` routing/service/TLS overrides are cleared, duplicate/unsupported URL options are rejected, and GSS encryption cannot bypass TLS verification. Remote TLS-policy parsing is tested offline; no real hosted TLS handshake is established by the offline drill.

Plaintext is allowed only for an explicitly synthetic local drill: the private container environment must contain `RECOVERY_LOCAL_SYNTHETIC=true` and the URL must explicitly use `sslmode=disable` with a literal loopback/`localhost` host or normalized absolute Unix-socket directory. The offline test uses `postgresql://postgres@/postgres?host=/tmp&sslmode=disable` and its disposable-target equivalent. This opt-out never permits remote hosts, multi-host routing or `hostaddr`; it is not a normal deployment option. Loopback/socket paths refer to the recovery container's network/filesystem, not automatically the host's database. The Docker-isolated drill supplies its own server.

The backup output must not already exist. The encrypted manifest names the format/version, PostgreSQL major, original app baseline and `public,private` application schemas; current corrective DDL is included in the dump, but the separate Supabase migration-history schema is not. Source, target and archive majors must match the recovery client's major. The peer drill used PostgreSQL 18; official `latest` may move and does not establish compatibility with hosted Supabase 15/17. A mismatch fails safely and needs separately reviewed version-compatible tooling, never bypassed major/TLS guards. The backup is executable SQL: age provides ciphertext integrity but does not authenticate the original sender. Restore only a backup from trusted custody, not an arbitrary encrypted archive.

Restore is destructive only to an explicitly confirmed target named `disposable_*`, rejects targets with `pg_cron`, authenticates ciphertext before modification, and uses a transaction for schema replacement. It captures/replaces **all** objects in `public` and `private`, potentially including unrelated objects; use an isolated application disposable database only. Provision compatible Supabase roles/Auth schema/helpers and matching Auth user UUIDs in the isolated target first. Objects are owned by the restore administrator (`--no-owner`), while ACL/RLS definitions are restored. Auth users/passwords/MFA, platform secrets, storage, extensions outside these schemas, SMTP and external schedules are not application-schema backups and are not recreated automatically.

The restore sanitizes runnable provider customer/account/link/job mappings, marks Stripe accounts disconnected, and revokes the backend gateway so even an accidentally started worker cannot replay provider work. Historical provider/source identifiers remain sensitive. Keep backend Stripe disabled and workers, schedules and webhook routing absent; gateway execution stays revoked until a separate reviewed re-enable. Reconcile the owner Auth UUID through trusted administration before access; do not copy production passwords, JWTs, MFA seeds or provider credentials into staging. A changed owner UUID is not automated: it needs a DBA-reviewed transaction across `private.app_owner` and every public/private `owner_id` reference, preserving composite foreign keys/constraints and rerunning owner/MFA/wrong-user RLS checks, not just an edit to the owner row. Production in-place restore/re-enable is intentionally not an unattended script path.

Choose a manual backup cadence based on acceptable data loss, for example before migrations/large imports and after material updates. Record backup timestamp, schema revision and a private restore-drill result without financial details. No automatic schedule or private production destination is configured. Recovery point is only the most recent usable backup; local disk loss, lost age keys, provider retention, unbacked Auth configuration and missed backups remain risks. Rehearse correct-key restore, wrong-key/corruption rejection, row/aggregate equivalence and RLS preservation with synthetic data before live use.

## Limits And Costs

- v1 is USD and America/Denver only, with no budget rollover, investments, loans, full net worth, shared access, recurring-bill prediction or money movement.
- CSV and Stripe overlapping date ranges require manual reconciliation/removal. Import undo retains annotated rows; review the resulting ledger. Repeated-file identities and duplicate candidates do not prove two similar purchases are the same transaction.
- The frontend fetches the ledger in paginated memory and renders a bounded visible list, not a large multi-user analytics backend. No persistent offline financial access is supported.
- Balance refresh has an app-enforced 24-hour per-account cooldown and 50 reserved attempts per UTC month across the app, with conservative accounting for uncertain failures and deleted accounts. Reporting months are Denver time; the cap month is UTC. Provider availability can impose additional delays; the usage timestamp is not a promise Stripe will accept a request.
- Previously advertised Stripe pricing was $0.30 per institution/account holder/month for transactions and $0.10 per successful balance call: roughly $0.90 for three institutions plus about $5 for 50 successful balance calls, **not an all-in quote or billing guarantee**. Recheck current terms/prices, verification/other fees and tax before enabling. This cap cannot limit subscriptions, external dashboard/API activity or charges outside this app.
- Each specific Wells Fargo account/card, Citi account/card and Mountain America account/card is **unverified until live testing**. An institution appearing in Stripe marketing does not establish transaction/balance coverage, personal-use eligibility, history depth or ongoing consent availability.
- Supabase Free has historically advertised 500 MB database storage and 500,000 Edge Function invocations, possible pausing after a week of inactivity, and no automatic database backups. Recheck current quotas/pricing; one-minute workers consume invocations even without new data. Free-tier pausing and quotas can interrupt sync/recovery; no uptime guarantee is implied.
- Vercel, SMTP, storage/egress and backup custody may have separate quotas/costs. Monitor platform usage and sanitized sync errors. Do not rely on a free tier as a recovery strategy.

## Contributing

Keep changes inside this standalone package unless specifically approved; preserve portfolio code and deployment behavior. Use synthetic fixtures, container-only dependency installation and meaningful assertions. Update API schemas, migrations, configuration contracts, tests and this documentation together when behavior changes. Keep production secrets and financial records out of logs, screenshots, CI artifacts, public build inputs and Git.

Run validation plus the relevant database/browser/local-stack/recovery checks, retain exact commands/results and inspect the artifact before review. A failing coverage gate, incomplete integration run or blocked external check must be reported plainly, not labeled production-ready. Do not perform hosted migrations, deploy, modify DNS, enable live Stripe or incur costs as part of ordinary contribution validation.
