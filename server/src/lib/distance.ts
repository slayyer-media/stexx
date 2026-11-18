/**
 * Server-side location handling. Never trust client coordinates: re-snap to our own grid,
 * store only the cell, compute distances cell-to-cell and bucket them before they leave the server.
 */

export const DEFAULT_CELL_METERS = 500;
const METERS_PER_DEGREE_LATITUDE = 111_320.0;
const EARTH_RADIUS_M = 6_371_000;

export interface Cell {
  latitude: number;
  longitude: number;
}

/** Exact port of ios/Stexx/Models/LocationFuzzer.swift `fuzz` (snap to the centre of a fixed grid cell). */
export function snapToCell(latitude: number, longitude: number, cellMeters = DEFAULT_CELL_METERS): Cell {
  const latStep = cellMeters / METERS_PER_DEGREE_LATITUDE;
  const snappedLat = Math.min(90, Math.max(-90, (Math.floor(latitude / latStep) + 0.5) * latStep));

  // Longitude cells use the latitude of the snapped row so every point in the same row shares one width.
  const metersPerDegreeLongitude = METERS_PER_DEGREE_LATITUDE * Math.max(Math.cos((snappedLat * Math.PI) / 180), 0.01);
  const lonStep = cellMeters / metersPerDegreeLongitude;
  let snappedLon = (Math.floor(longitude / lonStep) + 0.5) * lonStep;
  if (snappedLon > 180) snappedLon -= 360;
  if (snappedLon < -180) snappedLon += 360;

  return { latitude: snappedLat, longitude: snappedLon };
}

/** Great-circle distance in meters. Same formula as SQL `stexx_haversine_m`. */
export function haversineMeters(lat1: number, lon1: number, lat2: number, lon2: number): number {
  const rad = Math.PI / 180;
  const dLat = (lat2 - lat1) * rad;
  const dLon = (lon2 - lon1) * rad;
  const a = Math.sin(dLat / 2) ** 2 + Math.cos(lat1 * rad) * Math.cos(lat2 * rad) * Math.sin(dLon / 2) ** 2;
  return 2 * EARTH_RADIUS_M * Math.asin(Math.min(1, Math.sqrt(a)));
}

/**
 * Bucket a raw cell-to-cell distance. Same as SQL `stexx_distance_bucket`.
 * < 1 km: round UP to 100 m (min 100) | 1–5 km: 500 m | 5–25 km: 1 km | 25–100 km: 5 km | beyond: 10 km.
 */
export function bucketDistance(meters: number): number {
  if (meters < 1000) return Math.max(100, Math.ceil(meters / 100) * 100);
  if (meters < 5000) return Math.round(meters / 500) * 500;
  if (meters < 25_000) return Math.round(meters / 1000) * 1000;
  if (meters < 100_000) return Math.round(meters / 5000) * 5000;
  return Math.round(meters / 10_000) * 10_000;
}

/** Bucketed distance between two cells, or null if either is unknown. */
export function bucketedDistanceBetween(a: Cell | null | undefined, b: Cell | null | undefined): number | null {
  if (!a || !b) return null;
  return bucketDistance(haversineMeters(a.latitude, a.longitude, b.latitude, b.longitude));
}
