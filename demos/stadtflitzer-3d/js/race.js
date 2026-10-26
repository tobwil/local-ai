/* race.js – SF.Rennen: Startaufstellung, Countdown, Runden mit Kontrollpunkt, Platzierung, Zeiten und Power-ups
   (Batterie-Turbo, Wasserbombe, Öllache). */
window.SF = window.SF || {};

(function () {
  "use strict";
  var ARTEN = ["turbo", "wasserbombe", "oel"];
  var FARBE = { turbo: 0xFCC419, wasserbombe: 0x3aa0ff, oel: 0x3b3b3b };

  function Rennen(opt) {
    this.strecke = opt.strecke;
    this.autos = opt.autos;
    this.runden = opt.runden || 3;
    this.scene = opt.scene || null;
    this.tab = SF.streckenTabelle(this.strecke.kurve);
    this.status = "countdown";
    this.countdown = 3;
    this.zeit = 0;
    this.ereignisse = [];         // für Ton und Anzeige: { art, auto }
    this.geschosse = [];
    this.lachen = [];
    var self = this, laenge = this.tab.laenge;
    // Startaufstellung hinter der Linie, zwei Spuren; der Spieler (autos[0]) startet hinten – wie im Original.
    this.autos.forEach(function (a, i) {
      var reihe = self.autos.length - 1 - i;
      a.setzeAufStrecke(self.strecke.kurve, 1 - (6 + reihe * 7) / laenge, (reihe % 2 ? 3.4 : -3.4));
      a.powerup = null;
      a._r = { runde: 1, checkpoint: false, rundenStart: 0, zeiten: [], fertig: false, fertigZeit: 0 };
      if (self.scene && !a.mesh.parent) self.scene.add(a.mesh);
    });
    this.powerups = [];
    var anzahl = Math.max(4, Math.floor(laenge / 330));
    for (var k = 0; k < anzahl; k++) {
      var art = ARTEN[k % 3], i = Math.floor(((k + 0.5) / anzahl) * this.tab.punkte.length);
      var p = this.tab.punkte[i], n = this.tab.normalen[i], versatz = ((k * 7) % 3 - 1) * 3.5;
      var pu = { position: new THREE.Vector3(p.x + n.x * versatz, 1.2, p.z + n.z * versatz), art: art, aktiv: true, warte: 0, mesh: null };
      if (this.scene) { pu.mesh = kiste(art); pu.mesh.position.copy(pu.position); this.scene.add(pu.mesh); }
      this.powerups.push(pu);
    }
  }

  // Schwebende, leuchtende Kiste mit Symbolfarbe
  function kiste(art) {
    var g = new THREE.Group();
    var m = new THREE.Mesh(new THREE.BoxGeometry(1.6, 1.6, 1.6),
      new THREE.MeshPhongMaterial({ color: FARBE[art], emissive: FARBE[art], emissiveIntensity: 0.35, transparent: true, opacity: 0.88 }));
    m.castShadow = true;
    var rand = new THREE.LineSegments(new THREE.EdgesGeometry(m.geometry), new THREE.LineBasicMaterial({ color: 0xffffff }));
    g.add(m, rand);
    return g;
  }

  Rennen.prototype.update = function (dt, eingabeSpieler) {
    var self = this;
    this.ereignisse.length = 0;
    this.powerups.forEach(function (pu) {
      if (pu.mesh) { pu.mesh.rotation.y += dt * 1.6; pu.mesh.position.y = 1.2 + Math.sin(Date.now() / 300 + pu.position.x) * 0.25; pu.mesh.visible = pu.aktiv; }
      if (!pu.aktiv && (pu.warte -= dt) <= 0) pu.aktiv = true;
    });
    if (this.status === "countdown") {
      var vorher = Math.ceil(this.countdown);
      this.countdown -= dt;
      if (Math.ceil(this.countdown) !== vorher && this.countdown > 0) this.ereignisse.push({ art: "piep" });
      this.autos.forEach(function (a) { a.synchronisiere(0); });
      if (this.countdown <= 0) { this.countdown = 0; this.status = "laeuft"; this.ereignisse.push({ art: "los" }); }
      return;
    }
    if (this.status === "ziel") {
      // Nach dem Ziel fahren alle (auch der Spieler) per KI gemütlich weiter
      this.autos.forEach(function (a) { var e = a.kiEingabe(self.strecke); e.gas *= 0.5; a.update(dt, e, self.strecke); });
      return;
    }
    this.zeit += dt;
    this.autos.forEach(function (a, i) {
      var e = (i === 0 && !a._r.fertig) ? (eingabeSpieler || {}) : a.kiEingabe(self.strecke);
      var vorher = a.fortschritt;
      a.update(dt, e, self.strecke);
      self._runde(a, vorher);
      self._aufsammeln(a);
      self._oel(a);
      if (i > 0 && a.powerup && Math.random() < dt * 0.4) self.benutze(a);
    });
    this._geschosse(dt);
    if (this.autos[0]._r.fertig) { this.status = "ziel"; this.ereignisse.push({ art: "ziel" }); }
  };

  // Rundenzählung: Kontrollpunkt in der Streckenmitte verhindert Abkürzen und Rückwärts-Tricks.
  Rennen.prototype._runde = function (a, vorher) {
    var r = a._r, f = a.fortschritt;
    if (f > 0.4 && f < 0.6) r.checkpoint = true;
    if (vorher > 0.85 && f < 0.15 && r.checkpoint && !r.fertig) {
      r.zeiten.push(this.zeit - r.rundenStart);
      r.rundenStart = this.zeit;
      r.checkpoint = false;
      if (r.runde >= this.runden) { r.fertig = true; r.fertigZeit = this.zeit; this.ereignisse.push({ art: "fertig", auto: a }); }
      else { r.runde++; this.ereignisse.push({ art: "runde", auto: a }); }
    }
  };

  Rennen.prototype._aufsammeln = function (a) {
    if (a.powerup) return;
    for (var k = 0; k < this.powerups.length; k++) {
      var pu = this.powerups[k];
      if (pu.aktiv && Math.hypot(pu.position.x - a.position.x, pu.position.z - a.position.z) < 4.5) {
        a.powerup = ARTEN[Math.floor(Math.random() * ARTEN.length)];
        pu.aktiv = false; pu.warte = 6;
        this.ereignisse.push({ art: "aufgesammelt", auto: a });
        return;
      }
    }
  };

  Rennen.prototype.benutze = function (a) {
    var art = a.powerup;
    if (!art) return;
    a.powerup = null;
    var vor = new THREE.Vector3(Math.sin(a.richtung), 0, Math.cos(a.richtung));
    if (art === "turbo") {
      a.turbo = 3;
      a.geschw.addScaledVector(vor, 8);
    } else if (art === "oel") {
      var p = a.position.clone().addScaledVector(vor, -4);
      var lache = { position: p, besitzer: a, schutz: 1, leben: 25, mesh: null };
      if (this.scene) {
        lache.mesh = new THREE.Mesh(new THREE.CircleGeometry(2.6, 20), new THREE.MeshPhongMaterial({ color: 0x111111, shininess: 120, transparent: true, opacity: 0.85 }));
        lache.mesh.rotation.x = -Math.PI / 2; lache.mesh.position.set(p.x, 0.09, p.z);
        this.scene.add(lache.mesh);
      }
      this.lachen.push(lache);
    } else if (art === "wasserbombe") {
      // Ziel: das Auto direkt vor dir in der Platzierung (sonst geradeaus)
      var platz = this.platz(a), ziel = null, self = this;
      this.autos.forEach(function (b) { if (self.platz(b) === platz - 1) ziel = b; });
      var g = { position: a.position.clone().add(new THREE.Vector3(0, 1.5, 0)).addScaledVector(vor, 3), geschw: vor.clone().multiplyScalar(70), ziel: ziel, besitzer: a, leben: 3, mesh: null };
      if (this.scene) {
        g.mesh = new THREE.Mesh(new THREE.SphereGeometry(0.7, 14, 10), new THREE.MeshPhongMaterial({ color: 0x3aa0ff, transparent: true, opacity: 0.8, shininess: 100 }));
        g.mesh.position.copy(g.position);
        this.scene.add(g.mesh);
      }
      this.geschosse.push(g);
    }
    this.ereignisse.push({ art: "benutzt", auto: a, powerup: art });
  };

  Rennen.prototype._geschosse = function (dt) {
    var self = this;
    this.geschosse = this.geschosse.filter(function (g) {
      g.leben -= dt;
      if (g.ziel) {   // zielsuchend
        var soll = g.ziel.position.clone().add(new THREE.Vector3(0, 1, 0)).sub(g.position).normalize().multiplyScalar(70);
        g.geschw.lerp(soll, Math.min(1, dt * 4));
      }
      g.position.addScaledVector(g.geschw, dt);
      if (g.mesh) g.mesh.position.copy(g.position);
      var getroffen = null;
      self.autos.forEach(function (b) { if (b !== g.besitzer && b.position.distanceTo(g.position) < 3) getroffen = b; });
      if (getroffen) { getroffen.nass = 2.2; getroffen.geschw.multiplyScalar(0.5); self.ereignisse.push({ art: "treffer", auto: getroffen }); }
      var weg = getroffen || g.leben <= 0;
      if (weg && g.mesh && self.scene) self.scene.remove(g.mesh);
      return !weg;
    });
  };

  Rennen.prototype._oel = function (a) {
    for (var k = this.lachen.length - 1; k >= 0; k--) {
      var l = this.lachen[k];
      l.schutz -= 1 / 60; l.leben -= 1 / 60;
      if (l.leben <= 0) { if (l.mesh && this.scene) this.scene.remove(l.mesh); this.lachen.splice(k, 1); continue; }
      if ((l.besitzer !== a || l.schutz <= 0) && a.schleudern <= 0 && Math.hypot(l.position.x - a.position.x, l.position.z - a.position.z) < 2.8) {
        a.schleudern = 1.3;
        this.ereignisse.push({ art: "schleudern", auto: a });
      }
    }
  };

  // Gesamtfortschritt: Runde + Position; vor dem ersten Überqueren der Linie zählt die Startaufstellung als „davor“.
  Rennen.prototype._wert = function (a) {
    var r = a._r;
    if (r.fertig) return 1e6 - r.fertigZeit;
    var f = a.fortschritt;
    if (r.runde === 1 && !r.checkpoint && f > 0.5) f -= 1;
    return (r.runde - 1) + f;
  };

  Rennen.prototype.platz = function (a) {
    var self = this, w = this._wert(a), besser = 0;
    this.autos.forEach(function (b) { if (b !== a && self._wert(b) > w) besser++; });
    return besser + 1;
  };

  Rennen.prototype.runde = function (a) { return Math.min(a._r.runde, this.runden); };
  Rennen.prototype.rundenzeiten = function (a) { return a._r.zeiten.slice(); };
  Rennen.prototype.rangliste = function () {
    var self = this;
    return this.autos.slice().sort(function (a, b) { return self.platz(a) - self.platz(b); });
  };

  Rennen.prototype.entferne = function () {
    var s = this.scene;
    if (!s) return;
    this.powerups.forEach(function (p) { if (p.mesh) s.remove(p.mesh); });
    this.geschosse.forEach(function (g) { if (g.mesh) s.remove(g.mesh); });
    this.lachen.forEach(function (l) { if (l.mesh) s.remove(l.mesh); });
    this.autos.forEach(function (a) { s.remove(a.mesh); });
  };

  SF.Rennen = Rennen;
})();
