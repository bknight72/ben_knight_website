/* Built at Novacoast. No financial or authentication data is persisted. */
window.budgetBridge = {
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
    if (!window.Stripe) {
      await new Promise((resolve, reject) => {
        const script = document.createElement("script");
        script.src = "https://js.stripe.com/v3/";
        script.onload = resolve;
        script.onerror = reject;
        document.head.appendChild(script);
      });
    }
    const result = await window.Stripe(key).collectFinancialConnectionsAccounts(
      { clientSecret },
    );
    if (result.error || !result.financialConnectionsSession?.accounts?.length) {
      throw new Error("Bank connection was cancelled or failed.");
    }
    return result.financialConnectionsSession;
  },
};
