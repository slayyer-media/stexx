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

/**
 * Latitude/longitude ranges (degrees) on the same sphere as haversineMeters. Longitude is one range, or two when
 * the box crosses the antimeridian. Used as an index prefilter only: the exact distance is always rechecked.
 */
export interface LatLonBox {
  minLat: number;
  maxLat: number;
  /** Disjoint inclusive [min, max] ranges within [-180, 180]; [[-180, 180]] when every longitude is in range. */
  lonRanges: [number, number][];
}

/** Every longitude. */
const ALL_LONGITUDES: [number, number][] = [[-180, 180]];

/**
 * Normalize an inclusive longitude interval that may extend past ±180 (by less than 360 degrees in total) into
 * ranges within [-180, 180]. -180 and 180 are the same meridian, so an interval that reaches either one includes
 * both (a cell can be stored at exactly 180).
 */
export function lonRanges(lo: number, hi: number): [number, number][] {
  if (hi - lo >= 360) return ALL_LONGITUDES;
  if (lo <= -180) return [[lo + 360, 180], [-180, hi]];
  if (hi >= 180) return [[lo, 180], [-180, hi - 360]];
  return [[lo, hi]];
}

/**
 * The smallest latitude/longitude box containing every point within `radiusMeters` (great-circle) of `center`,
 * widened by `marginDeg` on each side against floating-point error. Near a pole, or when the circle is too big for
 * a meaningful longitude bound, the box spans all longitudes. (Bounding coordinates on a sphere: the widest
 * longitude offset of a circle of angular radius r around latitude φ that doesn't contain a pole is
 * asin(sin r / cos φ).)
 */
export function boundingBox(center: Cell, radiusMeters: number, marginDeg = 1e-6): LatLonBox {
  const deg = 180 / Math.PI;
  const r = Math.max(0, radiusMeters) / EARTH_RADIUS_M; // angular radius
  const minLat = center.latitude - r * deg - marginDeg;
  const maxLat = center.latitude + r * deg + marginDeg;
  const clamp = (lat: number) => Math.min(90, Math.max(-90, lat));
  // Circle reaches a pole (or wraps the whole sphere): every longitude is within reach.
  if (r >= Math.PI / 2 || minLat <= -90 || maxLat >= 90) {
    return { minLat: clamp(minLat), maxLat: clamp(maxLat), lonRanges: ALL_LONGITUDES };
  }
  const s = Math.sin(r) / Math.cos((center.latitude * Math.PI) / 180);
  if (s >= 1) return { minLat, maxLat, lonRanges: ALL_LONGITUDES };
  const dLon = Math.asin(s) * deg + marginDeg;
  return { minLat, maxLat, lonRanges: lonRanges(center.longitude - dLon, center.longitude + dLon) };
}
