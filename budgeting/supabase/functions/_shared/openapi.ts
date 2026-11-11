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
  ["401", "403", "404", "409", "422", "429", "503"].map((s) => [
    s,
    response(
      {
        "401": "Session missing or expired",
        "403": "Provisioned owner with MFA required",
        "404": "Resource not found",
        "409": "Completion in progress or connection inactive",
        "422": "Validation failed",
        "429":
          "Monthly cap, provider refresh availability, or provider throttling",
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
                "Next UTC month when the app cap is reached, null otherwise; provider availability and active state are checked separately",
              example: "2026-12-01T00:00:00Z",
            },
          }),
        },
      }),
      BudgeteerPlan: object({
        id: uuid("Plan identifier, generated by the database"),
        owner_id: uuid("Provisioned owner"),
        month: {
          ...string("Reporting month, first day only", "2026-11-01"),
          format: "date",
        },
        revision: {
          type: "integer",
          format: "int64",
          minimum: 0,
          description:
            "Optimistic concurrency revision; absent plan uses revision 0",
          example: 1,
        },
        created_at: {
          ...string("Creation timestamp", "2026-11-10T22:00:00+00:00"),
          format: "date-time",
        },
        updated_at: {
          ...string(
            "Last planning mutation or source deletion",
            "2026-11-10T22:00:00+00:00",
          ),
          format: "date-time",
        },
      }),
      BudgeteerSource: {
        type: "object",
        nullable: true,
        description:
          "Read-only raw bank transaction row, or null. Snapshot retained after source deletion. Positive posted sources not categorized expense fund deposits (expense refunds are excluded); negative posted non-income sources fund withdrawals (income reversals are excluded). Uncategorized sources use their sign. Transfers, card payments, exclusions, pending, void and zero rows are rejected on link/refresh. Source need not fall in plan month.",
        properties: {
          id: uuid("Source transaction identifier"),
          owner_id: uuid("Source owner"),
          account_id: uuid("Source account"),
          source: string("Bank row origin", "csv"),
          source_id: string("Bank/import row identity", "bank:example"),
          amount_minor: {
            type: "integer",
            format: "int64",
            description: "Signed USD cents, positive inflow",
            example: -1234,
          },
          currency: { ...string("Currency", "USD"), enum: ["USD"] },
          description: string("Bank description", "Groceries"),
          transaction_date: {
            ...string("Transaction date", "2026-11-01"),
            format: "date",
          },
          posted_date: {
            ...string("Posted date when known", "2026-11-02"),
            format: "date",
            nullable: true,
          },
          status: {
            ...string("Bank row status", "posted"),
            enum: ["pending", "posted", "void"],
          },
          provider_updated: {
            type: "integer",
            format: "int64",
            description: "Provider version",
            example: 0,
          },
          import_batch_id: {
            ...uuid("Optional CSV import batch"),
            nullable: true,
          },
          created_at: {
            ...string(
              "Bank row creation timestamp",
              "2026-11-10T22:00:00+00:00",
            ),
            format: "date-time",
          },
        },
      },
      BudgeteerGroup: object({
        id: uuid("Database-generated group ID"),
        owner_id: uuid("Provisioned owner"),
        plan_id: uuid("Containing plan"),
        name: {
          ...string(
            "Trimmed nonempty group name, max 80 characters",
            "Essentials",
          ),
          maxLength: 80,
        },
        color_key: string(
          "Lowercase palette key matching [a-z][a-z0-9_-]{0,31}; UI uses teal/blue/amber/rose/violet/slate",
          "teal",
        ),
        sort_position: {
          type: "integer",
          format: "int64",
          description: "Group order; Ungrouped is virtual and follows groups",
          example: 0,
        },
      }),
      BudgeteerEntry: object({
        id: uuid("Database-generated entry ID"),
        owner_id: uuid("Provisioned owner"),
        plan_id: uuid("Containing plan"),
        kind: {
          ...string("Planning entry kind", "withdrawal"),
          enum: ["deposit", "withdrawal"],
        },
        name: {
          ...string(
            "Independent trimmed nonempty name, max 120 characters",
            "Groceries",
          ),
          maxLength: 120,
        },
        amount_minor: {
          type: "integer",
          format: "int64",
          minimum: 1,
          maximum: 9000000000000,
          description:
            "Independent positive integer USD cents. Each kind's plan total is capped at 9000000000000",
          example: 1234,
        },
        group_id: {
          ...uuid("Optional withdrawal group; deposits must be ungrouped"),
          nullable: true,
        },
        sort_position: {
          type: "integer",
          format: "int64",
          minimum: 0,
          description: "Entry order within its group/kind",
          example: 0,
        },
        source_transaction_id: {
          ...uuid(
            "Optional bank row association, unique within the plan; null after deletion",
          ),
          nullable: true,
        },
        source_snapshot: ref("BudgeteerSource"),
        source_current: ref("BudgeteerSource"),
        source_state: {
          type: "string",
          enum: ["manual", "linked", "changed", "unavailable"],
          description:
            "manual: no snapshot; linked: current raw row equals snapshot; changed: raw row differs; unavailable: snapshot retained but source deleted. Provider sync never rewrites planning names/amounts",
          example: "linked",
        },
      }),
      BudgeteerLabel: object({
        id: uuid("Database-generated owner-global label ID"),
        owner_id: uuid("Provisioned owner"),
        name: {
          ...string(
            "Trimmed reusable nonempty label, max 80 characters, unique per owner",
            "Needs",
          ),
          maxLength: 80,
        },
        color_key: string(
          "Lowercase palette key matching [a-z][a-z0-9_-]{0,31}",
          "blue",
        ),
        updated_at: {
          ...string(
            "Opaque PostgreSQL ISO-8601 timestamp token with up to six fractional digits. Echo exact returned string as expected_updated_at; never parse/reformat through a millisecond-precision Date",
            "2026-11-10T22:00:00.123456+00:00",
          ),
          format: "date-time",
        },
      }),
      BudgeteerEntryLabel: object({
        owner_id: uuid("Provisioned owner"),
        entry_id: uuid("Withdrawal entry"),
        label_id: uuid("Reusable owner label"),
      }),
      BudgeteerSourceExclusion: object({
        id: uuid("Database-generated exclusion ID"),
        owner_id: uuid("Provisioned owner"),
        month: {
          ...string("Excluded reporting month, first day only", "2026-11-01"),
          format: "date",
        },
        source_transaction_id: uuid(
          "Excluded bank source; deleting its transaction cascades this exclusion",
        ),
      }),
      BudgeteerState: object({
        plan: {
          allOf: [ref("BudgeteerPlan")],
          nullable: true,
          description: "Null for an absent plan; reads do not create rows",
        },
        groups: {
          type: "array",
          description: "Ordered groups in this month",
          items: ref("BudgeteerGroup"),
        },
        entries: {
          type: "array",
          description:
            "Deposits first, then contiguous withdrawal groups, then Ungrouped",
          items: ref("BudgeteerEntry"),
        },
        labels: {
          type: "array",
          description:
            "All reusable owner labels, including when plan is absent",
          items: ref("BudgeteerLabel"),
        },
        entry_labels: {
          type: "array",
          description: "Assignments for this plan only",
          items: ref("BudgeteerEntryLabel"),
        },
        excluded_source_count: {
          type: "integer",
          minimum: 0,
          description:
            "Persisted exclusions for this owner/month, including sources currently ineligible; sources_restore clears all of them atomically",
          example: 2,
        },
      }),
      BudgeteerMutation: object({
        p_month: {
          ...string("Reporting month, first day only", "2026-11-01"),
          format: "date",
        },
        p_revision: {
          type: "integer",
          format: "int64",
          minimum: 0,
          description:
            "Exact last returned plan revision, or 0 when absent. Stale plan or label token raises PostgreSQL P0001 message budgeteer_conflict, with no partial writes",
          example: 0,
        },
        p_operation: {
          type: "string",
          enum: [
            "entry_save",
            "entry_delete",
            "group_save",
            "group_delete",
            "label_save",
            "label_delete",
            "source_refresh",
            "source_unlink",
            "sources_include",
            "sources_restore",
            "reorder",
          ],
          description: "Atomic operation selector",
          example: "entry_save",
        },
        p_payload: {
          type: "object",
          description:
            "Operation-specific payload: entry_save requires kind/name/amount_minor/label_ids and optional id/group_id/source_transaction_id; label_ids are complete and withdrawals only. group_save requires name/color_key and optional id. label_save requires name/color_key, optional id and expected_updated_at on update; label_delete requires id/expected_updated_at. entry_delete/group_delete/source_refresh/source_unlink require id. sources_include and sources_restore require an empty object. reorder requires complete unique groups:[UUID] and entries:[{id,group_id:UUID|null}] lists. IDs omitted on create are database-generated; supplied IDs must already belong to this plan/owner. Group deletion ungroups entries; label deletion removes assignments only. Existing links/snapshots are preserved by entry_save; explicit source_unlink clears both and excludes the former source for this month; deleting a linked entry also persists its exclusion. Explicit entry_save linking clears that source exclusion. source_refresh validates current source and resets snapshot/name/amount. Replacing an existing link requires unlink first.",
          properties: {
            id: uuid("Existing object ID; omit on create"),
            kind: {
              type: "string",
              enum: ["deposit", "withdrawal"],
              description: "Entry kind",
              example: "withdrawal",
            },
            name: string("Independent planning name", "Groceries"),
            amount_minor: {
              type: "integer",
              format: "int64",
              minimum: 1,
              maximum: 9000000000000,
              description: "Positive USD cents",
              example: 1234,
            },
            group_id: { ...uuid("Withdrawal group or null"), nullable: true },
            source_transaction_id: {
              ...uuid(
                "Optional eligible bank source; omitted on existing entry preserves source",
              ),
              nullable: true,
            },
            color_key: string("Palette key", "teal"),
            expected_updated_at: string(
              "Exact returned label updated_at token required on existing label update/delete",
              "2026-11-10T22:00:00.123456+00:00",
            ),
            label_ids: {
              type: "array",
              uniqueItems: true,
              description: "Complete label assignment list; empty for deposits",
              items: uuid("Owner label"),
            },
            groups: {
              type: "array",
              uniqueItems: true,
              description: "Complete ordered group IDs",
              items: uuid("Plan group"),
            },
            entries: {
              type: "array",
              description:
                "Complete ordered entry IDs and target groups, deposits included with null group",
              items: object({
                id: uuid("Plan entry"),
                group_id: {
                  ...uuid("Target group, null for ungrouped/deposits"),
                  nullable: true,
                },
              }),
            },
          },
          example: {
            kind: "withdrawal",
            name: "Groceries",
            amount_minor: 1234,
            label_ids: [],
          },
        },
      }),
    },
  },
  paths: {
    "/rest/v1/rpc/budgeteer_read": {
      servers: [{ url: "/" }],
      post: post(
        "Direct Supabase PostgREST RPC: owner/MFA monthly planning state, no creation on read",
        object({
          p_month: {
            ...string("First day of reporting month", "2026-11-01"),
            format: "date",
          },
        }),
        ref("BudgeteerState"),
      ),
    },
    "/rest/v1/rpc/budgeteer_mutate": {
      servers: [{ url: "/" }],
      post: {
        ...post(
          "Direct Supabase PostgREST RPC: serialized owner writes, atomic revision checks, canonical saved result",
          ref("BudgeteerMutation"),
          ref("BudgeteerState"),
        ),
        description:
          "sources_include appends every missing eligible posted nonzero transaction across all owner accounts for the reporting month, using posted_date then transaction_date. Transfers, card payments, budget-excluded activity, expense refunds and income reversals are excluded. Entries append deterministically by effective date then source UUID, withdrawals Ungrouped; existing values, snapshots, groups, labels and positions are untouched. sources_restore clears current-month exclusions then includes eligible sources in the same transaction. Both operations require exact revisions, enforce aggregate limits atomically and increment once only when state changes; a no-op leaves revision unchanged and an empty absent month remains absent. Other successful mutations create an absent plan. Owner-global label writes advance every owner plan revision and require opaque updated_at tokens on updates/deletes. Raw bank-source deletion preserves independent entries/snapshots, cascades exclusions and bumps affected plan revisions, including service-role account deletion/import undo. Plan deletion cascades exclusions. Exclusions identify transaction UUIDs, not newly assigned IDs on reimport. Reads and mutations never write bank tables. Tables allow owner/MFA SELECT only for browsers; direct browser writes are revoked. PostgREST errors use its native {code,message,details,hint} shape, with budgeteer_conflict identifiable in message (P0001). Other validation errors roll back all changes.",
      },
    },
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
        "Verify all owned selections and durably queue subscriptions and ingestion; replay returns the recorded acceptance without reactivating accounts",
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
    "/api/v1/connections/pending": {
      get: {
        summary:
          "List owner-initiated sessions available for explicit completion retry, without client secrets",
        security: [{ bearerAuth: [] }],
        responses: {
          "200": response(
            "Resumable owned sessions",
            object({
              sessions: {
                type: "array",
                description:
                  "Unaccepted connection sessions; no automatic subscriptions",
                items: object({
                  sessionId: string("Owned session ID", "fcsess_example"),
                  createdAt: {
                    ...string(
                      "Session creation timestamp",
                      "2026-11-10T00:00:00Z",
                    ),
                    format: "date-time",
                  },
                  status: string("Sanitized completion state", "pending"),
                }),
              },
            }),
          ),
          ...errorResponses,
        },
      },
    },
    "/api/v1/accounts/{id}/balance-refresh": {
      parameters: accountParameter,
      post: post(
        "Reserve one of 50 monthly UTC attempts and queue an explicitly confirmed paid refresh without an app cooldown; provider availability limits apply and ambiguous failures retain reservation",
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
    "/api/v1/accounts/{id}/subscription-retry": {
      parameters: accountParameter,
      post: post(
        "Explicitly retry an accepted transaction subscription using its existing durable identity; no new link or balance refresh",
        object({
          confirmCost: {
            type: "boolean",
            description:
              "Owner confirms ongoing daily transaction feed charges",
            example: true,
          },
        }),
        object({
          requestId: uuid("Existing subscription job"),
          status: string("Retry state", "queued"),
        }),
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
          "Owner/MFA-protected UTC monthly reserved attempts and cap eligibility; works while Stripe is disabled",
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
            description:
              "Existing version/currency/exportedAt and profiles/accounts/balance_snapshots/transactions/transaction_annotations/categories/monthly_budgets/import_batches fields are unchanged. Adds all owner-scoped Budgeteer storage rows; computed source_current/source_state are obtained through budgeteer_read, not stored in export.",
            properties: {
              budgeteer_plans: {
                type: "array",
                items: ref("BudgeteerPlan"),
                description: "All monthly plans",
              },
              budgeteer_groups: {
                type: "array",
                items: ref("BudgeteerGroup"),
                description: "All plan groups",
              },
              budgeteer_entries: {
                type: "array",
                items: {
                  type: "object",
                  description:
                    "BudgeteerEntry stored columns, excluding computed source_current/source_state",
                },
                description: "Independent entries and source snapshots",
              },
              budgeteer_labels: {
                type: "array",
                items: ref("BudgeteerLabel"),
                description: "Owner-global labels",
              },
              budgeteer_entry_labels: {
                type: "array",
                items: ref("BudgeteerEntryLabel"),
                description: "All entry assignments",
              },
              budgeteer_source_exclusions: {
                type: "array",
                items: ref("BudgeteerSourceExclusion"),
                description: "All persistent owner/month/source exclusions",
              },
            },
          }),
          ...errorResponses,
        },
      },
    },
  },
};
