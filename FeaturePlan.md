# Budgeting Launch Plan

Status: user approved repository CI/integration remediation and containerized local
validation on 2026-11-06. Hosted actions and live Stripe remain unapproved.

## Scope And Architecture

Launch the existing CSV-backed Flutter app on a dedicated Vercel project with a
dedicated Supabase PostgreSQL/Auth/Edge backend. Preserve the portfolio's GitHub
Pages deployment and all apex/www DNS records. Keep Stripe disabled in both the
frontend and backend. Automatic bank connections are a separately authorized
second milestone, not a prerequisite for CSV use.

All dependency installation and build/test tooling must remain containerized.
Do not commit credentials, financial data, backups, or generated artifacts.

## Verified Baseline

Checked on 2026-11-06 against commit
`229e5521f1899847c4685375fd4a166340401960`; the initial working tree was clean.

- GitHub Pages run 42156567756 failed at `Analyze`; web build, artifact upload,
  and deployment were skipped.
- Budgeting Validation run 42156567708 passed containerized validation/coverage
  and packaging, then failed `Real isolated Supabase integration`.
- Public GitHub API job metadata and annotations establish the failing steps,
  but do not establish their detailed root causes. Annotations show exit code 1.
- `https://benknight.dev` returned HTTP 200 over HTTPS, with a Last-Modified date
  of 2026-09-24. The previous portfolio remains served.
- Docker responded with server version 29.5.3. This is not proof that container
  builds, corporate trust, or host networking work.
- Host `gh`, `supabase`, and `vercel` CLIs are unavailable. Do not install host
  dependencies to work around this; use authenticated container tooling if needed.

Evidence:

- https://github.com/bknight72/ben_knight_website/actions/runs/42156567756
- https://github.com/bknight72/ben_knight_website/actions/runs/42156567708

## Milestone 1: CSV Launch

1. Obtain full failed-job logs through approved authenticated GitHub access or
   reproduce the failures in containers. Isolate root portfolio analysis from
   the independently validated nested package if confirmed as the cause. Preserve
   the successful-build prerequisite for Pages deployment; never publish a failed
   or partial artifact. Rerun portfolio and budgeting checks against the fixes.
2. On an isolated test environment, rerun the signed-in Chromium/Supabase phase
   using `build-local-browser.sh` and `supabase/tests/run-local.sh`. The harness
   exposes local Supabase ports on all interfaces; confirm network isolation
   before execution. Do not remove existing containers without checking ownership.
3. With explicit hosted authorization, create the dedicated Supabase project and
   select region/plan. Apply `202611040001_budgeting.sql`, followed by
   `202611050001_usage_and_worker_hardening.sql`. Never apply test bootstrap SQL
   remotely. Disable signup, enable TOTP, administratively create the confirmed
   owner and insert the actual Auth UUID into `private.app_owner`.
4. Configure exact production origin/recovery redirects and verified SMTP. Deploy
   `api`, `stripe-webhook`, and `worker` with their checked-in settings. Inject
   backend-only secrets through platform facilities. Set `STRIPE_ENABLED=false`,
   `STRIPE_MODE=test`, and `STRIPE_LIVE_AUTHORIZED=false`; do not schedule Stripe
   work or supply live bank credentials.
5. Confirm the hosted PostgreSQL major. Review a compatible recovery-tooling
   approach before changing it: keep major-version matching, TLS hostname
   validation, encrypted streaming, and destructive-restore safeguards. Do not
   bypass guards or pin an image tag contrary to project standards. Rehearse
   synthetic restoration in an isolated compatible target before real imports.
6. Build with only public Supabase configuration and Stripe disabled; audit and
   package `.vercel/output`. Create a separate Vercel project and use the documented
   containerized prebuilt deployment, not the no-op source-build configuration.
   Preserve a known-good artifact for rollback.
7. Add only `budgeting.benknight.dev` to Vercel. Use the exact CNAME and any exact
   verification TXT record supplied for that project; leave apex, www, portfolio,
   nameservers, and mail records unchanged. Verify DNS/TLS and production behavior.
8. Complete synthetic-data acceptance, private encrypted backup custody and
   restoration, and actual VS Code Dev Container use before importing finances.

## Files To Create Or Modify

- `FeaturePlan.md`: this approval and execution plan.
- `analysis_options.yaml` and/or `.github/workflows/deploy.yml`: minimal portfolio
  analysis isolation if confirmed by failure logs; retain analysis of portfolio
  production and test code and keep budgeting checks independent.
- `budgeting/supabase/tests/*`, `budgeting/scripts/*`, and
  `budgeting/integration_test/*`, `.github/workflows/budgeting-ci.yml`: only changes justified by reproduced
  integration failures; no skipped checks or weaker coverage gates.
- `budgeting/recovery/Dockerfile`, `recovery/run.sh`, `recovery/connect.py`,
  `recovery/test.sh`, and backup/restore scripts: only the reviewed compatible
  recovery implementation and its tests, once the hosted major is known.
- `.devcontainer/*`: only corrections found by container/editor verification.
- `budgeting/README.md`: update exact procedures/results when behavior changes;
  distinguish executed checks from pending hosted acceptance.
- No speculative schema migrations, application rewrites, automatic deployment
  pipeline, portfolio dependency changes, or production secrets in tracked files.

The exact implementation diff depends on failed-job logs and the hosted database
major. Any broader change needs an updated reviewed plan.

## API Contracts And Data Models

No API or financial data-model change is proposed. Preserve integer USD cents,
dated snapshots, transaction/import semantics, categories, monthly budgets, and
the immutable singleton owner mapping. Financial tables, RPCs, and Edge routes
must require the correct owner and verified `aal2` session.

Preserve the Edge base `$SUPABASE_URL/functions/v1/api`, financial routes under
`/api/v1`, and anonymous operational `/health`, `/metrics`, `/docs`, and
`/openapi.json`. Keep service-role and worker secrets backend-only. Recovery
returns to the exact frontend origin root and must not grant MFA assurance.

## Acceptance And Edge Cases

- Both GitHub workflows pass on the final revision; signed-in browser acceptance
  actually executes. A passing static build or API-only harness is insufficient.
- Anonymous, wrong-owner, expired/tampered, and non-MFA sessions cannot access
  financial data through either Edge or direct PostgREST.
- Verify login, enrollment/challenge, password-reset delivery/navigation/password
  replacement, post-recovery MFA, logout, and session-loss data clearing.
- Verify CSV preview/commit/duplicate and overlap review/undo, snapshots,
  categories, budgets, and export with synthetic data.
- Verify HTTPS, direct-page reloads, SPA fallback/static precedence, security
  headers, and absence of persistent tokens, financial caches, and service workers.
- Verify correct-key restore and wrong-key/corruption rejection, schema/row
  equivalence, RLS, disabled provider work, matching PostgreSQL majors, and private
  backup/identity custody. An application export is not a complete backup.
- Confirm VS Code analyzer and both Flutter packages work inside the actual Dev
  Container; host-generated path diagnostics are not a reason to install locally.
- Keep the last successful portfolio online throughout. Roll back frontend
  artifacts independently; never restore a database as an automatic deploy rollback.

## Milestone 2: Bank Connections

Only after separate approval: confirm Stripe Financial Connections eligibility,
production access and current pricing; verify each specific Wells Fargo, Citi,
and Mountain America account/card; configure isolated test secrets, signed
webhooks and the secret-authenticated minute worker; pass test-mode boundaries
and retry/disconnect tests. Obtain explicit live authorization, then connect one
account at a time. Never infer account support from institution listings.

## Approval And External Prerequisites

Implementation approval is separate from permission to create hosted resources,
apply remote SQL, deploy production, change DNS, accept terms/costs, or connect
banks. Hosted work needs owner-selected Supabase/Vercel organizations, project
region/plan, trusted owner identity, SMTP provider, DNS access, and secure backup
custody. Use protected local/platform credential entry, never secret values in chat.

Initial approval should cover repository CI/integration remediation and local
validation only. Hosted deployment and all live Stripe actions remain gated.

## Local Execution Results

- Reproduced root analysis scanning budgeting with unresolved independent package
  dependencies. Added root analyzer exclusions for build/web output and the
  independently validated budgeting package. Portfolio analysis and release web
  compilation then passed in Docker with the existing public build CA.
- An additional portfolio widget-test run failed in hero-animation expectations,
  featured-work count/layout, and the home-page test. These are outside the Pages
  workflow and remain unresolved; no portfolio application behavior was changed.
- `.devcontainer/setup.sh` resolved both packages inside the tooling container
  with public CA trust injected. This does not verify the actual VS Code client.
- Budgeting analysis and all 57 Flutter tests passed in its own package context;
  conservative line coverage remains 1,084/1,218 (89.0%). An initial test invocation
  from the portfolio context failed package resolution; the corrected independent
  invocation passed.
- Backend type checks and 27 tests passed; fixed-scope coverage was 1,458/1,654
  (88.15%). Disposable database authorization, concurrency, usage, and lease tests
  passed with `sh budgeting/scripts/test-database.sh`.
- Static browser artifact checks and non-root runtime health/graceful-stop checks
  passed. The offline encrypted recovery drill passed, including wrong-key and
  corruption rejection and target preservation. This does not resolve hosted
  PostgreSQL-major compatibility or establish production backup custody.
- Reproduced isolated Supabase readiness failure: the local gateway returns a
  wildcard CORS header even when the function accepts the exact configured
  browser origin. A test-only readiness correction accepts exact-origin or
  wildcard on anonymous loopback health, while requiring HTTP 200 and healthy
  database JSON. Production CORS and owner/MFA authorization are unchanged.
- With that correction, the real local API harness passed MFA/RLS/CSV/usage/
  export/recovery/JWT checks. Signed-in Chromium acceptance remains incomplete;
  API success alone does not complete this gate.
- The full `BUILD_CA_FILE=<existing-public-ca> sh budgeting/scripts/validate.sh`
  run completed successfully, including rebuilding the tooling image, release
  compilation, 37 Deno tests (27 original plus 10 readiness regressions), database,
  browser/runtime checks, and the encrypted restore drill. Fixed-scope production
  coverage remains 88.15%. Packaging/audit also passed, but the artifact remains
  intentionally unconfigured and unsuitable for production deployment.
- No hosted resources, DNS, remote SQL, production deploys, or bank connections
  have been changed. GitHub workflows still need a separately requested push/run
  to verify the final remote revision.

## Current Handoff

The user redirected work to a usable, pushable repository rather than extended
browser-test investigation. Retain validated analysis isolation and local
readiness fixes, meaningful regression coverage, and accurate pending gates.
Signed-in Chromium acceptance remains a launch blocker, not a reason to skip or
disable the CI step. No commit or push was requested or performed. Hosted setup,
configured production artifact, database-major-compatible recovery, actual VS Code
client verification, and all live bank work remain pending.

The browser investigation exposed unreliable synthetic credential entry through
Flutter semantics; it did not establish an application authentication defect.
Unvalidated browser-harness experiments were removed. The session-owned isolated
Docker daemon was stopped; no unrelated services were changed.

## Signed-In Acceptance Follow-Up

On 2026-11-06 the user requested resuming focused signed-in browser acceptance
after pushing the repository changes. Scope remains synthetic local testing in an
isolated Docker network, browser-harness corrections, and regression verification.
Preserve real password login, TOTP verification, owner/RLS checks, account writes,
logout clearing, and storage/service-worker assertions. No hosted or live-bank
actions are authorized. Investigate asynchronous Flutter semantics focus before
changing application authentication behavior.

### Acceptance Result

The complete real-stack Chromium flow passed at 2026-11-06T23:15:34Z and again
at 23:23:05Z, both with exit status 0. Only `budgeting/supabase/tests/browser_integration.mjs` needed
implementation changes: wait for focused semantic editing handlers, commit input
with focus traversal, assert submitted synthetic credentials, match MFA paths
without query strings, and target merged account-card accessible group names.
No application authentication or authorization behavior changed.

Verified real password login and TOTP, actual dashboard fixture rendering,
manual-account creation (HTTP 201), direct PostgREST verification of exactly one
row owned by the expected UUID, logout financial UI clearing, empty localStorage,
no service workers, and no page runtime errors. JavaScript syntax and patch
whitespace checks passed. The repeat initially paused at slow CLI package
extraction, then completed both API and Chromium acceptance successfully. The
isolated daemon, synthetic services, and anonymous state were removed after
normal cleanup. Hosted recovery/SMTP and full deployed acceptance remain pending.
