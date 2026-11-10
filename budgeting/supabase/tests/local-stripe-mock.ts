// Synthetic Stripe HTTP boundary. Auth, SQL and function dispatch are not mocked.
export function startStripeMock() {
  const sessions = new Map<string, any>();
  const accounts = new Map<string, any>();
  const requests: { path: string; method: string; key: string | null }[] = [];
  let customerCount = 0, subscriptionFailures = 0;
  const server = Deno.serve(
    { hostname: "0.0.0.0", port: 58082, onListen() {} },
    async (req) => {
      const url = new URL(req.url), path = url.pathname;
      const json = (data: unknown, status = 200) =>
        Response.json(data, { status });
      if (path === "/control" && req.method === "POST") {
        const input = await req.json();
        if (input.sessionId) {
          const session = sessions.get(input.sessionId);
          if (!session) return json({ error: "unknown_session" }, 404);
          const accountId = `fca_local${input.sessionId.slice(7)}`;
          accounts.set(accountId, {
            id: accountId,
            livemode: false,
            status: "active",
            category: "cash",
            display_name: "Synthetic linked checking",
            institution_name: "Mock institution",
            last4: "4242",
            permissions: ["balances", "transactions"],
            subscriptions: [],
            account_holder: session.account_holder,
            transaction_refresh: {
              status: "succeeded",
              id: `fctxnref_${accountId}`,
            },
          });
          session.accounts.data = [{ id: accountId }];
        }
        if (input.accountId && input.status) {
          accounts.get(input.accountId)
            .status = input.status;
        }
        if (input.subscriptionFailures !== undefined) {
          subscriptionFailures = input.subscriptionFailures;
        }
        return json({ ok: true });
      }
      if (path === "/inspect") {
        return json({
          requests,
          customerCount,
          accounts: [...accounts.values()],
        });
      }
      requests.push({
        path,
        method: req.method,
        key: req.headers.get("idempotency-key"),
      });
      if (
        req.headers.get("authorization") !==
          "Bearer sk_test_localSyntheticOnly123"
      ) {
        return json({ error: "unexpected_key" }, 401);
      }
      const form = new URLSearchParams(
        req.method === "POST" ? await req.text() : "",
      );
      if (path === "/v1/customers" && req.method === "POST") {
        customerCount++;
        return json({ id: "cus_localOwner", livemode: false });
      }
      if (
        path === "/v1/financial_connections/sessions" && req.method === "POST"
      ) {
        if (
          form.get("permissions[0]") !== "balances" ||
          form.get("permissions[1]") !== "transactions"
        ) {
          return json({ error: "unexpected_permissions" }, 400);
        }
        const id = `fcsess_local${sessions.size + 1}`;
        const session = {
          id,
          livemode: false,
          client_secret: `${id}_secret_synthetic`,
          account_holder: { customer: form.get("account_holder[customer]") },
          accounts: { data: [], has_more: false },
        };
        sessions.set(id, session);
        return json(session);
      }
      const session = sessions.get(path.split("/").at(-1)!);
      if (session && req.method === "GET") return json(session);
      const parts = path.split("/"), account = accounts.get(parts[4]);
      if (account && parts.length === 5 && req.method === "GET") {
        return json(account);
      }
      if (account && parts[5] === "subscribe") {
        if (subscriptionFailures-- > 0) {
          return json({ error: "synthetic_failure" }, 503);
        }
        account.subscriptions = ["transactions"];
        return json(account);
      }
      if (account && parts[5] === "unsubscribe") {
        account.subscriptions = [];
        return json(account);
      }
      if (account && parts[5] === "disconnect") {
        account.status = "disconnected";
        return json(account);
      }
      if (path === "/v1/financial_connections/transactions") {
        const provider = url.searchParams.get("account");
        if (!accounts.has(provider!)) {
          return json({ error: "unknown_account" }, 404);
        }
        const second = url.searchParams.has("starting_after");
        return json({
          data: [{
            id: second ? `fctxn_${provider}2` : `fctxn_${provider}1`,
            account: provider,
            livemode: false,
            amount: second ? 234 : -1234,
            currency: "usd",
            status: "posted",
            description: "Synthetic provider transaction",
            transacted_at: 1793548800,
            updated: 1793635200,
            status_transitions: { posted_at: 1793635200 },
          }],
          has_more: !second,
        });
      }
      return json({ error: "unimplemented_mock_boundary" }, 400);
    },
  );
  return server;
}
