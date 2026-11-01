#!/usr/bin/env python3
"""Side-by-side POI comparison for the meet-up suggestion pipeline.

Compares the place names returned by:
  * OpenStreetMap (Overpass)          - what the app uses today, no key
  * Overture Maps (monthly parquet)   - free/open, no key (needs duckdb)
  * TomTom Search     (TOMTOM_API_KEY)
  * HERE Browse       (HERE_API_KEY)
  * Google Places     (GOOGLE_MAPS_API_KEY)
  * Foursquare Places (FOURSQUARE_API_KEY)

The point is to see which providers know the *current* name of a business
before MatchMe commits to one. Sources without a key are reported as skipped.

Usage:
  python scripts/compare_place_sources.py
  python scripts/compare_place_sources.py --center 32.114331,34.835678 --radius 900
  python scripts/compare_place_sources.py --pin 32.114331,34.835678 --only osm,overture
  python scripts/compare_place_sources.py --json out.json

Keys are read from the environment, never from the repo.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from typing import Any

DEFAULT_CENTER = (32.114331, 34.835678)  # Ramat HaHayal, the reported store
DEFAULT_RADIUS = 900
OVERPASS_ENDPOINTS = [
    "https://overpass-api.de/api/interpreter",
    "https://overpass.kumi.systems/api/interpreter",
    "https://overpass.private.coffee/api/interpreter",
]
# Bump when a new Overture release is published.
OVERTURE_RELEASE = "2026-10-21.0"
OVERTURE_PARQUET = (
    "s3://overturemaps-us-west-2/release/"
    f"{OVERTURE_RELEASE}/theme=places/type=place/*.parquet"
)

# Same categories the app asks Overpass for.
OVERPASS_QL = """
[out:json][timeout:25];
(
  nwr["name"]["leisure"~"^(park|garden)$"](around:{radius},{lat},{lon});
  nwr["name"]["place"="square"](around:{radius},{lat},{lon});
  nwr["name"]["historic"~"^(monument|memorial|city_gate|archaeological_site)$"](around:{radius},{lat},{lon});
  nwr["name"]["tourism"~"^(attraction|museum|viewpoint)$"](around:{radius},{lat},{lon});
  nwr["name"]["shop"~"^(supermarket|mall|department_store)$"](around:{radius},{lat},{lon});
  nwr["name"]["amenity"~"^(fuel|pharmacy|library|townhall|bus_station|marketplace)$"](around:{radius},{lat},{lon});
  nwr["name"]["railway"~"^(station|subway_entrance)$"](around:{radius},{lat},{lon});
  nwr["name"]["public_transport"="station"](around:{radius},{lat},{lon});
);
out center tags {limit};
"""


@dataclass
class Place:
    source: str
    name: str
    lat: float
    lon: float
    category: str = ""
    meta: dict[str, Any] = field(default_factory=dict)
    distance_m: float = 0.0


# Same category values the Overpass query above asks for.
WANTED_CATEGORIES = {
    "park",
    "garden",
    "square",
    "monument",
    "memorial",
    "city_gate",
    "archaeological_site",
    "attraction",
    "museum",
    "viewpoint",
    "supermarket",
    "mall",
    "department_store",
    "fuel",
    "pharmacy",
    "library",
    "townhall",
    "bus_station",
    "marketplace",
    "station",
    "subway_entrance",
}
CATEGORY_KEYS = (
    "leisure",
    "place",
    "historic",
    "tourism",
    "shop",
    "amenity",
    "railway",
    "public_transport",
)


class ProviderError(RuntimeError):
    pass


def haversine_m(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    radius = 6371000.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp = p2 - p1
    dl = math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * radius * math.asin(math.sqrt(a))


def http_json(
    url: str,
    *,
    method: str = "GET",
    headers: dict[str, str] | None = None,
    body: dict[str, Any] | None = None,
    form: dict[str, str] | None = None,
    timeout: int = 30,
) -> Any:
    data = None
    hdrs = {"User-Agent": "MatchMe-place-compare/1.0", **(headers or {})}
    if form is not None:
        data = urllib.parse.urlencode(form).encode("utf-8")
        hdrs.setdefault("Content-Type", "application/x-www-form-urlencoded")
    elif body is not None:
        data = json.dumps(body).encode("utf-8")
        hdrs.setdefault("Content-Type", "application/json")
    request = urllib.request.Request(url, data=data, headers=hdrs, method=method)
    context = ssl.create_default_context()
    with urllib.request.urlopen(request, timeout=timeout, context=context) as response:
        return json.loads(response.read().decode("utf-8"))


def fetch_osm(
    center: tuple[float, float], radius: int, limit: int = 120
) -> list[Place]:
    query = OVERPASS_QL.format(
        radius=radius, lat=center[0], lon=center[1], limit=limit
    )
    errors: list[str] = []
    for endpoint in OVERPASS_ENDPOINTS:
        try:
            payload = http_json(
                endpoint,
                method="POST",
                form={"data": query},
                timeout=45,
            )
            places: list[Place] = []
            for element in payload.get("elements", []):
                tags = element.get("tags") or {}
                name = (
                    tags.get("name")
                    or tags.get("name:en")
                    or tags.get("name:he")
                    or ""
                ).strip()
                if not name:
                    continue
                lat = element.get("lat")
                lon = element.get("lon")
                if lat is None or lon is None:
                    center_obj = element.get("center") or {}
                    lat, lon = center_obj.get("lat"), center_obj.get("lon")
                if lat is None or lon is None:
                    continue
                category = tags.get("shop") or tags.get("amenity") or tags.get(
                    "leisure"
                ) or tags.get("tourism") or tags.get("railway") or tags.get(
                    "public_transport"
                ) or tags.get("place") or tags.get("historic") or ""
                places.append(
                    Place(
                        source="OSM",
                        name=name,
                        lat=float(lat),
                        lon=float(lon),
                        category=str(category),
                        meta={
                            "name:en": tags.get("name:en"),
                            "name:he": tags.get("name:he"),
                            "brand": tags.get("brand"),
                            "brand:wikidata": tags.get("brand:wikidata"),
                            "website": tags.get("website"),
                            "osm": f"{element.get('type')}/{element.get('id')}",
                        },
                        distance_m=haversine_m(center[0], center[1], float(lat), float(lon)),
                    )
                )
            return places
        except Exception as error:  # noqa: BLE001 - try the next mirror
            errors.append(f"{endpoint}: {error}")
            time.sleep(1.0)
    raise ProviderError("Overpass unavailable:\n  " + "\n  ".join(errors))


def load_osm_xml(paths: list[str], center: tuple[float, float]) -> list[Place]:
    """Read OSM API map extracts (XML) with the same category filter."""
    lat, lon = center
    places: list[Place] = []
    for path in paths:
        root = ET.parse(path).getroot()
        coords: dict[str, tuple[float, float]] = {}
        for node in root.findall("node"):
            coords[node.get("id", "")] = (
                float(node.get("lat")),
                float(node.get("lon")),
            )
        for element in root:
            if element.tag not in ("node", "way", "relation"):
                continue
            tags = {
                tag.get("k", ""): tag.get("v", "")
                for tag in element.findall("tag")
            }
            name = (
                tags.get("name")
                or tags.get("name:en")
                or tags.get("name:he")
                or ""
            ).strip()
            if len(name) < 2:
                continue
            category = next(
                (
                    tags[key]
                    for key in CATEGORY_KEYS
                    if tags.get(key) in WANTED_CATEGORIES
                ),
                "",
            )
            if not category:
                continue
            if element.tag == "node":
                point = coords.get(element.get("id", ""))
            else:
                points = [
                    coords[node.get("ref", "")]
                    for node in element.findall("nd")
                    if node.get("ref", "") in coords
                ]
                point = (
                    (
                        sum(p[0] for p in points) / len(points),
                        sum(p[1] for p in points) / len(points),
                    )
                    if points
                    else None
                )
            if point is None:
                continue
            plat, plon = point
            places.append(
                Place(
                    source="OSM",
                    name=name,
                    lat=plat,
                    lon=plon,
                    category=str(category),
                    meta={
                        "name:en": tags.get("name:en"),
                        "name:he": tags.get("name:he"),
                        "brand": tags.get("brand"),
                        "brand:wikidata": tags.get("brand:wikidata"),
                        "website": tags.get("website"),
                        "osm": f"{element.tag}/{element.get('id')}",
                    },
                    distance_m=haversine_m(lat, lon, plat, plon),
                )
            )
    return places


def fetch_overture(center: tuple[float, float], radius: int) -> list[Place]:
    try:
        import duckdb  # noqa: PLC0415 - optional dependency, only for this tool
    except ImportError as error:
        raise ProviderError(
            "duckdb is not installed: python -m pip install --user duckdb"
        ) from error

    lat, lon = center
    dlat = radius / 111320.0
    dlon = radius / (111320.0 * math.cos(math.radians(lat)))
    xmin, xmax = lon - dlon, lon + dlon
    ymin, ymax = lat - dlat, lat + dlat

    con = duckdb.connect()
    con.execute("INSTALL httpfs; LOAD httpfs;")
    con.execute("SET s3_region='us-west-2';")
    rows = con.execute(
        f"""
        SELECT names.primary AS name,
               COALESCE(taxonomy.primary, basic_category) AS category,
               bbox.xmin, bbox.xmax, bbox.ymin, bbox.ymax,
               confidence,
               array_to_string(list_transform(sources, lambda s: s.dataset), ',') AS datasets
        FROM read_parquet('{OVERTURE_PARQUET}')
        WHERE bbox.xmin < {xmax} AND bbox.xmax > {xmin}
          AND bbox.ymin < {ymax} AND bbox.ymax > {ymin}
          AND names.primary IS NOT NULL
        LIMIT 3000
        """
    ).fetchall()
    con.close()

    places: list[Place] = []
    for name, category, x0, x1, y0, y1, confidence, datasets in rows:
        plat, plon = (y0 + y1) / 2.0, (x0 + x1) / 2.0
        places.append(
            Place(
                source="Overture",
                name=name,
                lat=plat,
                lon=plon,
                category=category or "",
                meta={
                    "confidence": round(float(confidence or 0), 3),
                    "datasets": datasets or "",
                },
                distance_m=haversine_m(lat, lon, plat, plon),
            )
        )
    return places


def fetch_tomtom(center: tuple[float, float], radius: int) -> list[Place]:
    key = os.environ.get("TOMTOM_API_KEY", "").strip()
    if not key:
        raise ProviderError("TOMTOM_API_KEY not set")
    lat, lon = center
    url = (
        "https://api.tomtom.com/search/2/nearbySearch/.json?"
        + urllib.parse.urlencode(
            {
                "key": key,
                "lat": lat,
                "lon": lon,
                "radius": radius,
                "limit": 100,
                "language": "he-IL",
            }
        )
    )
    payload = http_json(url, timeout=30)
    places: list[Place] = []
    for result in payload.get("results", []):
        poi = result.get("poi") or {}
        name = (poi.get("name") or "").strip()
        position = result.get("position") or {}
        if not name or "lat" not in position:
            continue
        plat, plon = float(position["lat"]), float(position["lon"])
        places.append(
            Place(
                source="TomTom",
                name=name,
                lat=plat,
                lon=plon,
                category=", ".join(result.get("poi", {}).get("categories") or []),
                meta={
                    "address": (result.get("address") or {}).get("freeformAddress"),
                    "dataSources": (result.get("dataSources") or {}).get(
                        "poiDetails"
                    ),
                },
                distance_m=haversine_m(lat, lon, plat, plon),
            )
        )
    return places


def fetch_here(center: tuple[float, float], radius: int) -> list[Place]:
    key = os.environ.get("HERE_API_KEY", "").strip()
    if not key:
        raise ProviderError("HERE_API_KEY not set")
    lat, lon = center
    url = (
        "https://browse.search.hereapi.com/v1/browse?"
        + urllib.parse.urlencode(
            {
                "apiKey": key,
                "at": f"{lat},{lon}",
                "limit": 100,
                "in": f"circle:{lat},{lon};r={radius}",
            }
        )
    )
    payload = http_json(url, timeout=30)
    places: list[Place] = []
    for item in payload.get("items", []):
        name = (item.get("title") or "").strip()
        position = item.get("position") or {}
        if not name or "lat" not in position:
            continue
        plat, plon = float(position["lat"]), float(position["lon"])
        places.append(
            Place(
                source="HERE",
                name=name,
                lat=plat,
                lon=plon,
                category=", ".join(
                    c.get("name", "") for c in (item.get("categories") or [])
                ),
                meta={"address": (item.get("address") or {}).get("label")},
                distance_m=haversine_m(lat, lon, plat, plon),
            )
        )
    return places


def fetch_google(center: tuple[float, float], radius: int) -> list[Place]:
    key = os.environ.get("GOOGLE_MAPS_API_KEY", "").strip()
    if not key:
        raise ProviderError("GOOGLE_MAPS_API_KEY not set")
    lat, lon = center
    payload = http_json(
        "https://places.googleapis.com/v1/places:searchNearby",
        method="POST",
        headers={
            "X-Goog-Api-Key": key,
            "X-Goog-FieldMask": (
                "places.displayName,places.location,places.types,"
                "places.formattedAddress,places.businessStatus"
            ),
        },
        body={
            "locationRestriction": {
                "circle": {
                    "center": {"latitude": lat, "longitude": lon},
                    "radius": float(radius),
                }
            },
            "maxResultCount": 20,
            "languageCode": "he",
        },
        timeout=30,
    )
    places: list[Place] = []
    for item in payload.get("places", []):
        name = ((item.get("displayName") or {}).get("text") or "").strip()
        location = item.get("location") or {}
        if not name or "latitude" not in location:
            continue
        plat, plon = float(location["latitude"]), float(location["longitude"])
        places.append(
            Place(
                source="Google",
                name=name,
                lat=plat,
                lon=plon,
                category=", ".join(item.get("types") or []),
                meta={
                    "address": item.get("formattedAddress"),
                    "status": item.get("businessStatus"),
                },
                distance_m=haversine_m(lat, lon, plat, plon),
            )
        )
    return places


def fetch_foursquare(center: tuple[float, float], radius: int) -> list[Place]:
    key = os.environ.get("FOURSQUARE_API_KEY", "").strip()
    if not key:
        raise ProviderError("FOURSQUARE_API_KEY not set")
    lat, lon = center
    # The old v3 host (api.foursquare.com/v3) is retired and answers 410. The
    # current Places API is places-api.foursquare.com with a service key and a
    # pinned API version. Coordinates are top-level here, not geocodes.main.
    url = (
        "https://places-api.foursquare.com/places/search?"
        + urllib.parse.urlencode(
            {
                "ll": f"{lat},{lon}",
                "radius": radius,
                "limit": 50,
                "sort": "DISTANCE",
                "fields": (
                    "fsq_place_id,name,location,categories,"
                    "latitude,longitude,date_refreshed"
                ),
            }
        )
    )
    payload = http_json(
        url,
        headers={
            "Authorization": f"Bearer {key}",
            "X-Places-Api-Version": "2025-06-17",
        },
        timeout=30,
    )
    places: list[Place] = []
    for item in payload.get("results", []):
        name = (item.get("name") or "").strip()
        if not name or item.get("latitude") is None or item.get("longitude") is None:
            continue
        plat, plon = float(item["latitude"]), float(item["longitude"])
        places.append(
            Place(
                source="Foursquare",
                name=name,
                lat=plat,
                lon=plon,
                category=", ".join(
                    c.get("name", "") for c in (item.get("categories") or [])
                ),
                meta={
                    "address": (item.get("location") or {}).get("formatted_address"),
                    "fsq_place_id": item.get("fsq_place_id"),
                    "refreshed": item.get("date_refreshed"),
                },
                distance_m=haversine_m(lat, lon, plat, plon),
            )
        )
    return places


PROVIDERS = {
    "osm": ("OSM", fetch_osm),
    "overture": ("Overture", fetch_overture),
    "tomtom": ("TomTom", fetch_tomtom),
    "here": ("HERE", fetch_here),
    "google": ("Google", fetch_google),
    "foursquare": ("Foursquare", fetch_foursquare),
}

MATCH_RADIUS_M = 60.0


def nearest(places: list[Place], lat: float, lon: float, limit: float) -> Place | None:
    best: Place | None = None
    best_distance = limit
    for place in places:
        distance = haversine_m(lat, lon, place.lat, place.lon)
        if distance <= best_distance:
            best, best_distance = place, distance
    return best


def print_section(title: str) -> None:
    print()
    print(title)
    print("-" * len(title))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--center",
        default=f"{DEFAULT_CENTER[0]},{DEFAULT_CENTER[1]}",
        help="lat,lon of the area (default: the reported Ramat HaHayal store)",
    )
    parser.add_argument("--radius", type=int, default=DEFAULT_RADIUS)
    parser.add_argument(
        "--pin",
        action="append",
        default=[],
        help="lat,lon to inspect across providers (repeatable). "
        "Default: the center point.",
    )
    parser.add_argument(
        "--only",
        default="",
        help=f"comma list of: {', '.join(PROVIDERS)} (default: all)",
    )
    parser.add_argument("--limit", type=int, default=120, help="OSM result cap")
    parser.add_argument(
        "--osm-xml",
        action="append",
        default=[],
        metavar="FILE",
        help="read OSM API map extracts (.xml) instead of calling Overpass, "
        "for when the mirrors are down or offline comparison is wanted. "
        "Repeatable; the file must cover the area.",
    )
    parser.add_argument("--json", default="", help="write raw results to this file")
    args = parser.parse_args()

    center = tuple(float(v) for v in args.center.split(","))  # type: ignore[assignment]
    selected = [s.strip() for s in args.only.split(",") if s.strip()] or list(
        PROVIDERS
    )
    unknown = [s for s in selected if s not in PROVIDERS]
    if unknown:
        parser.error(f"unknown providers: {', '.join(unknown)}")

    results: dict[str, list[Place]] = {}
    skipped: dict[str, str] = {}
    for key in selected:
        label, loader = PROVIDERS[key]
        print(f"querying {label} ...", flush=True)
        try:
            if key == "osm" and args.osm_xml:
                results[label] = load_osm_xml(args.osm_xml, center)
            elif key == "osm":
                results[label] = fetch_osm(center, args.radius, args.limit)
            else:
                results[label] = loader(center, args.radius)  # type: ignore[arg-type]
        except ProviderError as error:
            skipped[label] = str(error)
            print(f"  skipped: {error}")
        except Exception as error:  # noqa: BLE001 - a provider outage must not stop the rest
            skipped[label] = f"{type(error).__name__}: {error}"
            print(f"  failed: {error}")
        time.sleep(0.5 if key == "osm" else 0.0)

    for label, places in results.items():
        places.sort(key=lambda p: p.distance_m)

    print_section(
        f"Area {center[0]:.6f},{center[1]:.6f}  radius {args.radius} m  "
        f"(Overture {OVERTURE_RELEASE})"
    )
    for label, places in results.items():
        print(f"  {label:<11} {len(places):>4} named places")

    pins = [tuple(float(v) for v in p.split(",")) for p in args.pin] or [center]
    for lat, lon in pins:
        print_section(f"Pin {lat:.6f},{lon:.6f} — nearest place per source (≤100 m)")
        for label, places in results.items():
            place = nearest(places, lat, lon, 100.0)
            if place is None:
                print(f"  {label:<11} —")
                continue
            print(
                f"  {label:<11} {place.name}  [{place.category or 'n/a'}]  "
                f"{place.distance_m:.0f} m"
            )
        for label, reason in skipped.items():
            print(f"  {label:<11} skipped ({reason})")

    osm = results.get("OSM", [])
    others = {k: v for k, v in results.items() if k != "OSM"}
    if osm and others:
        print_section(f"OSM candidates with nearest match in each other source (≤{MATCH_RADIUS_M:.0f} m)")
        header = f"{'OSM name':<32} {'cat':<16}"
        for label in others:
            header += f" | {label:<26}"
        print(header)
        print("-" * len(header))
        for place in osm[:40]:
            short = place.name if len(place.name) <= 30 else place.name[:29] + "…"
            row = f"{short:<32} {(place.category or '')[:15]:<16}"
            for label, collection in others.items():
                match = nearest(collection, place.lat, place.lon, MATCH_RADIUS_M)
                value = "—" if match is None else match.name
                if len(value) > 24:
                    value = value[:23] + "…"
                row += f" | {value:<26}"
            print(row)

    known = {"OSM", *others.keys()}
    for label, collection in others.items():
        only_here = [
            p
            for p in collection
            if not any(
                haversine_m(p.lat, p.lon, o.lat, o.lon) <= MATCH_RADIUS_M
                for o in osm
            )
        ]
        if not only_here:
            continue
        print_section(f"Only in {label} (no OSM place within {MATCH_RADIUS_M:.0f} m)")
        for place in only_here[:20]:
            print(
                f"  {place.name}  [{place.category or 'n/a'}]  "
                f"{place.distance_m:.0f} m from center"
            )

    if args.json:
        with open(args.json, "w", encoding="utf-8") as handle:
            json.dump(
                {
                    label: [place.__dict__ for place in places]
                    for label, places in results.items()
                },
                handle,
                ensure_ascii=False,
                indent=2,
            )
        print(f"\nraw results written to {args.json}")

    print()
    print("Providers without a key can be enabled by setting their env var:")
    print("  TOMTOM_API_KEY, HERE_API_KEY, GOOGLE_MAPS_API_KEY, FOURSQUARE_API_KEY")
    return 0


if __name__ == "__main__":
    try:
        sys.stdout.reconfigure(encoding="utf-8")  # type: ignore[attr-defined]
    except Exception:  # noqa: BLE001 - older consoles
        pass
    raise SystemExit(main())
