// Copied only into the disposable CLI functions workdir, never deployed.
export function install() {
  const realFetch = globalThis.fetch;
  globalThis.fetch = (input, init) => {
    const url = new URL(input instanceof Request ? input.url : String(input));
    if (url.origin === "https://api.stripe.com") {
      return realFetch(
        `http://host.docker.internal:58082${url.pathname}${url.search}`,
        init,
      );
    }
    const local = new URL(Deno.env.get("SUPABASE_URL")!);
    if (url.origin !== local.origin) {
      throw new Error(
        "Disposable integration blocked nonlocal outbound request",
      );
    }
    return realFetch(input, init);
  };
}
