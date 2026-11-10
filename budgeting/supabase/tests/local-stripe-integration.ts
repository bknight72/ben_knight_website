type Call = (
  path: string,
  token?: string,
  method?: string,
  body?: unknown,
  expected?: number,
) => Promise<any>;

export async function stripeIntegration(
  call: Call,
  token: string,
  low: string,
  wrong: string,
) {
  const root = "/functions/v1/api/api/v1";
  const assert = (ok: unknown, message: string) => {
    if (!ok) throw new Error(message);
  };
  const control = async (body: unknown) => {
    const response = await fetch("http://127.0.0.1:58082/control", {
      method: "POST",
      body: JSON.stringify(body),
    });
    assert(response.ok, "Synthetic Stripe control failed");
  };
  const inspect = async () =>
    (await fetch("http://127.0.0.1:58082/inspect")).json();
  const worker = () =>
    call("/functions/v1/worker", "local-synthetic-worker-only", "POST", {});
  const account = async (id: string) =>
    (await call(`/rest/v1/accounts?id=eq.${id}&select=*`, token))[0];
  const webhook = async (id: string, type: string, provider: string) => {
    const raw = JSON.stringify({
      id,
      type: `financial_connections.account.${type}`,
      livemode: false,
      data: { object: { id: provider } },
    });
    const t = Math.floor(Date.now() / 1000);
    const key = await crypto.subtle.importKey(
      "raw",
      new TextEncoder().encode("whsec_localSyntheticOnly"),
      { name: "HMAC", hash: "SHA-256" },
      false,
      ["sign"],
    );
    const signature = [
      ...new Uint8Array(
        await crypto.subtle.sign(
          "HMAC",
          key,
          new TextEncoder().encode(`${t}.${raw}`),
        ),
      ),
    ].map((n) => n.toString(16).padStart(2, "0")).join("");
    const response = await fetch(
      `${Deno.env.get("LOCAL_SUPABASE_URL")}/functions/v1/stripe-webhook`,
      {
        method: "POST",
        headers: {
          "stripe-signature": `t=${t},v1=${signature}`,
          "Content-Type": "application/json",
        },
        body: raw,
      },
    );
    assert(response.status === 200, "Signed local webhook was rejected");
  };
  for (
    const [credential, status] of [[Deno.env.get("LOCAL_ANON_KEY")!, 401], [
      low,
      403,
    ], [wrong, 403]] as const
  ) {
    await call(
      `${root}/connections/pending`,
      credential,
      "GET",
      undefined,
      status,
    );
    await call(`${root}/connections/session`, credential, "POST", {}, status);
    await call(`${root}/connections/complete`, credential, "POST", {
      sessionId: "fcsess_local1",
    }, status);
  }
  assert(
    (await inspect()).requests.length === 0,
    "Owner/MFA denial reached Stripe",
  );
  const session = await call(`${root}/connections/session`, token, "POST", {});
  const pending = await call(`${root}/connections/pending`, token);
  assert(
    pending.sessions.some((s: any) => s.sessionId === session.sessionId),
    "Session not resumable",
  );
  assert(
    !JSON.stringify(pending).includes("secret"),
    "Pending summary leaked client secret",
  );
  await call(`${root}/connections/complete`, token, "POST", {
    sessionId: session.sessionId,
  }, 422);
  assert(
    !(await inspect()).requests.some((r: any) => r.path.endsWith("/subscribe")),
    "Empty consent subscribed",
  );
  await control({ sessionId: session.sessionId, subscriptionFailures: 3 });
  const result = await call(`${root}/connections/complete`, token, "POST", {
    sessionId: session.sessionId,
  });
  assert(
    result.status === "queued" && result.accountIds.length === 1,
    "Completion did not durably queue subscription",
  );
  const id = result.accountIds[0];
  assert(
    (await account(id)).sync_error === "subscription_pending",
    "Missing pending subscription state",
  );
  const beforeReplay = (await inspect()).requests.length;
  const replay = await call(`${root}/connections/complete`, token, "POST", {
    sessionId: session.sessionId,
  });
  assert(
    JSON.stringify(replay) === JSON.stringify(result),
    "Completed replay changed result",
  );
  assert(
    (await inspect()).requests.length === beforeReplay,
    "Completed replay contacted Stripe",
  );
  assert(
    !(await call(`${root}/connections/pending`, token)).sessions.length,
    "Accepted session remained pending",
  );
  const failed = await worker();
  assert(failed.failed >= 1, "Synthetic subscribe failure not exercised");
  assert(
    (await account(id)).sync_error === "provider_unavailable",
    "Subscription failure not durable",
  );
  // Advance only the synthetic job's scheduler, not wall time or production logic.
  const advanced = await new Deno.Command("docker", {
    args: [
      "exec",
      "supabase_db_private-budgeting",
      "psql",
      "-U",
      "postgres",
      "-v",
      "ON_ERROR_STOP=1",
      "-c",
      `update private.jobs set available_at=now() where account_id='${id}' and status='queued';`,
    ],
    stdout: "null",
    stderr: "piped",
  }).output();
  assert(advanced.success, "Could not advance disposable subscription retry");
  await worker();
  const state = await inspect(), provider = state.accounts[0].id;
  assert(
    state.accounts[0].subscriptions.includes("transactions"),
    "Subscription retry failed",
  );
  const subscribe = state.requests.filter((r: any) =>
    r.path.endsWith("/subscribe")
  );
  assert(
    subscribe.length === 4 &&
      new Set(subscribe.map((r: any) => r.key)).size === 1 && subscribe[0].key,
    "Retry changed subscription idempotency identity",
  );
  assert(
    !state.requests.some((r: any) => r.path.endsWith("/refresh")),
    "Linking prefetched paid balances",
  );
  assert(state.customerCount === 1, "Resume created another customer");
  const transactions = await call(
    `/rest/v1/transactions?account_id=eq.${id}&select=*`,
    token,
  );
  assert(
    transactions.length === 2 &&
      transactions.some((t: any) => t.amount_minor === -1234) &&
      transactions.some((t: any) => t.amount_minor === 234),
    "Paginated Stripe transaction writes/signs did not persist",
  );
  const categories = await call("/rest/v1/categories?select=id", token);
  const ownerId = (await account(id)).owner_id;
  await call("/rest/v1/transaction_annotations", token, "POST", {
    owner_id: ownerId,
    transaction_id: transactions[0].id,
    category_id: categories[0].id,
    note: "Synthetic retained annotation",
  }, 201);
  await webhook("evt_localTransactions", "refreshed_transactions", provider);
  await webhook("evt_localTransactions", "refreshed_transactions", provider);
  await worker();
  assert(
    (await call(`/rest/v1/transactions?account_id=eq.${id}&select=id`, token))
      .length === 2,
    "Transaction replay duplicated rows",
  );
  assert(
    (await call(
      `/rest/v1/transaction_annotations?transaction_id=eq.${
        transactions[0].id
      }&select=note`,
      token,
    ))[0]?.note === "Synthetic retained annotation",
    "Provider replay overwrote annotation",
  );
  await control({ accountId: provider, status: "inactive" });
  await webhook("evt_localInactive", "deactivated", provider);
  await webhook("evt_localInactive", "deactivated", provider);
  await worker();
  assert(
    (await account(id)).connection_state === "error" &&
      (await account(id)).sync_error === "connection_inactive",
    "Inactive lifecycle not persisted",
  );
  await control({ accountId: provider, status: "active" });
  await webhook("evt_localActive", "reactivated", provider);
  await worker();
  assert(
    (await account(id)).connection_state === "active",
    "Reactivation did not recover",
  );
  await call(`${root}/accounts/${id}/disconnect`, token, "POST", {}, 202);
  await worker();
  assert(
    (await account(id)).connection_state === "disconnected",
    "Disconnect did not finish",
  );
  assert(
    (await call(`/rest/v1/transactions?account_id=eq.${id}&select=id`, token))
      .length === 2,
    "Disconnect deleted local provider history",
  );
  await call(`${root}/connections/complete`, token, "POST", {
    sessionId: session.sessionId,
  });
  await control({ accountId: provider, status: "active" });
  await webhook("evt_localLateActive", "reactivated", provider);
  await worker();
  assert(
    (await account(id)).connection_state === "disconnected",
    "Late replay reactivated disconnected account",
  );
  const final = await inspect();
  assert(
    final.accounts[0].subscriptions.length === 0 &&
      final.requests.filter((r: any) => r.path.endsWith("/subscribe"))
          .length === 4,
    "Replay restored paid feed",
  );
  console.log(
    "PASS real local Auth/Postgres/functions + mocked Stripe HTTP: owner/MFA denial, pending/resume, empty consent, durable subscribe failure/retry identity, completed replay, signed duplicate lifecycle webhooks, disconnect fencing, no balance prefetch",
  );
}
