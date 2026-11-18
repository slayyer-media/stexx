import sharp from "sharp";

/**
 * Port of NudeNet v3's detector pre/post-processing (nudenet/nudenet.py, AGPL-3.0, github.com/notAI-tech/NudeNet)
 * for its 320n YOLOv8 ONNX model. Pure functions here; the ONNX session lives in classifier.ts.
 *
 * Pre: pad the image to a square at the bottom/right with black, resize to 320×320, BGR, /255, NCHW float32.
 * Post: output0 is [1, 4 + 18, anchors]; per anchor take the best class, keep ≥ 0.2, class-agnostic NMS
 * (score 0.25, IoU 0.45) like cv2.dnn.NMSBoxes. We keep only the best score per label (no boxes leave this file).
 */

import { NUDENET_LABELS, type NudeNetLabel } from "./labels.ts";

export { DEFAULT_EXPLICIT_LABELS, NUDENET_LABELS, type NudeNetLabel } from "./labels.ts";

export const NUDENET_INPUT_SIZE = 320;
const CANDIDATE_MIN = 0.2;
const NMS_SCORE = 0.25;
const NMS_IOU = 0.45;

export interface NudeNetInput {
  tensor: Float32Array; // [1, 3, 320, 320]
  width: number; // original
  height: number;
}

/**
 * Decode + letterbox an image into the model's input tensor, matching NudeNet's reference exactly:
 * - Channel order is BGR. NudeNet reads BGR with OpenCV, its cvtColor(RGBA2BGR) on a 3-channel image swaps to RGB,
 *   and blobFromImage(swapRB=True) swaps back, so the model was run (and is accurate) on BGR input.
 * - The square is padded at the bottom/right with black, then resized with OpenCV-style bilinear sampling (half-pixel
 *   centres, no antialiasing), which libvips' resize kernels don't reproduce.
 */
export async function nudenetInput(image: Uint8Array, size = NUDENET_INPUT_SIZE): Promise<NudeNetInput> {
  const { data, info } = await sharp(image, { failOn: "error" })
    .removeAlpha()
    .toColourspace("srgb")
    .raw()
    .toBuffer({ resolveWithObject: true });
  const { width, height, channels: ch } = info;
  if (!width || !height || ch < 3) throw new Error("unexpected decoded image");
  return { tensor: letterboxBgr(data, width, height, ch, size), width, height };
}

/** Pure: interleaved RGB(A) bytes → [1, 3, size, size] BGR float32 in 0..1 (pad bottom/right, bilinear). */
export function letterboxBgr(
  rgb: ArrayLike<number>,
  width: number,
  height: number,
  channels: number,
  size = NUDENET_INPUT_SIZE,
): Float32Array {
  const side = Math.max(width, height);
  const scale = side / size;
  const plane = size * size;
  const out = new Float32Array(3 * plane);
  // Pixel of the padded square, black outside the image.
  const px = (x: number, y: number, c: number) => (x < width && y < height ? rgb[(y * width + x) * channels + c]! : 0);
  for (let dy = 0; dy < size; dy++) {
    let sy = (dy + 0.5) * scale - 0.5;
    if (sy < 0) sy = 0;
    let y0 = Math.floor(sy);
    if (y0 > side - 1) y0 = side - 1;
    const y1 = Math.min(y0 + 1, side - 1);
    const fy = Math.min(1, sy - y0);
    for (let dx = 0; dx < size; dx++) {
      let sx = (dx + 0.5) * scale - 0.5;
      if (sx < 0) sx = 0;
      let x0 = Math.floor(sx);
      if (x0 > side - 1) x0 = side - 1;
      const x1 = Math.min(x0 + 1, side - 1);
      const fx = Math.min(1, sx - x0);
      const o = dy * size + dx;
      for (let c = 0; c < 3; c++) {
        const v =
          (px(x0, y0, c) * (1 - fx) + px(x1, y0, c) * fx) * (1 - fy) + (px(x0, y1, c) * (1 - fx) + px(x1, y1, c) * fx) * fy;
        // RGB channel c goes to BGR plane 2 - c.
        out[(2 - c) * plane + o] = v / 255;
      }
    }
  }
  return out;
}

interface Box {
  x: number;
  y: number;
  w: number;
  h: number;
  score: number;
  cls: number;
}

function iou(a: Box, b: Box): number {
  const x1 = Math.max(a.x, b.x);
  const y1 = Math.max(a.y, b.y);
  const x2 = Math.min(a.x + a.w, b.x + b.w);
  const y2 = Math.min(a.y + a.h, b.y + b.h);
  const inter = Math.max(0, x2 - x1) * Math.max(0, y2 - y1);
  const union = a.w * a.h + b.w * b.h - inter;
  return union > 0 ? inter / union : 0;
}

/**
 * Best score per label from the raw output (`dims` = [1, 4 + classes, anchors]). Labels with no surviving
 * detection are absent. Scores are rounded to 3 decimals.
 */
export function nudenetScores(
  output: Float32Array,
  dims: readonly number[],
  input: { width: number; height: number },
  size = NUDENET_INPUT_SIZE,
): Partial<Record<NudeNetLabel, number>> {
  const rows = dims[1] ?? 0;
  const anchors = dims[2] ?? 0;
  const classes = rows - 4;
  if (dims.length !== 3 || classes !== NUDENET_LABELS.length || output.length < rows * anchors) {
    throw new Error(`unexpected NudeNet output shape [${dims.join(", ")}]`);
  }
  const side = Math.max(input.width, input.height); // original + padding
  const scale = side / size;
  const boxes: Box[] = [];
  for (let i = 0; i < anchors; i++) {
    let best = -1;
    let score = -Infinity;
    for (let c = 0; c < classes; c++) {
      const s = output[(4 + c) * anchors + i]!;
      if (s > score) {
        score = s;
        best = c;
      }
    }
    if (score < CANDIDATE_MIN) continue;
    const cx = output[i]!;
    const cy = output[anchors + i]!;
    const bw = output[2 * anchors + i]!;
    const bh = output[3 * anchors + i]!;
    // Scale to the padded original, then clip to the real image (as NudeNet does before NMS).
    const x = Math.max(0, Math.min((cx - bw / 2) * scale, input.width));
    const y = Math.max(0, Math.min((cy - bh / 2) * scale, input.height));
    const w = Math.min(bw * scale, input.width - x);
    const h = Math.min(bh * scale, input.height - y);
    boxes.push({ x, y, w, h, score, cls: best });
  }
  // Class-agnostic greedy NMS, like cv2.dnn.NMSBoxes(boxes, scores, 0.25, 0.45).
  const candidates = boxes.filter((b) => b.score > NMS_SCORE).sort((a, b) => b.score - a.score);
  const kept: Box[] = [];
  for (const b of candidates) {
    if (kept.every((k) => iou(k, b) <= NMS_IOU)) kept.push(b);
  }
  const out: Partial<Record<NudeNetLabel, number>> = {};
  for (const k of kept) {
    const label = NUDENET_LABELS[k.cls]!;
    const s = Math.round(k.score * 1000) / 1000;
    if ((out[label] ?? -1) < s) out[label] = s;
  }
  return out;
}
