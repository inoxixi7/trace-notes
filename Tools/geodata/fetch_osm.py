#!/usr/bin/env python3
"""Fetch OpenStreetMap data used to build Trace Notes' China mainland region and debug routes.

Data © OpenStreetMap contributors, ODbL 1.0 (https://www.openstreetmap.org/copyright).

Usage: python3 -I fetch_osm.py <output_dir>
Writes <output_dir>/boundaries.json (Hong Kong and Macau, ISO3166-1 HK / MO, with geometry)
and <output_dir>/routes/<id>.json (road geometries for the debug page presets).
Development-time only; nothing here ships in the app.
"""
import json
import pathlib
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

ENDPOINT = "https://overpass-api.de/api/interpreter"
USER_AGENT = "trace-notes-geodata/1.0"

BOUNDARIES = '[out:json][timeout:120];rel["ISO3166-1"~"^(HK|MO)$"]["boundary"="administrative"];out geom;'

# (id, overpass filter). Bounding boxes are (south, west, north, east).
ROUTES = [
    ("beijing-changan", 'way["highway"]["name"~"长安街"](39.9050,116.3700,39.9100,116.4250);'),
    ("shanghai-nanjing-road", 'way["highway"]["name"="南京东路"](31.2330,121.4700,31.2420,121.4920);'),
    ("shenzhen-hongkong-lowu-rail", 'way["railway"="rail"](22.4960,114.1050,22.5450,114.1300);'),
    ("zhuhai-macau-gongbei", 'way["highway"]["name"~"迎宾南路"](22.2150,113.5400,22.2400,113.5600);'
                             'way["highway"]["name:pt"~"Almirante Lacerda"](22.1950,113.5400,22.2150,113.5560);'),
    ("hongkong-nathan-road", 'way["highway"]["name:en"="Nathan Road"](22.2950,114.1650,22.3300,114.1750);'),
    ("tokyo-chuo-dori", 'way["highway"]["name"="中央通り"](35.6650,139.7600,35.7000,139.7750);'),
]


def query(ql: str, attempts: int = 5) -> dict:
    """POST an Overpass QL query. The public instance often answers 429/502/504 under load,
    so retry with exponential backoff before giving up."""
    body = urllib.parse.urlencode({"data": ql}).encode()
    for attempt in range(attempts):
        request = urllib.request.Request(ENDPOINT, data=body, headers={"User-Agent": USER_AGENT})
        try:
            with urllib.request.urlopen(request, timeout=180) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            if error.code not in (429, 502, 503, 504) or attempt == attempts - 1:
                raise
            wait = 5 * 2 ** attempt
            print(f"  Overpass HTTP {error.code}; retrying in {wait}s", file=sys.stderr)
            time.sleep(wait)
    raise RuntimeError("unreachable")


def main() -> None:
    out = pathlib.Path(sys.argv[1])
    (out / "routes").mkdir(parents=True, exist_ok=True)
    boundaries = out / "boundaries.json"
    if not boundaries.exists():
        data = query(BOUNDARIES)
        boundaries.write_text(json.dumps(data))
        print("boundaries:", [e.get("tags", {}).get("name:en") for e in data["elements"]])
    for route_id, ql_filter in ROUTES:
        if (out / "routes" / f"{route_id}.json").exists():
            continue
        time.sleep(2)  # be polite to the public Overpass instance
        data = query(f"[out:json][timeout:60];({ql_filter});out geom;")
        (out / "routes" / f"{route_id}.json").write_text(json.dumps(data))
        print(route_id, "ways:", len(data["elements"]))


if __name__ == "__main__":
    main()
