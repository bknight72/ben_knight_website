# CSV Production Launch Runbook

This runbook takes the private budgeting app from validated local code to
`https://budgeting.benknight.dev`. Launch CSV imports and manual snapshots first.
Stripe Financial Connections is a separate, optional milestone.

Writing this guide does not perform or authorize hosted changes. Project creation,
remote SQL, deployments, DNS edits, subscriptions, and live bank access require
the owner's approval and appropriate platform access. Do not enter credentials,
bank records, recovery links, or TOTP seeds in chat or Git.

## 1. Current Status And Launch Gates

As of 2026-11-06:

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
| Stripe | Keep disabled throughout CSV launch |

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
| `vercel.env` | `VERCEL_TOKEN`, `VERCEL_ORG_ID`, `VERCEL_PROJECT_ID` only |
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
- `Budgeting Validation` must pass, including `Real isolated Supabase integration`.
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

Create a separate Vercel project for budgeting. Record its organization and
project IDs in private `vercel.env`. Do not connect the current no-op source-build
settings as an automatic deployment pipeline. Do not change the portfolio project.

Build only with browser-safe values:

```sh
SUPABASE_URL=https://YOUR_PROJECT.supabase.co \
SUPABASE_PUBLISHABLE_KEY=YOUR_BROWSER_SAFE_PUBLISHABLE_KEY \
STRIPE_ENABLED=false \
STRIPE_PUBLISHABLE_KEY= \
sh budgeting/scripts/build.sh
```

Add `BUILD_CA_FILE=/absolute/path/to/public-ca.crt` if the build requires approved
corporate trust. These public values are embedded in JavaScript and are not
secrets. Never substitute a service-role or secret key. Backend configuration must
not be supplied as Docker build arguments or loaded into this shell invocation.

The script replaces `budgeting/build/web`, audits the static artifact, and packages
`budgeting/.vercel/output`. Verify that output is for the intended project and
does not display the safe unconfigured screen. Do not deploy
`build/local-browser`, which embeds disposable localhost configuration.

Archive the exact configured prebuilt artifact privately with the source revision
and build date so it can be redeployed. The artifact audit is useful defense, not
a substitute for keeping privileged credentials out of the build.

## 8. Deploy Vercel And Configure The Subdomain

With explicit production authorization and the verified project IDs:

```sh
docker run --rm \
  --env-file /absolute/private/vercel.env \
  -v "$PWD/budgeting:/workspace" -w /workspace \
  node:latest sh -ec \
  'npx --yes vercel deploy --prebuilt --prod --token "$VERCEL_TOKEN"'
```

Record the deployment URL and confirm it belongs to the dedicated project. An
isolated preview can omit `--prod`, but real Auth/API behavior needs its exact
origin in Auth/CORS; never solve preview problems with wildcard production access.

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
SUPABASE_URL=https://YOUR_PROJECT.supabase.co

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
6. Log out with a financial dialog open and verify dialogs and records clear.
   Reload and open a new browser session: sign-in must be required again.
7. In browser storage tools, verify no auth tokens/financial responses remain in
   localStorage or persistent caches and no app service worker is registered.
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
- [ ] Dedicated Supabase project, correct region/plan, and both migrations applied successfully.
- [ ] Public signup disabled; `private` not exposed; confirmed owner mapping and TOTP operational.
- [ ] Production Edge functions/secrets verified; frontend/backend Stripe disabled and no sync schedule.
- [ ] Anonymous Edge health reports connected database; anonymized metrics, Swagger UI, and OpenAPI schema are reachable without authentication.
- [ ] Anonymous, wrong-owner, non-MFA, expired, and tampered access denied through Edge and PostgREST.
- [ ] Real recovery email, redirect, new password, post-recovery MFA, and lost-factor procedure verified.
- [ ] Matching-major encrypted backup and isolated restoration rehearsed; private storage, cadence, and key custody established.
- [ ] Configured audited prebuilt artifact deployed to the correct separate Vercel project.
- [ ] Only budgeting DNS records changed; HTTPS, headers, assets, direct reloads, and production origin verified.
- [ ] Synthetic CSV/snapshot/category/budget/export/logout workflows pass on mobile and desktop.
- [ ] No persistent financial/auth browser storage or service worker; no sensitive diagnostics retained.
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

For a bad frontend release, redeploy the retained known-good configured prebuilt
artifact to the same Vercel project. Do not roll back DNS, disable RLS/MFA, or
restore financial tables as an automatic response to a frontend problem. Repair
schema issues with reviewed forward migrations; production data restoration is
a separate, explicitly controlled incident procedure.

Keep a private recovery note for project access, encrypted backup/key locations,
Auth UUID, SMTP configuration, and administrative contacts. Do not put secrets in
this runbook. An account compromise requires session/key revocation and impact
assessment, not merely a static redeploy.

## 13. Optional Bank Connections Later

CSV production readiness does not authorize Stripe enablement. Before automatic
bank data:

1. Obtain Financial Connections production eligibility/approval and accept current
   pricing explicitly. Verify each specific Wells Fargo, Citi, and Mountain
   America account/card supports the needed transaction/balance features.
2. Use isolated Stripe test configuration first. Configure backend secret keys,
   matching public key, raw-body signed webhooks, and a private secret-authenticated
   minute scheduler. Test retries, deduplication, leases, cost/cooldown limits,
   disconnect/delete cleanup, and environment boundaries.
3. Confirm backup/MFA recovery and the consequences of restoring provider state.
   Check that disabling the app does not leave recurring subscriptions active.
4. Obtain explicit live authorization before setting live keys, mode, and live
   authorization flags. Connect one account at a time and verify history,
   balances, overlap handling, and charges.

See the README's Worker Operations, Backup And Recovery, and Limits And Costs
sections for detailed constraints. Never infer exact-account support from an
institution name in provider marketing.
