/* car.js – SF.Auto: ferngesteuertes Spielzeugauto mit Arcade-Physik (Gas, Bremse, Lenken, leichtes Driften),
   Abprallen am Straßenrand, Power-up-Effekte und einer KI für die Gegner. */
window.SF = window.SF || {};

(function () {
  "use strict";
  var MAX_TEMPO = 38, TURBO_TEMPO = 54, BESCHLEUNIGUNG = 17, TURBO_BESCHL = 32;

  function Auto(opt) {
    opt = opt || {};
    this.name = opt.name || "Auto";
    this.farbe = opt.farbe !== undefined ? opt.farbe : 0xFCC419;
    this.koennen = opt.koennen || 1;            // Gegner: 0.88–0.97 der Höchstgeschwindigkeit
    this.position = new THREE.Vector3();
    this.geschw = new THREE.Vector3();
    this.richtung = 0;
    this.tempo = 0;
    this.fortschritt = 0;
    this.powerup = null;
    this.turbo = 0; this.schleudern = 0; this.nass = 0;
    this.lenkwinkel = 0;
    this.spur = (Math.random() - 0.5) * 6;        // bevorzugte Spur der KI
    this._index = -1;
    this.mesh = baueModell(this.farbe);
  }

  // Spielzeugauto: flache Wanne, Kabine, dicke Räder, Spoiler, Antenne mit Fähnchen. Front zeigt nach +z.
  function baueModell(farbe) {
    var g = new THREE.Group();
    var lack = new THREE.MeshPhongMaterial({ color: farbe, shininess: 80 });
    var dunkel = new THREE.MeshLambertMaterial({ color: 0x1d2433 });
    var gummi = new THREE.MeshLambertMaterial({ color: 0x151515 });
    var felge = new THREE.MeshLambertMaterial({ color: 0xd0d4da });
    function teil(geo, mat, x, y, z) { var m = new THREE.Mesh(geo, mat); m.position.set(x, y, z); m.castShadow = true; g.add(m); return m; }
    teil(new THREE.BoxGeometry(1.8, 0.45, 3.6), lack, 0, 0.62, 0);
    teil(new THREE.BoxGeometry(1.3, 0.42, 1.5), dunkel, 0, 1.05, -0.2);
    var nase = teil(new THREE.BoxGeometry(1.7, 0.3, 0.7), lack, 0, 0.55, 1.75); nase.rotation.x = 0.35;
    teil(new THREE.BoxGeometry(1.9, 0.08, 0.5), lack, 0, 1.3, -1.6);
    teil(new THREE.BoxGeometry(0.1, 0.45, 0.35), dunkel, -0.75, 1.07, -1.6);
    teil(new THREE.BoxGeometry(0.1, 0.45, 0.35), dunkel, 0.75, 1.07, -1.6);
    var antenne = teil(new THREE.CylinderGeometry(0.025, 0.025, 1.6, 4), dunkel, 0.6, 1.6, -1.1);
    var faehnchen = teil(new THREE.PlaneGeometry(0.45, 0.28), new THREE.MeshLambertMaterial({ color: 0xFCC419, side: THREE.DoubleSide }), 0.83, 2.25, -1.1);
    g.userData.antenne = antenne; g.userData.faehnchen = faehnchen;
    g.userData.raeder = [];
    [[-1, 1.15], [1, 1.15], [-1, -1.15], [1, -1.15]].forEach(function (p) {
      var rad = new THREE.Group();
      var reifen = new THREE.Mesh(new THREE.CylinderGeometry(0.52, 0.52, 0.5, 14), gummi);
      reifen.rotation.z = Math.PI / 2; reifen.castShadow = true;
      var nabe = new THREE.Mesh(new THREE.CylinderGeometry(0.28, 0.28, 0.52, 8), felge);
      nabe.rotation.z = Math.PI / 2;
      rad.add(reifen, nabe);
      rad.position.set(p[0] * 0.98, 0.52, p[1]);
      rad.userData.vorne = p[1] > 0;
      g.add(rad);
      g.userData.raeder.push(rad);
    });
    return g;
  }

  // Nächster Stützpunkt der Strecke – erst in der Nähe des letzten, sonst überall suchen.
  function naechster(auto, tab) {
    var n = tab.punkte.length, best = -1, bestD = 1e18, p = auto.position;
    function pruefe(i) { var q = tab.punkte[(i + n) % n], d = (q.x - p.x) * (q.x - p.x) + (q.z - p.z) * (q.z - p.z); if (d < bestD) { bestD = d; best = (i + n) % n; } }
    if (auto._index >= 0) for (var k = -40; k <= 40; k++) pruefe(auto._index + k);
    if (best < 0 || bestD > 400) for (var j = 0; j < n; j++) pruefe(j);
    auto._index = best;
    return best;
  }

  Auto.prototype.setzeAufStrecke = function (kurve, t, versatz) {
    var tab = SF.streckenTabelle(kurve), n = tab.punkte.length;
    var i = Math.floor(((t % 1) + 1) % 1 * n) % n, p = tab.punkte[i], q = tab.normalen[i], v = tab.punkte[(i + 1) % n];
    this.position.set(p.x + q.x * (versatz || 0), 0, p.z + q.z * (versatz || 0));
    this.richtung = Math.atan2(v.x - p.x, v.z - p.z);
    this.geschw.set(0, 0, 0); this.tempo = 0;
    this.turbo = this.schleudern = this.nass = 0;
    this._index = i;
    this.fortschritt = i / n;
    this.synchronisiere(0);
  };

  Auto.prototype.update = function (dt, eingabe, strecke) {
    eingabe = eingabe || {};
    var tab = SF.streckenTabelle(strecke.kurve);
    var gas = eingabe.gas || 0, bremse = eingabe.bremse || 0, lenkung = Math.max(-1, Math.min(1, eingabe.lenkung || 0));
    this.turbo = Math.max(0, this.turbo - dt);
    this.nass = Math.max(0, this.nass - dt);
    this.schleudern = Math.max(0, this.schleudern - dt);

    var vor = new THREE.Vector3(Math.sin(this.richtung), 0, Math.cos(this.richtung));
    var rechts = new THREE.Vector3(Math.cos(this.richtung), 0, -Math.sin(this.richtung));
    var vf = this.geschw.dot(vor), vl = this.geschw.dot(rechts);
    var maxT = (this.turbo > 0 ? TURBO_TEMPO : MAX_TEMPO) * this.koennen * (this.nass > 0 ? 0.55 : 1);

    // Antrieb, Bremse, Rückwärts, Roll- und Luftwiderstand
    if (this.schleudern > 0) { gas *= 0.2; lenkung = 0; }
    if (gas > 0 && vf < maxT) vf += (this.turbo > 0 ? TURBO_BESCHL : BESCHLEUNIGUNG) * gas * dt * (1 - Math.max(0, vf) / (maxT * 1.15));
    if (bremse > 0) vf = vf > 0.5 ? Math.max(0, vf - 34 * bremse * dt) : Math.max(-10, vf - 9 * bremse * dt);
    vf -= vf * 0.12 * dt + Math.sign(vf) * Math.min(Math.abs(vf), 1.2 * dt);
    if (vf > maxT) vf = Math.max(maxT, vf - 20 * dt);

    // Lenken: wirkt erst mit Tempo, bei hohem Tempo etwas weniger; rückwärts umgekehrt
    this.lenkwinkel += (lenkung - this.lenkwinkel) * Math.min(1, dt * 10);
    var dreh = this.lenkwinkel * 2.5 * Math.min(1, Math.abs(vf) / 7) * (1 - 0.38 * Math.min(1, Math.abs(vf) / MAX_TEMPO));
    this.richtung -= dreh * dt * (vf >= 0 ? 1 : -1);
    if (this.schleudern > 0) this.richtung += 9 * dt;

    // Seitenhaftung < 1: leichtes Driften in schnellen Kurven
    var haftung = this.schleudern > 0 ? 0.6 : (Math.abs(this.lenkwinkel) > 0.6 && vf > 24 ? 3.2 : 7.5);
    vl *= Math.exp(-haftung * dt);

    vor.set(Math.sin(this.richtung), 0, Math.cos(this.richtung));
    rechts.set(Math.cos(this.richtung), 0, -Math.sin(this.richtung));
    this.geschw.copy(vor).multiplyScalar(vf).addScaledVector(rechts, vl);
    this.position.addScaledVector(this.geschw, dt);

    // Straßenrand: zurückschieben, abprallen, abbremsen, Richtung etwas zur Strecke drehen
    var i = naechster(this, tab), p = tab.punkte[i], nrm = tab.normalen[i];
    var quer = (this.position.x - p.x) * nrm.x + (this.position.z - p.z) * nrm.z;
    var grenze = strecke.breite / 2 - 1.1;
    this.amRand = false;
    if (Math.abs(quer) > grenze) {
      var s = Math.sign(quer);
      this.position.x -= nrm.x * (quer - s * grenze);
      this.position.z -= nrm.z * (quer - s * grenze);
      var raus = this.geschw.x * nrm.x * s + this.geschw.z * nrm.z * s;
      if (raus > 0) this.geschw.addScaledVector(nrm, -s * raus * 1.35);
      this.geschw.multiplyScalar(Math.pow(0.35, dt * 4));
      var naechsterP = tab.punkte[(i + 1) % tab.punkte.length];
      var ziel = Math.atan2(naechsterP.x - p.x, naechsterP.z - p.z), diff = winkelDiff(ziel, this.richtung);
      if (Math.abs(diff) < Math.PI * 0.7) this.richtung += diff * Math.min(1, dt * 3);
      this.amRand = true;
    }
    this.tempo = this.geschw.dot(new THREE.Vector3(Math.sin(this.richtung), 0, Math.cos(this.richtung)));
    this.fortschritt = i / tab.punkte.length;
    this.synchronisiere(dt);
  };

  function winkelDiff(a, b) { var d = a - b; while (d > Math.PI) d -= Math.PI * 2; while (d < -Math.PI) d += Math.PI * 2; return d; }
  SF.winkelDiff = winkelDiff;

  // Modell an Physik angleichen: Lage, Räder drehen, Vorderräder lenken, Antenne wippt, Neigung in Kurven.
  Auto.prototype.synchronisiere = function (dt) {
    var m = this.mesh;
    m.position.copy(this.position);
    m.rotation.set(0, this.richtung, 0);
    m.rotation.z = -this.lenkwinkel * Math.min(1, Math.abs(this.tempo) / 30) * 0.08;
    var r = m.userData.raeder || [];
    for (var k = 0; k < r.length; k++) {
      r[k].children[0].rotation.x += this.tempo * dt / 0.52;
      r[k].children[1].rotation.x = r[k].children[0].rotation.x;
      if (r[k].userData.vorne) r[k].rotation.y = this.lenkwinkel * 0.45;
    }
    if (m.userData.antenne) m.userData.antenne.rotation.x = -Math.min(0.5, Math.abs(this.tempo) / 60) + Math.sin(Date.now() / 90) * 0.04;
  };

  // KI: Zielpunkt voraus auf der eigenen Spur ansteuern, vor engen Kurven Gas wegnehmen.
  Auto.prototype.kiEingabe = function (strecke) {
    var tab = SF.streckenTabelle(strecke.kurve), n = tab.punkte.length;
    var i = this._index >= 0 ? this._index : naechster(this, tab);
    var voraus = Math.round((9 + Math.max(0, this.tempo) * 0.75) / tab.abstand);
    var j = (i + voraus) % n, q = tab.punkte[j], nrm = tab.normalen[j];
    if (Math.random() < 0.004) this.spur = (Math.random() - 0.5) * 7;
    var zx = q.x + nrm.x * this.spur, zz = q.z + nrm.z * this.spur;
    var diff = winkelDiff(Math.atan2(zx - this.position.x, zz - this.position.z), this.richtung);
    // Krümmung weiter voraus abschätzen: Richtungsänderung über ~40 m
    var a = tab.punkte[j], b = tab.punkte[(j + Math.round(40 / tab.abstand)) % n];
    var kurve = Math.abs(winkelDiff(Math.atan2(b.x - a.x, b.z - a.z), Math.atan2(a.x - tab.punkte[i].x, a.z - tab.punkte[i].z)));
    var bremsen = kurve > 0.9 && this.tempo > 24;
    return { gas: bremsen ? 0 : 1, bremse: bremsen ? 0.6 : 0, lenkung: Math.max(-1, Math.min(1, -diff * 2.6)) };
  };

  SF.Auto = Auto;
})();
