// Fail without printing values if server credentials enter a public build.
const forbidden = [
  /\b(?:sk|rk)_(?:live|test)_[A-Za-z0-9_]{10,}/,
  /\bwhsec_[A-Za-z0-9]{10,}/,
  /\bsb_secret_[A-Za-z0-9_-]{10,}/,
  /-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/,
  /postgres(?:ql)?:\/\/[^\s"']+:[^\s"']+@/,
];
let files = 0;
async function audit(path: string) {
  for await (const entry of Deno.readDir(path)) {
    const file = `${path}/${entry.name}`;
    if (entry.isSymlink) {
      throw new Error("Symlinks are not allowed in public artifacts.");
    }
    if (entry.isDirectory) {
      await audit(file);
      continue;
    }
    files++;
    if (/\.(?:js|json|html|yaml|txt|map)$/.test(entry.name)) {
      const text = await Deno.readTextFile(file);
      if (forbidden.some((pattern) => pattern.test(text))) {
        throw new Error(
          "Potential server credential in public artifact. Refusing packaging.",
        );
      }
      for (
        const candidate of text.matchAll(
          /eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/g,
        )
      ) {
        try {
          const claims = JSON.parse(
            atob(
              candidate[0].split(".")[1].replaceAll("-", "+").replaceAll(
                "_",
                "/",
              ),
            ),
          );
          if (claims.role === "service_role") {
            throw new Error("Privileged JWT in public artifact.");
          }
        } catch (error) {
          if (
            error instanceof Error &&
            error.message === "Privileged JWT in public artifact."
          ) throw error;
        }
      }
    }
  }
}
await audit(Deno.args[0] ?? "build/web");
if (!files) throw new Error("Artifact is empty.");
console.log(
  `Audited ${files} static files without printing configuration values.`,
);
