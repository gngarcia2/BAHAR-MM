"""
BAHAR Preprocessing Script v6
==============================
Reads NCR 100-year flood depth tiled shapefiles (precise cm-level depths),
rasterises to a QC-wide binary grid using the fast scanline algorithm.

Requires: pyshp  (pip install pyshp)   — no pyproj needed, UTM math is built-in.

Input:  NCR_Flood Depth(100year) tile folder  (set SHP_DIR below)
Output: qc_flood.bin + qc_flood_header.json
"""

import os, json, math, array
import shapefile

# ── Paths ─────────────────────────────────────────────────────────────────────
SHP_DIR    = r"c:\Users\eka\Desktop\NOAH AR\Data\NCR_Flood Depth(100year)"
OUTPUT_DIR = r"c:\Users\eka\Desktop\NOAH AR"

# ── Grid — full Quezon City ───────────────────────────────────────────────────
BOUNDS = {
    "west":  120.945,
    "south": 14.580,
    "east":  121.175,
    "north": 14.785,
}
CELL_DEG = 0.00005   # ≈ 5.5 m per cell
STEP     = 0.01      # 1 cm depth quantisation

cols = round((BOUNDS["east"]  - BOUNDS["west"])  / CELL_DEG)
rows = round((BOUNDS["north"] - BOUNDS["south"]) / CELL_DEG)
print(f"Grid : {cols} cols × {rows} rows = {cols*rows:,} cells")
print(f"Size : {cols*rows*2/1024/1024:.1f} MB binary\n")

depth_grid = array.array("H", bytes(cols * rows * 2))

# ── Pure-Python UTM Zone 51N → WGS84 ─────────────────────────────────────────
_A  = 6378137.0
_E  = 0.0818191908426215
_K0 = 0.9996

def utm_to_wgs84(easting, northing):
    x  = easting - 500000.0
    M  = northing / _K0
    mu = M / (_A * (1 - _E**2/4 - 3*_E**4/64 - 5*_E**6/256))
    e1 = (1 - math.sqrt(1 - _E**2)) / (1 + math.sqrt(1 - _E**2))
    p1 = (mu
          + (3*e1/2      - 27*e1**3/32)   * math.sin(2*mu)
          + (21*e1**2/16 - 55*e1**4/32)   * math.sin(4*mu)
          + (151*e1**3/96)                 * math.sin(6*mu)
          + (1097*e1**4/512)               * math.sin(8*mu))
    sp  = math.sin(p1); cp = math.cos(p1); tp = math.tan(p1)
    ep2 = _E**2 / (1 - _E**2)
    N1  = _A / math.sqrt(1 - (_E*sp)**2)
    T1  = tp**2
    C1  = ep2 * cp**2
    R1  = _A * (1 - _E**2) / (1 - (_E*sp)**2)**1.5
    D   = x / (N1 * _K0)
    lat = p1 - (N1*tp/R1) * (
          D**2/2
        - (5 + 3*T1 + 10*C1 - 4*C1**2 - 9*ep2) * D**4/24
        + (61 + 90*T1 + 298*C1 + 45*T1**2 - 252*ep2 - 3*C1**2) * D**6/720)
    lon = 2.1467549799530254 + (          # radians(123.0) — Zone 51N CM
          D
        - (1 + 2*T1 + C1) * D**3/6
        + (5 - 2*C1 + 28*T1 - 3*C1**2 + 8*ep2 + 24*T1**2) * D**5/120
    ) / cp
    return math.degrees(lon), math.degrees(lat)

def wgs84_to_utm_northing(lat_deg):
    lr = math.radians(lat_deg)
    M  = _A * (
          (1 - _E**2/4   - 3*_E**4/64   - 5*_E**6/256)  * lr
        - (3*_E**2/8     + 3*_E**4/32   + 45*_E**6/1024) * math.sin(2*lr)
        + (15*_E**4/256  + 45*_E**6/1024)                * math.sin(4*lr)
        - (35*_E**6/3072)                                 * math.sin(6*lr))
    return _K0 * M

_utm_s = wgs84_to_utm_northing(BOUNDS["south"])
_utm_n = wgs84_to_utm_northing(BOUNDS["north"])
_north = BOUNDS["north"]
_west  = BOUNDS["west"]

# ── Scanline rasteriser ───────────────────────────────────────────────────────
def rasterise_ring(ring_utm, q_val, erase=False):
    ys = [p[1] for p in ring_utm]
    if max(ys) < _utm_s or min(ys) > _utm_n:
        return
    xs_utm = [p[0] for p in ring_utm]
    if max(xs_utm) < 265000 or min(xs_utm) > 302000:
        return

    ring_wgs = [utm_to_wgs84(x, y) for x, y in ring_utm]
    lons = [p[0] for p in ring_wgs]
    lats = [p[1] for p in ring_wgs]

    lat_max = min(max(lats), BOUNDS["north"])
    lat_min = max(min(lats), BOUNDS["south"])
    if lat_max <= lat_min:
        return
    lon_max = min(max(lons), BOUNDS["east"])
    lon_min = max(min(lons), BOUNDS["west"])
    if lon_max <= lon_min:
        return

    row_min = max(0,      int((_north - lat_max) / CELL_DEG))
    row_max = min(rows-1, int((_north - lat_min) / CELL_DEG))
    col_min = max(0,      int((lon_min - _west)  / CELL_DEG))
    col_max = min(cols-1, int((lon_max - _west)  / CELL_DEG))
    n = len(ring_wgs)

    for row in range(row_min, row_max + 1):
        lat_c  = _north - (row + 0.5) * CELL_DEG
        x_ints = []
        j = n - 1
        for i in range(n):
            lat_i = lats[i]; lat_j = lats[j]
            if (lat_i <= lat_c < lat_j) or (lat_j <= lat_c < lat_i):
                t = (lat_c - lat_i) / (lat_j - lat_i)
                x_ints.append(lons[i] + t * (lons[j] - lons[i]))
            j = i
        if len(x_ints) < 2:
            continue
        x_ints.sort()
        base = row * cols
        for k in range(0, len(x_ints) - 1, 2):
            c0 = max(col_min, math.ceil( (x_ints[k]   - _west) / CELL_DEG - 0.5))
            c1 = min(col_max, math.floor((x_ints[k+1] - _west) / CELL_DEG - 0.5))
            if c0 > c1:
                continue
            if erase:
                for c in range(c0, c1 + 1):
                    depth_grid[base + c] = 0
            else:
                for c in range(c0, c1 + 1):
                    idx = base + c
                    if q_val > depth_grid[idx]:
                        depth_grid[idx] = q_val

# ── Discover tiles ────────────────────────────────────────────────────────────
tiles = sorted(
    name[len("100yr_FD_clipped_"):-4]
    for name in os.listdir(SHP_DIR)
    if name.startswith("100yr_FD_clipped_") and name.endswith(".shp")
)
print(f"Found {len(tiles)} tiles: {tiles}\n")

# ── Process tiles ─────────────────────────────────────────────────────────────
total_kept = 0

for tile in tiles:
    path = os.path.join(SHP_DIR, f"100yr_FD_clipped_{tile}")
    sf   = shapefile.Reader(path)

    # Tile-level bbox check (UTM)
    tb = sf.bbox
    if tb[2] < 265000 or tb[0] > 302000 or tb[3] < _utm_s or tb[1] > _utm_n:
        print(f"Tile {tile}: skipped (outside QC bounds)")
        continue

    total = len(sf)
    print(f"Tile {tile}: {total:,} records", flush=True)
    kept  = 0

    for i, (shape_rec, record) in enumerate(zip(sf.iterShapes(), sf.iterRecords())):
        if i % 100_000 == 0 and i > 0:
            print(f"  {i:,}/{total:,}  (kept {kept:,} cells)", end="\r", flush=True)

        depth = float(record["Var"])
        if depth <= 0:
            continue

        # Shape-level bbox check
        bbox = shape_rec.bbox
        if bbox[2] < 265000 or bbox[0] > 302000 or bbox[3] < _utm_s or bbox[1] > _utm_n:
            continue

        q_val = min(int(round(depth / STEP)), 65535)
        parts = list(shape_rec.parts) + [len(shape_rec.points)]

        for pi in range(len(parts) - 1):
            ring = shape_rec.points[parts[pi]:parts[pi+1]]
            erase = (pi > 0)   # first ring = exterior fill; subsequent = hole erase
            rasterise_ring(ring, q_val, erase)
            if not erase:
                kept += 1

    total_kept += kept
    print(f"  Tile {tile}: {kept:,} polygons rasterised", flush=True)

nz = sum(1 for v in depth_grid if v > 0)
print(f"\nTotal polygons rasterised : {total_kept:,}")
print(f"Flooded cells : {nz:,} / {cols*rows:,} ({100*nz/(cols*rows):.1f}%)", flush=True)

# ── Write binary ──────────────────────────────────────────────────────────────
bin_path = os.path.join(OUTPUT_DIR, "qc_flood.bin")
with open(bin_path, "wb") as f:
    depth_grid.tofile(f)
print(f"\nBinary : {bin_path}  ({os.path.getsize(bin_path)/1024/1024:.1f} MB)", flush=True)

# ── Write header ──────────────────────────────────────────────────────────────
header = {
    "bounds":   BOUNDS,
    "cols":     cols,
    "rows":     rows,
    "cellDeg":  CELL_DEG,
    "step":     STEP,
    "dtype":    "uint16-le",
    "dataFile": "qc_flood.bin",
    "encoding": f"uint16 LE - value x {STEP} = depth_metres; 0 = no flood",
}
with open(os.path.join(OUTPUT_DIR, "qc_flood_header.json"), "w") as f:
    json.dump(header, f, indent=2)

nz_vals = [v for v in depth_grid if v > 0]
if nz_vals:
    print(f"Depth stats : min {min(nz_vals)*STEP:.2f} m  |  "
          f"max {max(nz_vals)*STEP:.2f} m  |  "
          f"{len(set(nz_vals)):,} unique depth values")
print("\nDone.", flush=True)
