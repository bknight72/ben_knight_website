export class ApiError extends Error {
  constructor(
    public status: number,
    public code: string,
    message: string,
    public retryAt?: string,
  ) {
    super(message);
  }
}

export const MAX_BYTES = 5 * 1024 * 1024;
export const MAX_ROWS = 10000;
export const UUID =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export function id(value: unknown): string {
  if (typeof value !== "string" || !UUID.test(value)) {
    throw new ApiError(422, "invalid_id", "A valid identifier is required.");
  }
  return value;
}
export function invalid(message: string): never {
  throw new ApiError(422, "invalid_data", message);
}
export function minorUnits(input: string): number {
  const value = input.trim();
  if (!/^-?(?:0|[1-9]\d{0,10})(?:\.\d{1,2})?$/.test(value)) {
    invalid(
      "Money must be an ungrouped decimal with at most two decimal places.",
    );
  }
  const negative = value.startsWith("-");
  const [whole, fraction = ""] = value.replace("-", "").split(".");
  const amount = Number(whole) * 100 + Number(fraction.padEnd(2, "0"));
  if (amount > 9000000000000) invalid("Money exceeds the supported range.");
  return negative ? -amount : amount;
}

export function csvParse(csv: string): string[][] {
  if (new TextEncoder().encode(csv).length > MAX_BYTES) {
    invalid("CSV exceeds 5 MB.");
  }
  if (csv.includes("\0")) invalid("CSV contains null bytes.");
  const rows: string[][] = [];
  let row: string[] = [], field = "", quoted = false, closed = false;
  const pushField = () => {
    row.push(field);
    field = "";
    closed = false;
    if (row.length > 100) invalid("CSV exceeds 100 columns.");
  };
  const pushRow = () => {
    pushField();
    if (row.some((v) => v !== "")) rows.push(row);
    row = [];
    if (rows.length > MAX_ROWS + 1) invalid("CSV exceeds 10,000 rows.");
  };
  for (let i = 0; i < csv.length; i++) {
    const ch = csv[i];
    if (quoted) {
      if (ch === '"') {
        if (csv[i + 1] === '"') {
          field += '"';
          i++;
        } else {
          quoted = false;
          closed = true;
        }
      } else field += ch;
    } else if (ch === "," || ch === "\n" || ch === "\r") {
      if (ch === ",") pushField();
      else {
        pushRow();
        if (ch === "\r" && csv[i + 1] === "\n") i++;
      }
    } else if (ch === '"') {
      if (field || closed) invalid("Unexpected quote in CSV.");
      quoted = true;
    } else {
      if (closed) invalid("Unexpected text after quoted field.");
      field += ch;
    }
    if (field.length > 2000) invalid("CSV field exceeds 2,000 characters.");
  }
  if (quoted) invalid("Unterminated CSV quote.");
  if (field || row.length || closed) pushRow();
  return rows;
}

export interface Mapping {
  date: string;
  description: string;
  amount?: string;
  debit?: string;
  credit?: string;
  transactionId?: string;
  currency?: string;
  dateFormat: "YYYY-MM-DD" | "MM/DD/YYYY" | "DD/MM/YYYY";
  sign: "inflow-positive" | "outflow-positive";
}
export interface ImportRow {
  source_id: string;
  amount_minor: number;
  description: string;
  transaction_date: string;
}
export function dateValue(
  value: string,
  format: Mapping["dateFormat"],
): string {
  let y: number, m: number, d: number;
  if (format === "YYYY-MM-DD" && /^\d{4}-\d{2}-\d{2}$/.test(value)) {
    [y, m, d] = value.split("-").map(Number);
  } else if (
    (format === "MM/DD/YYYY" || format === "DD/MM/YYYY") &&
    /^\d{2}\/\d{2}\/\d{4}$/.test(value)
  ) {
    const parts = value.split("/").map(Number);
    y = parts[2];
    m = parts[format === "MM/DD/YYYY" ? 0 : 1];
    d = parts[format === "MM/DD/YYYY" ? 1 : 0];
  } else invalid("Date does not match the selected format.");
  const date = new Date(Date.UTC(y, m - 1, d));
  if (
    y < 1900 || y > 2200 || date.getUTCMonth() !== m - 1 ||
    date.getUTCDate() !== d
  ) invalid("Invalid calendar date.");
  return date.toISOString().slice(0, 10);
}
export async function sha256(value: string): Promise<string> {
  return [
    ...new Uint8Array(
      await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value)),
    ),
  ].map((b) => b.toString(16).padStart(2, "0")).join("");
}
export async function parseImport(csv: string, mapping: Mapping) {
  if (
    !mapping || !["inflow-positive", "outflow-positive"].includes(mapping.sign)
  ) invalid("An explicit sign mapping is required.");
  if (
    !["YYYY-MM-DD", "MM/DD/YYYY", "DD/MM/YYYY"].includes(mapping.dateFormat)
  ) invalid("An explicit date format is required.");
  const parsed = csvParse(csv.replace(/^\uFEFF/, ""));
  if (parsed.length < 2) {
    invalid("CSV requires a header and at least one data row.");
  }
  const header = parsed.shift()!.map((s) => s.trim());
  if (new Set(header).size !== header.length || header.some((h) => !h)) {
    invalid("Headers must be nonempty and unique.");
  }
  const fields = [
    mapping.date,
    mapping.description,
    mapping.amount,
    mapping.debit,
    mapping.credit,
    mapping.transactionId,
    mapping.currency,
  ].filter(Boolean);
  if (fields.some((f) => !header.includes(f!))) {
    invalid("Mapped column was not found.");
  }
  if (
    !mapping.date || !mapping.description ||
    (!!mapping.amount === !!(mapping.debit && mapping.credit)) ||
    (mapping.amount && (mapping.debit || mapping.credit))
  ) invalid("Map either amount or both debit and credit columns.");
  const rows: ImportRow[] = [], errors: { row: number; message: string }[] = [];
  const occurrences = new Map<string, number>();
  for (let i = 0; i < parsed.length; i++) {
    try {
      if (parsed[i].length !== header.length) {
        invalid("Column count does not match the header.");
      }
      const get = (key?: string) =>
        key ? parsed[i][header.indexOf(key)].trim() : "";
      if (mapping.currency && get(mapping.currency).toUpperCase() !== "USD") {
        invalid("Only USD is supported.");
      }
      const description = get(mapping.description);
      if (description.length > 500) {
        invalid("Description exceeds 500 characters.");
      }
      const transaction_date = dateValue(get(mapping.date), mapping.dateFormat);
      let amount_minor: number;
      if (mapping.amount) {
        amount_minor = minorUnits(get(mapping.amount)) *
          (mapping.sign === "outflow-positive" ? -1 : 1);
      } else {
        const debit = minorUnits(get(mapping.debit) || "0"),
          credit = minorUnits(get(mapping.credit) || "0");
        if (debit < 0 || credit < 0 || (debit !== 0 && credit !== 0)) {
          invalid(
            "Debit and credit must be nonnegative and not both populated.",
          );
        }
        amount_minor = credit - debit;
      }
      const bankId = get(mapping.transactionId);
      if (mapping.transactionId && (!bankId || bankId.length > 180)) {
        invalid("Bank transaction ID must contain 1-180 characters.");
      }
      const identity = await sha256(
        JSON.stringify([transaction_date, amount_minor, description]),
      );
      const occurrence = (occurrences.get(identity) || 0) + 1;
      occurrences.set(identity, occurrence);
      rows.push({
        source_id: bankId ? `bank:${bankId}` : `row:${identity}:${occurrence}`,
        amount_minor,
        description,
        transaction_date,
      });
    } catch (e) {
      if (e instanceof ApiError) {
        if (errors.length < 100) {
          errors.push({ row: i + 2, message: e.message });
        }
      } else throw e;
    }
  }
  // Mapping is part of the identity so a corrected sign/date mapping is not silently ignored.
  const fingerprint = await sha256(
    JSON.stringify([csv, Object.fromEntries(Object.entries(mapping).sort())]),
  );
  return { rows, errors, fingerprint, rowCount: parsed.length };
}

export function constantTimeEqual(a: string, b: string): boolean {
  let diff = a.length ^ b.length;
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    diff |= (a.charCodeAt(i) || 0) ^ (b.charCodeAt(i) || 0);
  }
  return diff === 0;
}
export async function verifyWebhook(
  body: string,
  header: string,
  secret: string,
  now = Date.now(),
): Promise<void> {
  const parts = header.split(",").map((p) => p.split("="));
  const timestamp = parts.find(([k]) => k === "t")?.[1];
  if (
    !timestamp || !/^\d+$/.test(timestamp) ||
    Math.abs(now / 1000 - Number(timestamp)) > 300
  ) throw new ApiError(400, "invalid_signature", "Invalid webhook signature.");
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = [
    ...new Uint8Array(
      await crypto.subtle.sign(
        "HMAC",
        key,
        new TextEncoder().encode(`${timestamp}.${body}`),
      ),
    ),
  ].map((b) => b.toString(16).padStart(2, "0")).join("");
  if (
    !parts.some(([k, value]) =>
      k === "v1" && constantTimeEqual(signature, value || "")
    )
  ) throw new ApiError(400, "invalid_signature", "Invalid webhook signature.");
}

export function stripeMode(
  env: (key: string) => string | undefined,
): { enabled: boolean; live: boolean } {
  if (env("STRIPE_ENABLED") !== "true") return { enabled: false, live: false };
  const mode = env("STRIPE_MODE"), key = env("STRIPE_SECRET_KEY") || "";
  if (
    !["test", "live"].includes(mode || "") ||
    !key.startsWith(mode === "live" ? "sk_live_" : "sk_test_")
  ) {
    throw new ApiError(
      503,
      "stripe_configuration",
      "Stripe mode is not configured safely.",
    );
  }
  if (mode === "live" && env("STRIPE_LIVE_AUTHORIZED") !== "true") {
    throw new ApiError(
      503,
      "live_not_authorized",
      "Live Stripe access has not been authorized.",
    );
  }
  return { enabled: true, live: mode === "live" };
}
export function reportingDate(seconds: number): string {
  if (!Number.isSafeInteger(seconds)) invalid("Invalid provider timestamp.");
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: "America/Denver",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(new Date(seconds * 1000));
  const part = (name: string) => parts.find((p) => p.type === name)!.value;
  return `${part("year")}-${part("month")}-${part("day")}`;
}
export function stripeTransaction(
  t: Record<string, any>,
): Record<string, unknown> {
  if (
    t.currency !== "usd" || !Number.isSafeInteger(t.amount) ||
    Math.abs(t.amount) > 9000000000000 ||
    !["pending", "posted", "void"].includes(t.status)
  ) invalid("Unsupported provider transaction.");
  // Stripe Financial Connections uses positive inflows and negative outflows.
  return {
    source_id: t.id,
    amount_minor: t.amount,
    description: String(t.description || "").slice(0, 500),
    transaction_date: reportingDate(t.transacted_at),
    posted_date: t.status_transitions?.posted_at
      ? reportingDate(t.status_transitions.posted_at)
      : null,
    status: t.status,
    provider_updated: t.updated,
  };
}
export function safeExport(value: unknown): unknown {
  if (typeof value === "string") {
    return /^[\s]*[=+@\-\t\r]/.test(value) ? `'${value}` : value;
  }
  if (Array.isArray(value)) return value.map(safeExport);
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value).map(([k, v]) => [k, safeExport(v)]),
    );
  }
  return value;
}

export async function boundedBody(
  req: Request,
  max = MAX_BYTES + 65536,
): Promise<string> {
  if (Number(req.headers.get("content-length")) > max) {
    throw new ApiError(
      413,
      "payload_too_large",
      "Request exceeds the upload limit.",
    );
  }
  const reader = req.body?.getReader();
  if (!reader) return "";
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.length;
      if (size > max) {
        await reader.cancel();
        throw new ApiError(
          413,
          "payload_too_large",
          "Request exceeds the upload limit.",
        );
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.length;
  }
  return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
}
