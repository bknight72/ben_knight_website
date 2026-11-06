import { ApiError, stripeMode } from "./core.ts";

export type RecordData = Record<string, any>;
export const env = (key: string) => Deno.env.get(key);
export const json = (
  data: unknown,
  status = 200,
  headers: Record<string, string> = {},
) =>
  new Response(JSON.stringify(data), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff",
      ...headers,
    },
  });

export class Database {
  constructor(
    public token = env("SUPABASE_SERVICE_ROLE_KEY") || "",
    public fetcher: typeof fetch = fetch,
  ) {}
  async call(path: string, method = "GET", body?: unknown): Promise<any> {
    const response = await this.fetcher(
      `${env("SUPABASE_URL")}/rest/v1/${path}`,
      {
        method,
        headers: {
          apikey: env("SUPABASE_SERVICE_ROLE_KEY") || "",
          Authorization: `Bearer ${this.token}`,
          "Content-Type": "application/json",
          Prefer: "return=representation,resolution=merge-duplicates",
        },
        body: body === undefined ? undefined : JSON.stringify(body),
        signal: AbortSignal.timeout(15000),
      },
    );
    if (!response.ok) {
      const error = await response.json().catch(() => ({}));
      if (/cross_source_overlap/.test(error.message || "")) {
        throw new ApiError(
          422,
          "cross_source_overlap",
          "CSV and provider dates overlap. Reconcile account coverage before importing or syncing.",
        );
      }
      if (/monthly_cap|cooldown/.test(error.message || "")) {
        throw new ApiError(
          429,
          /monthly_cap/.test(error.message) ? "monthly_cap" : "cooldown",
          "Balance refresh limit reached. Try again after the cooldown or next UTC month.",
        );
      }
      if (/account_not_found|batch_not_found/.test(error.message || "")) {
        throw new ApiError(404, "not_found", "Resource not found.");
      }
      throw new ApiError(
        503,
        "database_unavailable",
        "The database operation could not be completed.",
      );
    }
    if (response.status === 204) return null;
    return response.json();
  }
  state(op: string, payload: RecordData = {}): Promise<any> {
    return this.call("rpc/backend_state", "POST", { op, payload });
  }
  async account(accountId: string, ownerId: string): Promise<RecordData> {
    const rows = await this.call(
      `accounts?id=eq.${accountId}&owner_id=eq.${ownerId}&select=*`,
    );
    if (!rows.length) {
      throw new ApiError(404, "not_found", "Account not found.");
    }
    return rows[0];
  }
  async all(table: string, query = ""): Promise<RecordData[]> {
    const result: RecordData[] = [];
    for (let offset = 0;; offset += 1000) {
      const page = await this.call(
        `${table}?select=*&order=${
          table === "transaction_annotations"
            ? "transaction_id"
            : table === "profiles"
            ? "owner_id"
            : "id"
        }&limit=1000&offset=${offset}${query}`,
      );
      result.push(...page);
      if (result.length > 100000) {
        throw new ApiError(
          422,
          "export_too_large",
          "Use an administrator backup for datasets exceeding 100,000 records per table.",
        );
      }
      if (page.length < 1000) return result;
    }
  }
}

export async function authorize(req: Request, db: Database): Promise<string> {
  const authorization = req.headers.get("authorization") || "";
  if (!/^Bearer [\w.-]+$/.test(authorization)) {
    throw new ApiError(401, "unauthenticated", "Sign in is required.");
  }
  // GoTrue verifies signature and expiration. Never authorize by decoding an unverified JWT alone.
  const response = await db.fetcher(`${env("SUPABASE_URL")}/auth/v1/user`, {
    headers: {
      Authorization: authorization,
      apikey: env("SUPABASE_ANON_KEY") || env("SUPABASE_SERVICE_ROLE_KEY") ||
        "",
    },
    signal: AbortSignal.timeout(10000),
  });
  if (!response.ok) {
    throw new ApiError(
      401,
      "unauthenticated",
      "Session has expired or is invalid.",
    );
  }
  const user = await response.json();
  let claims: RecordData;
  try {
    const encoded = authorization.slice(7).split(".")[1].replace(/-/g, "+")
      .replace(/_/g, "/");
    claims = JSON.parse(atob(encoded));
  } catch {
    throw new ApiError(401, "unauthenticated", "Session is invalid.");
  }
  const owner = await db.state("owner");
  if (
    !owner.owner_id || user.id !== owner.owner_id ||
    claims.sub !== owner.owner_id || claims.aal !== "aal2"
  ) {
    throw new ApiError(
      403,
      "owner_mfa_required",
      "The provisioned owner and verified MFA are required.",
    );
  }
  return owner.owner_id;
}

export class Stripe {
  live: boolean;
  constructor(public fetcher: typeof fetch = fetch) {
    const mode = stripeMode(env);
    if (!mode.enabled) {
      throw new ApiError(
        503,
        "stripe_disabled",
        "Bank connections are disabled. CSV and manual accounts remain available.",
      );
    }
    this.live = mode.live;
  }
  async call(
    path: string,
    method = "GET",
    params: RecordData = {},
    idempotencyKey?: string,
  ): Promise<any> {
    const encoded = new URLSearchParams();
    for (const [key, value] of Object.entries(params)) {
      if (value !== undefined && value !== null) {
        encoded.set(key, String(value));
      }
    }
    const response = await this.fetcher(
      `https://api.stripe.com/v1/${path}${
        method === "GET" && encoded.size ? `?${encoded}` : ""
      }`,
      {
        method,
        headers: {
          Authorization: `Bearer ${env("STRIPE_SECRET_KEY")}`,
          "Content-Type": "application/x-www-form-urlencoded",
          "User-Agent": "novacoast-budgeting/1.0",
          ...(idempotencyKey ? { "Idempotency-Key": idempotencyKey } : {}),
        },
        body: method === "GET" ? undefined : encoded.toString(),
        signal: AbortSignal.timeout(15000),
      },
    );
    if (!response.ok) {
      throw new ApiError(
        response.status === 429 ? 429 : 503,
        "provider_unavailable",
        "The banking provider is temporarily unavailable.",
      );
    }
    const data = await response.json();
    if (typeof data.livemode === "boolean" && data.livemode !== this.live) {
      throw new ApiError(
        503,
        "mode_mismatch",
        "Provider mode does not match this environment.",
      );
    }
    return data;
  }
}

export async function metric(
  db: Database,
  route: string,
  method: string,
  status: number,
  elapsed: number,
) {
  const bucket = elapsed <= 100
    ? "100"
    : elapsed <= 500
    ? "500"
    : elapsed <= 2000
    ? "2000"
    : "+Inf";
  try {
    await db.state("metric", { route, method, status, bucket });
  } catch {
    /* Metrics failure must not change a committed financial operation. */
  }
}
export function errorResponse(error: unknown, requestId: string) {
  const e = error instanceof ApiError ? error : new ApiError(
    503,
    "unavailable",
    "The operation is temporarily unavailable.",
  );
  return json(
    {
      code: e.code,
      message: e.message,
      requestId,
      ...(e.retryAt ? { retryAt: e.retryAt } : {}),
    },
    e.status,
    { "X-Request-Id": requestId },
  );
}
