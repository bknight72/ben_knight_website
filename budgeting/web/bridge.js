/* Built at Novacoast. No financial or authentication data is persisted. */
window.budgetBridge = {
  stripeGeneration: 0,
  clearStripe() {
    this.stripeGeneration++;
  },
  clearAuthUrl() {
    history.replaceState(null, "", location.pathname);
  },
  pickCsv() {
    return new Promise((resolve, reject) => {
      const input = document.createElement("input");
      input.type = "file";
      input.accept = ".csv,text/csv";
      input.oncancel = () => resolve(null);
      input.onchange = async () => {
        const file = input.files[0];
        if (!file) return resolve(null);
        if (file.size > 5242880) return reject(new Error("CSV exceeds 5 MB."));
        try {
          resolve(await file.text());
        } catch (error) {
          reject(error);
        }
      };
      input.click();
    });
  },
  download(name, content) {
    const url = URL.createObjectURL(
      new Blob([content], { type: "application/json" }),
    );
    const a = document.createElement("a");
    a.href = url;
    a.download = name;
    a.click();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  },
  async linkStripe(key, clientSecret) {
    const generation = this.stripeGeneration;
    if (!window.Stripe) {
      try {
        await new Promise((resolve, reject) => {
          const script = document.createElement("script");
          const timeout = setTimeout(() => {
            script.remove();
            reject(new Error("Stripe load timed out"));
          }, 15000);
          script.src = "https://js.stripe.com/v3/";
          script.onload = () => {
            clearTimeout(timeout);
            resolve();
          };
          script.onerror = () => {
            clearTimeout(timeout);
            script.remove();
            reject(new Error("Stripe load failed"));
          };
          document.head.appendChild(script);
        });
      } catch (_) {
        clientSecret = null;
        return "load_failed";
      }
    }
    if (generation !== this.stripeGeneration) return "cancelled";
    try {
      const pending = window.Stripe(key).collectFinancialConnectionsAccounts(
        { clientSecret },
      );
      clientSecret = null;
      const result = await pending;
      if (generation !== this.stripeGeneration) return "cancelled";
      if (result.error) return "failed";
      if (!result.financialConnectionsSession?.accounts?.length) {
        return "cancelled";
      }
      // Browser account attributes are neither returned nor used for completion.
      return "completed";
    } catch (_) {
      return "failed";
    } finally {
      clientSecret = null;
    }
  },
};
