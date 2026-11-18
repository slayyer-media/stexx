/**
 * Disposable-email blocking for sign-up and sign-in links. The list is bundled (disposable-domains.txt, from
 * github.com/disposable-email-domains/disposable-email-domains, CC0) so no address or domain ever leaves the
 * server. Subdomains of a listed domain match too. Refresh the file from upstream now and then.
 */
import { readFileSync } from "node:fs";
import { badRequest } from "../errors.ts";

const LIST_URL = new URL("./disposable-domains.txt", import.meta.url);

let domains: Set<string> | null = null;
function load(): Set<string> {
  domains ??= new Set(
    readFileSync(LIST_URL, "utf8")
      .split("\n")
      .map((l) => l.trim().toLowerCase())
      .filter((l) => l && !l.startsWith("#")),
  );
  return domains;
}

/** True if the address's domain (or any parent domain) is on the bundled disposable list. */
export function isDisposableEmail(address: string): boolean {
  const at = address.lastIndexOf("@");
  if (at < 0) return false;
  const domain = address.slice(at + 1).trim().toLowerCase().replace(/\.+$/, "");
  const list = load();
  const labels = domain.split(".");
  for (let i = 0; i < labels.length - 1; i++) {
    if (list.has(labels.slice(i).join("."))) return true;
  }
  return false;
}

/** 400 `disposable_email` for throwaway addresses. */
export function assertNotDisposable(address: string): void {
  if (isDisposableEmail(address)) {
    throw badRequest("Please use a regular email address. Temporary inboxes aren't supported.", "disposable_email");
  }
}

/** Number of bundled domains (for tests/diagnostics). */
export function disposableDomainCount(): number {
  return load().size;
}
