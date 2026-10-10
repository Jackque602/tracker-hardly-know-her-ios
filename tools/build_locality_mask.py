#!/usr/bin/env python3
"""Builds the finer-grained atlases that sit underneath a state.

`regions.bin` stops at the state, and it has to: it is drawn at z12, where one square is about
56 km2, and the median American city is 30 km2. Rasterising a city onto that grid would hand it
every fog cell for miles around and call it fully explored after one drive past the airport.

So the detail tiers ship as their own files, each at the resolution its tier actually needs:

    counties-us.bin   z12   a county is ~1,600 km2, which is ~29 squares - the existing grid is
                            already fine enough, so this costs almost nothing
    cities-us.bin     z15   one square is ~0.9 km2, so a median city is ~34 squares, which is
                            enough for a percentage to mean something

Both are written in exactly the format `regions.bin` uses, so the app reads all three with one
decoder. Each file is self-contained: the states its localities belong to are repeated inside it
as parent records, carrying the same `US-XX` codes the main atlas uses, which is what lets the
app join the two without either file knowing the other's region numbering.

`regions.bin` itself is deliberately NOT rebuilt. It is shared byte for byte with the Android
build, whose reader rejects region kinds it does not know, so adding a tier to it would blank out
that app's statistics entirely.

Usage:
    python3 tools/build_locality_mask.py counties --zoom 12 \
        --counties geojson-counties-fips.json \
        --subdivisions ne_10m_admin_1_states_provinces.geojson \
        --out Core/Sources/RoamedCore/Resources/counties-us.bin

    python3 tools/build_locality_mask.py cities --zoom 15 \
        --urban ne_10m_urban_areas.geojson \
        --places ne_10m_populated_places.geojson \
        --subdivisions ne_10m_admin_1_states_provinces.geojson \
        --out Core/Sources/RoamedCore/Resources/cities-us.bin

Source data:
  - US county boundaries: US Census Bureau cartographic boundary files (public domain).
  - Urban footprints and populated places: Natural Earth (public domain).
"""

from __future__ import annotations

import argparse
import json
import math
import os
import struct
import sys
from collections import defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from build_region_mask import (  # noqa: E402
    Rasteriser,
    SUBDIVISION,
    geometry_area_m2,
    lat_to_tile_y,
    lon_to_tile_x,
    polygons_of,
    write_mask,
)

# Two tiers below a state. Kept out of `regions.bin`, which only ever holds 0, 1 and 2.
COUNTY, CITY = 3, 4

# Census state FIPS to the USPS abbreviation the atlas's `US-XX` codes are built from.
STATE_FIPS = {
    "01": "AL", "02": "AK", "04": "AZ", "05": "AR", "06": "CA", "08": "CO", "09": "CT",
    "10": "DE", "11": "DC", "12": "FL", "13": "GA", "15": "HI", "16": "ID", "17": "IL",
    "18": "IN", "19": "IA", "20": "KS", "21": "KY", "22": "LA", "23": "ME", "24": "MD",
    "25": "MA", "26": "MI", "27": "MN", "28": "MS", "29": "MO", "30": "MT", "31": "NE",
    "32": "NV", "33": "NH", "34": "NJ", "35": "NM", "36": "NY", "37": "NC", "38": "ND",
    "39": "OH", "40": "OK", "41": "OR", "42": "PA", "44": "RI", "45": "SC", "46": "SD",
    "47": "TN", "48": "TX", "49": "UT", "50": "VT", "51": "VA", "53": "WA", "54": "WV",
    "55": "WI", "56": "WY", "60": "AS", "66": "GU", "69": "MP", "72": "PR", "78": "VI",
}


def load_features(path):
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)["features"]


def us_states(subdivision_path):
    """The atlas's own US states: `US-XX` code, name and true area, keyed by code.

    Read from the same Natural Earth file `regions.bin` was built from, so the codes, the names
    and the denominators all agree with what the main atlas already shows.
    """
    states = {}
    for feature in load_features(subdivision_path):
        properties = feature["properties"]
        if (properties.get("adm0_a3") or properties.get("sov_a3")) != "USA":
            continue
        name = properties.get("name") or properties.get("name_en")
        code = properties.get("iso_3166_2")
        if not name or not code or not code.startswith("US-"):
            continue
        states[code] = {
            "code": code,
            "name": name,
            "area": geometry_area_m2(feature["geometry"]),
            "geometry": feature["geometry"],
        }
    return states


# --------------------------------------------------------------------- the atlas to agree with

class MainAtlas:
    """Just enough of `regions.bin` to ask which state a square is counted under."""

    def __init__(self, path):
        data = open(path, "rb").read()
        self.pos = 0
        self.data = data
        if self._take(4) != b"RMRG":
            raise SystemExit(f"{path} is not a region mask")
        self._take(1)
        self.zoom = self._take(1)[0]
        count = struct.unpack(">H", self._take(2))[0]
        self.regions = []
        for _ in range(count):
            kind = self._take(1)[0]
            parent = struct.unpack(">h", self._take(2))[0]
            struct.unpack(">d", self._take(8))[0]
            code = self._take(self._take(1)[0]).decode("utf-8")
            self._take(self._take(1)[0])
            self.regions.append((kind, parent, code))
        rows = struct.unpack(">i", self._take(4))[0]
        size = 1 << self.zoom
        self.size = size
        self.offsets = [0] * (size + 1)
        self.starts, self.lengths, self.values = [], [], []
        next_row = 0
        for _ in range(rows):
            y = struct.unpack(">i", self._take(4))[0]
            for empty in range(next_row, y + 1):
                self.offsets[empty] = len(self.starts)
            for _ in range(struct.unpack(">H", self._take(2))[0]):
                self.starts.append(struct.unpack(">H", self._take(2))[0])
                self.lengths.append(struct.unpack(">H", self._take(2))[0])
                self.values.append(struct.unpack(">H", self._take(2))[0])
            next_row = y + 1
        for trailing in range(next_row, size + 1):
            self.offsets[trailing] = len(self.starts)

    def _take(self, n):
        value = self.data[self.pos:self.pos + n]
        self.pos += n
        return value

    def region_at(self, x, y):
        if y < 0 or y >= self.size:
            return -1
        low, high = self.offsets[y], self.offsets[y + 1] - 1
        while low <= high:
            mid = (low + high) // 2
            start = self.starts[mid]
            if x < start:
                high = mid - 1
            elif x >= start + self.lengths[mid]:
                low = mid + 1
            else:
                return self.values[mid]
        return -1

    def subdivision_code_at(self, x, y):
        """The `US-XX` code of the state owning a square, or None."""
        region = self.region_at(x, y)
        while region != -1:
            kind, parent, code = self.regions[region]
            if kind == SUBDIVISION:
                return code
            region = parent
        return None


def straddlers(raster, atlas, owner_of, zoom):
    """Localities holding ground the main atlas counts under some other state.

    A quick, coarse question asked of the cheap file, only to decide who needs the expensive
    answer. Counties never genuinely straddle - the Census draws them inside one state by
    construction - so anything this flags there is two rasters disagreeing along a border, which
    is not worth correcting. Cities really do straddle, and those get clipped properly below.
    """
    shift = zoom - atlas.zoom
    if shift < 0:
        raise SystemExit(f"the locality grid (z{zoom}) is coarser than the atlas (z{atlas.zoom})")
    foreign = set()
    for y, row in enumerate(raster.grid):
        if not row:
            continue
        for x, region_id in row.items():
            code = atlas.subdivision_code_at(x >> shift, y >> shift)
            if code is not None and code != owner_of[region_id]:
                foreign.add(region_id)
    return foreign


def clip_cities_to_states(raster, entries, states, owner_of, suspects, zoom):
    """Trims a city back to the one state it is filed under.

    Natural Earth draws Philadelphia as the whole metropolitan footprint, which runs well into
    Delaware and New Jersey. Left alone, walking around Christiana would be credited to a
    Pennsylvania city - and the app would then be counting the same ground under two places that
    do not contain one another, which is the one thing the nesting is supposed to guarantee.

    The state's own boundary is rasterised at the city grid's resolution to do it. Clipping
    against the main atlas instead would be cheaper and much worse: its squares are 56 km2, so it
    would take most of Washington D.C. off the map along with the part of Philadelphia that is
    really in New Jersey.

    Returns the surviving share of each clipped city's squares, which its area is then scaled by
    so that a trimmed city can still read as fully explored.
    """
    by_state = defaultdict(list)
    for region_id in suspects:
        by_state[owner_of[region_id]].append(region_id)

    cells_of = defaultdict(list)
    for y, row in enumerate(raster.grid):
        if not row:
            continue
        for x, region_id in row.items():
            if region_id in suspects:
                cells_of[region_id].append((x, y))

    kept = {}
    for code, region_ids in sorted(by_state.items()):
        state_raster = Rasteriser(zoom)
        state_raster.fill(states[code]["geometry"], 1)
        for region_id in region_ids:
            cells = cells_of[region_id]
            survivors = 0
            for x, y in cells:
                row = state_raster.grid[y]
                if row is not None and x in row:
                    survivors += 1
                else:
                    del raster.grid[y][x]
            kept[region_id] = survivors / len(cells) if cells else 0.0
    return kept


# ------------------------------------------------------------------------------------- the tiers

def collect_counties(args, states):
    """County polygons, parented to the state their FIPS prefix names."""
    out = []
    skipped = 0
    for feature in load_features(args.counties):
        properties = feature["properties"]
        abbreviation = STATE_FIPS.get(properties.get("STATE") or "")
        code = f"US-{abbreviation}" if abbreviation else None
        if code not in states:
            skipped += 1
            continue
        name = properties.get("NAME") or ""
        if not name:
            skipped += 1
            continue
        # "Autauga" is not what anyone calls it; Louisiana has parishes and Alaska has boroughs,
        # and LSAD is the field that knows which.
        suffix = (properties.get("LSAD") or "County").strip()
        full = name if name.endswith(suffix) else f"{name} {suffix}".strip()
        out.append({
            "parent": code,
            "code": f"{properties.get('STATE','')}{properties.get('COUNTY','')}",
            "name": full,
            "area": geometry_area_m2(feature["geometry"]),
            "geometry": feature["geometry"],
            "point": None,
        })
    print(f"  {len(out)} counties ({skipped} outside the states the atlas knows)", file=sys.stderr)
    return out


def ring_contains(ring, lon, lat):
    """Even-odd point in ring, in plain lon/lat - exact enough at a city's scale."""
    inside = False
    count = len(ring)
    j = count - 1
    for i in range(count):
        xi, yi = ring[i][0], ring[i][1]
        xj, yj = ring[j][0], ring[j][1]
        if (yi > lat) != (yj > lat):
            if lon < (xj - xi) * (lat - yi) / (yj - yi) + xi:
                inside = not inside
        j = i
    return inside


def polygon_contains(polygon, lon, lat):
    if not polygon or not ring_contains(polygon[0], lon, lat):
        return False
    return not any(ring_contains(hole, lon, lat) for hole in polygon[1:])


def collect_cities(args, states):
    """Urban footprints, named by the populated place sitting inside them.

    Natural Earth's urban areas are unnamed - they are a cartographic layer of built-up ground,
    not a gazetteer - and its populated places are bare points, which have no area and so cannot
    carry a percentage. One is the shape and the other is the name, so they are joined here: an
    urban polygon takes the name of the largest place inside it. Polygons with no place in them
    are suburbs and sprawl that nobody would recognise as a city, and are dropped.
    """
    by_state_name = {s["name"]: s["code"] for s in states.values()}

    places = []
    for feature in load_features(args.places):
        properties = feature["properties"]
        if properties.get("ISO_A2") != "US" and properties.get("ADM0_A3") != "USA":
            continue
        parent = by_state_name.get(properties.get("ADM1NAME") or "")
        if parent is None:
            continue
        coordinates = (feature.get("geometry") or {}).get("coordinates")
        if not coordinates:
            continue
        places.append({
            "name": properties.get("NAME") or properties.get("NAMEASCII") or "",
            "parent": parent,
            "lon": float(coordinates[0]),
            "lat": float(coordinates[1]),
            "pop": int(properties.get("POP_MAX") or 0),
        })
    print(f"  {len(places)} US populated places with a state", file=sys.stderr)

    # One-degree buckets, so each polygon only tests the handful of points near it.
    buckets = {}
    for place in places:
        buckets.setdefault((int(math.floor(place["lon"])), int(math.floor(place["lat"]))), []).append(place)

    out = []
    for feature in load_features(args.urban):
        geometry = feature.get("geometry")
        best = None
        for polygon in polygons_of(geometry):
            if not polygon:
                continue
            ring = polygon[0]
            lons = [p[0] for p in ring]
            lats = [p[1] for p in ring]
            # Continental US plus Alaska and Hawaii; everything else is somebody else's city.
            if max(lons) < -180 or min(lons) > -66 or max(lats) < 17 or min(lats) > 72:
                continue
            candidates = []
            for bx in range(int(math.floor(min(lons))), int(math.floor(max(lons))) + 1):
                for by in range(int(math.floor(min(lats))), int(math.floor(max(lats))) + 1):
                    candidates.extend(buckets.get((bx, by), ()))
            for place in candidates:
                if place["pop"] <= (best["pop"] if best else -1):
                    continue
                if polygon_contains(polygon, place["lon"], place["lat"]):
                    best = place
        if best is None:
            continue
        out.append({
            "parent": best["parent"],
            "code": f"{best['parent']}-{best['name']}".replace(" ", "-"),
            "name": best["name"],
            "area": geometry_area_m2(geometry),
            "geometry": geometry,
            "point": (best["lat"], best["lon"]),
        })

    # One name can win two polygons - a city split by a river shows up twice in the source. Keep
    # the largest, or the list reads as a duplicate.
    best_by_name = {}
    for city in out:
        key = (city["parent"], city["name"])
        if key not in best_by_name or city["area"] > best_by_name[key]["area"]:
            best_by_name[key] = city
    cities = sorted(best_by_name.values(), key=lambda c: -c["area"])
    print(f"  {len(cities)} named US urban footprints", file=sys.stderr)
    return cities


# ------------------------------------------------------------------------------------------ main

def build(args, localities, states):
    used = sorted({locality["parent"] for locality in localities})
    regions = []
    stub_ids = {}
    for code in used:
        state = states[code]
        stub_ids[code] = len(regions)
        regions.append([SUBDIVISION, -1, state["code"], state["name"], state["area"]])

    kind = COUNTY if args.command == "counties" else CITY
    entries = []
    for locality in localities:
        region_id = len(regions)
        regions.append([kind, stub_ids[locality["parent"]], locality["code"], locality["name"],
                        locality["area"]])
        entries.append((region_id, locality))

    if len(regions) > 0xFFFF:
        raise SystemExit(f"too many regions for a 16-bit id: {len(regions)}")
    if (1 << args.zoom) > 0x10000:
        raise SystemExit(f"z{args.zoom} is wider than a 16-bit column index")

    print(f"rasterising {len(entries)} at z{args.zoom} "
          f"({1 << args.zoom} squares across)...", file=sys.stderr)
    raster = Rasteriser(args.zoom)
    # Largest first, so where two footprints overlap the smaller one wins the shared ground - a
    # town swallowed by a metro area should still be findable as itself.
    for region_id, locality in sorted(entries, key=lambda e: -e[1]["area"]):
        raster.fill(locality["geometry"], region_id)
    for region_id, locality in entries:
        point = locality["point"]
        if point is not None:
            raster.force_cell(point[0], point[1], region_id)

    owner_of = {region_id: locality["parent"] for region_id, locality in entries}
    if args.command == "cities":
        print("checking which cities cross a state line...", file=sys.stderr)
        suspects = straddlers(raster, MainAtlas(args.regions), owner_of, args.zoom)
        print(f"  {len(suspects)} of {len(entries)} do; clipping those to their state",
              file=sys.stderr)
        kept = clip_cities_to_states(raster, entries, states, owner_of, suspects, args.zoom)
        for region_id, share in kept.items():
            # The denominator has to shrink with the ground, or a city half of which is in the
            # next state along could never read as fully explored.
            regions[region_id][4] *= share
        emptied = sum(1 for share in kept.values() if share <= 0.0)
        for name, share in sorted(((regions[i][3], s) for i, s in kept.items()),
                                  key=lambda c: c[1])[:6]:
            print(f"      {name}: kept {share * 100:.0f}%", file=sys.stderr)
        if emptied:
            # Nothing left to explore, so they can never appear in a tally. Left in the file
            # rather than renumbering every region around them; they cost twenty bytes each.
            print(f"  {emptied} were wholly in another state and will never show", file=sys.stderr)

    rows = [(y, runs) for y, runs in raster.runs()]
    run_count = sum(len(r) for _, r in rows)
    print(f"  {len(rows)} rows, {run_count} runs", file=sys.stderr)

    size = write_mask(args.out, args.zoom, regions, rows)
    print(f"wrote {args.out}: {size / 1024:.0f} KiB, {len(regions)} regions "
          f"({len(used)} states + {len(entries)} localities)", file=sys.stderr)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=("counties", "cities"))
    parser.add_argument("--zoom", type=int)
    parser.add_argument("--subdivisions", required=True)
    parser.add_argument("--regions", required=True,
                        help="the main regions.bin, which decides which state a square is in")
    parser.add_argument("--counties")
    parser.add_argument("--urban")
    parser.add_argument("--places")
    parser.add_argument("--out", required=True)
    args = parser.parse_args(argv)
    if args.zoom is None:
        args.zoom = 12 if args.command == "counties" else 15

    print("reading the atlas's own states...", file=sys.stderr)
    states = us_states(args.subdivisions)
    print(f"  {len(states)} US states and districts", file=sys.stderr)

    if args.command == "counties":
        if not args.counties:
            raise SystemExit("counties needs --counties")
        localities = collect_counties(args, states)
    else:
        if not (args.urban and args.places):
            raise SystemExit("cities needs --urban and --places")
        localities = collect_cities(args, states)

    build(args, localities, states)


if __name__ == "__main__":
    main()
