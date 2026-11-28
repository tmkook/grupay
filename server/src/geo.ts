/** 城市级位置信息：来自 Cloudflare 请求的 cf 字段，不保存更精确的位置。 */
export interface Geo {
  city: string | null;
  region: string | null;
  lat: number | null;
  lon: number | null;
}

export const emptyGeo = (): Geo => ({ city: null, region: null, lat: null, lon: null });

const text = (value: unknown) => {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed ? trimmed.slice(0, 64) : null;
};

// 坐标保留两位小数（约 1km），既能排序又不过度定位。
const coordinate = (value: unknown, limit: number) => {
  const number =
    typeof value === "number"
      ? value
      : typeof value === "string" && value.trim()
        ? Number(value)
        : NaN;
  return Number.isFinite(number) && Math.abs(number) <= limit
    ? Math.round(number * 100) / 100
    : null;
};

export function geoFromCf(cf: IncomingRequestCfProperties | undefined): Geo {
  return {
    city: text(cf?.city),
    region: text(cf?.region),
    lat: coordinate(cf?.latitude, 90),
    lon: coordinate(cf?.longitude, 180),
  };
}

export function parseGeoHeader(value: string | null): Geo {
  if (!value) return emptyGeo();
  try {
    const raw = JSON.parse(value) as Record<string, unknown>;
    return {
      city: text(raw.city),
      region: text(raw.region),
      lat: coordinate(raw.lat, 90),
      lon: coordinate(raw.lon, 180),
    };
  } catch {
    return emptyGeo();
  }
}

/** 两个城市级坐标之间的球面距离（公里）；坐标缺失时返回 Infinity。 */
export function distanceKm(
  aLat: number | null,
  aLon: number | null,
  bLat: number | null,
  bLon: number | null,
): number {
  if (aLat == null || aLon == null || bLat == null || bLon == null)
    return Infinity;
  const rad = Math.PI / 180;
  const dLat = (bLat - aLat) * rad;
  const dLon = (bLon - aLon) * rad;
  const h =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(aLat * rad) * Math.cos(bLat * rad) * Math.sin(dLon / 2) ** 2;
  return 2 * 6371 * Math.asin(Math.min(1, Math.sqrt(h)));
}
