const string = (description: string, example: string) => ({
  type: "string",
  description,
  example,
});
const uuid = (description: string) => ({
  ...string(description, "00000000-0000-4000-8000-000000000001"),
  format: "uuid",
});
const object = (
  properties: Record<string, unknown>,
  required = Object.keys(properties),
) => ({ type: "object", properties, required, additionalProperties: false });
const response = (description: string, schema: unknown) => ({
  description,
  content: { "application/json": { schema } },
});
const ref = (name: string) => ({ $ref: `#/components/schemas/${name}` });
const errorResponses = Object.fromEntries(
  ["401", "403", "404", "422", "429", "503"].map((s) => [
    s,
    response(
      {
        "401": "Session missing or expired",
        "403": "Provisioned owner with MFA required",
        "404": "Resource not found",
        "422": "Validation failed",
        "429": "Cooldown, monthly cap, or provider throttling",
        "503": "Database/provider disabled or unavailable",
      }[s]!,
      ref("Error"),
    ),
  ]),
);
const post = (
  summary: string,
  request: unknown,
  result: unknown,
  accepted = false,
) => ({
  summary,
  description: summary,
  security: [{ bearerAuth: [] }],
  requestBody: {
    required: true,
    content: { "application/json": { schema: request } },
  },
  responses: {
    [accepted ? "202" : "200"]: response("Operation accepted", result),
    ...errorResponses,
  },
});
const accountParameter = [{
  name: "id",
  in: "path",
  required: true,
  schema: uuid("Internal account or import batch ID"),
  description: "Owner-scoped internal identifier",
}];
export const openapi = {
  openapi: "3.0.3",
  info: {
    title: "Private Budgeting API",
    version: "1.0.0",
    description:
      "Built at Novacoast. Single provisioned owner, USD only, verified MFA required for all financial operations. Stripe disabled by default. All responses are no-store.",
  },
  servers: [{ url: "/functions/v1/api" }],
  components: {
    securitySchemes: {
      bearerAuth: {
        type: "http",
        scheme: "bearer",
        bearerFormat: "Supabase JWT with aal2",
      },
    },
    schemas: {
      Error: object({
        code: string(
          "Stable machine-readable error code",
          "owner_mfa_required",
        ),
        message: string(
          "Sanitized user-facing error",
          "The provisioned owner and verified MFA are required.",
        ),
        requestId: uuid("Request correlation ID"),
        retryAt: {
          ...string("Earliest retry time when known", "2026-11-06T00:00:00Z"),
          format: "date-time",
        },
      }, ["code", "message", "requestId"]),
      Mapping: object({
        date: string("Exact date header", "Date"),
        description: string("Exact description header", "Description"),
        amount: string(
          "Signed decimal amount header; mutually exclusive with debit/credit",
          "Amount",
        ),
        debit: string("Nonnegative debit header", "Debit"),
        credit: string("Nonnegative credit header", "Credit"),
        transactionId: string("Optional bank identifier header", "ID"),
        currency: string("Optional USD currency header", "Currency"),
        dateFormat: {
          type: "string",
          enum: ["YYYY-MM-DD", "MM/DD/YYYY", "DD/MM/YYYY"],
          description: "Explicit unambiguous input date format",
          example: "YYYY-MM-DD",
        },
        sign: {
          type: "string",
          enum: ["inflow-positive", "outflow-positive"],
          description:
            "Signed amount convention; debit/credit columns always credit minus debit",
          example: "inflow-positive",
        },
      }, ["date", "description", "dateFormat", "sign"]),
      ImportRequest: object({
        accountId: uuid("Destination account"),
        csv: string(
          "UTF-8 CSV, max 5 MB/10,000 rows/100 columns; no raw CSV is retained",
          "Date,Description,Amount\n2026-11-01,Example,-12.34",
        ),
        mapping: ref("Mapping"),
        confirmOverlap: {
          type: "boolean",
          description:
            "Confirm reviewed ambiguous same-source duplicates. Cross-source overlapping dates still require removal/reconciliation.",
          example: false,
        },
      }, ["accountId", "csv", "mapping"]),
      ImportRow: object({
        source_id: string(
          "Bank ID or content hash with occurrence count",
          "bank:example",
        ),
        amount_minor: {
          type: "integer",
          description: "USD cents; positive inflow",
          example: -1234,
        },
        description: string("Transaction description", "Example"),
        transaction_date: {
          ...string("Validated calendar date", "2026-11-01"),
          format: "date",
        },
      }),
      Preview: object({
        rows: {
          type: "array",
          description: "Validated normalized rows",
          items: ref("ImportRow"),
        },
        errors: {
          type: "array",
          description: "Up to 100 row-level errors; any error prevents commit",
          items: object({
            row: { type: "integer", description: "CSV line index", example: 2 },
            message: string("Validation message", "Invalid calendar date."),
          }),
        },
        rowCount: {
          type: "integer",
          description: "Input data row count",
          example: 1,
        },
        fingerprint: string("SHA-256 of CSV plus mapping", "a".repeat(64)),
        duplicateCandidates: {
          type: "array",
          description: "Existing same-source row identities to review",
          items: { type: "object" },
        },
        overlapRequiresConfirmation: {
          type: "boolean",
          description: "Review required before commit",
          example: false,
        },
      }),
      Queued: object({
        requestId: uuid("Durable job/reservation identifier"),
        status: string("Queued for bounded worker processing", "queued"),
      }),
      Usage: object({
        month: string("Current UTC calendar month", "2026-11"),
        reservedAttempts: {
          type: "integer",
          minimum: 0,
          description:
            "All app reservations, including uncertain failures and deleted accounts",
          example: 2,
        },
        limit: {
          type: "integer",
          enum: [50],
          description: "Fixed monthly app attempt limit",
          example: 50,
        },
        remainingAttempts: {
          type: "integer",
          minimum: 0,
          maximum: 50,
          description: "Unused attempts this UTC month",
          example: 48,
        },
        accounts: {
          type: "array",
          description: "Owned Stripe accounts, no provider or job data",
          items: object({
            accountId: uuid("Internal account identifier"),
            nextEligibleRefreshAt: {
              type: "string",
              format: "date-time",
              nullable: true,
              description:
                "App cooldown/cap eligibility, null when no app delay; provider availability and active state are checked separately",
              example: "2026-11-06T12:00:00Z",
            },
          }),
        },
      }),
    },
  },
  paths: {
    "/health": {
      get: {
        summary: "Anonymous database connectivity check",
        responses: {
          "200": response(
            "Operational",
            object({
              status: string("Service state", "ok"),
              database: string("Connectivity state", "connected"),
            }),
          ),
          "503": response("Database unavailable", ref("Error")),
        },
      },
    },
    "/metrics": {
      get: {
        summary:
          "Anonymous aggregate counts, latency buckets, error rates, cold-start uptime and import/sync counters; no financial or identifying labels",
        responses: {
          "200": response("Anonymized metrics", { type: "object" }),
        },
      },
    },
    "/openapi.json": {
      get: {
        summary: "OpenAPI specification",
        responses: { "200": response("This document", { type: "object" }) },
      },
    },
    "/docs": {
      get: {
        summary: "Anonymous Swagger UI",
        responses: { "200": { description: "Swagger UI HTML" } },
      },
    },
    "/api/v1/imports/preview": {
      post: post(
        "Validate bounded CSV and identify overlaps without retaining the raw upload",
        ref("ImportRequest"),
        ref("Preview"),
      ),
    },
    "/api/v1/imports/commit": {
      post: post(
        "Revalidate and atomically commit CSV; exact reimports are idempotent",
        ref("ImportRequest"),
        object({
          batchId: uuid("Import batch"),
          inserted: { type: "integer", description: "New rows", example: 1 },
          duplicates: {
            type: "integer",
            description: "Existing rows retained",
            example: 0,
          },
        }),
      ),
    },
    "/api/v1/imports/{id}/undo": {
      parameters: accountParameter,
      post: post(
        "Undo only unannotated CSV rows belonging to this batch; retain later user edits",
        object({}),
        object({
          deleted: { type: "integer", description: "Rows removed", example: 1 },
          retained: {
            type: "integer",
            description: "Annotated rows retained",
            example: 0,
          },
        }),
      ),
    },
    "/api/v1/connections/session": {
      post: post(
        "Create a data-only Stripe session for the server-selected customer, no balance prefetch",
        object({}),
        object({
          sessionId: string("Stripe session ID", "fcsess_example"),
          clientSecret: string(
            "Short-lived secret for Stripe.js only",
            "fcsess_client_secret_example",
          ),
        }),
      ),
    },
    "/api/v1/connections/complete": {
      post: post(
        "Verify owned active accounts, paginate, map, subscribe and queue ingestion",
        object({
          sessionId: string(
            "Previously created owned Stripe session ID",
            "fcsess_example",
          ),
        }),
        object({
          accountIds: {
            type: "array",
            description: "Internal linked account IDs",
            items: uuid("Account ID"),
          },
          status: string("Ingestion state", "queued"),
        }),
      ),
    },
    "/api/v1/accounts/{id}/balance-refresh": {
      parameters: accountParameter,
      post: post(
        "Reserve one of 50 monthly UTC attempts, enforce 24-hour cooldown and queue a paid refresh; ambiguous failures retain reservation",
        object({
          confirmCost: {
            type: "boolean",
            enum: [true],
            description: "Explicit acknowledgement of provider cost",
            example: true,
          },
        }),
        ref("Queued"),
        true,
      ),
    },
    "/api/v1/accounts/{id}/disconnect": {
      parameters: accountParameter,
      post: post(
        "Durably unsubscribe/disconnect provider while retaining local history",
        object({}),
        ref("Queued"),
        true,
      ),
    },
    "/api/v1/accounts/{id}/delete": {
      parameters: accountParameter,
      post: post(
        "Permanently delete local account/history only after durable provider cleanup; manual accounts delete immediately",
        object({
          confirmDelete: {
            type: "boolean",
            enum: [true],
            description: "Irreversible deletion confirmation",
            example: true,
          },
        }),
        ref("Queued"),
        true,
      ),
    },
    "/api/v1/usage": {
      get: {
        summary:
          "Owner/MFA-protected UTC monthly reserved attempts and per-account app cooldowns; works while Stripe is disabled",
        security: [{ bearerAuth: [] }],
        responses: {
          "200": response("Current app refresh usage", ref("Usage")),
          ...errorResponses,
        },
      },
    },
    "/api/v1/export": {
      get: {
        summary:
          "Owner-only paginated JSON export; formula-leading strings escaped; sensitive download, no-store",
        security: [{ bearerAuth: [] }],
        responses: {
          "200": response("Portable JSON financial export, version 1", {
            type: "object",
          }),
          ...errorResponses,
        },
      },
    },
  },
};
