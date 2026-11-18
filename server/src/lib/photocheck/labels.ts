/** NudeNet v3 label set. Kept free of imports so config.ts can validate PHOTO_NSFW_LABELS. */

/** Model class order (index = output row - 4). */
export const NUDENET_LABELS = [
  "FEMALE_GENITALIA_COVERED",
  "FACE_FEMALE",
  "BUTTOCKS_EXPOSED",
  "FEMALE_BREAST_EXPOSED",
  "FEMALE_GENITALIA_EXPOSED",
  "MALE_BREAST_EXPOSED",
  "ANUS_EXPOSED",
  "FEET_EXPOSED",
  "BELLY_COVERED",
  "FEET_COVERED",
  "ARMPITS_COVERED",
  "ARMPITS_EXPOSED",
  "FACE_MALE",
  "BELLY_EXPOSED",
  "MALE_GENITALIA_EXPOSED",
  "ANUS_COVERED",
  "FEMALE_BREAST_COVERED",
  "BUTTOCKS_COVERED",
] as const;
export type NudeNetLabel = (typeof NUDENET_LABELS)[number];

/**
 * Labels that make a photo explicit by default: exposed genitals, anus or buttocks. Shirtless (MALE_BREAST_EXPOSED),
 * underwear (…_COVERED) and faces are fine on a profile. FEMALE_BREAST_EXPOSED is left out on purpose: on men's
 * photos the model often gives bare (and even clothed) chests that label, e.g. 0.44 on a clothed cyclist in our seed
 * set. Add it with PHOTO_NSFW_LABELS if you want it.
 */
export const DEFAULT_EXPLICIT_LABELS: readonly NudeNetLabel[] = [
  "MALE_GENITALIA_EXPOSED",
  "FEMALE_GENITALIA_EXPOSED",
  "ANUS_EXPOSED",
  "BUTTOCKS_EXPOSED",
];
