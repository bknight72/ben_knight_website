import { ApiError, boundedBody, verifyWebhook } from "../_shared/core.ts";
import {
  Database,
  env,
  errorResponse,
  json,
  Stripe,
} from "../_shared/runtime.ts";

export async function handle(
  req: Request,
  db = new Database(),
): Promise<Response> {
  const requestId = crypto.randomUUID();
  try {
    if (req.method !== "POST") {
      throw new ApiError(405, "method_not_allowed", "Use POST.");
    }
    const stripe = new Stripe();
    const secret = env("STRIPE_WEBHOOK_SECRET");
    if (!secret) {
      throw new ApiError(
        503,
        "webhook_unconfigured",
        "Webhook is not configured.",
      );
    }
    const raw = await boundedBody(req, 262144);
    await verifyWebhook(raw, req.headers.get("stripe-signature") || "", secret);
    const event = JSON.parse(raw);
    if (
      !/^evt_[A-Za-z0-9]+$/.test(event.id) || event.livemode !== stripe.live
    ) {
      throw new ApiError(
        400,
        "invalid_event",
        "Webhook mode or identifier is invalid.",
      );
    }
    const kinds: Record<string, string> = {
      "financial_connections.account.refreshed_transactions": "sync",
      "financial_connections.account.refreshed_balance": "balance",
      "financial_connections.account.disconnected": "disconnect",
    };
    const kind = kinds[event.type];
    if (!kind) return json({ received: true, ignored: true });
    const providerId = event.data?.object?.id;
    if (
      typeof providerId !== "string" || !/^fca_[A-Za-z0-9]+$/.test(providerId)
    ) throw new ApiError(400, "invalid_event", "Account event is invalid.");
    const mapping = await db.state("mapping", { provider_id: providerId });
    // Unknown accounts are acknowledged without retaining their payload or IDs.
    if (!mapping.account_id) return json({ received: true, ignored: true });
    if (mapping.livemode !== stripe.live) {
      throw new ApiError(400, "mode_mismatch", "Account mode mismatch.");
    }
    // Balance webhook jobs read the already refreshed balance, never purchase another refresh.
    await db.state("webhook", {
      id: event.id,
      type: event.type,
      account_id: mapping.account_id,
      kind,
    });
    return json({ received: true });
  } catch (e) {
    return errorResponse(e, requestId);
  }
}
