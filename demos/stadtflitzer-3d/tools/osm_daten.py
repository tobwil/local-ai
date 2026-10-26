#!/Users/tobias/.local/bin/python3.12
# -*- coding: utf-8 -*-
"""osm_daten.py –holt Stadtteile aus OpenStreetMap (Overpass-API) und schreibt
   die Spieldaten nach data/<stadt>.js. Nutzt nur die Python-Standardbibliothek.

Aufruf:  python3 tools/osm_daten.py
"""

import json
import math
import os
import time
import urllib.request
import urllib.parse

# --- Konstanten -------------------------------------------------------------
# Skalierung: 1 Grade Länge ≈ 111320 m, 1 Grade Latitude ≈ 110540 m (WGS84-Approx.)
METER_PRO_GRAD_LON = 111320.0
METER_PRO_GRAD_LAT = 110540.0

# Zwischenstopps zwischen den Städten.
WART_SEKUNDEN = 3.0
# Rückgaberate (429) / Gateway-Zeitüberschreitung (504): nach 20 s einmal erneut.
RETRY_SEKUNDEN = 20.0

MAX_GEBAUDE = 4500
STRECKE_ABSTAND = 11.0   # m – Abstand Punkt -> Strecke
MIN_PUNKTE_GEBAUDE = 3   # Gebäude mit < 3 Punkten wird weggelassen

# Overpass-Endpunkt und User-Agent.
OVERPASS_URL = "https://overpass-api.de/api/interpreter"
USER_AGENT = "KI-lokal/0.6 (Stadtflitzer-Demo; kisruptiv.de)"


# ---------- Hilfsfunktionen -------------------------------------------------

def punkt_abstand_zur_strecke(px, pz, pts):
    """Abstand des Punktes (px, pz) zur geschlossenen Streckenlinie.

    pts: Liste von (x, z)-Punkten. Strecke wird als geschlossener Linienzug
    aufgefasst (Letzte-Kante zurück zum ersten Punkt)."""
    n = len(pts)
    if n == 0:
        return 0.0
    if n == 1:
        dx = px - pts[0][0]
        dz = pz - pts[0][1]
        return math.sqrt(dx * dx + dz * dz)
    best = None
    for i in range(n):
        ax, az = pts[i]
        bx, bz = pts[(i + 1) % n]
        dx = bx - ax
        dz = bz - az
        seg_len_sq = dx * dx + dz * dz
        # Projektionsparameter t auf [0,1].
        if seg_len_sq < 1e-12:
            t = 0.0
        else:
            t = ((px - ax) * dx + (pz - az) * dz) / seg_len_sq
            t = max(0.0, min(1.0, t))
        cx = ax + t * dx
        cz = az + t * dz
        ex = px - cx
        ez = pz - cz
        d = math.sqrt(ex * ex + ez * ez)
        if best is None or d < best:
            best = d
    return best


def umrechnen(lon, lat, lon0, lat0, massstab):
    """Umrechnung WGS84 in Meter-Koordinaten relativ zum Mittelpunkt (0,0)."""
    x = (lon - lon0) * METER_PRO_GRAD_LON * math.cos(math.radians(lat0)) * massstab
    z = -(lat - lat0) * METER_PRO_GRAD_LAT * massstab
    return round(x, 1), round(z, 1)


def anfrage_bauen(s, w, n, o):
    """Overpass-Query als Text (POST-Body) aufbauen."""
    template = (
        "[out:json][timeout:90];"
        "(way[\"building\"](%s,%s,%s,%s);"
        "way[\"natural\"=\"water\"](%s,%s,%s,%s);"
        "way[\"waterway\"=\"riverbank\"](%s,%s,%s,%s);"
        "way[\"leisure\"=\"park\"](%s,%s,%s,%s);"
        ");"
        "out geom;"
    )
    return template % (s, w, n, o, s, w, n, o, s, w, n, o, s, w, n, o)


def hoehe_aus_tag(el):
    return hoehe_aus_tag_dict(el.get("tags") or {})


def hoehe_aus_tag_dict(daten):
    """Höhe in Metern ableiten.

    1) tag "height" (Zahl am Anfang des Strings),
    2) sonst building:levels * 3,2 (+ roof:levels * 2),
    3) sonst 14."""
    if "height" in daten:
        s = str(daten["height"]).strip()
        num = ""
        for ch in s:
            if ch.isdigit() or ch == ".":
                num += ch
            else:
                break
        if num:
            try:
                return float(num)
            except ValueError:
                pass
    levels = int(float(daten.get("building:levels", 0) or 0))
    roof_levels = int(float(daten.get("roof:levels", 0) or 0))
    return levels * 3.2 + roof_levels * 2.0

def streckenlaenge(strecke):
    """Gesamtlänge einer geschlossenen Strecke in Metern."""
    ges = 0.0
    n = len(strecke)
    for i in range(n):
        x1, z1 = strecke[i]
        x2, z2 = strecke[(i + 1) % n]
        ges += math.sqrt((x2 - x1) ** 2 + (z2 - z1) ** 2)
    return ges


def javascript_schreiben(stadt, daten):
    """Schreibt die data/<stadt>.js-Datei im DESIGN-Format als String."""
    lines = ["window.SF_DATEN = window.SF_DATEN || {};"]
    lines.append("window.SF_DATEN.%s = {" % stadt)
    lines.append('  name: %s,' % json.dumps(daten["name"]))
    lines.append('  untertitel: %s,' % json.dumps(daten["untertitel"]))
    lines.append("  farben: %s," % json.dumps(daten["farben"]))
    lines.append("  strecke: %s," % json.dumps(daten["strecke"]))
    lines.append("  gebaeude: %s," % json.dumps(daten["gebaeude"]))
    lines.append("  wasser: %s," % json.dumps(daten["wasser"]))
    lines.append("  parks: %s," % json.dumps(daten["parks"]))
    lines.append("  wahrzeichen: %s" % json.dumps(daten["wahrzeichen"]))
    lines.append("};")
    return "\n".join(lines) + "\n"


# ---------- Hauptprogramm ---------------------------------------------------

def main():
    hier = os.path.dirname(os.path.abspath(__file__))
    mit_hier = lambda name: os.path.join(hier, name)

    # Städte laden
    with open(mit_hier("cities.json"), encoding="utf-8") as f:
        staedte = json.load(f)

    # Ausgabeverzeichnis
    daten_dir = os.path.join(os.path.dirname(hier), "data")
    os.makedirs(daten_dir, exist_ok=True)

    print("Stadtflitzer 3D – Overpass-Datenabholer")
    print("=" * 60)

    for stadt, infos in staedte.items():
        if not isinstance(infos, dict):
            continue  # z. B. "_hinweis" überspringen

        name = infos.get("name", stadt)
        bbox = infos["bbox"]  # [süd, west, nord, ost]
        massstab = infos.get("massstab", 1.0)
        strecke_geo = infos["strecke"]  # Liste [lat, lon]

        s, w, n, o = bbox

        # Mittelpunkt der Streckenpunkte (lat/lon als Mittelwert).
        lats = [p[0] for p in strecke_geo]
        lons = [p[1] for p in strecke_geo]
        lat0 = sum(lats) / len(lats)
        lon0 = sum(lons) / len(lons)

        # Streckenpunkte in Meter umrechnen (Ursprung = Mittelpunkt).
        strecke_m = []
        for (lat, lon) in strecke_geo:
            x, z = umrechnen(lon, lat, lon0, lat0, massstab)
            strecke_m.append((x, z))

        # Overpass-Anfrage aufbauen
        abfrage = anfrage_bauen(s, w, n, o)

        print("\n[Stadt %s] Mittelpunkt (%.6f, %.6f), bbox [%.5f, %.5f, %.5f, %.5f]" % (
            name, lat0, lon0, s, w, n, o))

        def absenden():
            body = ("data=" + urllib.parse.quote(abfrage)).encode("utf-8")
            req = urllib.request.Request(
                OVERPASS_URL, data=body,
                headers={"Content-Type": "application/x-www-form-urlencoded",
                         "User-Agent": USER_AGENT},
                method="POST",
            )
            with urllib.request.urlopen(req, timeout=90) as resp:
                raw = resp.read().decode("utf-8")
            return raw

        raw = None
        try:
            raw = absenden()
            print("  [DEBUG] HTTP 200, Antwortlänge %d Zeichen" % len(raw))
        except urllib.error.HTTPError as e:
            body = e.read().decode("utf-8")
            print("  [DEBUG] HTTP-Fehler %s: %s" % (e.code, body[:300]))
            print("  HTTP-Fehler %s, warte %s s und wiederhole ..." % (e.code, RETRY_SEKUNDEN))
            time.sleep(RETRY_SEKUNDEN)
            try:
                raw = absenden()
            except Exception as ex:
                print("  erneut gescheitert: %s" % type(ex).__name__)
                raw = None
        except Exception as ex:
            print("  Fehler: %s (%s)" % (ex, type(ex).__name__))
            raw = None

        payload = None
        if raw:
            try:
                payload = json.loads(raw)
            except json.JSONDecodeError:
                payload = None

        elements = payload.get("elements", []) if payload else []

        gebaeude_list = [el for el in elements if (el.get("tags") or {}).get("building") is not None]
        wat_list = [el for el in elements if (el.get("tags") or {}).get("natural") == "water"]
        par_list = [el for el in elements if (el.get("tags") or {}).get("leisure") == "park"]

        # Abstand zum Polygon: Mittelpunkt (Mittel der Ecken) -> Strecke.
        def polygon_mitte(poly):
            lat = sum((p.get("lat") or 0) for p in poly) / len(poly)
            lon = sum((p.get("lon") or 0) for p in poly) / len(poly)
            return lat, lon

        gebaeude_out = []
        for el in gebaeude_list:
            poly = el.get("geometry")
            if not poly or len(poly) < MIN_PUNKTE_GEBAUDE:
                continue
            ml, mo = polygon_mitte(poly)
            # Mittelpunkt in Meter -> Streckenabstand prüfen.
            cx, cz = umrechnen(mo, ml, lon0, lat0, massstab)
            if punkt_abstand_zur_strecke(cx, cz, strecke_m) < STRECKE_ABSTAND:
                continue
            hoehe = hoehe_aus_tag(el) * massstab
            poly_m = [umrechnen(p["lon"], p["lat"], lon0, lat0, massstab) for p in poly]
            gebaeude_out.append({"p": poly_m, "h": round(hoehe, 1)})

        # Nach Nähe zur Strecke sortieren, höchstens MAX_GEBAUDE (nächste behalten).
        def mitte_erstes(p):
            return punkt_abstand_zur_strecke(p["p"][0][0], p["p"][0][1], strecke_m)
        gebaeude_out.sort(key=mitte_erstes)
        gebaeude_out = gebaeude_out[:MAX_GEBAUDE]

        wasser = [[umrechnen(p["lon"], p["lat"], lon0, lat0, massstab) for p in el["geometry"]]
                  for el in wat_list if el.get("geometry")]
        parks = [[umrechnen(p["lon"], p["lat"], lon0, lat0, massstab) for p in el["geometry"]]
                 for el in par_list if el.get("geometry")]

        # Wahrzeichen
        wahrzeichen_out = []
        for wz in infos.get("wahrzeichen", []):
            lat, lon = wz["pos"]
            x, z = umrechnen(lon, lat, lon0, lat0, massstab)
            hoehe = round(float(wz.get("hoehe", 0)) * massstab, 1)
            wahrzeichen_out.append({
                "name": wz.get("name", ""),
                "x": x, "z": z,
                "hoehe": hoehe,
                "form": wz.get("form", "turm"),
            })

        daten_js = {
            "name": name,
            "untertitel": infos.get("untertitel", ""),
            "farben": infos.get("farben", {}),
            "strecke": strecke_m,
            "gebaeude": gebaeude_out,
            "wasser": wasser,
            "parks": parks,
            "wahrzeichen": wahrzeichen_out,
        }

        pfad = os.path.join(daten_dir, "%s.js" % stadt)
        text = javascript_schreiben(stadt, daten_js)
        with open(pfad, "w", encoding="utf-8") as f:
            f.write(text)
        groesse = os.path.getsize(pfad)

        print("  Gebäude: %d  Wasser: %d  Parks: %d" % (
            len(gebaeude_out), len(wasser), len(parks)))
        print("  Strecke: %.1f m  Dateigröße: %d Byte" % (
            streckenlaenge(strecke_m), groesse))

    print("\nFertig. Dateien in %s" % daten_dir)


if __name__ == "__main__":
    main()
