import { createHash } from "node:crypto";
import { access, readFile } from "node:fs/promises";
import { config } from "../../config.ts";
import { logError, logInfo } from "../logger.ts";
import { nudenetInput, nudenetScores, NUDENET_INPUT_SIZE } from "./nudenet.ts";

/**
 * The NSFW classifier behind an interface, so tests (and a future model) can swap it.
 *
 * Production uses NudeNet 320n (12 MB ONNX) in-process through onnxruntime-node on the CPU: ~10 ms per photo on one
 * thread. Inferences run one at a time; at most MAX_QUEUED wait, beyond that classify() throws ClassifierBusy and
 * the photo stays unchecked for the background job. The model is loaded lazily on first use. When it is missing or
 * fails to load, photoClassifier() resolves to null (uploads still work, photos stay unchecked) and loading is
 * retried every RETRY_LOAD_MS, so dropping the file in place later needs no restart.
 */

export interface PhotoClassifier {
  /** Stored with every result, e.g. "nudenet-3.4-320n". */
  readonly model: string;
  /** Best score per label (labels with no detection absent). Input: the sanitized JPEG. */
  classify(image: Uint8Array): Promise<Record<string, number>>;
}

export class ClassifierBusy extends Error {
  override name = "ClassifierBusy";
}

/** SHA-256 of the pinned weights (scripts/fetch-photo-model.sh). Any other file gets a "-<sha>" model id. */
export const NUDENET_320N_SHA256 = "c15d8273adad2d0a92f014cc69ab2d6c311a06777a55545f2c4eb46f51911f0f";
const PINNED_MODEL_ID = "nudenet-3.4-320n";
const MAX_QUEUED = 8;
const RETRY_LOAD_MS = 5 * 60_000;

let override: PhotoClassifier | null | undefined;
let loading: Promise<PhotoClassifier | null> | null = null;
let loadedAt = 0;

/** The active classifier, or null when photo classification is off or unavailable. */
export async function photoClassifier(): Promise<PhotoClassifier | null> {
  if (override !== undefined) return override;
  if (config.photoChecks.classifier === "off") return null;
  if (loading && Date.now() - loadedAt > RETRY_LOAD_MS) {
    const stale = loading;
    // Retry a failed/missing load, unless a concurrent caller already started the retry.
    if (!(await stale) && loading === stale) loading = null;
  }
  if (!loading) {
    loadedAt = Date.now();
    loading = createNudeNetClassifier(config.photoChecks.modelPath, config.photoChecks.threads);
  }
  return loading;
}

/** Tests: inject a fake (or null = unavailable). `undefined` restores the configured one. */
export function setPhotoClassifierForTests(c: PhotoClassifier | null | undefined): void {
  override = c;
}

/** Load NudeNet from `path`; null (logged) when the file is missing or fails to load. */
export async function createNudeNetClassifier(path: string, threads = 1): Promise<PhotoClassifier | null> {
  try {
    await access(path);
  } catch {
    logInfo("photo_checks.model_missing", { hint: "run scripts/fetch-photo-model.sh; photos stay unchecked" });
    return null;
  }
  try {
    const sha = createHash("sha256").update(await readFile(path)).digest("hex");
    const model = sha === NUDENET_320N_SHA256 ? PINNED_MODEL_ID : `nudenet-320n-${sha.slice(0, 12)}`;
    // Dynamic import: the native addon is only loaded when a model is actually present.
    const ort = await import("onnxruntime-node");
    const session = await ort.InferenceSession.create(path, {
      executionProviders: ["cpu"],
      intraOpNumThreads: threads,
      interOpNumThreads: 1,
      executionMode: "sequential",
      graphOptimizationLevel: "all",
    });
    const inputName = session.inputNames[0]!;
    const outputName = session.outputNames[0]!;
    const run = oneAtATime(async (image: Uint8Array) => {
      const input = await nudenetInput(image);
      const tensor = new ort.Tensor("float32", input.tensor, [1, 3, NUDENET_INPUT_SIZE, NUDENET_INPUT_SIZE]);
      const out = await session.run({ [inputName]: tensor });
      const result = out[outputName]!;
      try {
        return nudenetScores(result.data as Float32Array, result.dims, input) as Record<string, number>;
      } finally {
        tensor.dispose?.();
        result.dispose?.();
      }
    });
    logInfo("photo_checks.model_loaded", { model, threads });
    return { model, classify: run };
  } catch (err) {
    logError("photo_checks.model_load", err);
    return null;
  }
}

/** One call at a time; at most `maxQueued` waiting, then ClassifierBusy. */
export function oneAtATime<A, R>(fn: (a: A) => Promise<R>, maxQueued = MAX_QUEUED): (a: A) => Promise<R> {
  let tail: Promise<unknown> = Promise.resolve();
  let waiting = 0;
  return (a: A) => {
    if (waiting >= maxQueued) return Promise.reject(new ClassifierBusy("classifier queue full"));
    waiting++;
    const run = tail.then(
      () => {
        waiting--;
        return fn(a);
      },
      () => {
        waiting--;
        return fn(a);
      },
    );
    tail = run.catch(() => {});
    return run;
  };
}
