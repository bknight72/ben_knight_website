# Ben's Budgeteering

Ben's Budgeteering is a standalone, single-owner Flutter web budgeting application for `https://budgeting.benknight.dev`. Built at Novacoast. This package is independent of the portfolio Flutter application and its GitHub Pages deployment.

The CSV-backed workflow is the default: manual cash/card accounts, dated balance snapshots, CSV preview/import/undo, transaction annotations, global deposit/withdrawal group management, monthly Budgeteer funding plans, and portable JSON export. Optional Stripe Financial Connections supplies read-only transactions and balances, not payments. Stripe is disabled by default.

This is a repository handoff, not evidence of a production deployment. Consult the final coordinator validation report and CI logs for actual results against the final tree. Commands below describe checks to run; their presence does not mean they passed. Hosted Supabase/Vercel behavior, SMTP delivery, DNS/TLS, and live bank access require separate owner-approved verification. No hosted projects, remote migrations, DNS changes, deployments, or paid subscriptions are authorized by these instructions alone.

For the ordered CSV launch procedure, platform setup, verification matrix, and go/no-go checklist, use [Production Setup](PRODUCTION_SETUP.md). This README remains the reference for architecture, scripts, API contracts, and recovery limitations.

## Architecture

| Component | Responsibility |
| --- | --- |
| `lib/`, `web/` | Flutter UI, validated public configuration, remembered Supabase MFA session, browser CSV/download and Stripe.js bridge |
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

## Budgeteer

Budgeteer has separate **Tower of Money**, **Withdrawals**, and **Deposits** tabs. Transaction creation and editing live on the corresponding withdrawal/deposit tab. Both lists show Ungrouped first only when it contains transactions; it remains an available assignment even while hidden. This is display order only: named withdrawal groups still fund in monthly priority order, followed by Ungrouped. Empty named groups remain available for editing.

**Group manager** replaces the former **Budgets** sidebar entry. It lists **Deposit groups** and **Withdrawal groups**, with **Add deposit group** and **Add withdrawal group** actions; empty sections show **No deposit groups yet.** and **No withdrawal groups yet.** It reuses the Budgeteer group editor for names, colors and withdrawal parents. Opening or changing the reporting month in Group manager only reads `budgeteer_read`: it does not initialize a monthly plan or include bank sources. Explicit saves use the existing revision-checked `group_save` operation through `budgeteer_mutate`. The old category/monthly-limit management entrypoint is removed, not its data: existing categories, annotations, monthly budget rows, reporting calculations and export remain preserved.

Budgeteer is a separate monthly USD funding plan. Opening a month initializes it through a revision-checked mutation and includes eligible posted deposits and withdrawals across all accounts, using posted date or transaction date when posted date is unavailable. Transfers, card payments, budget-excluded activity, expense refunds, and income reversals retain their existing exclusions. Deposits are manually assigned to flat deposit groups or remain Ungrouped and feed the synthetic Income root (100% of available funding). Withdrawal groups and subgroups form a separate hierarchy using an optional parent. Each withdrawal belongs directly to at most one withdrawal group; unassigned withdrawals remain Ungrouped. Group cards remain navigable even when empty or unfunded.

Funding uses exact integer cents in deterministic depth-first sibling order (sort position, then stable ID): a group's direct withdrawals before its children, with top-level Ungrouped last. Parent totals roll up descendants once; direct allocations are distinguished from child allocations. Links show funded amounts only. Remaining income and unfunded withdrawals are separate, not additional funding. Explicit arrow controls reorder siblings for the selected month without changing global hierarchy or another month's priority. Global parent edits can change allocation priority in every month. Deleting a group moves its directly assigned transactions to Ungrouped in **all months** and promotes its immediate children to its former parent, preserving descendants and their assignments. Entries, amounts, bank links, source snapshots and exclusions are not deleted.

Plans, groups, entries, archived labels and associations, and source exclusions persist in dedicated `budgeteer_*` PostgreSQL tables. Removed linked transactions stay excluded for that month across reloads; Restore excluded transactions includes eligible excluded sources again. Manual entries remain available. New eligible transactions are included on the next page load without overwriting existing plan edits. Editing a plan never edits raw bank transactions, ledger annotations, categories, or balances. Linked entries retain independent names and amounts; bank changes are flagged for explicit source refresh. Source deletion preserves planning entries and snapshots. Exclusions use transaction IDs, so reimports creating new IDs are treated as new sources. There is no transaction unlink control in the UI.

Deposit and withdrawal groups now form one owner-scoped global catalog: IDs, names, colors, kinds and hierarchy are shared across past, future and not-yet-initialized months. Creates, renames, color changes and reparenting apply everywhere. Monthly transaction assignments, amounts, source exclusions and funding priority remain independent. `budgeteer_groups` has no `plan_id`; `budgeteer_group_positions` stores per-plan `sort_position` overrides and `budgeteer_group_state` stores the owner's global revision. Months without overrides use global default order. There is no automatic monthly group copy, copy preview or **Copy earlier groups** action; `groups_copy` is retired.

The lossless forward migration preserves every existing group UUID, hierarchy, transaction assignment and original monthly ordering. Previously independent copies with identical names remain distinct global groups; names are not used to guess equivalence or silently merge IDs. Review duplicates explicitly after upgrading rather than deleting or deduplicating them during migration.

Legacy labels and entry-label associations remain read-only archived records and remain covered by authorized export. The forward migration snapshots associations and original withdrawal data in `budgeteer_legacy_entry_labels`, independently of active entry lifetime, so deleting a planning entry does not erase its archive. The **Review archived labels** button and archive-conversion UI are retired; stored archives and backend conversion contracts remain intact. Existing transaction assignments remain authoritative. Active labels and label-edit operations are retired.

Authenticated owner/MFA-only `budgeteer_read` and `budgeteer_mutate` RPCs return canonical state with `schema_version: 4`, top-level `owner_id` and `groups_revision`, including when `plan` is null. Groups have no `plan_id` and expose effective selected-month `sort_position`. The mutation signature remains `(p_month,p_revision,p_operation,p_payload)`. Every payload requires numeric `schema_version: 4` and `expected_groups_revision` from the last read; even otherwise empty operations use `{"schema_version":4,"expected_groups_revision":0}` with the actual returned revision. Missing, older, newer or string schema markers fail with `budgeteer_schema_upgrade_required` before any writes. Reads are side-effect-free. An owner advisory lock serializes mutations; stale monthly or global revisions raise `budgeteer_conflict` without partial writes, including cross-month catalog edits. Reload and review before reapplying. Global deletion also advances revisions of months whose assignments changed. The backend rejects cycles, self-parenting, cross-owner parents, invalid membership and stale label clients.

Global groups have immutable `kind: deposit|withdrawal` (existing rows and omitted `group_save.kind` default to `withdrawal`). Deposit groups are flat and separate from the withdrawal hierarchy: their explicit `parent_group_id` must be null and they cannot parent withdrawals. `group_save` otherwise retains `name`, `color_key`, explicit nullable `parent_group_id` and optional `id`. Colors retain the existing preset keys or custom `hex_rrggbb` format. Both entry kinds accept a manually assigned same-owner, same-kind global `group_id`, or null for Ungrouped; bank inclusion/restoration never infers groups and source refresh preserves assignments. Complete `reorder` payloads must contain every global group and selected-month entry of BOTH kinds, including empty groups, with unique IDs and same-kind targets. Reorder changes only selected-month priority and assignments. Deleting a deposit group ungroups its deposits across all months without deleting them. Archived-label conversion only creates or targets withdrawal groups.

Deployment order requires separate approval: after earlier migrations, apply `supabase/migrations/202611110001_budgeteer_hierarchy.sql`, `supabase/migrations/202611110002_budgeteer_deposit_groups.sql`, then `supabase/migrations/202611110003_budgeteer_global_groups.sql` in that order (never rewrite or rerun applied migrations). Back up first and review preserved IDs, assignments, duplicate names and monthly ordering. Release the matching API export/OpenAPI documentation, then the v4 frontend. Old clients must reload/update; they cannot safely mutate after the v4 migration. Until the schema update is deployed, the new UI reports an actionable database-update message instead of interpreting old responses as successful migration. Local synthetic verification does not apply hosted migrations or authorize deployment. Signed-in local development still targets the real backend and must not be used for automated financial-write tests.

Portable export remains version 1 and includes every owner-scoped financial table: `profiles`, `accounts`, `balance_snapshots`, `transactions`, `transaction_annotations`, `categories`, `monthly_budgets`, `import_batches`, `budgeteer_plans`, `budgeteer_groups`, `budgeteer_group_state`, `budgeteer_group_positions`, `budgeteer_entries`, `budgeteer_labels`, `budgeteer_entry_labels`, `budgeteer_legacy_entry_labels`, and `budgeteer_source_exclusions`. Each table is paginated using its stable key and the verified owner filter, including composite monthly priority keys. Exported groups contain stored default ordering, while overrides are exported separately. Computed source status comes from reads, not storage. The owner/MFA-only, no-store download remains sensitive and formula-leading strings are escaped; it is not a complete database backup.

Budgeteer domain, widget, repository, and SQL tests run through the existing containerized validation scripts. No additional environment variables or host dependencies are needed.

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
| `SUPABASE_URL` | Release build requires `https://<20 lowercase alphanumeric project-ref>.supabase.co`, with no credentials, port, non-root path, query, or fragment |
| `SUPABASE_PUBLISHABLE_KEY` | Release build requires `sb_publishable_` followed by at least 20 letters, digits, underscores, or hyphens; no placeholders, legacy JWT anon keys, service-role keys, or secret keys |
| `STRIPE_PUBLISHABLE_KEY` | Empty when disabled; enabled production releases require `pk_live_` plus at least 20 alphanumeric characters, without placeholders |
| `STRIPE_ENABLED` | Defaults to `false`; only exact `true` opts into live-enabled production builds |

These values are embedded in public JavaScript. Anyone can read them. `scripts/build.sh` runs containerized `release.ts preflight` before compilation and passes only these four values as Docker build arguments. Key-shape validation cannot prove project ownership: verify the Supabase pair and matching Stripe account/mode privately. Secret/restricted, test-mode, malformed and placeholder Stripe keys are rejected without printing values. Local mocked/test-mode validation is separate from this production contract. Public `config.yaml` permits the capability (`stripe_enabled: true`) but cannot activate it: the build flag defaults false, a public key is required, and independent backend `STRIPE_ENABLED`, `STRIPE_MODE=live`, `STRIPE_LIVE_AUTHORIZED=true`, credentials, owner and MFA gates remain mandatory. YAML false blocks linking even with the build flag; YAML true plus a disabled build still blocks linking. The default `AppConfig` remains false. Backend authorization is never inferred from YAML or release evidence.

### Backend And Administration

| Variable | Meaning |
| --- | --- |
| `SUPABASE_ANON_KEY` | Backend compatibility name used for authenticated Supabase requests; use the project's compatible public/anon key, not a service-role key |
| `SUPABASE_SERVICE_ROLE_KEY` | Backend/admin key for narrow privileged operations; never sent to Flutter |
| `ALLOWED_ORIGINS` | Comma-separated exact frontend origins; production default is `https://budgeting.benknight.dev`; explicitly allow a chosen local/preview origin when needed |
| `STRIPE_ENABLED` | Independent backend enablement; defaults to `false`; a public build flag does not enable it |
| `STRIPE_MODE` | `test` by default; test and live projects/keys/data must remain isolated |
| `STRIPE_LIVE_AUTHORIZED` | Defaults to `false`; explicit additional live authorization gate |
| `STRIPE_SECRET_KEY` | Backend-only `rk_live_`/`sk_live_` (or isolated test counterpart), with matching mode; prefer least-privilege restricted key, no payments/payouts/Connect permissions |
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

### F5 From Host VS Code

Keep VS Code open normally on macOS; this workflow does not require reopening
in a devcontainer or installing Flutter/dependencies on the host.

1. Start Docker Desktop (or your existing Docker engine) and install Chrome.
2. Open the repository root in VS Code.
3. Select **Budgeting (Docker, Real Backend)** in Run and Debug and press F5.
4. Wait for the development task to compile, then use the Chrome window at
   **http://localhost:8180**. Sign in using your existing owner password and TOTP.

The task reuses `budgeting-flutter:latest`, building it if missing. It retrieves
the deployed site's public `release-config.json` over verified HTTPS and passes
only its Supabase URL/publishable key to Flutter. Stripe is always disabled for
this workflow. No backend `.env` is loaded or mounted. This targets the **real
backend**: signed-in changes affect real financial records, not a sandbox.
The local origin has its own remembered session; expect to sign in initially.

Port 8180 is published on host loopback only; port 8080 was already occupied
on the development machine. Keep the exact `localhost` hostname for CORS and
session consistency. Do not share the server through tunnels or public port
forwarding. The source mounts contain only `lib`, `web`, public YAML and the
development helper; generated packages/build state live in checkout-specific
Docker volumes, leaving release artifacts and host package configuration alone.

Saving Dart files under `lib/` or files under `web/` triggers Flutter reload via
a container-side metadata watcher (rather than unreliable macOS bind-mount
inotify). **Tasks: Run Task** also offers **Budgeting: Reload UI** and
**Budgeting: Restart UI**. Reload preserves supported widget state; restart
reruns initialization. Browser asset/bootstrap changes may require refreshing
the browser or stopping and relaunching. Changes to dependencies, public
configuration or `config.yaml` require stopping and relaunching.

Stopping the browser debugging session runs **Budgeting: Stop Development
Server**. The same task can stop an orphaned server. Task cancellation also
cleans up the owned container. Other containers are never stopped; an occupied
port or existing checkout development container causes startup to fail rather
than attach to an unrelated service. Package/build cache volumes remain for
the next launch and contain no copied financial records.

This is a host Chrome browser-debug launch, **not an attached Dart debugger**:
Dart breakpoints/Flutter Inspector and host analyzer SDK resolution are not
provided. Use the devcontainer workflow below for container-aware Dart analysis.
The VS Code browser launch itself requires a manual F5 acceptance check in the
editor; CLI/browser smoke validation is not evidence that the editor was used.

#### Backend Origin Settings

Normal password/TOTP login and ledger reads use Supabase Auth/PostgREST. Edge
operations (including import/export and usage) additionally require this exact
origin in the hosted API's `ALLOWED_ORIGINS`:

```text
https://budgeting.benknight.dev,http://localhost:8180
```

Preserve any other explicitly approved origins already configured. The startup
task performs an anonymous OPTIONS probe and warns if localhost is not allowed;
it never modifies hosted settings. The initial November 11 probe returned 403,
so Edge-backed features require that owner-approved hosted setting update.
Do not disable CORS, MFA, RLS, or owner checks to work around it. For password
recovery initiated from `/`, add `http://localhost:8180/` to Supabase Auth's
allowed redirect URLs; keep the production Site URL unchanged. Ordinary
password/TOTP sign-in does not require a redirect allowlist change.

#### Corporate Trust And Public Overrides

On a TLS-inspecting network, provide the approved **public CA certificate** at
the gitignored `budgeting/dev-ca.local.crt`, or start VS Code with an absolute
`BUILD_CA_FILE` environment value. The existing public development CA was
placed at that local path on this machine; it is not committed. This certificate
is mounted read-only and installed into container trust before dropping to the
non-root builder. TLS verification remains enabled. Never use a private key.

For a different approved backend or if the deployed public manifest is
unavailable, set `BUDGETING_DEV_PUBLIC_CONFIG` in the development task's
`options.env` to an absolute JSON file path. A gitignored location is
`budgeting/dev-public.local.json`. Its format is:

```json
{
  "supabaseUrl": "https://YOUR_PROJECT_REF.supabase.co",
  "supabasePublishableKey": "YOUR_PUBLIC_PUBLISHABLE_KEY"
}
```

Replace both placeholders with the matching hosted project's **public** values.
Unknown fields, non-hosted URLs, legacy JWT keys and secret keys are rejected.
Never point this option to `.env`, export credentials, or a backend secrets file.
Configuration values are not printed in launcher logs. Network, trust or invalid
configuration errors stop startup instead of silently opening an unconfigured app.

### VS Code Diagnostics

Container-generated `.dart_tool/package_config.json` references `/home/builder/.pub-cache` and `/opt/flutter`. A macOS VS Code analyzer cannot resolve these container-only paths; this produces missing imports and cascading Dart errors even when container analysis passes. Do not hide errors or run host package installation to work around it.

Build `budgeting-flutter:latest` using the validation/tooling instructions, then open the repository in VS Code and run **Dev Containers: Reopen in Container**. The root `.devcontainer/devcontainer.json` uses that local image, installs editor extensions, and resolves both Flutter packages inside the container. The setup script does not load financial secrets. If package downloads require corporate trust, supply the approved public CA to the container system trust store before rerunning setup; never disable TLS. Until VS Code is reopened in the container, the host analyzer's container-path diagnostics are expected to remain.

The editor and container must share the same package cache path. Do not edit or commit `.dart_tool/package_config.json`; it is generated and gitignored. The devcontainer intentionally does not mount the Docker socket or load backend environment files. It is an editing environment, not permission to access live finances or deploy.

### Validate And Build

```sh
sh budgeting/scripts/validate.sh
```

The validation entrypoint builds the Flutter tooling image, resolves packages in Docker, checks formatting, analyzes Flutter, runs unit/widget coverage and its gate, and builds an unconfigured release web app. It then runs browser-bridge tests, release-preflight/manifest/verification tests, packager/artifact-audit tests, the exact backend `supabase/tests/run-deno.sh` runner, disposable PostgreSQL checks, browser-artifact checks, non-root static runtime health/graceful-stop checks, and the offline encrypted recovery drill. It stops at the first failure; later checks are not evidence of execution if Flutter or an earlier step fails. The actual local Supabase stack harness remains separately invokable below and is a separate CI step. It does not contact live banks. Historical results in Tests do not establish results for the current revision; hosted acceptance remains a separate gate.

For a TLS-inspecting network, use an absolute path to the operator-approved public CA:

```sh
BUILD_CA_FILE=/absolute/path/to/public-ca.crt sh budgeting/scripts/validate.sh
```

The CA is supplied using a BuildKit secret and a read-only runtime mount for validation. Host TLS verification remains enabled. Build failures should be diagnosed from the issuer/hostname and trusted chain, not bypassed with insecure curl/Dart settings. The CA is not an app secret and must not be added to Git.

Build a public-configured release artifact separately:

```sh
SUPABASE_URL="${SUPABASE_URL:?Set the verified hosted project URL}" \
SUPABASE_PUBLISHABLE_KEY="${SUPABASE_PUBLISHABLE_KEY:?Set its browser publishable key}" \
STRIPE_ENABLED=false \
STRIPE_PUBLISHABLE_KEY= \
sh budgeting/scripts/build.sh
```

Set the two public shell values from the intended project before this command; placeholder values will fail preflight. Add `BUILD_CA_FILE=/absolute/path/to/public-ca.crt` if required. Do not pass a backend environment file to `docker build`. Output is `budgeting/build/web/`, then the script packages `budgeting/.vercel/output/`. Empty public values fail `build.sh`; intentional unconfigured builds belong to `validate.sh` and must never be released. After a configured build, run `sh budgeting/scripts/test-release-browser.sh` to smoke-test the packaged output locally without logging in or writing hosted data.

Repackage an already-built artifact without recompilation:

```sh
sh budgeting/scripts/package-vercel.sh
```

The packager copies only static web assets, omits `flutter_service_worker.js`, and generates Vercel Build Output API version 3 routes: security headers, filesystem precedence, then SPA fallback. Financial data is never an offline cache. Authentication credentials are deliberately remembered in project-scoped browser storage so reloads and browser restarts can restore an MFA-verified session. Financial responses, passwords, TOTP setup secrets/codes, and Stripe client secrets must not be persisted. Fresh authentication still requires TOTP; session restoration still verifies the owner and AAL2 before loading financial data.

Remembered access lasts until logout, revocation, browser storage removal, or Supabase session expiry. Short-lived access tokens are renewed using refresh tokens, not made indefinitely valid. Browser-stored tokens are sensitive bearer credentials accessible to same-origin JavaScript and potentially browser extensions or other users of the device. Use a trusted device, retain CSP and dependency protections, and sign out before sharing it. This is not biometric/passkey authentication or hardware-bound token storage. Hosted session timeouts and refresh-token policies remain controlled by Supabase; this change does not alter them.

### Local Runtime

The Dockerfile also has a non-root nginx runtime on port 8080. Build it with the same public values (and optional BuildKit CA secret) when a standalone server is needed:

```sh
docker build --target runtime -t budgeting-runtime:latest \
  --build-arg "SUPABASE_URL=${SUPABASE_URL:?Set the verified hosted project URL}" \
  --build-arg "SUPABASE_PUBLISHABLE_KEY=${SUPABASE_PUBLISHABLE_KEY:?Set its browser publishable key}" \
  --build-arg STRIPE_ENABLED=false --build-arg STRIPE_PUBLISHABLE_KEY= budgeting
docker run --rm --name budgeting-local -p 8080:8080 budgeting-runtime:latest
```

The static `/health` endpoint reports frontend liveness only, not database availability. nginx uses `SIGQUIT` for graceful shutdown; stop it with `docker stop --time 30 budgeting-local`. Local nginx is not proof of Vercel edge headers or redirects. If testing real Auth locally, allow the exact local origin in backend CORS and Auth redirects and use an isolated test backend.

## Tests

Historical local verification recorded on 2026-11-06: Flutter analysis passed, 57 Flutter tests passed with 89.0% conservative whole-library coverage, 27 backend tests passed with 88.15% fixed-production coverage, and 7 browser bridge tests passed. Release compilation, Chromium artifact smoke checks at three viewports under CSP, non-root runtime liveness/graceful stop, static credential audit, and Vercel packaging passed. Database authorization/concurrency/usage/lease tests and the offline encrypted recovery drill passed. These are historical local results, not results for the new release pipeline, hosted deployment, or live-bank verification; rerun the commands against changes and consult the final handoff for remaining integration limits.

Signed-in Chromium-to-Supabase acceptance passed locally twice on 2026-11-06 (23:15:34Z and 23:23:05Z, both exit 0) against real disposable stacks with synthetic data and no host-published ports. The harness waits for Flutter's focused accessibility input to activate its editing handlers before filling, matches MFA response paths independently of query strings, and targets merged account-card accessibility names. It verifies real password login, TOTP, dashboard fixture data, a manual account persisted through PostgREST with the correct owner, sign-out financial clearing, empty local storage, no service workers, and no browser runtime errors. No Auth or financial requests are mocked. Owned test services and isolated daemon state were removed afterward. This does not establish hosted acceptance, browser password-recovery completion, or live bank support. The editor devcontainer configuration also remains unverified in the VS Code client until reopened in the container.

```sh
sh budgeting/scripts/validate.sh
sh budgeting/scripts/test-database.sh
sh budgeting/scripts/test-browser.sh
sh budgeting/scripts/test-runtime.sh
sh budgeting/supabase/tests/run-local.sh
docker run --rm -v "$PWD/budgeting/supabase:/work" -w /work \
  denoland/deno:latest sh tests/run-deno.sh
```

`test-database.sh` creates disposable plain PostgreSQL, bootstraps synthetic Auth roles, applies migrations in filename order, then runs `authorization.sql`, `concurrency.sql` and `usage_and_leases.sql`. These cover owner/MFA authorization, cap concurrency, immediate repeated refresh reservations, UTC usage boundaries and worker lease fencing. `supabase/tests/bootstrap.sql` is **only** for disposable plain PostgreSQL; never apply it to managed Supabase. Local-stack tests must use the real Supabase Auth/PostgREST/Edge services rather than that bootstrap as a substitute.

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

Both CI definitions also exercise explicit enabled linking against mocked Stripe only:

```sh
BUDGETING_MOCK_STRIPE=true sh budgeting/scripts/build-local-browser.sh
BUDGETING_MOCK_STRIPE=true BUDGETING_BROWSER_INTEGRATION=true \
BUDGETING_BROWSER_ARTIFACT="$PWD/budgeting/build/local-browser-stripe" \
sh budgeting/supabase/tests/run-local.sh
```

This separate synthetic artifact uses a test-shaped public key. Disposable function wrappers intercept only Stripe HTTP requests; Auth, MFA, PostgreSQL and function dispatch remain real. The browser mocks Stripe.js consent, interrupts completion, reloads and resumes the same pending session. No real bank calls occur. For offline local checks with an already cached container image, `BUDGETING_FLUTTER_IMAGE=budgeting-build:latest BUDGETING_PUB_OFFLINE=true` permits cached dependency resolution without weakening TLS. CI continues to fetch dependencies normally.

The current auth acceptance harness checks password/TOTP once, refresh-token rotation with preserved owner/AAL2 authorization, remembered login after reload and page reopening, project-scoped authentication storage without financial caches, and cross-tab logout followed by a signed-out reload. This updated real local Supabase/Chromium flow passed on November 10, 2026, including expired-access refresh and invalid-refresh denial. True browser-process restart and hosted session expiry/revocation policies still require deployment acceptance on the intended devices. No hosted authentication settings were changed by local validation.

The harness uses a `corporate_ca` BuildKit secret for image trust and mounts the public certificate read-only for runtime `NODE_EXTRA_CA_CERTS`. This is separate from Flutter/browser `BUILD_CA_FILE` and recovery database TLS roots; no TLS bypass is used.

The network harness covers real MFA/owner/RLS denial, manual records, CSV operations, annotations/budgets, usage and export. It checks recovery-email receipt in Mailpit, rejects a correctly HMAC-signed but expired JWT at both Edge and PostgREST, and separately rejects a tampered JWT. This does **not** complete browser recovery-link navigation, password replacement, post-recovery MFA or hosted SMTP delivery. `integration_test/local_supabase_test.dart` additionally expects explicitly supplied synthetic `TEST_SUPABASE_URL`, `TEST_SUPABASE_KEY`, `TEST_OWNER_EMAIL`, `TEST_OWNER_PASSWORD` and `TEST_OWNER_TOTP_SECRET` build defines and a prepared local fixture; it is not equivalent to running the standalone Deno harness. The passing Chromium phase covers the specific signed-in flow listed above, not the complete hosted launch checklist or live Stripe acceptance.

The required coverage threshold is at least 70% executable lines separately for first-party Flutter and Deno backend code. Flutter output is `budgeting/coverage/lcov.info`; the root checker is `scripts/check_coverage.dart`. Validation explicitly requires app, domain, config, repository, and main records. Any omitted production Dart library, including the browser-only adapter, contributes every nonblank/non-comment line as uncovered: a conservative denominator rather than silently excluded source. The measured final VM report is 1,084/1,218 lines (89.0%) with this conservative adjustment; browser behavior is separately tested, not credited as instrumented adapter coverage.

The backend command above is the authoritative fixed-production-scope runner. `supabase/tests/run-deno.sh` type-checks all three entrypoints, runs the Deno tests with coverage, writes `/tmp/budgeting-coverage/lcov.info` inside its container, and invokes `supabase/tests/check_coverage.ts`. That checker discovers **every** `functions/**/*.ts` file and counts only their executable LCOV lines, excluding test source. The current nine files are `_shared/core.ts`, `_shared/runtime.ts`, `_shared/openapi.ts`, and `handler.ts` plus `index.ts` under each of `api/`, `worker/` and `stripe-webhook/`. Entrypoint tests execute actual registration with `Deno.serve` intercepted rather than excluding those modules. Missing/empty production records or aggregate coverage below 70% fail. `validate.sh` also copies the backend LCOV to `budgeting/coverage/backend.lcov` and runs the root checker. Standalone `docker run --rm` discards its temporary report unless explicitly copied out. Browser bridge checks are behavioral tests, not a claim of instrumented JS coverage. Do not improve reported coverage by excluding difficult UI/auth/worker code or unexecuted production modules.

GitHub's `Budgeting Validation and Release` workflow is `.github/workflows/budgeting-ci.yml`: relevant budgeting/security/workflow pull requests validate only, every push to `master` validates without a path filter, and manual runs are available. Its unconfigured artifact is not deployable production output. Release policy and activation are below; the portfolio workflow remains separate. For GitLab, select `budgeting/.gitlab-ci.yml` as the CI configuration path, enable the instance runner under Settings > CI/CD > Runners, and provide a trusted shell runner with local Docker tagged `shared`; rules cover merge requests and `main`/`master`. A remote Docker-in-Docker daemon cannot resolve the scripts' checkout bind paths. GitLab validation is not this GitHub release pipeline. Creating a mirror, enabling runners, and protected secrets are operator tasks, not actions performed by this README.

Launch follow-up on 2026-11-06:

- Public GitHub job metadata confirms Pages run `42156567756` failed at root analysis and Budgeting Validation run `42156567708` passed validation/packaging but failed isolated Supabase integration.
- Root analysis scanning this independent package was reproduced locally; root analyzer exclusions now keep budgeting under its dedicated validation. Portfolio analysis/release build pass locally, while an additional portfolio widget-test run has unresolved failures outside that workflow. The existing portfolio returned HTTP 200.
- Budgeting analysis, 57 Flutter tests (89.0%), 27 backend tests (88.15%), disposable database checks, static browser checks, runtime checks, package/audit tests, 7 bridge tests, and the offline encrypted restore drill passed again locally.
- The complete `scripts/validate.sh` entrypoint then passed with the existing public build CA, including a fresh tooling-image build, release compilation, and 37 Deno tests (27 existing tests plus 10 local-readiness regressions). Fixed-scope production coverage remains 88.15%; test helpers are not credited toward that gate. The packaged artifact remains unconfigured and must not be deployed as production.
- Isolated-stack testing reproduced a local readiness bug: Kong replaces the function's CORS header with `*`. The test-only probe now accepts that header only with HTTP 200 and healthy database JSON; production CORS and financial authorization are unchanged. The real API acceptance harness then passed. Subsequent browser-harness focus, response-matching, and accessibility-locator fixes also passed the signed-in Chromium phase; no application authentication changes were needed.
- Dev Container setup resolved both packages with the existing public CA, but actual VS Code client use and hosted acceptance remain separate gates. No hosted deployment or successful final GitHub rerun is established by these results.

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
7. Enroll and challenge the owner's TOTP. Verify reload and reopening the same browser restore the MFA-verified session without another code; expired access tokens refresh before financial access. Verify explicit logout/session loss clears open financial dialogs and data, logout removes remembered credentials across tabs, and the next reload requires sign-in. Browser storage may contain only the approved auth session/coordination entries, never financial responses or Stripe secrets; no app service worker is permitted.

### MFA Recovery

Keep the TOTP seed in the owner's secure authenticator/key custody process. Password recovery resets a password; it does not satisfy or remove MFA. The app clears recovery tokens from the URL and requires MFA before financial access.

For a lost factor, a trusted Supabase administrator must independently verify the owner's identity before using supported Auth administration to remove the lost factor and revoke existing sessions. Reconfirm the same Auth UUID and immutable owner mapping, recover the password if needed, then require enrollment and successful challenge of a replacement factor. Until `aal2` is restored, financial access must remain denied. Do not edit `aal` claims, disable RLS, copy production credentials into test, or let an unauthenticated client reset MFA. Rehearse this recovery process before live use and record only non-sensitive operational evidence.

## API Reference

Let `SUPABASE_URL` be the verified hosted origin described under Public Build Values. The Edge API base is **`$SUPABASE_URL/functions/v1/api`**, not the frontend domain. Anonymous endpoints are:

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
| `GET /api/v1/connections/pending` | Owner/MFA-only resumable session summaries `{sessions:[{sessionId,createdAt,status}]}`, never client secrets |
| `POST /api/v1/connections/complete` | `{sessionId}`; authoritative owner/customer/mode/permission checks; `{accountIds,status:'queued'}` durably accepts subscriptions before async sync, completed replay returns recorded result |
| `POST /api/v1/accounts/{id}/subscription-retry` | `{confirmCost:true}`; explicitly requeues the same accepted subscription job/identity after failure, no new link or balance purchase |
| `POST /api/v1/accounts/{id}/balance-refresh` | `{confirmCost:true}`; 202 durable request ID/status, no app cooldown, subject to cap/provider checks |
| `POST /api/v1/accounts/{id}/disconnect` | Durable provider cleanup, retaining local history |
| `POST /api/v1/accounts/{id}/delete` | `{confirmDelete:true}`; provider cleanup before local cascading deletion |

CSV mapping names exact headers: `date`, `description`, either signed `amount` or `debit`/`credit`, optional `transactionId`/`currency`, explicit `dateFormat` (`YYYY-MM-DD`, `MM/DD/YYYY`, `DD/MM/YYYY`) and `sign` (`inflow-positive` or `outflow-positive`). Imports are bounded to 5 MiB/10,000 rows; raw CSV is not retained. Same-source ambiguous repeats require review. Cross-source overlapping dates are refused even with confirmation; reconcile/remove overlapping history manually rather than double-counting.

Profiles, manual accounts/snapshots, categories, annotations and budgets use owner/MFA-protected PostgREST tables/RPCs. Provider writes remain backend-only. Errors are sanitized `{code,message,requestId,retryAt?}`, with 401 unauthenticated/expired, 403 owner/MFA required, 422 validation, 429 cap/provider availability/throttling and 503 unavailable/disabled. See OpenAPI for exact current success/error schemas.

### Worker Operations

The webhook URL is `$SUPABASE_URL/functions/v1/stripe-webhook`, requiring the environment's Stripe raw-body signature and expected test/live mode. Select live snapshot events `financial_connections.account.refreshed_transactions`, `financial_connections.account.refreshed_balance`, `financial_connections.account.disconnected`, `financial_connections.account.deactivated`, and `financial_connections.account.reactivated` only. Do not select thin events, preview relink or payments events. The worker is `POST $SUPABASE_URL/functions/v1/worker` with `Authorization: Bearer <WORKER_SECRET>`. An approved scheduler must invoke it every minute; never expose that secret in a public cron URL or frontend. Use the platform's private secret facilities. No schedule is created by a static deploy. [Production Setup section 13](PRODUCTION_SETUP.md#13-owner-operated-live-bank-activation) includes the owner-run Vault/pg_cron template, listing/last-run/removal checks, webhook API-version gate and first-account acceptance.

Jobs are durable, leased, bounded and retried with backoff. Lease expiry allows recovery; after eight failed attempts a trusted operator must investigate the sanitized error, provider/account state and overlap before a narrowly scoped retry. Do not reset all jobs, replay old webhooks, refund uncertain paid reservations, or enqueue fresh balance purchases as a recovery shortcut. Daily transaction recovery is not a paid balance refresh and cannot prove that every missed event was recovered without checking sync state.

Paid-refresh recovery conservatively compares the persisted pre-dispatch balance
timestamp and first dispatch time with authoritative provider results. Same-second
or unchanged `as_of` values can remain uncertain even if Stripe succeeded. Keep
the original reservation counted and reconcile existing dashboard/webhook/job
evidence using sanitized IDs; never create a second paid reservation merely to
resolve uncertainty or infer success from an unrelated old balance.

To pause safely, disable new frontend/backend linking and refresh. This does not cancel Stripe recurring subscriptions. When abandoning sync, keep matching credentials, mode/live authorization and the worker available for authenticated disconnect cleanup even with new activity disabled. Verify subscriptions/provider access are stopped before pausing/removing the worker schedule or revoking keys. Retain financial history/backups and retry records. Investigate exhausted disconnect jobs before assuming charges stopped; frontend rollback, hiding controls or pausing workers does not stop feed charges.

## Deployment

### Gated Prebuilt Releases

For this artifact-only pipeline, leave the dedicated Vercel project's **Root
Directory empty**, not `budgeting`. GitHub builds the budgeting package, but
Vercel CLI receives only the staged release directory. A nonempty remote root
would point inside that artifact directory; target verification rejects it.
This replaces the root-directory advice for a repository-based Vercel import.

Hosted smoke also verifies HTML/JavaScript SHA-256 against the retained artifact,
so a prior release with the same public configuration cannot masquerade as the
new release. For local configured smoke, export the same public build values
and optional `BUILD_CA_FILE` before invoking `test-release-browser.sh`.

Release jobs are disabled unless repository variable `BUDGETING_DEPLOY_ENABLED` is exactly `true`; leave it unset during implementation and platform setup. Approval of code is not authorization to activate or publish. Configure these values securely in GitHub, not in backend `.env` files:

| Location | Setting | Required value / purpose |
| --- | --- | --- |
| Repository variable | `BUDGETING_DEPLOY_ENABLED` | Unset/anything other than exact `true` means validation only |
| Repository variable | `SUPABASE_URL` | Verified hosted origin satisfying release preflight |
| Repository variable | `SUPABASE_PUBLISHABLE_KEY` | Matching browser-safe `sb_publishable_...` key |
| Repository variable | `STRIPE_ENABLED` | Unset defaults false; exact `true` only after owner activation readiness |
| Repository variable | `STRIPE_PUBLISHABLE_KEY` | Empty by default/when disabled; matching live public key only when enabled |
| `budgeting-production` environment variable | `SUPABASE_PROJECT_REF` | Production project ref; `SUPABASE_URL` must equal `https://<ref>.supabase.co` exactly |
| Same environment secret | `SUPABASE_ACCESS_TOKEN` | Supabase account token authorized to read project metadata and deploy functions; not a project API key |
| `budgeting-production` environment variable | `VERCEL_ORG_ID` | Verified dedicated account/team ID |
| Same environment variable | `VERCEL_PROJECT_ID` | Verified dedicated budgeting project ID |
| Same environment variable | `VERCEL_PROJECT_NAME` | Exact existing project name, lowercase letters/digits/hyphens/underscores; not the hostname |
| Same environment variable | `BUDGETING_PRODUCTION_URL` | Exactly `https://budgeting.benknight.dev` |
| Same environment secret | `VERCEL_TOKEN` | Least-access practical deployment token |
| Same environment secret, optional | `VERCEL_AUTOMATION_BYPASS_SECRET` | Approved automation bypass for protected unique deployment smoke only |

Restrict `budgeting-production` deployments to `master` in GitHub environment settings. Required reviewers are optional where supported; the branch restriction is mandatory. The workflow cannot configure this platform control for you. Disable duplicate Vercel Git deployments using the dedicated project's supported Git deployment control, not by disconnecting the portfolio/shared integration. Keep `vercel.json` prebuilt-only: its no-op install/build settings are not a source-build pipeline.

After explicit activation authorization, every `master` push/merge is eligible, including documentation-only changes. Manual dispatch must select current `master`; re-runs can release only while their SHA is still current. Freshness is checked before building and again after the serialized deployment queue; stale runs fail and require a new dispatch against current `master`. PRs (including forks), other branches/tags, previews, schedules, and daily container rebuilds do not release. Concurrent validation may be canceled, but production publishing uses a fixed group with `cancel-in-progress: false`. GitHub does not guarantee FIFO ordering and may supersede pending releases.

`release-build` requires successful validation, both independent 70% coverage gates, and real disposable Supabase/browser integration. It runs `build.sh` with public repository values (Stripe defaults disabled), then configured local browser smoke using those same settings. It stages only `release/.vercel/output` and non-served `manifest.json`. The build emits browser-safe `release-config.json` containing public Supabase and Stripe enablement/key identity; smoke compares it and compiled key identity to intended values. The manifest binds that public configuration, source SHA, run/attempt, build time, tool/image evidence and per-file SHA-256 checksums. Deploy compares the manifest and static evidence to its current public settings before any backend mutation or publication; changes between jobs fail closed and require a new run. No backend Stripe credentials enter GitHub builds. The immutable `budgeting-release-<run>-<attempt>` artifact includes hidden output, fails if missing, and is retained 30 days. Artifact access follows repository permissions; all contents must be browser-safe. Do not upload source, `.env`, backend secrets, `build/local-browser`, or the unconfigured validation artifact as a release.

`deploy` depends on validation and that build, uses a fresh trusted-SHA checkout, downloads the exact same-run artifact ID, and verifies its source/checksums with read-only tooling. It does not execute artifact-provided scripts or rebuild. `release.ts target` authenticates and verifies existing Vercel project/account/name before containerized `vercel deploy --prebuilt --prod`; it must not create/relink a project. The Vercel token is available only to that publish step, not dependency installation, release build, or smoke tests. Tool dependencies are installed only in containers. Actions use full commit SHAs; default token access is read-only, with `actions: read` added only for deployment artifact access and checkout credentials not persisted.

The same serialized job now deploys the Supabase backend before Vercel publishing.
The Vercel token is also scoped to the separate pre-backend target-verification
step; it is never passed to Supabase deployment or backend health.
It installs the CLI in a credential-free, non-root-runtime Node container, records
the resolved version/image, and verifies both targets before mutation. Supabase
preflight requires a matching project ref/URL and authenticated `ACTIVE_HEALTHY`
project. The account token is exposed only to that preflight/deploy step, never to
installation, builds, health checks, or artifacts. Use scoped access with
`projects_read` and `edge_functions_write`, plus any read/branch permissions the
current CLI requires; do not use a service-role key as the account token.

Functions `api`, `stripe-webhook`, then `worker` deploy sequentially from the same
trusted SHA using `--remote=<ref> --use-api --yes` and the checked-in config. The
container copies only function source/config into a temporary writable workspace;
it mounts neither the Docker socket nor backend `.env` files. Anonymous backend
health must pass before frontend publication. Current-master checks apply before
backend mutation and again before frontend publishing. No migrations, migration
history repair, user provisioning, secrets upload, Stripe activation, or worker
schedule is performed. Existing hosted secrets and completed manual schema/Auth
setup remain prerequisites. Reconcile manually applied migration history before
any separately approved future `db push`.

Backend deployment is not atomic across functions or with Vercel. If deployment,
health, or a later frontend step fails, some new backend code may already be live.
The job summary records successful functions and warns on partial releases.
Inspect both platforms before retrying; keep backend changes compatible with the
previous frontend/schema. No automatic rollback runs. Explicitly authorized
recovery may redeploy reviewed known-good function source without reverting data.
Rotate the Supabase account token independently through platform settings.

The workflow captures the unique project deployment URL/ID, then checks that URL and the exact production URL for HTTPS root, extensionless reload, JS content type/configuration, expected security/no-store headers, healthy backend JSON including database connectivity, and configured browser startup. HTTP checks retry with bounds; smoke checks do not log in or perform financial writes. The optional protection-bypass secret is supplied only to smoke steps, scoped to the unique Vercel origin, never to the backend or canonical production origin. Do not disable Deployment Protection to pass CI. Summaries retain revision, artifact ID/digest, deployment links/ID, and check results. These checks do not replace section 10 of the runbook: owner/MFA denial, SMTP recovery, synthetic financial flows, and backup readiness remain separate launch gates. No new test or hosted acceptance result is asserted here.

### DNS And External Gates

1. The owner approves and creates separate Supabase/Vercel resources, selects regions/terms and confirms quotas, secrets, SMTP and recovery. Repository completion does not create them.
2. Add **only `budgeting.benknight.dev`** to the intended Vercel project. At the authoritative DNS zone for `benknight.dev`, create/update the **`budgeting` CNAME** to the **exact target Vercel displays for that project/domain**. No target has been allocated or verified in this repository; do not assume a generic CNAME value. Add only the exact domain-verification TXT record if Vercel requests it. Resolve conflicting records for this subdomain deliberately, never the apex, `www`, portfolio records, nameservers or unrelated mail records.
3. Wait for authoritative DNS verification and Vercel-issued TLS, then verify HTTPS, actual response headers and recovery redirects at `https://budgeting.benknight.dev`. Match this exact origin in Auth/CORS. DNS/TLS and hosted edge behavior are external gates, not local-test results.
4. Run owner/MFA denial, SMTP/reset, backup/restore and CSV-only smoke checks with synthetic data before importing real finances. Deploy CSV-only while Stripe remains disabled.
5. The owner chose live-first Financial Connections and reports balances/transactions approval and an empty financial database. Repository approval does not authorize hosted activation or paid calls. Follow Production Setup section 13: verify matching live keys, webhook, minute worker and recovery first, accept one checking/savings account before expanding. Account coverage and live operation remain unverified until that acceptance.

### Rollback

First unset `BUDGETING_DEPLOY_ENABLED` (or set it to `false`) to prevent future release jobs; this does not cancel an already-running publish or undo a live deployment. A post-publish smoke failure fails CI but can leave the new release live: inspect Vercel before retrying. With explicit owner authorization, use the dedicated project's Vercel dashboard rollback/promotion control to select a verified retained known-good deployment, then repeat unique/production smoke and launch-relevant checks. Record the resulting deployment and revision. Do not rerun stale CI to roll back; it is deliberately rejected. An archived artifact may be redeployed only through separately authorized, reviewed tooling after checksum/source verification; rebuilding old source is not the same artifact. Artifacts expire after 30 days, so retain required recovery evidence securely before expiry.

Rotate/revoke a compromised Vercel token in Vercel and replace only the environment secret; rotate the optional bypass separately and never log either value. Re-enable releases only after cause and checks are reviewed. Do not overwrite financial data, change DNS, or weaken RLS/MFA/TLS during frontend rollback. Pause linking/refresh and schedules as appropriate, but explicitly stop recurring subscriptions/disconnect when abandoning syncing. Use forward corrective SQL migrations; database restore is a separately controlled recovery event, never an automatic frontend rollback.

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
- Explicitly confirmed paid balance refreshes have no app cooldown and allow 50 reserved attempts per UTC month across the app, with conservative accounting for uncertain failures and deleted accounts. Reporting months are Denver time; the cap month is UTC. Provider availability can impose delays; the usage timestamp reflects monthly-cap eligibility only and is not a promise Stripe will accept a request.
- Published Stripe pricing checked November 10, 2026 was $0.30 per institution/account holder/month for transactions and $0.10 per successful balance call, **not an all-in quote or billing guarantee**. Owner accepts daily paid transaction subscriptions and separate explicit balance refresh charges. Recheck current terms/prices, other fees and tax before enabling. The 50-attempt UTC-month cap cannot limit subscriptions, external dashboard/API activity or charges outside this app; linking never prefetches paid balances. History availability is institution-dependent, up to 180 days.
- Each specific Wells Fargo account/card, Citi account/card and Mountain America account/card is **unverified until live testing**. An institution appearing in Stripe marketing does not establish transaction/balance coverage, personal-use eligibility, history depth or ongoing consent availability.
- Supabase Free has historically advertised 500 MB database storage and 500,000 Edge Function invocations, possible pausing after a week of inactivity, and no automatic database backups. Recheck current quotas/pricing; one-minute workers consume invocations even without new data. Free-tier pausing and quotas can interrupt sync/recovery; no uptime guarantee is implied.
- Vercel, SMTP, storage/egress and backup custody may have separate quotas/costs. Monitor platform usage and sanitized sync errors. Do not rely on a free tier as a recovery strategy.

## Contributing

Keep changes inside this standalone package unless specifically approved; preserve portfolio code and deployment behavior. Use synthetic fixtures, container-only dependency installation and meaningful assertions. Update API schemas, migrations, configuration contracts, tests and this documentation together when behavior changes. Keep production secrets and financial records out of logs, screenshots, CI artifacts, public build inputs and Git.

Run validation plus the relevant database/browser/local-stack/recovery checks, retain exact commands/results and inspect the artifact before review. A failing coverage gate, incomplete integration run or blocked external check must be reported plainly, not labeled production-ready. Do not perform hosted migrations, deploy, modify DNS, enable live Stripe or incur costs as part of ordinary contribution validation.
