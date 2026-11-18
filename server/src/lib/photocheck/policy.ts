import { config } from "../../config.ts";

/** Photo-check policy: the labelling and visibility rules (no I/O, so serialize.ts can import it cheaply). */

export interface PhotoPolicy {
  threshold: number;
  explicitLabels: readonly string[];
  /** -1 = off. */
  duplicateMaxDistance: number;
  hideUnchecked: boolean;
  classifyTimeoutMs: number;
}

let policyOverride: Partial<PhotoPolicy> | null = null;

export function photoPolicy(): PhotoPolicy {
  const c = config.photoChecks;
  return {
    threshold: c.threshold,
    explicitLabels: c.explicitLabels,
    duplicateMaxDistance: c.duplicateMaxDistance,
    hideUnchecked: c.hideUnchecked,
    classifyTimeoutMs: 15_000,
    ...policyOverride,
  };
}

/** Tests: override parts of the policy (null restores config). */
export function setPhotoPolicyForTests(p: Partial<PhotoPolicy> | null): void {
  policyOverride = p;
}

/** The labelling rule: explicit when any configured explicit label scores ≥ threshold. */
export function explicitVerdict(
  labels: Record<string, number>,
  policy: Pick<PhotoPolicy, "threshold" | "explicitLabels"> = photoPolicy(),
): { score: number; isExplicit: boolean } {
  let score = 0;
  for (const label of policy.explicitLabels) {
    const s = labels[label];
    if (typeof s === "number" && Number.isFinite(s) && s > score) score = s;
  }
  score = Math.min(1, Math.max(0, score));
  return { score, isExplicit: score >= policy.threshold };
}

/** Is this photo shown to people other than its owner? */
export function visibleToOthers(p: { is_explicit: boolean; is_checked: boolean }, policy = photoPolicy()): boolean {
  return !p.is_explicit && (p.is_checked || !policy.hideUnchecked);
}

