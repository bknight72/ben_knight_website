import {
  ApiError,
  constantTimeEqual,
  stripeTransaction,
} from "../_shared/core.ts";
import {
  Database,
  env,
  errorResponse,
  json,
  metric,
  type RecordData,
  Stripe,
} from "../_shared/runtime.ts";

export async function processJob(
  job: RecordData,
  db: Database,
  stripe: Stripe,
  deadline: number,
) {
  const mapping = await db.state("mapping", { account_id: job.account_id });
  if (!mapping.provider_id || mapping.livemode !== stripe.live) {
    throw new ApiError(
      503,
      "mapping_mismatch",
      "Provider mapping is unavailable.",
    );
  }
  const account =
    (await db.call(`accounts?id=eq.${job.account_id}&select=*`))[0];
  const path = `financial_connections/accounts/${mapping.provider_id}`;
  const renew = () =>
    db.state("job_renew", { id: job.id, lease_token: job.lease_token });
  const providerAccount = async () => {
    await renew();
    const provider = await stripe.call(path);
    if (
      provider.livemode !== stripe.live ||
      provider.account_holder?.customer !== mapping.customer_id
    ) {
      throw new ApiError(
        503,
        "mapping_mismatch",
        "Provider account ownership or mode does not match.",
      );
    }
    return provider;
  };
  const activeProvider = async () => {
    const provider = await providerAccount();
    if (
      provider.status !== "active" ||
      !provider.permissions?.includes("balances") ||
      !provider.permissions?.includes("transactions")
    ) {
      throw new ApiError(
        409,
        "connection_inactive",
        "The provider connection is inactive or lacks permissions.",
      );
    }
    return provider;
  };
  if (job.kind === "disconnect") {
    const provider = await providerAccount();
    if (provider.subscriptions?.includes("transactions")) {
      await renew();
      await stripe.call(`${path}/unsubscribe`, "POST", {
        "features[]": "transactions",
      }, `unsubscribe:${job.id}`);
    }
    if (provider.status !== "disconnected") {
      await renew();
      await stripe.call(
        `${path}/disconnect`,
        "POST",
        {},
        `disconnect:${job.id}`,
      );
    }
    const after = await providerAccount();
    if (
      after.status !== "disconnected" ||
      after.subscriptions?.includes("transactions")
    ) {
      throw new ApiError(
        503,
        "provider_unavailable",
        "Provider cleanup is not yet complete.",
      );
    }
    await db.state("disconnected", {
      id: job.id,
      lease_token: job.lease_token,
    });
  } else if (job.kind === "lifecycle") {
    const provider = await providerAccount();
    if (!["active", "inactive", "disconnected"].includes(provider.status)) {
      throw new ApiError(
        503,
        "connection_inactive",
        "The provider state is unavailable.",
      );
    }
    await db.state("lifecycle", {
      id: job.id,
      lease_token: job.lease_token,
      provider_status: provider.status === "active" &&
          (!provider.permissions?.includes("balances") ||
            !provider.permissions?.includes("transactions"))
        ? "inactive"
        : provider.status,
    });
    return;
  } else if (
    !account ||
    ["disconnecting", "disconnected"].includes(account.connection_state) ||
    mapping.disconnect_requested_at
  ) {
    // Queued work after disconnect must never restore subscriptions or buy a balance.
  } else if (job.kind === "subscribe") {
    stripe.requireActivity();
    let provider = await activeProvider();
    if (!provider.subscriptions?.includes("transactions")) {
      await db.state("subscribe_started", {
        id: job.id,
        lease_token: job.lease_token,
      });
      await stripe.call(`${path}/subscribe`, "POST", {
        "features[]": "transactions",
      }, job.dedupe_key);
      // Never infer current subscription state from a cached idempotent POST response.
      provider = await activeProvider();
    }
    if (!provider.subscriptions?.includes("transactions")) {
      throw new ApiError(
        503,
        "subscription_pending",
        "Transaction subscription is still pending.",
      );
    }
    await db.state("subscribe_finish", {
      id: job.id,
      lease_token: job.lease_token,
    });
    return;
  } else if (job.kind === "balance") {
    let provider = await activeProvider();
    if (job.dedupe_key.startsWith("refresh:")) {
      stripe.requireActivity();
      const completedAfterDispatch = job.paid_started &&
        Number.isFinite(Date.parse(job.balance_dispatch_at)) &&
        Number.isSafeInteger(provider.balance?.as_of) &&
        provider.balance.as_of > (job.balance_baseline ?? 0) &&
        provider.balance.as_of >=
          Math.floor(Date.parse(job.balance_dispatch_at) / 1000) &&
        provider.balance_refresh?.status === "succeeded";
      if (!completedAfterDispatch) {
        const next = provider.balance_refresh?.next_refresh_available_at;
        // Before paid dispatch respect availability. After durable dispatch marking, retries
        // replay the same idempotency key because provider acceptance may be ambiguous.
        if (
          !job.paid_started && provider.balance_refresh &&
          (!next || next * 1000 > Date.now())
        ) {
          throw new ApiError(
            429,
            "provider_cooldown",
            "Provider balance refresh is not available yet.",
          );
        }
        // Reservation is permanent. Retry uses the same provider idempotency key.
        // Never reissue a paid call after Stripe's >=24h idempotency retention window.
        if (Date.now() - Date.parse(job.created_at) > 23 * 3600000) {
          throw new ApiError(
            503,
            "refresh_expired",
            "Refresh reservation expired; inspect provider state before retrying.",
          );
        }
        await db.state("balance_started", {
          id: job.id,
          lease_token: job.lease_token,
          baseline_as_of: Number.isSafeInteger(provider.balance?.as_of)
            ? provider.balance.as_of
            : null,
        });
        await stripe.call(
          `${path}/refresh`,
          "POST",
          { "features[]": "balance" },
          job.dedupe_key,
        );
        // Refresh responses are asynchronous and idempotent responses may remain cached as pending.
        provider = await activeProvider();
      }
    }
    if (provider.balance_refresh?.status !== "succeeded") {
      throw new ApiError(
        503,
        provider.balance_refresh?.status === "failed"
          ? "balance_failed"
          : "balance_not_ready",
        "Balance refresh is pending or failed.",
      );
    }
    const balance = provider.balance;
    if (balance?.current?.usd !== undefined) {
      const current = balance.current.usd,
        available = balance.cash?.available?.usd ?? null;
      if (
        !Number.isSafeInteger(balance.as_of) || balance.as_of <= 0 ||
        !Number.isSafeInteger(current) || Math.abs(current) > 9000000000000 ||
        (available !== null &&
          (!Number.isSafeInteger(available) ||
            Math.abs(available) > 9000000000000))
      ) {
        throw new ApiError(
          422,
          "invalid_balance",
          "Provider returned invalid USD balance.",
        );
      }
      // Retain Stripe's signed balance: negative means owed by the holder.
      // Readers normalize credit liabilities using the snapshot's stripe source.
      await db.state(
        "balance_snapshot",
        {
          id: job.id,
          lease_token: job.lease_token,
          current_minor: current,
          available_minor: available,
          observed_at: new Date(balance.as_of * 1000).toISOString(),
        },
      );
    } else {
      throw new ApiError(
        422,
        "balance_unavailable",
        "A USD balance is unavailable for this account.",
      );
    }
  } else if (job.kind === "sync") {
    const provider = await activeProvider();
    if (provider.transaction_refresh?.status !== "succeeded") {
      throw new ApiError(
        503,
        provider.transaction_refresh?.status === "failed"
          ? "transactions_failed"
          : "transactions_not_ready",
        "Transaction refresh is pending or failed.",
      );
    }
    let cursor = job.cursor;
    for (let pages = 0; pages < 10 && Date.now() < deadline; pages++) {
      await renew();
      const page = await stripe.call(
        "financial_connections/transactions",
        "GET",
        { account: mapping.provider_id, limit: 100, starting_after: cursor },
      );
      if (!Array.isArray(page.data) || (page.has_more && !page.data.length)) {
        throw new ApiError(
          503,
          "invalid_provider_page",
          "Provider returned an invalid transaction page.",
        );
      }
      for (const transaction of page.data) {
        if (
          transaction.account !== mapping.provider_id ||
          transaction.livemode !== stripe.live
        ) {
          throw new ApiError(
            503,
            "transaction_mismatch",
            "Transaction mapping or mode mismatch.",
          );
        }
      }
      cursor = page.data.at(-1)?.id || cursor;
      await db.state("page", {
        id: job.id,
        lease_token: job.lease_token,
        rows: page.data.map(stripeTransaction),
        cursor,
      });
      if (!page.has_more) {
        await db.state("finish", { id: job.id, lease_token: job.lease_token });
        return;
      }
    }
    // Pagination is progress, not failure; large histories must not exhaust the retry budget.
    await db.state("yield", { id: job.id, lease_token: job.lease_token });
    return;
  } else {throw new ApiError(
      422,
      "invalid_job",
      "Unsupported worker operation.",
    );}
  await db.state("finish", { id: job.id, lease_token: job.lease_token });
}

export async function handle(
  req: Request,
  db = new Database(),
): Promise<Response> {
  const requestId = crypto.randomUUID();
  try {
    const secret = env("WORKER_SECRET") || "";
    if (
      !secret ||
      !constantTimeEqual(
        req.headers.get("authorization") || "",
        `Bearer ${secret}`,
      )
    ) {
      throw new ApiError(
        401,
        "unauthenticated",
        "Trusted worker authorization is required.",
      );
    }
    if (req.method !== "POST") {
      throw new ApiError(405, "method_not_allowed", "Use POST.");
    }
    const stripe = new Stripe(fetch, true);
    await db.state("recovery");
    const deadline = Date.now() + 45000;
    let processed = 0, failed = 0;
    for (let i = 0; i < 4 && Date.now() < deadline; i++) {
      const job = await db.state("claim");
      if (!job.id) break;
      const begin = Date.now();
      try {
        await processJob(job, db, stripe, deadline);
        processed++;
        await metric(db, `worker/${job.kind}`, "POST", 200, Date.now() - begin);
      } catch (error) {
        try {
          await db.state("retry", {
            id: job.id,
            lease_token: job.lease_token,
            error: error instanceof ApiError
              ? error.code
              : "provider_unavailable",
          });
        } catch {
          // Lease loss means a newer worker owns recovery. Do not overwrite its state.
        }
        failed++;
        await metric(db, `worker/${job.kind}`, "POST", 503, Date.now() - begin);
      }
    }
    return json({ processed, failed });
  } catch (e) {
    return errorResponse(e, requestId);
  }
}
