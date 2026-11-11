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
        kind: {
          ...string(
            "Immutable group kind; existing groups default to withdrawal",
            "withdrawal",
          ),
          enum: ["deposit", "withdrawal"],
          default: "withdrawal",
        },
        parent_group_id: {
          ...uuid(
            "Optional global withdrawal parent belonging to the same owner; deposits require null; cycles rejected",
          ),
          nullable: true,
        },
        name: {
          ...string(
            "Trimmed nonempty group name, max 80 characters",
            "Essentials",
          ),
          maxLength: 80,
        },
        color_key: string(
          "Lowercase color key matching [a-z][a-z0-9_-]{0,31}; presets teal/blue/amber/rose/violet/slate or custom RGB hex_rrggbb",
          "teal",
        ),
        sort_position: {
          type: "integer",
          format: "int64",
          description:
            "Effective selected-month sibling order in reads, global default order in storage/export; stable ID breaks ties. DFS allocation visits direct entries then children, Ungrouped last",
          example: 0,
        },
      }),
      BudgeteerGroupState: object({
        owner_id: uuid("Provisioned owner; primary key"),
        revision: {
          type: "integer",
          format: "int64",
          minimum: 0,
          description:
            "Owner-global catalog revision returned as groups_revision",
          example: 1,
        },
      }),
      BudgeteerGroupPosition: object({
        owner_id: uuid("Provisioned owner"),
        plan_id: uuid("Monthly plan whose priority is overridden"),
        group_id: uuid("Owner-global group; composite key with plan_id"),
        sort_position: {
          type: "integer",
          format: "int64",
          description:
            "Monthly sibling priority; does not change global group definitions",
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
          ...uuid(
            "Optional same-kind global group belonging to the same owner; null means Ungrouped",
          ),
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
            "Archived label timestamp, read-only; active label mutations are retired",
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
      BudgeteerLegacyEntryLabel: object({
        id: uuid("Immutable archive record"),
        owner_id: uuid("Provisioned owner"),
        plan_id: uuid("Original monthly plan"),
        entry_id: uuid("Original withdrawal ID, retained after entry deletion"),
        label_id: uuid("Archived owner label"),
        entry_snapshot: {
          type: "object",
          description:
            "Immutable original stored withdrawal fields, including identity, name, amount and source snapshot",
          example: {
            id: "00000000-0000-4000-8000-000000000001",
            kind: "withdrawal",
            name: "Groceries",
            amount_minor: 1234,
          },
        },
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
        schema_version: {
          type: "integer",
          enum: [4],
          description: "Required owner-global groups contract version",
          example: 4,
        },
        owner_id: uuid("Provisioned owner, present even when plan is null"),
        groups_revision: {
          type: "integer",
          format: "int64",
          minimum: 0,
          description:
            "Owner-global catalog revision, present even when plan is null",
          example: 0,
        },
        plan: {
          allOf: [ref("BudgeteerPlan")],
          nullable: true,
          description: "Null for an absent plan; reads do not create rows",
        },
        groups: {
          type: "array",
          description:
            "All owner-global groups with effective selected-month sort_position, including when plan is null; no plan_id on groups",
          items: ref("BudgeteerGroup"),
        },
        entries: {
          type: "array",
          description:
            "Canonical entries; clients allocate withdrawals in DFS sibling order, direct entries before children, Ungrouped last",
          items: ref("BudgeteerEntry"),
        },
        legacy_labels: {
          type: "array",
          description:
            "Read-only archived owner labels, including when plan is absent",
          items: ref("BudgeteerLabel"),
        },
        legacy_entry_labels: {
          type: "array",
          description:
            "Immutable archived associations for this plan; survives entry deletion",
          items: ref("BudgeteerLegacyEntryLabel"),
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
            "Exact last returned plan revision, or 0 when absent. Stale monthly or global revision raises budgeteer_conflict with no partial writes",
          example: 0,
        },
        p_operation: {
          type: "string",
          enum: [
            "entry_save",
            "entry_delete",
            "group_save",
            "group_delete",
            "initialize",
            "legacy_label_convert",
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
            "EVERY operation requires numeric schema_version:4 and expected_groups_revision from the last read, even when plan is null; missing, stale or string schema markers fail with budgeteer_schema_upgrade_required before writes. Stale monthly or global revisions raise budgeteer_conflict. entry_save requires kind/name/amount_minor and optional id/group_id/source_transaction_id; group_id must match entry kind and owner; omit retired label_ids. group_save requires name/color_key/parent_group_id (nullable), optional id and immutable kind (default withdrawal); definitions are global. Deposit groups require null parent; withdrawal parents must be same-owner withdrawal groups. group_delete ungroups directly assigned entries in ALL months, promotes immediate children to the deleted group's parent and updates affected monthly revisions; descendants, amounts, source links/snapshots and exclusions persist. initialize, sources_include and sources_restore use {schema_version:4,expected_groups_revision:0} with the actual returned revision; no automatic copying. groups_copy and label operations are retired. legacy_label_convert requires confirmed:true,label_id,entry_ids and either a withdrawal group_id or name/color_key/parent_group_id for a new global withdrawal group; only selected monthly entries move. Archives persist. reorder requires complete unique groups:[UUID] of BOTH kinds and entries:[{id,group_id:UUID|null}] of BOTH kinds, with same-kind targets; it changes only selected-month priority and assignments. entry_delete/source_refresh/source_unlink require id. Source validation and exclusions remain enforced.",
          required: ["schema_version", "expected_groups_revision"],
          properties: {
            schema_version: {
              type: "integer",
              enum: [4],
              description:
                "Required on every mutation; exact numeric client contract marker",
              example: 4,
            },
            expected_groups_revision: {
              type: "integer",
              format: "int64",
              minimum: 0,
              description:
                "Required exact groups_revision from the last read, including absent-plan reads; stale cross-month edits conflict",
              example: 0,
            },
            id: uuid("Existing object ID; omit on create"),
            kind: {
              type: "string",
              enum: ["deposit", "withdrawal"],
              description:
                "Entry kind or immutable group kind; group_save defaults to withdrawal",
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
            group_id: { ...uuid("Same-kind group or null"), nullable: true },
            source_transaction_id: {
              ...uuid(
                "Optional eligible bank source; omitted on existing entry preserves source",
              ),
              nullable: true,
            },
            color_key: string("Palette key or custom RGB hex_rrggbb", "teal"),
            parent_group_id: {
              ...uuid(
                "Explicit same-owner global withdrawal parent; null for top level and all deposit groups",
              ),
              nullable: true,
            },
            confirmed: {
              type: "boolean",
              description: "Explicit archived-label conversion confirmation",
              example: true,
            },
            label_id: uuid("Archived label to review"),
            entry_ids: {
              type: "array",
              uniqueItems: true,
              description:
                "Explicitly selected monthly withdrawals carrying the archived label",
              items: uuid("Chosen withdrawal"),
            },
            groups: {
              type: "array",
              uniqueItems: true,
              description:
                "Complete ordered global group IDs of both kinds; priority is stored for the selected month only",
              items: uuid("Global group"),
            },
            entries: {
              type: "array",
              description:
                "Complete ordered entry IDs of both kinds and same-kind target groups",
              items: object({
                id: uuid("Plan entry"),
                group_id: {
                  ...uuid("Same-kind target group, null for Ungrouped"),
                  nullable: true,
                },
              }),
            },
          },
          example: {
            schema_version: 4,
            expected_groups_revision: 0,
            kind: "withdrawal",
            name: "Groceries",
            amount_minor: 1234,
            group_id: null,
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
          "Signature remains p_month,p_revision,p_operation,p_payload. Every operation requires numeric p_payload.schema_version:4 and expected_groups_revision. Old or invalid schema markers fail closed with budgeteer_schema_upgrade_required before writes; stale monthly/global revisions raise budgeteer_conflict. Owner advisory locking serializes cross-month edits. Groups are owner-global with shared IDs, kinds, names, colors and withdrawal hierarchy, including absent-plan reads. Group deletion ungroups direct entries in every month and promotes children, preserving entries, amounts, sources, snapshots and exclusions; affected monthly revisions advance. Monthly priority is separate from global definitions. initialize and source inclusion never copy groups; groups_copy and copy previews are retired. Source inclusion appends both kinds Ungrouped without changing saved entries; refresh preserves assignments. Owner/MFA, complete reorder membership, immutable group kind, same-kind assignments, same-owner parents and cycle prevention are enforced server-side. Deposit groups stay flat. Archives remain read-only; conversion targets withdrawals only. Direct browser writes are revoked. PostgREST errors use native {code,message,details,hint}; budgeteer_conflict requires reload/review. Validation errors roll back all changes.",
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
              "Complete owner-scoped table enumeration below; version/currency/exportedAt and existing financial fields remain unchanged. Includes global catalog revision and monthly priority rows. Global groups have no plan_id and their stored sort_position is the default, not an effective monthly override. Computed source_current/source_state are obtained through budgeteer_read, not stored in export. Formula-leading strings are escaped for safety; this sensitive portable download is not a database backup.",
            properties: {
              version: {
                type: "integer",
                enum: [1],
                description: "Portable export format version",
                example: 1,
              },
              currency: { ...string("Export currency", "USD"), enum: ["USD"] },
              exportedAt: {
                ...string("Export timestamp", "2026-11-11T00:00:00Z"),
                format: "date-time",
              },
              ...Object.fromEntries([
                "profiles",
                "accounts",
                "balance_snapshots",
                "transactions",
                "transaction_annotations",
                "categories",
                "monthly_budgets",
                "import_batches",
              ].map((table) => [table, {
                type: "array",
                description: `All owner-scoped ${table} storage rows`,
                items: { type: "object" },
              }])),
              budgeteer_plans: {
                type: "array",
                items: ref("BudgeteerPlan"),
                description: "All monthly plans",
              },
              budgeteer_groups: {
                type: "array",
                items: ref("BudgeteerGroup"),
                description:
                  "All owner-global groups with stable IDs, kinds, hierarchy, colors and default order; no plan_id",
              },
              budgeteer_group_state: {
                type: "array",
                items: ref("BudgeteerGroupState"),
                description: "Owner-global revision state",
              },
              budgeteer_group_positions: {
                type: "array",
                items: ref("BudgeteerGroupPosition"),
                description:
                  "All monthly group priority overrides, ordered by plan_id and group_id for pagination",
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
              budgeteer_legacy_entry_labels: {
                type: "array",
                items: ref("BudgeteerLegacyEntryLabel"),
                description:
                  "Immutable archived associations and original withdrawal snapshots, including deleted entries",
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
