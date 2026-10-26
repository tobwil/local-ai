/* world.js – baut die Stadt: Boden, Rennstrecke mit Randsteinen und Startportal, Gebäude mit Fensterfassaden,
   Wasser, Parks mit Bäumen und die Wahrzeichen. Alles aus SF_DATEN (echte OpenStreetMap-Grundrisse). */
window.SF = window.SF || {};

(function () {
  "use strict";
  var BREITE = 14;

  // ---------- Texturen (zur Laufzeit gezeichnet, keine Bilddateien) ----------
  function leinwand(w, h, malen) {
    var c = document.createElement("canvas");
    c.width = w; c.height = h;
    var g = c.getContext("2d");
    if (g && g.fillRect) malen(g, w, h);
    var t = new THREE.CanvasTexture(c);
    t.wrapS = t.wrapT = THREE.RepeatWrapping;
    t.anisotropy = 4;
    return t;
  }

  // Fassade: helle Wand mit Fensterraster (4 × 4 Fenster), einige Fenster warm erleuchtet.
  function fassadenTextur() {
    return leinwand(256, 256, function (g, w, h) {
      g.fillStyle = "#f2efe8"; g.fillRect(0, 0, w, h);
      for (var y = 0; y < 4; y++) for (var x = 0; x < 4; x++) {
        var licht = Math.random() < 0.18;
        g.fillStyle = licht ? "#ffe39a" : (Math.random() < 0.5 ? "#6f8aa8" : "#5d7895");
        g.fillRect(x * 64 + 14, y * 64 + 12, 36, 40);
        g.fillStyle = "rgba(255,255,255,0.25)";
        g.fillRect(x * 64 + 14, y * 64 + 12, 36, 6);
      }
    });
  }

  // Asphalt: Rauschen, weiße Randlinien, gelbe Mittelstriche (Textur läuft entlang der Strecke).
  function strassenTextur(farbe) {
    return leinwand(128, 512, function (g, w, h) {
      g.fillStyle = farbe; g.fillRect(0, 0, w, h);
      for (var i = 0; i < 2600; i++) {
        var v = Math.random() * 40 - 20;
        g.fillStyle = "rgba(" + (v > 0 ? "255,255,255," + v / 220 : "0,0,0," + -v / 160) + ")";
        g.fillRect(Math.random() * w, Math.random() * h, 2, 2);
      }
      g.fillStyle = "#f4f4f4"; g.fillRect(6, 0, 5, h); g.fillRect(w - 11, 0, 5, h);
      g.fillStyle = "#ffcc22"; g.fillRect(w / 2 - 2, 0, 4, h * 0.45);
    });
  }

  function bodenTextur(farbe) {
    return leinwand(256, 256, function (g, w, h) {
      g.fillStyle = farbe; g.fillRect(0, 0, w, h);
      g.strokeStyle = "rgba(0,0,0,0.06)"; g.lineWidth = 2;
      for (var i = 0; i <= w; i += 32) { g.beginPath(); g.moveTo(i, 0); g.lineTo(i, h); g.stroke(); g.beginPath(); g.moveTo(0, i); g.lineTo(w, i); g.stroke(); }
    });
  }

  // ---------- Hilfen ----------
  function farbeVariiert(hex, staerke) {
    var c = new THREE.Color(hex);
    var f = 1 + (Math.random() - 0.5) * staerke;
    return new THREE.Color(Math.min(1, c.r * f), Math.min(1, c.g * f), Math.min(1, c.b * f));
  }

  // Grundriss bereinigen: doppelten Endpunkt weg, mindestens 3 Punkte, gegen den Uhrzeigersinn.
  function kontur(punkte) {
    var p = punkte.slice();
    if (p.length > 1 && p[0][0] === p[p.length - 1][0] && p[0][1] === p[p.length - 1][1]) p.pop();
    if (p.length < 3) return null;
    var v = p.map(function (q) { return new THREE.Vector2(q[0], q[1]); });
    if (THREE.ShapeUtils.isClockWise(v)) v.reverse();
    return v;
  }

  function geometrie(pos, farben, index, uv) {
    var g = new THREE.BufferGeometry();
    g.setAttribute("position", new THREE.Float32BufferAttribute(pos, 3));
    if (farben) g.setAttribute("color", new THREE.Float32BufferAttribute(farben, 3));
    if (uv) g.setAttribute("uv", new THREE.Float32BufferAttribute(uv, 2));
    if (index) g.setIndex(index);
    g.computeVertexNormals();
    return g;
  }

  // ---------- Strecke ----------
  // Gleichmäßige Stützpunkte (alle ~2 m) mit Normale – für Straße, Randsteine und die Fahrphysik.
  SF.streckenTabelle = function (kurve) {
    if (kurve._sfTabelle) return kurve._sfTabelle;
    var laenge = kurve.getLength();
    var n = Math.max(400, Math.round(laenge / 2));
    var punkte = kurve.getSpacedPoints(n);
    punkte.pop();
    var normalen = punkte.map(function (p, i) {
      var q = punkte[(i + 1) % n], o = punkte[(i - 1 + n) % n];
      var t = new THREE.Vector3(q.x - o.x, 0, q.z - o.z).normalize();
      return new THREE.Vector3(-t.z, 0, t.x);   // zeigt nach rechts (in Fahrtrichtung)
    });
    kurve._sfTabelle = { punkte: punkte, normalen: normalen, laenge: laenge, abstand: laenge / n };
    return kurve._sfTabelle;
  };

  function baueStrasse(gruppe, kurve, farben) {
    var tab = SF.streckenTabelle(kurve), n = tab.punkte.length, halb = BREITE / 2;
    var pos = [], uv = [], idx = [], weg = 0;
    for (var i = 0; i <= n; i++) {
      var p = tab.punkte[i % n], q = tab.normalen[i % n];
      pos.push(p.x - q.x * halb, 0.06, p.z - q.z * halb, p.x + q.x * halb, 0.06, p.z + q.z * halb);
      uv.push(0, weg / 32, 1, weg / 32);
      weg += tab.abstand;
    }
    // Dreiecke gegen den Uhrzeigersinn von oben gesehen (sonst sieht man die Rückseite und die Straße verschwindet)
    for (var k = 0; k < n; k++) { var a = k * 2; idx.push(a, a + 1, a + 2, a + 1, a + 3, a + 2); }
    var strasse = new THREE.Mesh(geometrie(pos, null, idx, uv),
      new THREE.MeshLambertMaterial({ map: strassenTextur(farben.strasse || "#4a4a4f") }));
    strasse.receiveShadow = true;
    gruppe.add(strasse);

    // Randsteine rot/weiß wie auf einer Rennstrecke (eine Instanz pro 2 m und Seite)
    var stein = new THREE.BoxGeometry(0.9, 0.35, tab.abstand * 0.98);
    var steine = new THREE.InstancedMesh(stein, new THREE.MeshLambertMaterial({ color: 0xffffff }), n * 2);
    var m = new THREE.Matrix4(), rot = new THREE.Color(0xd8283a), weiss = new THREE.Color(0xf6f6f6), oben = new THREE.Vector3(0, 1, 0);
    for (var s = 0; s < n; s++) {
      var pt = tab.punkte[s], no = tab.normalen[s];
      var winkel = Math.atan2(no.x, no.z) + Math.PI / 2;
      for (var seite = -1; seite <= 1; seite += 2) {
        m.makeRotationAxis(oben, winkel);
        m.setPosition(pt.x + no.x * (halb + 0.45) * seite, 0.17, pt.z + no.z * (halb + 0.45) * seite);
        var j = s * 2 + (seite > 0 ? 1 : 0);
        steine.setMatrixAt(j, m);
        steine.setColorAt(j, (Math.floor(s / 2) % 2) ? rot : weiss);
      }
    }
    gruppe.add(steine);

    // Start/Ziel: Schachbrettstreifen und Portal mit Schriftzug
    var start = tab.punkte[0], nst = tab.normalen[0];
    var karo = leinwand(256, 32, function (g) { for (var x = 0; x < 16; x++) for (var y = 0; y < 2; y++) { g.fillStyle = (x + y) % 2 ? "#111" : "#fff"; g.fillRect(x * 16, y * 16, 16, 16); } });
    var linie = new THREE.Mesh(new THREE.PlaneGeometry(BREITE, 2.5), new THREE.MeshLambertMaterial({ map: karo }));
    linie.rotation.x = -Math.PI / 2;
    linie.rotation.z = Math.atan2(nst.z, nst.x) * -1;
    linie.position.set(start.x, 0.08, start.z);
    gruppe.add(linie);
    var portal = new THREE.Group();
    var saeule = new THREE.BoxGeometry(1.2, 9, 1.2), blau = new THREE.MeshLambertMaterial({ color: 0x274060 });
    [-1, 1].forEach(function (sx) { var p = new THREE.Mesh(saeule, blau); p.position.set(sx * (halb + 1.5), 4.5, 0); p.castShadow = true; portal.add(p); });
    var schild = leinwand(512, 64, function (g, w, h) {
      g.fillStyle = "#274060"; g.fillRect(0, 0, w, h);
      g.fillStyle = "#FCC419"; g.fillRect(0, h - 6, w, 6);
      g.font = "bold 38px -apple-system, Helvetica, sans-serif"; g.textAlign = "center"; g.fillStyle = "#fff";
      g.fillText("STADTFLITZER  ·  KI/lokal", w / 2, 44);
    });
    var balken = new THREE.Mesh(new THREE.BoxGeometry(BREITE + 4.2, 2, 0.8), [blau, blau, blau, blau,
      new THREE.MeshBasicMaterial({ map: schild }), new THREE.MeshBasicMaterial({ map: schild })]);
    balken.position.y = 9;
    portal.add(balken);
    portal.position.set(start.x, 0, start.z);
    portal.rotation.y = Math.atan2(nst.x, nst.z) + Math.PI / 2;
    gruppe.add(portal);
  }

  // ---------- Gebäude ----------
  function baueGebaeude(gruppe, liste, farbe) {
    var wand = [], wandFarbe = [], wandUV = [], dach = [], dachFarbe = [], dachIdx = [];
    for (var b = 0; b < liste.length; b++) {
      var k = kontur(liste[b].p);
      if (!k) continue;
      var h = Math.max(6, liste[b].h || 12);
      var c = farbeVariiert(farbe, 0.28), cd = c.clone().multiplyScalar(0.72);
      var u = 0;
      for (var i = 0; i < k.length; i++) {
        var a = k[i], e = k[(i + 1) % k.length];
        var l = Math.hypot(e.x - a.x, e.y - a.y);
        // Zwei Dreiecke je Wandstück, Texturkoordinaten in Metern (16 m × 12,8 m pro Fensterbild)
        wand.push(a.x, 0, a.y, e.x, 0, e.y, e.x, h, e.y, a.x, 0, a.y, e.x, h, e.y, a.x, h, a.y);
        wandUV.push(u / 16, 0, (u + l) / 16, 0, (u + l) / 16, h / 12.8, u / 16, 0, (u + l) / 16, h / 12.8, u / 16, h / 12.8);
        for (var z = 0; z < 6; z++) wandFarbe.push(c.r, c.g, c.b);
        u += l;
      }
      var basis = dach.length / 3;
      k.forEach(function (p) { dach.push(p.x, h, p.y); dachFarbe.push(cd.r, cd.g, cd.b); });
      THREE.ShapeUtils.triangulateShape(k, []).forEach(function (t) { dachIdx.push(basis + t[0], basis + t[2], basis + t[1]); });
    }
    var waende = new THREE.Mesh(geometrie(wand, wandFarbe, null, wandUV),
      new THREE.MeshLambertMaterial({ map: fassadenTextur(), vertexColors: true, side: THREE.DoubleSide }));
    var daecher = new THREE.Mesh(geometrie(dach, dachFarbe, dachIdx),
      new THREE.MeshLambertMaterial({ vertexColors: true, side: THREE.DoubleSide }));
    waende.receiveShadow = daecher.receiveShadow = true;
    gruppe.add(waende, daecher);
  }

  // ---------- Wasser, Parks, Bäume ----------
  function baueFlaechen(gruppe, polygone, farbe, hoehe) {
    var pos = [], idx = [];
    polygone.forEach(function (poly) {
      var k = kontur(poly);
      if (!k) return;
      var basis = pos.length / 3;
      k.forEach(function (p) { pos.push(p.x, hoehe, p.y); });
      THREE.ShapeUtils.triangulateShape(k, []).forEach(function (t) { idx.push(basis + t[0], basis + t[2], basis + t[1]); });
    });
    if (!pos.length) return;
    var m = new THREE.Mesh(geometrie(pos, null, idx), new THREE.MeshLambertMaterial({ color: farbe, side: THREE.DoubleSide }));
    m.receiveShadow = true;
    gruppe.add(m);
  }

  function imPolygon(x, z, poly) {
    var drin = false;
    for (var i = 0, j = poly.length - 1; i < poly.length; j = i++) {
      var a = poly[i], b = poly[j];
      if ((a[1] > z) !== (b[1] > z) && x < (b[0] - a[0]) * (z - a[1]) / (b[1] - a[1]) + a[0]) drin = !drin;
    }
    return drin;
  }

  function baueBaeume(gruppe, parks, tab) {
    var orte = [];
    parks.forEach(function (poly) {
      if (poly.length < 3) return;
      var minX = 1e9, maxX = -1e9, minZ = 1e9, maxZ = -1e9;
      poly.forEach(function (p) { minX = Math.min(minX, p[0]); maxX = Math.max(maxX, p[0]); minZ = Math.min(minZ, p[1]); maxZ = Math.max(maxZ, p[1]); });
      var anzahl = Math.min(140, Math.round((maxX - minX) * (maxZ - minZ) / 220));
      for (var i = 0; i < anzahl * 3 && orte.length < 700; i++) {
        var x = minX + Math.random() * (maxX - minX), z = minZ + Math.random() * (maxZ - minZ);
        if (imPolygon(x, z, poly) && SF.abstandZurStrecke(tab, x, z) > BREITE) orte.push([x, z]);
      }
    });
    if (!orte.length) return;
    var stamm = new THREE.InstancedMesh(new THREE.CylinderGeometry(0.35, 0.5, 3, 6), new THREE.MeshLambertMaterial({ color: 0x6b4a2f }), orte.length);
    var krone = new THREE.InstancedMesh(new THREE.IcosahedronGeometry(3.2, 0), new THREE.MeshLambertMaterial({ color: 0xffffff }), orte.length);
    var m = new THREE.Matrix4(), s = new THREE.Vector3(), q = new THREE.Quaternion(), p = new THREE.Vector3();
    orte.forEach(function (o, i) {
      var g = 0.8 + Math.random() * 0.7;
      m.compose(p.set(o[0], 1.5 * g, o[1]), q, s.set(g, g, g)); stamm.setMatrixAt(i, m);
      m.compose(p.set(o[0], 4.6 * g, o[1]), q, s.set(g, g * 1.15, g)); krone.setMatrixAt(i, m);
      krone.setColorAt(i, new THREE.Color().setHSL(0.27 + Math.random() * 0.06, 0.45, 0.32 + Math.random() * 0.1));
    });
    krone.castShadow = true;
    gruppe.add(stamm, krone);
  }

  // Abstand eines Punktes zur Mittellinie (grob, über die Stützpunkte) – für Bäume und Wahrzeichen.
  SF.abstandZurStrecke = function (tab, x, z) {
    var best = 1e9;
    for (var i = 0; i < tab.punkte.length; i += 3) {
      var p = tab.punkte[i], d = (p.x - x) * (p.x - x) + (p.z - z) * (p.z - z);
      if (d < best) best = d;
    }
    return Math.sqrt(best);
  };

  // ---------- Wahrzeichen ----------
  function schild(text, farbe) {
    var t = leinwand(512, 96, function (g, w, h) {
      g.fillStyle = farbe; g.fillRect(0, 0, w, h);
      g.fillStyle = "#FCC419"; g.fillRect(0, h - 8, w, 8);
      g.font = "bold 50px -apple-system, Helvetica, sans-serif"; g.textAlign = "center"; g.fillStyle = "#fff";
      g.fillText(text, w / 2, 62);
    });
    var s = new THREE.Sprite(new THREE.SpriteMaterial({ map: t, depthTest: false, fog: false }));
    s.scale.set(48, 9, 1);
    s.renderOrder = 10;
    return s;
  }

  function teil(gruppe, geo, farbe, x, y, z) {
    var m = new THREE.Mesh(geo, new THREE.MeshLambertMaterial({ color: farbe }));
    m.position.set(x, y, z);
    m.castShadow = true;
    gruppe.add(m);
    return m;
  }

  function baueWahrzeichen(w, farben) {
    var g = new THREE.Group(), h = Math.max(15, w.hoehe), akzent = farben.akzent || "#274060";
    var hell = 0xefe6d6, ziegel = 0xa5523a, kupfer = 0x5fa38c, glas = 0x9cc6e6;
    switch (w.form) {
      case "zwei_tuerme": // Frauenkirche: Kirchenschiff, zwei Türme mit „Welschen Hauben“
        teil(g, new THREE.BoxGeometry(30, h * 0.35, 70), ziegel, 0, h * 0.175, 28);
        [-9, 9].forEach(function (x) {
          teil(g, new THREE.BoxGeometry(14, h * 0.78, 14), ziegel, x, h * 0.39, 0);
          var haube = teil(g, new THREE.SphereGeometry(7.5, 16, 12), kupfer, x, h * 0.84, 0);
          haube.scale.set(1, 1.5, 1);
        });
        break;
      case "tor": // Stadttor bzw. Brandenburger Tor: Säulen und Gebälk
        for (var i = -3; i <= 3; i++) teil(g, new THREE.CylinderGeometry(1.1, 1.3, h * 0.7, 10), hell, i * 4.2, h * 0.35, 0);
        teil(g, new THREE.BoxGeometry(32, h * 0.22, 9), hell, 0, h * 0.81, 0);
        teil(g, new THREE.BoxGeometry(6, h * 0.12, 4), kupfer, 0, h * 0.98, 0);
        break;
      case "welle": // Elbphilharmonie: Backsteinsockel, Glaskörper, geschwungenes Dach
        teil(g, new THREE.BoxGeometry(60, h * 0.36, 34), ziegel, 0, h * 0.18, 0);
        var glasKoerper = teil(g, new THREE.BoxGeometry(60, h * 0.5, 34), glas, 0, h * 0.61, 0);
        glasKoerper.material.transparent = true; glasKoerper.material.opacity = 0.85;
        [-20, -4, 13, 25].forEach(function (x, i) {
          var welle = teil(g, new THREE.SphereGeometry(11 + i % 2 * 3, 18, 10, 0, Math.PI * 2, 0, Math.PI / 2), 0xf4f6f8, x, h * 0.86, 0);
          welle.scale.set(1, 0.8 + (i % 2) * 0.5, 1.4);
        });
        break;
      case "kuppel": // Dom bzw. Reichstag
        teil(g, new THREE.BoxGeometry(46, h * 0.5, 40), hell, 0, h * 0.25, 0);
        var kuppel = teil(g, new THREE.SphereGeometry(16, 24, 16, 0, Math.PI * 2, 0, Math.PI / 2), w.hoehe > 70 ? kupfer : glas, 0, h * 0.5, 0);
        kuppel.scale.y = 1.4;
        teil(g, new THREE.CylinderGeometry(1.2, 1.6, h * 0.12, 8), kupfer, 0, h * 0.94, 0);
        break;
      case "fernsehturm": // Schaft, Kugel, Antenne
        teil(g, new THREE.CylinderGeometry(3.2, 6.5, h * 0.56, 16), 0xe9ecef, 0, h * 0.28, 0);
        teil(g, new THREE.SphereGeometry(h * 0.045, 24, 18), 0xb9c3cc, 0, h * 0.58, 0);
        teil(g, new THREE.CylinderGeometry(2.2, 3, h * 0.1, 12), 0xe9ecef, 0, h * 0.66, 0);
        teil(g, new THREE.CylinderGeometry(0.6, 1.4, h * 0.3, 8), 0xd94040, 0, h * 0.85, 0);
        break;
      case "speicher": // Speicherstadt: Backsteinblöcke mit Treppengiebeln
        for (var s = 0; s < 4; s++) {
          teil(g, new THREE.BoxGeometry(20, h * 0.75, 30), ziegel, s * 23 - 34, h * 0.375, 0);
          teil(g, new THREE.ConeGeometry(11, h * 0.35, 4), 0x2f6b5d, s * 23 - 34, h * 0.92, 0).rotation.y = Math.PI / 4;
        }
        break;
      default: // Turm (Rathaus, Michel): Sockel, Turm, Spitze
        teil(g, new THREE.BoxGeometry(34, h * 0.32, 24), hell, 0, h * 0.16, 0);
        teil(g, new THREE.BoxGeometry(11, h * 0.62, 11), hell, 0, h * 0.31, 0);
        teil(g, new THREE.ConeGeometry(7.5, h * 0.38, 8), kupfer, 0, h * 0.81, 0);
    }
    var label = schild(w.name, akzent);
    label.position.set(0, h + 12, 0);
    g.add(label);
    g.position.set(w.x, 0, w.z);
    return g;
  }

  // ---------- Hauptfunktion ----------
  function baueWelt(scene, daten) {
    var farben = daten.farben || {};
    var gruppe = new THREE.Group();
    gruppe.name = "welt";

    var bt = bodenTextur(farben.boden || "#c9c2b4");
    bt.repeat.set(160, 160);
    var boden = new THREE.Mesh(new THREE.PlaneGeometry(5000, 5000), new THREE.MeshLambertMaterial({ map: bt }));
    boden.rotation.x = -Math.PI / 2;
    boden.receiveShadow = true;
    gruppe.add(boden);

    var punkte = daten.strecke.map(function (p) { return new THREE.Vector3(p[0], 0, p[1]); });
    var kurve = new THREE.CatmullRomCurve3(punkte, true, "centripetal");
    var tab = SF.streckenTabelle(kurve);

    baueFlaechen(gruppe, daten.wasser || [], 0x5b8db8, 0.03);
    baueFlaechen(gruppe, daten.parks || [], 0x7fb069, 0.02);
    baueStrasse(gruppe, kurve, farben);
    baueGebaeude(gruppe, daten.gebaeude || [], farben.gebaeude || "#e8dcc8");
    baueBaeume(gruppe, daten.parks || [], tab);
    (daten.wahrzeichen || []).forEach(function (w) {
      var m = baueWahrzeichen(w, farben);
      // Steht ein Wahrzeichen zu nah an der Strecke (z. B. ein Tor direkt auf der Route), seitlich verschieben
      var d = SF.abstandZurStrecke(tab, w.x, w.z);
      if (d < 30) {
        var naechster = 0, best = 1e9;
        tab.punkte.forEach(function (p, i) { var e = (p.x - w.x) * (p.x - w.x) + (p.z - w.z) * (p.z - w.z); if (e < best) { best = e; naechster = i; } });
        var nrm = tab.normalen[naechster], seite = ((w.x - tab.punkte[naechster].x) * nrm.x + (w.z - tab.punkte[naechster].z) * nrm.z) >= 0 ? 1 : -1;
        m.position.set(tab.punkte[naechster].x + nrm.x * 34 * seite, 0, tab.punkte[naechster].z + nrm.z * 34 * seite);
      }
      gruppe.add(m);
    });
    scene.add(gruppe);
    return { kurve: kurve, breite: BREITE, gruppe: gruppe };
  }

  SF.baueWelt = baueWelt;
})();
