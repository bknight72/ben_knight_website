import {
  ApiError,
  boundedBody,
  id,
  invalid,
  type Mapping,
  parseImport,
  safeExport,
} from "../_shared/core.ts";
import {
  authorize,
  Database,
  env,
  errorResponse,
  json,
  metric,
  type RecordData,
  Stripe,
} from "../_shared/runtime.ts";
import { openapi } from "../_shared/openapi.ts";

const started = Date.now();
export function routeName(path: string): string {
  const names = [
    "/health",
    "/metrics",
    "/docs",
    "/openapi.json",
    "/api/v1/export",
    "/api/v1/usage",
    "/api/v1/connections/session",
    "/api/v1/connections/complete",
    "/api/v1/connections/pending",
    "/api/v1/imports/preview",
    "/api/v1/imports/commit",
  ];
  if (names.includes(path)) return path;
  if (
    /^\/api\/v1\/accounts\/[^/]+\/(balance-refresh|subscription-retry|disconnect|delete)$/
      .test(
        path,
      )
  ) return "/api/v1/accounts/:id/" + path.split("/").pop();
  if (/^\/api\/v1\/imports\/[^/]+\/undo$/.test(path)) {
    return "/api/v1/imports/:id/undo";
  }
  return "unmatched";
}

async function importRequest(
  body: RecordData,
  ownerId: string,
  db: Database,
  commit: boolean,
) {
  const accountId = id(body.accountId);
  const account = await db.account(accountId, ownerId);
  if (typeof body.csv !== "string") invalid("csv must contain a CSV string.");
  const parsed = await parseImport(body.csv, body.mapping as Mapping);
  if (commit && parsed.errors.length) {
    throw new ApiError(
      422,
      "invalid_rows",
      "Correct all CSV validation errors before committing.",
    );
  }
  const existing: RecordData[] = [];
  // Only fetch bounded identity fields, never full provider payloads.
  const dates = parsed.rows.map((r) => r.transaction_date).sort();
  if (dates.length) {
    for (let offset = 0;; offset += 1000) {
      const page = await db.call(
        `transactions?account_id=eq.${accountId}&transaction_date=gte.${
          dates[0]
        }&transaction_date=lte.${
          dates.at(-1)
        }&select=id,source,source_id,transaction_date,amount_minor,description&order=id&limit=1000&offset=${offset}`,
      );
      existing.push(...page);
      if (existing.length > 50000) {
        invalid(
          "Import date range contains too much history. Split the CSV into smaller date ranges.",
        );
      }
      if (page.length < 1000) break;
    }
  }
  const identities = new Set(
    existing.filter((r) => r.source === "csv").map((r) => r.source_id),
  );
  const duplicateCandidates = parsed.rows.filter((r) =>
    identities.has(r.source_id)
  ).map((r) => ({
    sourceId: r.source_id,
    date: r.transaction_date,
    amountMinor: r.amount_minor,
  }));
  const overlapRequiresConfirmation = account.source === "stripe" ||
    existing.some((r) => r.source === "stripe") ||
    duplicateCandidates.some((r) => r.sourceId.startsWith("row:"));
  if (!commit) {
    return { ...parsed, duplicateCandidates, overlapRequiresConfirmation };
  }
  if (overlapRequiresConfirmation && body.confirmOverlap !== true) {
    throw new ApiError(
      422,
      "overlap_confirmation_required",
      "Review duplicate candidates and confirm overlap. Existing matching rows will be retained, not merged across sources.",
    );
  }
  if (
    account.source === "stripe" || existing.some((r) => r.source === "stripe")
  ) {
    // Deliberately refuse cross-source overlap until the owner has selected which rows to keep.
    // This avoids reporting duplicate spending merely because a checkbox was accepted.
    const stripeDates = new Set(
      existing.filter((r) => r.source === "stripe").map((r) =>
        r.transaction_date
      ),
    );
    if (parsed.rows.some((r) => stripeDates.has(r.transaction_date))) {
      throw new ApiError(
        422,
        "cross_source_overlap",
        "Remove rows on dates already covered by Stripe, or import into a separate manual account after reconciling coverage.",
      );
    }
  }
  return db.state("import", {
    account_id: accountId,
    owner_id: ownerId,
    fingerprint: parsed.fingerprint,
    mapping: body.mapping,
    rows: parsed.rows,
  });
}

async function completeSession(
  body: RecordData,
  ownerId: string,
  db: Database,
  stripe: Stripe,
) {
  if (
    typeof body.sessionId !== "string" ||
    !/^fcsess_[A-Za-z0-9]+$/.test(body.sessionId)
  ) invalid("Invalid connection session.");
  const saved = await db.state("session_claim", {
    id: body.sessionId,
    owner_id: ownerId,
  });
  if (!saved.id) {
    throw new ApiError(404, "not_found", "Connection session not found.");
  }
  if (saved.completion_result) return saved.completion_result;
  const claim = {
    id: body.sessionId,
    owner_id: ownerId,
    claim_token: saved.claim_token,
  };
  try {
    const session = await stripe.call(
      `financial_connections/sessions/${body.sessionId}`,
    );
    if (
      session.account_holder?.customer !== saved.customer_id ||
      session.livemode !== stripe.live
    ) {
      throw new ApiError(
        403,
        "session_mismatch",
        "Connection session does not belong to this owner.",
      );
    }
    // FC Sessions have no status attribute. Completion is established by owned, active selected accounts.
    if (!session.accounts?.data?.length) {
      invalid("No linked accounts were selected.");
    }
    let page = session.accounts;
    const accounts: RecordData[] = [];
    for (let pages = 0;; pages++) {
      if (pages >= 20) {
        throw new ApiError(
          422,
          "account_limit",
          "The connection contains too many accounts.",
        );
      }
      if (!Array.isArray(page.data) || (page.has_more && !page.data.length)) {
        throw new ApiError(
          503,
          "invalid_provider_page",
          "Provider returned an invalid account page.",
        );
      }
      for (const selected of page.data) {
        if (
          typeof selected.id !== "string" ||
          !/^fca_[A-Za-z0-9]+$/.test(selected.id)
        ) {
          throw new ApiError(
            503,
            "invalid_provider_page",
            "Provider returned an invalid account identity.",
          );
        }
        await db.state("session_renew", claim);
        const a = await stripe.call(
          `financial_connections/accounts/${encodeURIComponent(selected.id)}`,
        );
        if (
          a.id !== selected.id ||
          a.account_holder?.customer !== saved.customer_id ||
          a.status !== "active" || !["cash", "credit"].includes(a.category) ||
          a.livemode !== stripe.live ||
          !a.permissions?.includes("transactions") ||
          !a.permissions?.includes("balances")
        ) {
          invalid(
            "Linked account is not active or does not support the requested read-only features.",
          );
        }
        accounts.push({
          provider_id: a.id,
          name: String(a.display_name || "Linked account").slice(0, 120),
          institution: String(a.institution_name || "").slice(0, 120),
          last_four: /^\d{4}$/.test(a.last4) ? a.last4 : null,
          kind: a.category,
          livemode: stripe.live,
        });
      }
      if (!page.has_more) break;
      const last = page.data.at(-1)?.id;
      if (!last) {
        throw new ApiError(
          503,
          "invalid_provider_page",
          "Provider returned an invalid account page.",
        );
      }
      await db.state("session_renew", claim);
      page = await stripe.call("financial_connections/accounts", "GET", {
        session: body.sessionId,
        starting_after: last,
        limit: 100,
      });
    }
    return await db.state("session_accept", {
      id: body.sessionId,
      owner_id: ownerId,
      claim_token: saved.claim_token,
      accounts,
    });
  } finally {
    try {
      await db.state("session_release", claim);
    } catch {
      // A lost response must not replace a durable acceptance. The claim also expires.
    }
  }
}

export async function handle(
  req: Request,
  db = new Database(),
): Promise<Response> {
  const requestId = crypto.randomUUID(), begin = Date.now();
  const url = new URL(req.url),
    path = url.pathname.replace(/^\/functions\/v1\/api(?=\/)/, "").replace(
      /^\/api(?=\/api\/v1|\/health|\/metrics|\/docs|\/openapi\.json)/,
      "",
    );
  const route = routeName(path), origin = req.headers.get("origin");
  const allowed = (env("ALLOWED_ORIGINS") || "https://budgeting.benknight.dev")
    .split(",").map((s) => s.trim());
  const cors: Record<string, string> = origin && allowed.includes(origin)
    ? {
      "Access-Control-Allow-Origin": origin,
      Vary: "Origin",
      "Access-Control-Allow-Headers":
        "authorization, apikey, content-type, x-client-info",
      "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    }
    : {};
  let response: Response;
  try {
    if (origin && !allowed.includes(origin)) {
      throw new ApiError(403, "origin_denied", "Origin is not allowed.");
    }
    if (req.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: cors });
    }
    if (req.method === "GET" && path === "/health") {
      await db.state("owner");
      response = json({ status: "ok", database: "connected" });
    } else if (req.method === "GET" && path === "/metrics") {
      const metrics = await db.state("metrics");
      response = json({
        uptime_seconds: Math.floor((Date.now() - started) / 1000),
        request_counts_and_response_time_buckets_ms: metrics,
        errors: metrics.filter((m: RecordData) => m.status >= 400),
        counters: {
          imports: metrics.filter((m: RecordData) =>
            m.route === "/api/v1/imports/commit" && m.status < 300
          ).reduce((sum: number, m: RecordData) => sum + Number(m.count), 0),
          sync_jobs: metrics.filter((m: RecordData) =>
            m.route === "worker/sync" && m.status < 300
          ).reduce((sum: number, m: RecordData) => sum + Number(m.count), 0),
        },
      });
    } else if (req.method === "GET" && path === "/openapi.json") {
      response = json(openapi);
    } else if (req.method === "GET" && path === "/docs") {
      response = new Response(
        '<!doctype html><html><head><title>Budgeting API</title><link rel="stylesheet" href="https://unpkg.com/swagger-ui-dist/swagger-ui.css"></head><body><div id="swagger-ui"></div><script src="https://unpkg.com/swagger-ui-dist/swagger-ui-bundle.js"></script><script>SwaggerUIBundle({url:"./openapi.json",dom_id:"#swagger-ui",persistAuthorization:false})</script></body></html>',
        {
          headers: {
            "Content-Type": "text/html",
            "Cache-Control": "no-store",
            "Content-Security-Policy":
              "default-src 'none'; script-src https://unpkg.com 'unsafe-inline'; style-src https://unpkg.com 'unsafe-inline'; connect-src 'self'; img-src data:",
          },
        },
      );
    } else {
      const ownerId = await authorize(req, db);
      if (req.method === "GET" && path === "/api/v1/connections/pending") {
        response = json(
          await db.state("session_pending", { owner_id: ownerId }),
        );
      } else if (req.method === "GET" && path === "/api/v1/usage") {
        // Use the verified caller JWT so the narrow RPC independently enforces RLS identity/MFA.
        response = json(
          await new Database(
            req.headers.get("authorization")!.slice(7),
            db.fetcher,
          ).call("rpc/budget_refresh_usage", "POST", {}),
        );
      } else if (req.method === "GET" && path === "/api/v1/export") {
        const data: RecordData = {
          version: 1,
          exportedAt: new Date().toISOString(),
          currency: "USD",
        };
        for (
          const table of [
            "profiles",
            "accounts",
            "balance_snapshots",
            "transactions",
            "transaction_annotations",
            "categories",
            "monthly_budgets",
            "import_batches",
            "budgeteer_plans",
            "budgeteer_groups",
            "budgeteer_entries",
            "budgeteer_labels",
            "budgeteer_entry_labels",
            "budgeteer_source_exclusions",
          ]
        ) data[table] = await db.all(table, `&owner_id=eq.${ownerId}`);
        response = json(safeExport(data), 200, {
          "Content-Disposition": 'attachment; filename="budgeting-export.json"',
        });
      } else if (req.method === "POST") {
        let body: RecordData;
        try {
          body = JSON.parse(await boundedBody(req));
        } catch (e) {
          if (e instanceof ApiError) throw e;
          invalid("Request must contain valid JSON.");
        }
        if (!body || typeof body !== "object" || Array.isArray(body)) {
          invalid("Request must be an object.");
        }
        if (
          path === "/api/v1/imports/preview" ||
          path === "/api/v1/imports/commit"
        ) {
          response = json(
            await importRequest(body, ownerId, db, path.endsWith("/commit")),
          );
        } else if (/^\/api\/v1\/imports\/[^/]+\/undo$/.test(path)) {
          response = json(
            await db.state("undo", {
              id: id(path.split("/")[4]),
              owner_id: ownerId,
            }),
          );
        } else if (path === "/api/v1/connections/session") {
          const stripe = new Stripe();
          let customer = await db.state("customer_get", { owner_id: ownerId });
          if (!customer.customer_id) {
            const created = await stripe.call("customers", "POST", {
              description: "Private budgeting owner",
            }, `budgeting-owner:${ownerId}:${stripe.live}`);
            customer = await db.state("customer_put", {
              owner_id: ownerId,
              customer_id: created.id,
              livemode: stripe.live,
            });
          }
          if (customer.livemode !== stripe.live) {
            throw new ApiError(
              503,
              "mode_mismatch",
              "Use separate Supabase projects for live and test data.",
            );
          }
          const session = await stripe.call(
            "financial_connections/sessions",
            "POST",
            {
              "account_holder[type]": "customer",
              "account_holder[customer]": customer.customer_id,
              "permissions[0]": "balances",
              "permissions[1]": "transactions",
              "filters[countries][0]": "US",
            },
            `session:${requestId}`,
          );
          await db.state("session_put", {
            id: session.id,
            owner_id: ownerId,
            customer_id: customer.customer_id,
          });
          response = json({
            sessionId: session.id,
            clientSecret: session.client_secret,
          });
        } else if (path === "/api/v1/connections/complete") {
          response = json(
            await completeSession(body, ownerId, db, new Stripe()),
          );
        } else if (
          /^\/api\/v1\/accounts\/[^/]+\/(balance-refresh|subscription-retry|disconnect|delete)$/
            .test(path)
        ) {
          const accountId = id(path.split("/")[4]);
          const account = await db.account(accountId, ownerId);
          const deleteLocal = path.endsWith("/delete");
          if (deleteLocal && body.confirmDelete !== true) {
            invalid("Explicit permanent deletion confirmation is required.");
          }
          if (deleteLocal && account.source === "manual") {
            await db.call(
              `accounts?id=eq.${accountId}&owner_id=eq.${ownerId}`,
              "DELETE",
            );
            response = json({ status: "deleted" });
          } else {
            if (account.source !== "stripe") {
              invalid("This action requires a connected Stripe account.");
            }
            const stripe = new Stripe(
              fetch,
              path.endsWith("/disconnect") || deleteLocal,
            );
            const mapping = await db.state("mapping", {
              account_id: accountId,
            });
            if (
              mapping.owner_id !== ownerId || mapping.livemode !== stripe.live
            ) {
              throw new ApiError(
                403,
                "mapping_mismatch",
                "Provider mapping does not match this owner and mode.",
              );
            }
            if (path.endsWith("/subscription-retry")) {
              if (body.confirmCost !== true) {
                invalid(
                  "Explicit ongoing transaction feed cost confirmation is required.",
                );
              }
              response = json(
                await db.state("subscription_retry", { account_id: accountId }),
                202,
              );
            } else if (path.endsWith("/balance-refresh")) {
              if (body.confirmCost !== true) {
                invalid(
                  "Explicit balance refresh cost confirmation is required.",
                );
              }
              if (account.connection_state !== "active") {
                invalid("Account is not active.");
              }
              const provider = await stripe.call(
                `financial_connections/accounts/${mapping.provider_id}`,
              );
              if (
                provider.status !== "active" ||
                provider.livemode !== stripe.live ||
                provider.account_holder?.customer !== mapping.customer_id ||
                !provider.permissions?.includes("balances") ||
                !provider.permissions?.includes("transactions")
              ) {
                throw new ApiError(
                  409,
                  "connection_inactive",
                  "The provider connection is inactive or lacks permissions.",
                );
              }
              const next = provider.balance_refresh?.next_refresh_available_at;
              if (
                provider.balance_refresh && (!next || next * 1000 > Date.now())
              ) {
                throw new ApiError(
                  429,
                  "provider_cooldown",
                  "Provider balance refresh is not yet available.",
                  next ? new Date(next * 1000).toISOString() : undefined,
                );
              }
              response = json(
                await db.state("reserve", { account_id: accountId }),
                202,
              );
            } else {
              response = json(
                await db.state("disconnect_request", {
                  account_id: accountId,
                  kind: "disconnect",
                  dedupe_key: `disconnect:${accountId}:${requestId}`,
                  delete_local: deleteLocal,
                }),
                202,
              );
            }
          }
        } else throw new ApiError(404, "not_found", "Route not found.");
      } else throw new ApiError(404, "not_found", "Route not found.");
    }
  } catch (e) {
    response = errorResponse(e, requestId);
  }
  if (route !== "/metrics") {
    await metric(
      db,
      route,
      ["GET", "POST", "OPTIONS"].includes(req.method) ? req.method : "OTHER",
      response.status,
      Date.now() - begin,
    );
  }
  for (const [key, value] of Object.entries(cors)) {
    response.headers.set(key, value);
  }
  response.headers.set("X-Request-Id", requestId);
  return response;
}
