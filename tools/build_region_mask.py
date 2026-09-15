#!/usr/bin/env python3
"""Turns Natural Earth boundaries into the region mask the app ships.

The mask answers one question as cheaply as possible: which country and which state is this
grid square in? It is a raster on the very same Web Mercator grid the fog uses, so a lookup is
a shift and an array index rather than a point-in-polygon test over a few million vertices.

Percentages are *not* measured from the raster. A raster cell is several kilometres across, so
a region smaller than one cell would read as fully explored the moment you clipped its corner.
The denominators are true geodesic polygon areas instead, and the raster only decides which
region a square belongs to.

Usage:
    python3 tools/build_region_mask.py --zoom 12 \
        --countries ne_50m_admin_0_countries.geojson \
        --subdivisions ne_10m_admin_1_states_provinces.geojson \
        --out app/src/main/assets/regions.bin

Source data: Natural Earth (public domain), https://www.naturalearthdata.com
"""

from __future__ import annotations

import argparse
import json
import math
import struct
import sys
from collections import defaultdict

EARTH_RADIUS_M = 6_371_008.8

# Natural Earth files the scattered island territories under an ocean rather than a continent, and
# it files the whole of Russia under Europe. Neither is useful here: the first leaves eight
# countries continent-less, and the second hands Europe thirteen million square kilometres of
# Siberia, which is most of the denominator of "how much of Europe have I seen".
OPEN_OCEAN = "Seven seas (open ocean)"

CONTINENT_OVERRIDE = {
    # Three quarters of Russia's land is east of the Urals, so counting all of it as Asia is much
    # closer to the truth than counting all of it as Europe. Whole countries are kept whole either
    # way - splitting one across two continents would break the country roll-up.
    "RUS": "Asia",
}


# --------------------------------------------------------------------------------------- geometry

def lon_to_tile_x(lon: float, zoom: int) -> float:
    return (lon + 180.0) / 360.0 * (1 << zoom)


def lat_to_tile_y(lat: float, zoom: int) -> float:
    lat = max(-85.05112877980659, min(85.05112877980659, lat))
    rad = math.radians(lat)
    y = math.log(math.tan(rad) + 1.0 / math.cos(rad))
    return (1.0 - y / math.pi) / 2.0 * (1 << zoom)


def tile_y_to_lat(y: float, zoom: int) -> float:
    n = math.pi - 2.0 * math.pi * y / (1 << zoom)
    return math.degrees(math.atan(math.sinh(n)))


def ring_signed_area_m2(ring) -> float:
    """Spherical excess of a closed ring, signed by winding direction."""
    if len(ring) < 4:
        return 0.0
    total = 0.0
    for i in range(len(ring) - 1):
        lon1, lat1 = ring[i][0], ring[i][1]
        lon2, lat2 = ring[i + 1][0], ring[i + 1][1]
        dlon = math.radians(lon2 - lon1)
        # A ring may step across the antimeridian; take the short way round.
        if dlon > math.pi:
            dlon -= 2 * math.pi
        elif dlon < -math.pi:
            dlon += 2 * math.pi
        total += dlon * (2.0 + math.sin(math.radians(lat1)) + math.sin(math.radians(lat2)))
    return total * EARTH_RADIUS_M * EARTH_RADIUS_M / 2.0


def polygons_of(geometry):
    """Yields every polygon as a list of rings, whatever the geometry type."""
    if geometry is None:
        return
    kind = geometry.get("type")
    coords = geometry.get("coordinates")
    if kind == "Polygon":
        yield coords
    elif kind == "MultiPolygon":
        for polygon in coords:
            yield polygon


def geometry_area_m2(geometry) -> float:
    total = 0.0
    for polygon in polygons_of(geometry):
        if not polygon:
            continue
        outer = abs(ring_signed_area_m2(polygon[0]))
        holes = sum(abs(ring_signed_area_m2(r)) for r in polygon[1:])
        total += max(0.0, outer - holes)
    return total


# ------------------------------------------------------------------------------------ rasterising

class Rasteriser:
    """Scanline fill of geographic polygons onto the tile grid.

    Each output row is filled from the crossings of the row's *centre* latitude, which is the
    latitude the app will compare against when it looks a square up.
    """

    def __init__(self, zoom: int):
        self.zoom = zoom
        self.size = 1 << zoom
        self.row_lat = [tile_y_to_lat(y + 0.5, zoom) for y in range(self.size)]
        self.grid = [None] * self.size  # row -> dict of x -> region id, filled lazily

    def _rows_touching(self, lat_lo: float, lat_hi: float):
        # Rows run north to south, so the northern latitude gives the first row.
        y0 = int(math.floor(lat_to_tile_y(lat_hi, self.zoom) - 0.5))
        y1 = int(math.ceil(lat_to_tile_y(lat_lo, self.zoom) - 0.5))
        return max(0, y0), min(self.size - 1, y1)

    def fill(self, geometry, region_id: int, overwrite: bool = True) -> int:
        """Paints one feature. Returns how many squares it claimed."""
        edges = []  # (top_row, bottom_row, lat1, lon1, lat2, lon2)
        for polygon in polygons_of(geometry):
            for ring in polygon:
                for i in range(len(ring) - 1):
                    lon1, lat1 = ring[i][0], ring[i][1]
                    lon2, lat2 = ring[i + 1][0], ring[i + 1][1]
                    if lat1 == lat2:
                        continue  # horizontal edges contribute no crossing
                    top, bottom = self._rows_touching(min(lat1, lat2), max(lat1, lat2))
                    if bottom < top:
                        continue
                    edges.append((top, bottom, lat1, lon1, lat2, lon2))
        if not edges:
            return 0

        # Active-edge sweep: an edge enters at its northern row and leaves at its southern one.
        edges.sort(key=lambda e: e[0])
        first_row = edges[0][0]
        last_row = max(e[1] for e in edges)
        active = []
        cursor = 0
        painted = 0

        for y in range(first_row, last_row + 1):
            while cursor < len(edges) and edges[cursor][0] == y:
                active.append(edges[cursor])
                cursor += 1
            if not active:
                continue
            active = [e for e in active if e[1] >= y]
            lat = self.row_lat[y]
            crossings = []
            for _, _, lat1, lon1, lat2, lon2 in active:
                # Half-open in latitude so a vertex shared by two edges is counted once.
                if (lat1 <= lat < lat2) or (lat2 <= lat < lat1):
                    t = (lat - lat1) / (lat2 - lat1)
                    dlon = lon2 - lon1
                    if dlon > 180.0:
                        dlon -= 360.0
                    elif dlon < -180.0:
                        dlon += 360.0
                    crossings.append(lon1 + t * dlon)
            if len(crossings) < 2:
                continue
            crossings.sort()
            row = self.grid[y]
            if row is None:
                row = self.grid[y] = {}
            for i in range(0, len(crossings) - 1, 2):
                painted += self._span(row, y, crossings[i], crossings[i + 1], region_id, overwrite)
        return painted

    def _span(self, row, y, lon_west, lon_east, region_id, overwrite) -> int:
        x0 = int(math.floor(lon_to_tile_x(lon_west, self.zoom)))
        x1 = int(math.floor(lon_to_tile_x(lon_east, self.zoom)))
        # A span thinner than a square still deserves its square, or slivers vanish.
        if x1 < x0:
            x0, x1 = x1, x0
        painted = 0
        for x in range(max(0, x0), min(self.size - 1, x1) + 1):
            if overwrite or x not in row:
                if row.get(x) != region_id:
                    painted += 1
                row[x] = region_id
        return painted

    def force_cell(self, lat: float, lon: float, region_id: int):
        """Gives a region too small to catch a scanline the one square it sits in."""
        y = min(self.size - 1, max(0, int(lat_to_tile_y(lat, self.zoom))))
        x = min(self.size - 1, max(0, int(lon_to_tile_x(lon, self.zoom))))
        row = self.grid[y]
        if row is None:
            row = self.grid[y] = {}
        row.setdefault(x, region_id)

    def runs(self):
        """Row-major run-length encoding: (row, [(start_x, length, region_id), ...])."""
        for y, row in enumerate(self.grid):
            if not row:
                continue
            out = []
            start = None
            previous_x = None
            current = None
            for x in sorted(row):
                value = row[x]
                if start is not None and x == previous_x + 1 and value == current:
                    previous_x = x
                    continue
                if start is not None:
                    out.append((start, previous_x - start + 1, current))
                start, previous_x, current = x, x, value
            if start is not None:
                out.append((start, previous_x - start + 1, current))
            yield y, out


# ----------------------------------------------------------------------------------------- output

CONTINENT, COUNTRY, SUBDIVISION = 0, 1, 2

MAGIC = b"RMRG"
FORMAT_VERSION = 1


def write_mask(path, zoom, regions, rows):
    """regions: list of (kind, parent_index, code, name, area_m2) in id order."""
    out = bytearray()
    out += MAGIC
    out += struct.pack(">BB", FORMAT_VERSION, zoom)
    out += struct.pack(">H", len(regions))
    for kind, parent, code, name, area in regions:
        out += struct.pack(">Bh", kind, parent)
        out += struct.pack(">d", area)
        for text in (code, name):
            raw = text.encode("utf-8")
            if len(raw) > 255:
                raw = raw[:255]
            out += struct.pack(">B", len(raw)) + raw
    out += struct.pack(">I", len(rows))
    for y, runs in rows:
        out += struct.pack(">IH", y, len(runs))
        for start, length, region in runs:
            out += struct.pack(">HHH", start, length, region)
    with open(path, "wb") as handle:
        handle.write(bytes(out))
    return len(out)


# ------------------------------------------------------------------------------------------- main

def load(path):
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)["features"]


def country_key(properties):
    for field in ("ADM0_A3", "ISO_A3", "SOV_A3"):
        value = properties.get(field)
        if value and value not in ("-99", "-1"):
            return value
    return properties.get("ADMIN") or properties.get("NAME") or "???"


def continent_of(properties, key):
    """The continent a country is counted under."""
    override = CONTINENT_OVERRIDE.get(key)
    if override:
        return override
    continent = properties.get("CONTINENT")
    if continent and continent != OPEN_OCEAN:
        return continent
    region = properties.get("REGION_UN")
    if region == "Americas":
        # The UN lumps both Americas together; latitude is enough to tell them apart.
        return "South America" if (properties.get("LABEL_Y") or 0.0) < 12.0 else "North America"
    return region or "Other"


def country_code(properties):
    for field in ("ISO_A2_EH", "ISO_A2"):
        value = properties.get(field)
        if value and value not in ("-99", "-1"):
            return value
    return country_key(properties)[:2]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--zoom", type=int, default=12)
    parser.add_argument("--countries", required=True)
    parser.add_argument("--subdivisions", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args(argv)

    regions = []          # (kind, parent, code, name, area_m2)
    continent_ids = {}
    country_ids = {}      # ADM0 key -> region id
    country_area = defaultdict(float)

    def add(kind, parent, code, name, area=0.0):
        regions.append([kind, parent, code, name, area])
        return len(regions) - 1

    print("reading countries...", file=sys.stderr)
    countries = load(args.countries)
    country_features = []
    for feature in countries:
        properties = feature["properties"]
        if properties.get("TYPE") == "Dependency" and not properties.get("ADMIN"):
            continue
        key = country_key(properties)
        name = properties.get("ADMIN") or properties.get("NAME") or key
        continent = continent_of(properties, key)
        if continent not in continent_ids:
            continent_ids[continent] = add(CONTINENT, -1, continent, continent)
        if key not in country_ids:
            country_ids[key] = add(COUNTRY, continent_ids[continent], country_code(properties), name)
        country_area[key] += geometry_area_m2(feature["geometry"])
        country_features.append((key, feature))

    for key, region_id in country_ids.items():
        regions[region_id][4] = country_area[key]
    # A continent is exactly the countries placed in it, so that a country percentage and a
    # continent percentage are always measured against the same ground.
    for region in regions:
        if region[0] == COUNTRY and region[1] >= 0:
            regions[region[1]][4] += region[4]

    print(f"  {len(country_ids)} countries in {len(continent_ids)} continents", file=sys.stderr)

    print("reading subdivisions...", file=sys.stderr)
    subdivisions = load(args.subdivisions)
    subdivision_features = []
    for feature in subdivisions:
        properties = feature["properties"]
        name = properties.get("name") or properties.get("name_en") or properties.get("gn_name")
        if not name:
            continue
        parent_key = properties.get("adm0_a3") or properties.get("sov_a3")
        parent = country_ids.get(parent_key)
        if parent is None:
            continue
        code = properties.get("iso_3166_2") or properties.get("postal") or name
        area = geometry_area_m2(feature["geometry"])
        region_id = add(SUBDIVISION, parent, code, name, area)
        subdivision_features.append((region_id, feature))

    print(f"  {len(subdivision_features)} subdivisions", file=sys.stderr)
    if len(regions) > 0xFFFF:
        raise SystemExit(f"too many regions for a 16-bit id: {len(regions)}")

    print(f"rasterising at z{args.zoom} ({1 << args.zoom} squares across)...", file=sys.stderr)
    raster = Rasteriser(args.zoom)
    # Countries first, so a square inside a country but outside every subdivision - the coastal
    # fringe where the two datasets disagree - still knows which country it is in.
    for key, feature in country_features:
        raster.fill(feature["geometry"], country_ids[key])
    for key, feature in country_features:
        properties = feature["properties"]
        if properties.get("LABEL_Y") is not None and properties.get("LABEL_X") is not None:
            raster.force_cell(properties["LABEL_Y"], properties["LABEL_X"], country_ids[key])

    for region_id, feature in subdivision_features:
        raster.fill(feature["geometry"], region_id)
    for region_id, feature in subdivision_features:
        properties = feature["properties"]
        if properties.get("latitude") is not None and properties.get("longitude") is not None:
            raster.force_cell(properties["latitude"], properties["longitude"], region_id)

    rows = [(y, runs) for y, runs in raster.runs()]
    run_count = sum(len(r) for _, r in rows)
    print(f"  {len(rows)} rows, {run_count} runs", file=sys.stderr)

    size = write_mask(args.out, args.zoom, regions, rows)
    print(f"wrote {args.out}: {size / 1024:.0f} KiB, {len(regions)} regions", file=sys.stderr)


if __name__ == "__main__":
    main()
