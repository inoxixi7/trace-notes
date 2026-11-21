#!/usr/bin/env python3
"""Build Trace Notes' "China mainland" display region (china-mainland.bin).

The region answers one question for the map display layer: should this WGS-84 point be shifted
to GCJ-02 before drawing? It is mainland China *excluding* Hong Kong, Macau and Taiwan-controlled
islands, extended a little out to sea so coastal and ferry tracks do not flip back and forth at a
coarse coastline.

Inputs (development-time only, not shipped):
  * Natural Earth 1:10m Admin-0 countries (public domain), https://www.naturalearthdata.com
  * OpenStreetMap boundary relations for Hong Kong and Macau (© OpenStreetMap contributors, ODbL 1.0),
    fetched by fetch_osm.py

Construction:
  sea  = buffer(NE China, SEA_BUFFER) − other countries' land (NE) − Hong Kong (OSM) − Macau (OSM)
         − buffer(NE Taiwan, TAIWAN_BUFFER)
  land = NE China − Hong Kong (OSM) − Macau (OSM)
  region = simplify(sea ∪ land, SIMPLIFY_TOLERANCE)
NE's Hong Kong and Macau units are replaced by the OSM ones, because NE's accuracy (hundreds of
metres) is not enough at the Lo Wu and Gongbei crossings.

Output format (little-endian):
  "TNCB" magic, uint32 version (1), uint32 polygon count;
  per polygon: uint32 ring count (first ring = exterior, then holes);
  per ring: uint32 point count, then point count × (int32 latitude·1e6, int32 longitude·1e6).

Usage: <venv>/bin/python -I build_boundary.py <ne_dir> <osm_dir> <output.bin>
"""
import json
import pathlib
import struct
import sys

from shapely import geometry, ops
from shapely.validation import make_valid

SEA_BUFFER = 0.1          # degrees (~10 km): covers piers, beaches and near-shore ferries
TAIWAN_BUFFER = 0.01      # degrees (~1 km): Kinmen is ~2 km from Xiamen, so keep this small
SIMPLIFY_TOLERANCE = 0.0002  # degrees (~20 m); Gongbei and Lo Wu crossings are ~200 m apart


# ---- Minimal shapefile (.shp polygon) + dBASE (.dbf) reader -----------------------------------

def read_dbf(path: pathlib.Path) -> list[dict]:
    data = path.read_bytes()
    records, header_len, record_len = struct.unpack("<xxxxIHH", data[:12])
    fields, offset = [], 32
    while data[offset] != 0x0D:
        name = data[offset:offset + 11].split(b"\0", 1)[0].decode("ascii")
        length = data[offset + 16]
        fields.append((name, length))
        offset += 32
    rows = []
    for index in range(records):
        start = header_len + index * record_len + 1  # skip deletion flag
        row, position = {}, start
        for name, length in fields:
            row[name] = data[position:position + length].decode("utf-8", "replace").strip()
            position += length
        rows.append(row)
    return rows


def read_shp_polygons(path: pathlib.Path) -> list:
    data = path.read_bytes()
    shapes, offset = [], 100
    while offset < len(data):
        _, content_len = struct.unpack(">II", data[offset:offset + 8])
        content = data[offset + 8:offset + 8 + content_len * 2]
        offset += 8 + content_len * 2
        shape_type = struct.unpack("<i", content[:4])[0]
        if shape_type == 0:
            shapes.append(None)
            continue
        assert shape_type == 5, f"unexpected shape type {shape_type}"
        num_parts, num_points = struct.unpack("<ii", content[36:44])
        parts = list(struct.unpack(f"<{num_parts}i", content[44:44 + 4 * num_parts]))
        points_start = 44 + 4 * num_parts
        points = [struct.unpack("<dd", content[points_start + 16 * i:points_start + 16 * i + 16])
                  for i in range(num_points)]
        rings = [points[start:end] for start, end in zip(parts, parts[1:] + [num_points])]
        # Shapefile rings: clockwise = exterior; build via polygonize-like union of exteriors minus holes.
        polygons, holes = [], []
        for ring in rings:
            if len(ring) < 4:
                continue
            (polygons if geometry.LinearRing(ring).is_ccw is False else holes).append(geometry.Polygon(ring))
        shape = ops.unary_union(polygons)
        if holes:
            shape = shape.difference(ops.unary_union(holes))
        shapes.append(make_valid(shape))
    return shapes


# ---- OSM relation → polygon ------------------------------------------------------------------

def osm_relation_polygon(relation: dict):
    lines = []
    for member in relation["members"]:
        if member["type"] == "way" and member.get("role") in ("outer", "") and "geometry" in member:
            lines.append(geometry.LineString([(p["lon"], p["lat"]) for p in member["geometry"]]))
    polygons = list(ops.polygonize(ops.linemerge(lines)))
    assert polygons, f"could not assemble relation {relation['id']}"
    return make_valid(ops.unary_union(polygons))


# ---- Build -----------------------------------------------------------------------------------

def main() -> None:
    ne_dir, osm_dir, output = (pathlib.Path(arg) for arg in sys.argv[1:4])
    rows = read_dbf(ne_dir / "ne_10m_admin_0_countries.dbf")
    shapes = read_shp_polygons(ne_dir / "ne_10m_admin_0_countries.shp")
    by_code = {}
    for row, shape in zip(rows, shapes):
        if shape is not None:
            by_code.setdefault(row["ADM0_A3"], []).append(shape)

    china = ops.unary_union(by_code.pop("CHN"))
    taiwan = ops.unary_union(by_code.pop("TWN"))
    by_code.pop("HKG", None)
    by_code.pop("MAC", None)
    others = ops.unary_union([shape for shapes_ in by_code.values() for shape in shapes_])

    osm = json.loads((osm_dir / "boundaries.json").read_text())
    special = {}
    for element in osm["elements"]:
        code = element["tags"]["ISO3166-1"]
        special[code] = osm_relation_polygon(element)
    hong_kong, macau = special["HK"], special["MO"]
    print(f"Hong Kong area {hong_kong.area:.4f} deg², Macau area {macau.area:.5f} deg²")

    near = china.buffer(SEA_BUFFER, quad_segs=4)
    others_near = others.intersection(near.envelope)
    sea = (near.difference(others_near)
               .difference(hong_kong)
               .difference(macau)
               .difference(taiwan.buffer(TAIWAN_BUFFER, quad_segs=4)))
    land = china.difference(hong_kong).difference(macau)
    region = make_valid(sea.union(land)).simplify(SIMPLIFY_TOLERANCE, preserve_topology=True)
    region = make_valid(region)

    polygons = [region] if region.geom_type == "Polygon" else [
        g for g in getattr(region, "geoms", []) if g.geom_type == "Polygon"]
    # Drop slivers created by buffering/difference (< ~0.01 km²).
    polygons = [p for p in polygons if p.area > 1e-6]

    payload = bytearray(b"TNCB")
    payload += struct.pack("<II", 1, len(polygons))
    total_points = 0
    for polygon in polygons:
        rings = [polygon.exterior, *polygon.interiors]
        payload += struct.pack("<I", len(rings))
        for ring in rings:
            coords = list(ring.coords)[:-1]  # drop closing duplicate
            payload += struct.pack("<I", len(coords))
            for lon, lat in coords:
                payload += struct.pack("<ii", round(lat * 1e6), round(lon * 1e6))
            total_points += len(coords)
    output.write_bytes(payload)
    print(f"polygons={len(polygons)} points={total_points} bytes={len(payload)}")

    # Spot checks (lat, lon) mirroring the Swift unit tests.
    checks = {
        "Beijing": (39.9042, 116.4074, True), "Shanghai": (31.2304, 121.4737, True),
        "Shenzhen Luohu": (22.5390, 114.1180, True), "Hong Kong Lo Wu": (22.5280, 114.1130, False),
        "Zhuhai Gongbei": (22.2180, 113.5490, True), "Macau Portas do Cerco": (22.2140, 113.5500, False),
        "Xiamen": (24.4798, 118.0894, True), "Kinmen": (24.4320, 118.3170, False),
        "Dandong": (40.1290, 124.3940, True), "Sinuiju": (40.1000, 124.3980, False),
        "Tokyo": (35.6762, 139.6503, False), "Seoul": (37.5665, 126.9780, False),
        "Taipei": (25.0330, 121.5654, False),
    }
    for name, (lat, lon, expected) in checks.items():
        inside = region.contains(geometry.Point(lon, lat))
        print(f"  {'OK ' if inside == expected else 'BAD'} {name}: inside={inside}")


if __name__ == "__main__":
    main()
