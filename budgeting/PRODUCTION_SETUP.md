# Budgeting Production Runbook

This runbook takes the private budgeting app from validated local code to
`https://budgeting.benknight.dev`. Launch CSV imports and manual snapshots first.
Stripe Financial Connections is a separate, owner-operated opt-in described in section 13.

Writing this guide does not perform or authorize hosted changes. Project creation,
remote SQL, deployments, DNS edits, subscriptions, and live bank access require
the owner's approval and appropriate platform access. Do not enter credentials,
bank records, recovery links, or TOTP seeds in chat or Git.

## 1. Current Status And Launch Gates

Historical baseline as of 2026-11-06 (not a current hosted-state assertion):

| Item | Evidence / remaining work |
| --- | --- |
| Portfolio isolation | Root analysis and release build pass locally; existing portfolio remains independently hosted on GitHub Pages |
| Budgeting validation | Full containerized validation passed; Flutter coverage 89.0%, backend production coverage 88.15% |
| Signed-in browser test | Passed twice against real isolated Supabase stacks, including password login, TOTP, dashboard, owned account write, logout, and storage checks |
| Browser recovery | Recovery-link navigation, password replacement, and post-recovery MFA still need end-to-end acceptance |
| Latest remote CI | Confirm both workflows on the revision containing the final browser-harness fixes; local success is not a GitHub result |
| Supabase / Vercel / DNS | No hosted setup or production deployment established by repository tests |
| Recovery | Offline encrypted drill passes; hosted PostgreSQL-major compatibility and private backup custody remain unresolved |
| VS Code | Container setup resolves both packages; actual editor use inside the Dev Container remains unverified |
| Stripe | Defaults remain disabled; owner chose live-first on November 10 and reports balances/transactions approval; live acceptance is still unverified |

The browser-harness fixes and documentation must be included in the revision
you intend to launch. The original portfolio widget suite also has known failures
outside the Pages workflow; do not represent those tests as passing.

**Stop before real financial imports unless every mandatory item in section 11
is complete.** A configured frontend alone is not a secure production launch.

## 2. Gather Access And Decisions

Confirm owner-controlled access to GitHub, Supabase, Vercel, the authoritative
`benknight.dev` DNS zone, an SMTP provider, and private encrypted backup storage.
Enable platform-account MFA where available. Select project organizations,
regions, plans, quotas, and acceptable costs before creating resources.

Keep an operational inventory in private storage, not this public repository:

| Record | Why it is needed |
| --- | --- |
| Release commit and successful CI run URLs | Reproducible release evidence |
| Supabase project reference, region, PostgreSQL major | Deployment target and recovery compatibility |
| Confirmed owner Auth UUID | Immutable application owner provisioning |
| Vercel organization/project IDs and deployment URL | Correct frontend target and rollback |
| Exact Vercel DNS instructions | Avoid changing unrelated records |
| SMTP sender, limits, and operator contact | Password recovery delivery |
| Backup location, cadence, key custodian, last drill | Recoverability and acceptable data loss |

Install dependencies only inside Docker/devcontainers. Do not run host
`npm install`, `npx`, `flutter pub get`, or Supabase package installation.
Examples below run from the repository root and use placeholder paths/values.

Create private files outside the checkout with owner-only permissions. Use a
password manager or secure editor to populate them. Do not shell-source a
combined environment inventory or pass it wholesale to builds.

| Private file | Allowed contents |
| --- | --- |
| `supabase-admin.env` | `SUPABASE_ACCESS_TOKEN` for approved containerized administration |
| `edge-secrets.env` | Application Edge secrets listed in section 5, not reserved Supabase names |
| Deployment credentials | Prefer GitHub's protected `budgeting-production` environment in section 8; never include its token in build/backend environment files |
| `source.env` | Recovery `DATABASE_URL` only, plus explicitly documented recovery settings if required |
| `age-recipients.txt` | Public native age recipient lines |
| `age-identity.txt` | Private native age identity, held separately from backups and deployment secrets |

Protect Docker access: trusted Docker administrators can inspect injected
environment values. Do not use shared/untrusted runners for secrets.

## 3. Verify The Release Revision

Commit/push the intended local fixes through your normal review process, then
open the repository Actions tab:

- `Deploy to GitHub Pages` must pass. Its build/deploy path serves the portfolio,
  not budgeting. Preserve its successful-build prerequisite.
- `Budgeting Validation and Release` must pass its validation job, including `Real isolated Supabase integration` and both independent 70% coverage gates.
  Do not skip this step merely because a prior local test passed.
- Record the actual commit SHA and run URLs. A green older commit is insufficient.

The core local commands are:

```sh
sh budgeting/scripts/validate.sh
BUILD_CA_FILE=/absolute/path/to/public-ca.crt \
  sh budgeting/scripts/build-local-browser.sh
BUDGETING_BROWSER_INTEGRATION=true \
  BUDGETING_BROWSER_ARTIFACT="$PWD/budgeting/build/local-browser" \
  sh budgeting/supabase/tests/run-local.sh
```

Omit `BUILD_CA_FILE` on standard-trust networks; supply `BUDGETING_CA_CERT` to the
local stack when its separate container needs corporate trust. Never disable TLS
verification. The stack publishes development ports on all interfaces: run only
on an isolated CI/test machine or an isolated nested Docker daemon with no host
port publishing. The local-browser artifact must never be deployed.

## 4. Provision Supabase

### Create And Secure The Project

Create a dedicated budgeting project. Do not reuse a database containing unrelated
applications. Store the database password privately; obtain the actual project
URL and browser publishable key from that project.

In trusted SQL administration, record:

```sql
show server_version;
show server_version_num;
```

In hosted Auth settings, disable public signup and enable TOTP enrollment and
verification. Checked-in `config.toml` is not proof that hosted Auth settings were
applied. Expose only the `public` API schema, never `private`.

Set Auth configuration to:

| Setting | Value |
| --- | --- |
| Site URL | `https://budgeting.benknight.dev` |
| Recovery redirect allowlist | `https://budgeting.benknight.dev/` |
| Public signup | Disabled |
| TOTP enrollment / verification | Enabled |

Avoid wildcard redirects. Add any isolated preview/test origin deliberately to
both Auth redirects and backend CORS, then remove it when no longer needed.
This app uses the approved email/password plus TOTP exception; it has no OIDC
callback route to configure.

### Apply The Schema

Through the Supabase SQL editor or reviewed migration tooling, apply the complete
files in this order:

1. `budgeting/supabase/migrations/202611040001_budgeting.sql`
2. `budgeting/supabase/migrations/202611050001_usage_and_worker_hardening.sql`
3. `budgeting/supabase/migrations/202611100001_stripe_linking_lifecycle.sql` for the reviewed live-linking release, before updated functions/frontend

For an existing two-migration deployment apply only the new forward migration,
after backup/review; do not rerun the first two files. Preserve old-frontend
compatibility and disable new linking during the upgrade. Never substitute a
test bootstrap or let release CI apply/repair migrations.

Review the selected project before executing. Record success and migration
history privately. Never apply `tests/bootstrap.sql` to managed Supabase. Do not
rerun migrations blindly after partial failures; inspect state and use reviewed
forward corrections rather than deleting history or financial tables.

Applying SQL through the dashboard does not register those files in the Supabase
CLI migration ledger. Record the application method. Before later switching to
`db push`, have trusted administration reconcile the CLI ledger against the
verified schema using supported migration-history tooling. A private deployment
note is not a substitute for CLI history, and blindly pushing can reapply DDL.

### Provision The Owner

Create the confirmed owner via trusted Supabase Auth administration, using a
strong unique password. Confirm the email and record the actual Auth user UUID.
After migrations, run:

```sql
insert into private.app_owner (owner_id)
values ('REPLACE-WITH-CONFIRMED-AUTH-USER-UUID'::uuid);
```

This initializes the profile and categories. The singleton mapping is not
first-user-wins and intentionally refuses a second owner. Do not change it to
work around login issues. Never grant clients write access to `private`.

## 5. Configure Email And Edge Functions

### Recovery Email

Configure custom SMTP in Supabase Auth using a verified sender and credentials
held by the platform. Follow the mail provider's exact domain-verification
instructions; do not overwrite existing SPF/MX/DKIM records indiscriminately.
Check sender authorization, delivery limits, reset-email templates, and token
expiry. Do not change mail records as part of the Vercel subdomain change.

Local Mailpit success is not production delivery evidence. Complete section 10's
recovery exercise before real imports, including a test from a separate browser.

### Backend Values

Populate `edge-secrets.env` with application values only:

```dotenv
ALLOWED_ORIGINS=https://budgeting.benknight.dev
STRIPE_ENABLED=false
STRIPE_MODE=test
STRIPE_LIVE_AUTHORIZED=false
WORKER_SECRET=REPLACE_WITH_AN_INDEPENDENT_HIGH_ENTROPY_SECRET
```

Generate the worker secret using trusted secure tooling. Do not configure Stripe
keys, live webhooks, or schedules for CSV launch. Hosted Supabase injects reserved
`SUPABASE_URL`, `SUPABASE_ANON_KEY`, and `SUPABASE_SERVICE_ROLE_KEY` values; do not
upload replacements from `.env.example`. Service-role credentials must never
enter Flutter builds or Vercel static assets.

One containerized administration pattern is below. Replace `PROJECT_REF` with
the verified project reference. These commands mutate the remote project; run
only after authorization. They install the CLI only inside a disposable container.

```sh
docker run --rm \
  --env-file /absolute/private/supabase-admin.env \
  -v /absolute/private/edge-secrets.env:/run/edge-secrets.env:ro \
  -v "$PWD/budgeting:/workspace" -w /workspace \
  node:latest sh -ec \
  'npx --yes supabase secrets set --project-ref PROJECT_REF --env-file /run/edge-secrets.env'

docker run --rm \
  --env-file /absolute/private/supabase-admin.env \
  -v "$PWD/budgeting:/workspace" -w /workspace \
  node:latest sh -ec \
  'npx --yes supabase functions deploy api --project-ref PROJECT_REF &&
   npx --yes supabase functions deploy stripe-webhook --project-ref PROJECT_REF &&
   npx --yes supabase functions deploy worker --project-ref PROJECT_REF'
```

Deploy from `budgeting` so the checked-in function settings are loaded. Gateway
JWT verification is intentionally disabled in those settings: `api` verifies the
session/owner/MFA, `stripe-webhook` verifies signatures, and `worker` verifies its
independent bearer secret. Do not replace these checks with UI-only restrictions.
If CLI configuration semantics change, inspect its help and the deployed settings
before proceeding rather than assuming success.

## 6. Establish Recoverability Before Real Data

**Mandatory stop condition:** the recovery image uses `postgres:latest`, while
the scripts require the client, source database, archive, and restore target to
have matching PostgreSQL majors. Supabase may run a different major. Merely
rebuilding the current image does not resolve this.

Compare section 4's server major with:

```sh
docker build --pull -t budgeting-recovery:latest budgeting/recovery
docker run --rm --entrypoint pg_dump budgeting-recovery:latest --version
```

If they differ, stop and arrange reviewed version-compatible recovery tooling.
Do not bypass the major guard, weaken TLS, or assume PostgreSQL 18 dumps restore
to a 15/17 target. This repository does not yet supply that compatibility fix.
Both backup/restore wrappers rebuild the recovery image with `--pull`; simply
retagging a compatible image locally will not fix their execution path.
Choose any alternative platform backup mechanism only after verifying its scope,
retention, restore capability, and costs; do not treat plan marketing as a drill.

Once compatible tooling is established:

1. Choose a private encrypted backup destination and cadence based on acceptable
   data loss, including backups before migrations and large imports.
2. Keep age identities separately in secure custody with a second recoverable
   copy. Restrict both identity and backup file access.
3. Put the source URL in private `source.env` with explicit
   `sslmode=verify-full`, correct host, and URL-encoded credentials. Use a direct
   or supported session connection appropriate for dump/restore, not an assumed
   transaction-pool endpoint. Confirm reachability from Docker.
4. Rehearse with synthetic application records in a compatible isolated target.
   Preserve required Supabase roles, Auth helpers, and matching owner UUIDs without
   copying production passwords or MFA seeds into a test environment.

Existing command interfaces are:

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
```

The output path must not exist. Optional public database CA arguments and required
URL options are documented in the README. Never use the synthetic-local TLS
exception for a remote database.

Restore replaces **all** `public` and `private` objects on the confirmed disposable
target. Do not point it at production or a shared project. Validate correct-key
restore, corruption/wrong-key rejection, row counts and aggregates, owner/MFA RLS,
and provider replay quarantine. Keep Stripe/workers disabled. Record the drill
result without financial contents.

These application-schema backups do not recreate Auth users/passwords/MFA,
platform secrets, SMTP, external schedules, or Supabase migration history.
Maintain separate secure platform configuration and identity-recovery procedures.
JSON export is useful portability, not a complete recovery backup.

## 7. Build A Production-Configured Artifact

Create a separate Vercel project for budgeting only after owner authorization.
Record its account/team ID, project ID, and exact project name securely. Disable
automatic Vercel Git deployments for this dedicated project using its supported
project-level control; do not disconnect a shared integration or change the
portfolio project. Clear the dedicated project's Vercel **Root Directory** setting
(leave it empty, rather than `budgeting`) for this artifact-only CLI pipeline.
GitHub builds from `budgeting`, but the deploy container receives only the release
artifact as its root; a remote `budgeting` root would reference a nonexistent
subdirectory. Target verification rejects a nonempty root before publishing.
The current no-op source-build settings are prebuilt-only,
not an automatic source-build pipeline.

Build only with browser-safe values:

```sh
SUPABASE_URL="${SUPABASE_URL:?Set the verified hosted project URL}" \
SUPABASE_PUBLISHABLE_KEY="${SUPABASE_PUBLISHABLE_KEY:?Set its browser publishable key}" \
STRIPE_ENABLED=false \
STRIPE_PUBLISHABLE_KEY= \
sh budgeting/scripts/build.sh
```

Add `BUILD_CA_FILE=/absolute/path/to/public-ca.crt` if the build requires approved
corporate trust. These public values are embedded in JavaScript and are not
secrets. Never substitute a service-role or secret key. Backend configuration must
not be supplied as Docker build arguments or loaded into this shell invocation.

Set these public shell values from the intended Supabase project first.
`build.sh` runs containerized `release.ts preflight`: the URL must be HTTPS with
a 20-character lowercase alphanumeric hosted project reference under
`supabase.co`, no credentials/port/query/fragment, and only the root path. The key
must use `sb_publishable_` plus at least 20 letters, digits, underscores, or
hyphens, without placeholder markers. Legacy JWT anon keys are not accepted by
this release path, even though application compatibility remains. Shape checks
cannot prove project/key ownership: confirm the pair in Supabase settings.
Stripe defaults to `false` with an empty publishable key. Approved live opt-in
requires exact `STRIPE_ENABLED=true` and `pk_live_` followed by at least 20
alphanumeric characters, with no placeholder markers. Secret/restricted keys,
test keys, whitespace and malformed values are rejected with redacted errors.
The bundled YAML permits the capability, but cannot enable it without the build
flag/key and independent backend gates. See section 13 before live activation.
Empty/unconfigured
builds are intentionally supported by `validate.sh` only, not `build.sh`.

The script replaces `budgeting/build/web`, audits the static artifact, and packages
`budgeting/.vercel/output`. Verify that output is for the intended project and
does not display the safe unconfigured screen. Do not deploy
`build/local-browser`, which embeds disposable localhost configuration.

Run `sh budgeting/scripts/test-release-browser.sh` after a configured local build
with the same `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY`, `STRIPE_ENABLED`, and
`STRIPE_PUBLISHABLE_KEY` exported (and
`BUILD_CA_FILE` if needed) to exercise startup and packaged assets without hosted
login or financial writes. Values assigned only before the build command are not
automatically retained for a subsequent smoke command.
The pipeline repeats this before retaining its exact artifact. An artifact audit
is useful defense, not a substitute for keeping privileged credentials out of
the build. These instructions do not claim the commands or hosted checks ran.

## 8. Deploy Vercel And Configure The Subdomain

### Configure GitHub Without Activating

Leave `BUDGETING_DEPLOY_ENABLED` unset until explicit first-publish authorization.
Any value other than exact `true` leaves releases disabled while validation runs.
Configure the following through GitHub settings, never tracked files or chat:

| Location | Setting | Value / purpose |
| --- | --- | --- |
| Repository variable | `BUDGETING_DEPLOY_ENABLED` | Unset initially; exact `true` enables release jobs |
| Repository variable | `SUPABASE_URL` | Verified production-shaped hosted project origin from section 7 |
| Repository variable | `SUPABASE_PUBLISHABLE_KEY` | Matching browser-safe publishable key |
| Repository variable | `STRIPE_ENABLED` | Unset defaults false; exact `true` opts in only after section 13 readiness |
| Repository variable | `STRIPE_PUBLISHABLE_KEY` | Empty when disabled; matching live public `pk_live_...` key when enabled |
| `budgeting-production` environment variable | `SUPABASE_PROJECT_REF` | Exact hosted project ref matching repository `SUPABASE_URL` without trailing slash |
| Same environment secret | `SUPABASE_ACCESS_TOKEN` | Supabase account token with project-read and function-deploy access, not the publishable/service-role key |
| `budgeting-production` environment variable | `VERCEL_ORG_ID` | Verified account/team identifier |
| Same environment variable | `VERCEL_PROJECT_ID` | Existing dedicated budgeting project ID |
| Same environment variable | `VERCEL_PROJECT_NAME` | Exact existing project name, lowercase letters/digits/hyphens/underscores; not the hostname |
| Same environment variable | `BUDGETING_PRODUCTION_URL` | Exactly `https://budgeting.benknight.dev` |
| Same environment secret | `VERCEL_TOKEN` | Least-access practical deployment token |
| Same environment secret, optional | `VERCEL_AUTOMATION_BYPASS_SECRET` | Approved bypass for protected unique deployment smoke |

Restrict the `budgeting-production` environment to branch `master` only. Optional
required reviewers may add approval where supported; none is required by default.
Verify this branch restriction in platform settings: YAML alone does not enforce
it. Keep environment secrets away from PR validation and build jobs. Do not load
backend `.env` files or service-role keys into any frontend job. Install Flutter,
Deno/npm dependencies, browser tooling, and Vercel CLI only in containers.

### Activate And Release

Complete platform/DNS/TLS/backend readiness and get explicit owner authorization
before setting the enable variable to `true` and dispatching current `master` in
Actions. Plan approval, writing these docs, or successful local checks alone do
not authorize activation, pushing, or publishing.

Every push/merge to `master` is eligible, even documentation-only changes. Manual
runs must select current `master`; a re-run is eligible only while its original
SHA is still current. PRs including forks validate only. Other branches, tags,
previews, schedules, and daily image/dependency rebuilds cannot trigger a release.
Do not enable a duplicate Vercel Git/source deployment path.

The workflow requires successful validation and real isolated Supabase/browser
integration before `release-build`, which runs configured `build.sh` and local
`test-release-browser.sh`. Failed gates cannot publish. It checks current master
before building and again inside the serialized `deploy` job after queuing.
Stale runs fail: dispatch a new current-master run instead of retrying old code.
Production uses `cancel-in-progress: false`, independently of cancelable
validation. GitHub concurrency is not FIFO and can supersede pending jobs; do not
manually cancel an in-flight production publish as a routine release strategy.

### Evidence And Verification

The serialized production job now deploys backend functions before frontend
publication. After artifact verification, credential-free container installation
records the Supabase CLI version/image. Vercel target identity is checked first;
Supabase preflight then verifies the ref matches `SUPABASE_URL`, account-token
access, returned project identity, and `ACTIVE_HEALTHY` status. Scope account
tokens to this project/access where supported: project metadata read and Edge
Function write access are required; additional function/branch read permissions
may be required by the current CLI. Never enter token values in chat or logs.

The job deploys `api`, `stripe-webhook`, and `worker` sequentially from the trusted
release SHA using `--remote=<ref> --use-api --yes`. Only source/config is copied
into its non-root temporary container workspace; no Docker socket or `.env` file
is mounted. The account token is available only in the backend preflight/deploy
step. A separate token-free anonymous backend health check gates Vercel publishing.
Existing postpublication health/frontend checks remain. No migrations, ledger
repair, owner creation, Auth/secret changes, Stripe enablement, webhook setup, or
worker schedule is automated. Previously SQL-Editor-applied migrations must be
reconciled before any separately reviewed future automated database workflow.

Deployments across functions/frontend are not transactional. A failed function
deploy or readiness check stops frontend publishing, but some functions may be
updated already. Successful function steps and partial-release warnings appear in
the job summary. A stale revision may deploy its backend then be blocked before
frontend publication if master advances. Maintain old-frontend compatibility,
inspect both platforms before retrying, and dispatch current master after review.
Do not automatically roll back functions or database. With explicit authorization,
redeploy reviewed known-good function source for recovery; rotating an account
token is a separate platform operation. First remote execution of this new
automation remains an acceptance step, not a result established by this runbook.

The immutable `budgeting-release-<run-id>-<attempt>` artifact contains only
`.vercel/output` and a non-served `manifest.json`. Hidden output is explicitly
included; missing files fail upload. Retention is 30 days and access follows
repository permissions, so all contents must be browser-safe. Never substitute
the unconfigured validation artifact or `build/local-browser`. The manifest
records source SHA, run/attempt, build time, resolved tool versions and image
evidence as available, public configuration identity, plus per-file checksums.
`build.sh` emits only public values in static `release-config.json`; local and
hosted browser smoke compare that evidence and compiled key identity to intended
settings. Deploy verifies both static evidence and manifest against its current
public settings before backend changes. Changing repository variables between
jobs fails closed; dispatch a new current-master run, never patch the artifact.
Keep necessary nonsensitive
recovery evidence securely before artifacts expire.

Deploy uses a fresh checkout of the trusted SHA and downloads the exact same-run
artifact ID, then verifies expected SHA, checksums, and allowed artifact contents
read-only. It runs no artifact-supplied scripts and does not recompile. Before
publishing, `release.ts target` checks authenticated Vercel account/project/name;
it must not implicitly create or relink a project. The token is scoped only to
the publish step, never dependency installation or smoke. Publishing uses the
containerized CLI's `vercel deploy --prebuilt --prod` from the staged release.

The workflow records the unique project deployment URL and ID, then performs
bounded/retrying HTTPS checks at that URL and the exact production URL: root,
extensionless reload, expected security/no-store headers, JS content type and
public config, exact HTML/JavaScript checksums from the retained release, and
backend JSON `status: ok` with `database: connected`. Hosted
configured browser smoke runs at both URLs with `BUDGET_HOSTED_SMOKE=true` and
`BUDGET_BROWSER_URL` set by the workflow. These steps receive no Vercel deployment
token and perform no financial writes or owner login. If Deployment Protection
requires the approved optional automation bypass, store it only as the environment
secret; it is injected only into smoke steps and sent only to the unique Vercel
origin, not the production domain or backend. Never disable protection or log the
secret to get green CI.

Record the actual run's source revision, artifact ID/digest, deployment URL/ID,
production link, and check results from its summary. A smoke failure after publish
fails CI but may leave the release live: inspect Vercel state before retrying.
Configured startup/readiness is not the full synthetic acceptance in section 10;
no new execution or hosted acceptance result is established by this guide.

### Configure Only The Budgeting Subdomain

In Vercel's domain settings add **only `budgeting.benknight.dev`**. At the
authoritative DNS provider:

- Create/update the `budgeting` CNAME using the exact target Vercel supplies.
- Add only the exact verification TXT record if requested.
- Resolve a conflicting `budgeting` record deliberately before replacing it.
- Leave apex, `www`, portfolio, nameservers, and unrelated mail records unchanged.

Do not guess a generic Vercel target. Wait for authoritative verification and
Vercel TLS issuance. Do not disable HTTPS verification to get a green check.

## 9. Check Hosted Routing And Operational Endpoints

Set public shell variables for read-only checks:

```sh
APP_URL=https://budgeting.benknight.dev
SUPABASE_URL="${SUPABASE_URL:?Set the verified hosted project URL from section 7}"

curl --fail --show-error --silent -I "$APP_URL/"
curl --fail --show-error --silent -I "$APP_URL/launch-check"
curl --fail --show-error --silent \
  "$SUPABASE_URL/functions/v1/api/health"
```

The frontend root and extensionless fallback must load through valid HTTPS. Open
`/launch-check` in a browser and reload it: the SPA should boot rather than return
a Vercel 404. This is a fallback test, not a promise of a named app route. Confirm
real JS/assets have the correct content type rather than returning `index.html`.

Inspect actual responses for `Cache-Control: no-store`, `X-Content-Type-Options:
nosniff`, `X-Frame-Options: DENY`, `Referrer-Policy: no-referrer`, noindex directives,
Permissions Policy, and the configured CSP. Use
`budgeting/.vercel/output/config.json` as the generated routing/header contract.
Check browser console errors, CanvasKit/WASM/worker loading, and TOTP rendering.

Edge `/health` must report healthy database connectivity; static frontend health
alone cannot prove it. Also verify unauthenticated access to:

- `$SUPABASE_URL/functions/v1/api/metrics`
- `$SUPABASE_URL/functions/v1/api/docs`
- `$SUPABASE_URL/functions/v1/api/openapi.json`

Metrics must remain anonymized. Never put access tokens, email addresses, IPs, or
financial amounts into monitoring labels or public uptime-check URLs.

## 10. Perform Hosted Acceptance With Synthetic Data

Use an isolated browser profile and non-financial fixtures first. Never collect
full browser network traces, screenshots, or CI artifacts containing passwords,
tokens, TOTP seeds, recovery links, or real account data.

### Authentication And Denial Matrix

| Session / caller | Expected result |
| --- | --- |
| No session, with only public key | Financial Edge routes denied; direct PostgREST reveals no financial rows and permits no financial mutations |
| Correct owner, password only (`aal1`) | No financial access; MFA required |
| Correct owner, verified TOTP (`aal2`) | Intended financial access |
| Different administered synthetic user, including `aal2` | No financial rows or mutations; Edge financial routes denied |
| Expired or tampered session | Denied by Edge and PostgREST |
| Browser with disallowed origin | Function CORS/origin controls reject it; authorization remains required regardless of CORS |

Test both the Edge API and direct PostgREST, not just visible navigation. RLS can
return an empty result for unauthorized reads instead of HTTP 403; the criterion
is no disclosure and no successful mutation. Use only the public key plus the
specific test session. A service-role key bypasses RLS and invalidates this test.

Financial Edge paths include two route segments, for example:
`$SUPABASE_URL/functions/v1/api/api/v1/usage`. PostgREST uses
`$SUPABASE_URL/rest/v1/...`. Keep test bearer tokens in a protected session/tool;
do not paste them into command history or this guide. Create any wrong-user test
identity administratively and remove it/revoke its sessions after verification;
leave public signup disabled.

### Owner Workflow

1. Sign in and enroll TOTP. Securely retain the seed under the owner's recovery
   process. Verify the challenge is required before financial data appears.
2. Create synthetic cash and card accounts and dated balance snapshots. Check
   positive cash, card debt, missing/stale balances, and resulting net position.
3. Preview and import a small synthetic CSV with explicit date/sign mappings.
   Check duplicates, overlap handling, malformed rows, and import undo behavior.
4. Create/edit categories, annotate transfers/card payments, set a monthly budget,
   and verify spending/income totals and refunds against known fixture values.
5. Export JSON and verify contents privately. Treat the download as sensitive and
   do not upload it to public artifacts or source control.
6. After password and TOTP verification, reload and reopen the same browser:
   the remembered session should restore without another authenticator code.
   Verify expired access tokens refresh before financial requests and owner/AAL2
   validation still runs. Repeat with a second tab, then log out with a financial
   dialog open: dialogs, records, and remembered credentials must clear across
   tabs. Reload after logout must require sign-in again. Invalid/revoked refresh
   tokens and AAL1 sessions must never unlock financial data.
7. In browser storage tools, allow only project-scoped auth session and approved
   coordination entries. Financial responses, passwords, TOTP seeds/codes, and
   Stripe secrets must not be persisted; no app service worker is registered.
   Remembered refresh tokens are sensitive JavaScript-accessible credentials,
   not device-bound biometric credentials. Use trusted devices and sign out
   before sharing them. Hosted Supabase session expiry/revocation still applies;
   this release does not change hosted Auth timeout settings.
8. Repeat basic navigation and imports on narrow/mobile and desktop layouts.

### Password And MFA Recovery

1. From the signed-out production app, request a reset for the confirmed owner.
2. Confirm delivery through the configured SMTP sender, not Mailpit. Open the link
   in a separate browser and verify the destination is exactly the production
   origin root, without an open redirect.
3. Confirm recovery credentials are removed from the URL, choose a strong new
   password, and verify financial access still requires valid TOTP.
4. Verify the old password no longer works and the new password plus MFA does.
   Check single-use and expired recovery-link behavior without exposing tokens.
5. Rehearse the lost-authenticator procedure with trusted administration and
   independently verified owner identity. Password reset alone must not remove
   MFA. Revoke sessions when replacing a lost factor, preserve the same owner
   UUID, and challenge the replacement factor before financial access.

Remove synthetic financial records deliberately before starting the real ledger;
do not drop schemas or change the owner mapping. Keep useful nonsensitive test
evidence, then take the first usable encrypted backup.

## 11. Go / No-Go Checklist

- [ ] Final release commit includes reviewed browser-harness fixes; both GitHub workflows pass on that revision.
- [ ] Dedicated Supabase project, correct region/plan, and all reviewed forward migrations applied successfully.
- [ ] Public signup disabled; `private` not exposed; confirmed owner mapping and TOTP operational.
- [ ] Production Edge functions/secrets verified; frontend/backend Stripe disabled and no sync schedule.
- [ ] Anonymous Edge health reports connected database; anonymized metrics, Swagger UI, and OpenAPI schema are reachable without authentication.
- [ ] Anonymous, wrong-owner, non-MFA, expired, and tampered access denied through Edge and PostgREST.
- [ ] Real recovery email, redirect, new password, post-recovery MFA, and lost-factor procedure verified.
- [ ] Matching-major encrypted backup and isolated restoration rehearsed; private storage, cadence, and key custody established.
- [ ] Configured audited prebuilt artifact deployed to the correct separate Vercel project.
- [ ] Explicit release activation authorized; GitHub environment restricted to `master`, correct vars/secrets verified, duplicate Vercel Git deployments disabled, and actual release artifact/deployment evidence recorded.
- [ ] Only budgeting DNS records changed; HTTPS, headers, assets, direct reloads, and production origin verified.
- [ ] Synthetic CSV/snapshot/category/budget/export/logout workflows pass on mobile and desktop.
- [ ] Remembered MFA sessions survive reload/reopen, refresh safely, and clear across tabs on logout; only approved auth storage persists, never financial data or service workers; no sensitive diagnostics retained.
- [ ] VS Code works inside the Dev Container, and operational owner/rollback responsibilities are recorded.

After all boxes pass, begin with a small real CSV import, reconcile it against a
known statement, and back up before expanding the ledger. Do not label the site
production-ready while a mandatory gate is unresolved.

## 12. Operate And Roll Back

Monitor frontend availability, Edge health/database connectivity, sanitized errors,
SMTP delivery, platform quotas/pausing, and backup freshness. Choose alerting
appropriate to personal financial data; free-tier availability is not guaranteed.
Back up before schema changes or large imports and periodically repeat a restore
drill. Refresh container dependencies and rerun validation before releases.

For a bad frontend release, first unset `BUDGETING_DEPLOY_ENABLED` or set it to
`false` to prevent future release jobs. This does not cancel an already-running
publish or revert the currently live site. Inspect the actual Vercel state after
any publish/smoke failure before retrying.

With explicit owner authorization, use the dedicated project's Vercel dashboard
rollback/promotion control to select a verified retained known-good deployment.
Confirm its project, revision, and retained artifact evidence, then repeat unique
and production URL checks and relevant synthetic acceptance. Record the resulting
deployment ID/URL and recovery result. Do not rerun stale CI for rollback: stale
SHAs deliberately fail. Redeploying an archived artifact requires separately
authorized reviewed tooling and source/checksum verification; rebuilding old source
does not reproduce the exact artifact. The 30-day GitHub artifact lifetime is not
a guarantee of Vercel deployment retention or a complete backup strategy.

Rotate the Vercel token by issuing a least-access replacement through trusted
Vercel administration, replacing the GitHub environment secret securely, and
revoking the old token. For suspected compromise revoke promptly and investigate
exposure before re-enabling releases. Rotate the optional automation bypass
separately when needed. Never print tokens in commands/logs/artifacts. Re-enable
only after the cause and checks are reviewed.

Do not roll back DNS, disable RLS/MFA/TLS, or restore financial tables as an
automatic response to a frontend problem. Repair schema issues with reviewed
forward migrations; database restoration is a separate, explicitly controlled
incident procedure, never part of frontend rollback.

Keep a private recovery note for project access, encrypted backup/key locations,
Auth UUID, SMTP configuration, and administrative contacts. Do not put secrets in
this runbook. An account compromise requires session/key revocation and impact
assessment, not merely a static redeploy.

## 13. Owner-Operated Live Bank Activation

The owner explicitly chose live-first on November 10, 2026, reports live balances
and transactions approval, an empty financial database, and accepts the existing
paid sync policy. Sandbox-first is not a prerequisite for this approved rollout;
synthetic tests with mocked Stripe remain mandatory. Repository implementation
does not authorize hosted changes, bank credentials, deployments or paid feeds.
No live account coverage, webhook delivery, scheduling, data correctness or
charges are verified by repository/CI results.

### Activation Order

1. Complete owner/MFA denial, password/MFA recovery and matching-major encrypted
   backup/restore gates before real data. Apply the reviewed forward migration
   in section 4 manually, then publish compatible backend/frontend code with
   public and backend `STRIPE_ENABLED=false`. Code release must not start feeds.
2. In Supabase application secrets only, install matching live backend credentials:
   `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET`, `STRIPE_MODE=live`, and the
   independent `WORKER_SECRET`. Initially keep `STRIPE_ENABLED=false` and
   `STRIPE_LIVE_AUTHORIZED=false`. Prefer a restricted `rk_live_` key with only
   Customer create/retrieve and Financial Connections session/account retrieval,
   transactions, balance refresh, subscribe/unsubscribe and disconnect abilities
   actually used. Verify the current Stripe restricted-key permission names in
   its dashboard; never grant payments, payouts or Connect. `STRIPE_SECRET_KEY`
   remains the server setting name for restricted keys. Keys must belong to the
   same Stripe account as the eventual public `pk_live_` key; do not reuse test
   customer mappings. Do not put any backend key in GitHub variables/builds.
3. Register the live snapshot webhook and verify signatures/events as below.
   Create and verify the private minute worker schedule before first linking.
   Anonymous `/health` success is not proof of worker/webhook readiness.
4. Owner explicitly sets backend `STRIPE_LIVE_AUTHORIZED=true` and
   `STRIPE_ENABLED=true` in Supabase. Keep `STRIPE_MODE=live` and matching keys.
   Owner then sets repository variables `STRIPE_ENABLED=true` and
   `STRIPE_PUBLISHABLE_KEY` to the matching live public key and releases current
   `master` through the existing gates. `BUDGETING_DEPLOY_ENABLED` independently
   controls publishing, not Stripe authorization. Do not shadow these public
   repository variables with different production-environment values.
5. Perform the one-account checklist below before expanding. Save only sanitized
   release revision, public configuration evidence, delivery/run status and
   acceptance outcome privately, never financial exports/screenshots in Git/CI.

### Live Snapshot Webhook

Destination: `$SUPABASE_URL/functions/v1/stripe-webhook`. Select only:

- `financial_connections.account.refreshed_transactions`
- `financial_connections.account.refreshed_balance`
- `financial_connections.account.disconnected`
- `financial_connections.account.deactivated`
- `financial_connections.account.reactivated`

Use snapshot payloads containing `data.object` account identity, `livemode` and
event identity; no thin events, preview relink or unrelated payment events.
The backend verifies raw-body signatures with this destination's `whsec_` secret
before durable deduplicated enqueue. Do not rewrite request bodies in a proxy.
The runtime sends `Stripe-Version: 2024-06-20`, the stable snapshot contract
covered by synthetic fixtures. Configure the live snapshot destination to match
`2024-06-20` and record it privately. Verify the dashboard supports that version
and confirm actual account/refresh/transaction payload compatibility before
activation; if unavailable or incompatible, stop for a reviewed code/fixture
update. Synthetic compatibility is not evidence of successful live delivery.
Verify delivery status and sanitized worker results without copying real payloads
into chat, source or diagnostics. Keep signing-secret rotation owner-operated.

### Minute Worker Schedule

Owner-run Supabase template, not an automatically applied migration: enable
`pg_cron`, `pg_net` and Vault through trusted platform administration. Using
Vault's private dashboard, store `budgeting_worker_url` as the exact HTTPS
`$SUPABASE_URL/functions/v1/worker` URL and `budgeting_worker_secret` as the same
independent secret installed in the worker. Supply values only through private
secret storage, not literal SQL, cron definitions, URLs or source. Restrict Vault
decryption, cron metadata and network response tables to trusted administration;
never grant browser roles access. Confirm no duplicate job before scheduling.

```sql
select cron.schedule(
  'budgeting-worker-minute', '* * * * *',
  $job$
    select net.http_post(
      url := (select decrypted_secret from vault.decrypted_secrets
              where name = 'budgeting_worker_url'),
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer ' ||
          (select decrypted_secret from vault.decrypted_secrets
           where name = 'budgeting_worker_secret')),
      body := '{}'::jsonb,
      timeout_milliseconds := 60000
    );
  $job$
);

-- List schedule without selecting decrypted secrets or command contents.
select jobid, jobname, schedule, active from cron.job
where jobname = 'budgeting-worker-minute';
-- Cron success means HTTP enqueue only, not successful worker processing.
select r.jobid, r.status, r.start_time, r.end_time
from cron.job_run_details r join cron.job j using (jobid)
where j.jobname = 'budgeting-worker-minute'
order by r.start_time desc limit 10;
-- Check asynchronous HTTP status, never response bodies/financial content.
select id, status_code, timed_out, created from net._http_response
order by created desc limit 10;
```

For a private one-shot verification, execute the same `net.http_post` expression
in trusted SQL and retain its returned request ID. Match that ID in
`net._http_response`, require HTTP 200, then confirm sanitized worker logs/private
job progression. The response table also contains other requests; recent rows
alone do not prove this schedule succeeded. Verify at least two minute runs,
no auth failures, durable job lease/retry behavior and pending work advancing.
Bounded worker batches can leave more work for the next invocation. Account for
one-minute invocation quotas, platform pausing and monitoring. Never expose the
worker secret as a query string or use an owner JWT as the scheduler credential.
The 60-second HTTP timeout accommodates the worker's bounded processing window;
platform execution limits or slow provider calls can still interrupt a run, so
verify durable leases/retries rather than assuming cron enqueue means success.

After provider cleanup (below), owner can pause or remove the schedule:

```sql
select cron.alter_job(jobid, active := false) from cron.job
where jobname = 'budgeting-worker-minute';
-- Resume only after reviewing cause, credentials and outstanding jobs.
-- select cron.alter_job(jobid, active := true) from cron.job
-- where jobname = 'budgeting-worker-minute';
select cron.unschedule(jobid) from cron.job
where jobname = 'budgeting-worker-minute';
```

Pausing/removing does not cancel an already-running request. Verify job listing,
last-run/HTTP status and outstanding work afterward; do not automatically delete
Vault credentials until provider cleanup is verified.

### First Live Account Acceptance

1. Owner signs in with MFA and links only one supported checking/savings account.
   Confirm data-only balances/transactions permissions, no payments or money
   movement, no automatic paid balance prefetch. This is staged rollout, not a
   permanent one-account limit. Cancel/retry errors must not imply success.
2. See pending transaction subscription/initial sync, verify signed webhook
   delivery and durable worker ingestion. If completion is interrupted, use the
   owner-initiated retry-completion path rather than starting another bank link.
   If accepted subscription work exhausts retries, review the sanitized cause and
   explicitly confirm Retry transaction subscription to requeue the same durable
   subscription identity and ongoing cost, not a new link or balance purchase.
   Check sanitized partial/error/inactive states. History is institution-dependent,
   up to 180 days; unsupported accounts retain CSV/manual fallback.
3. Compare selected entries, dates, signs and USD amounts privately with the bank.
   Do not automatically merge CSV/manual accounts or overlapping history. Missing
   or unsupported balances must remain visible, never silently zero.
4. Explicitly confirm one paid manual balance refresh, verify timestamp/value and
   usage reservation. The server-authoritative cap is 50 attempts per UTC month
   across the app, including conservative uncertain attempts, with no app cooldown.
   Provider availability checks still apply. It is not a total Stripe bill cap.
5. Disconnect and verify provider unsubscribe/access cleanup, stopped feed and
   retained local history before linking additional accounts. Verify no late
   webhook/job reactivates a locally disconnected account. Do not infer exact
   Wells Fargo/Citi/Mountain America account support from institution marketing.

Published pricing checked November 10, 2026: transactions $0.30 per
institution/account holder/month, balances $0.10 per successful call; other
charges may apply. Owner accepts daily transaction subscriptions and separate
balance charges. Recheck current terms; this is not a billing guarantee.

### Charge-Stopping Rollback

Disable backend new activity with `STRIPE_ENABLED=false` and release public
`STRIPE_ENABLED=false` with empty `STRIPE_PUBLISHABLE_KEY` if hiding new linking
is needed. Neither setting stops existing Stripe subscriptions. Keep mode,
matching backend credentials, `STRIPE_LIVE_AUTHORIZED=true`, owner/MFA access and
worker availability for cleanup. Use authenticated disconnect, inspect pending
cleanup/retry state and Stripe subscription/access state, and verify feeds stopped
before pausing/removing the schedule or revoking keys. Escalate provider failures
through trusted Stripe administration; do not assume an inactive UI means charges
stopped. Preserve local history, retry records and backups. Hiding the frontend,
pausing workers or Vercel rollback alone cannot stop paid feeds. Do not delete
financial tables, reset migration history or replay uncertain paid refreshes.

See README Worker Operations, Backup And Recovery, and Limits And Costs for
recovery constraints. Actual hosted acceptance remains owner-operated and
unverified until these checks are completed and recorded.
