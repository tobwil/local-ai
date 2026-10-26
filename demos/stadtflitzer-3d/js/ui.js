/* ui.js – Menü mit Stadtkarten, HUD (Runde, Zeit, Platz, Tempo, Power-up), Minimap, Meldungen, Ziel-Bildschirm
   und Ton (WebAudio: Motor, Countdown, Effekte). */
window.SF = window.SF || {};

(function () {
  "use strict";
  var $ = function (id) { return document.getElementById(id); };
  var POWER = { turbo: ["🔋", "Batterie-Turbo"], wasserbombe: ["💧", "Wasserbombe"], oel: ["🛢️", "Öllache"] };
  var NAMEN = ["Du", "Blitz", "Rosso", "Grünspan"];

  function zeit(s) {
    if (!isFinite(s)) return "–";
    var m = Math.floor(s / 60), r = s - m * 60;
    return m + ":" + (r < 10 ? "0" : "") + r.toFixed(2);
  }
  SF.formatZeit = zeit;

  // Streckenbild für Menükarte und Minimap
  function zeichneStrecke(canvas, daten, punkteExtra) {
    var g = canvas.getContext("2d"), w = canvas.width, h = canvas.height;
    var xs = daten.strecke.map(function (p) { return p[0]; }), zs = daten.strecke.map(function (p) { return p[1]; });
    var minX = Math.min.apply(null, xs), maxX = Math.max.apply(null, xs), minZ = Math.min.apply(null, zs), maxZ = Math.max.apply(null, zs);
    var s = Math.min((w - 40) / (maxX - minX), (h - 40) / (maxZ - minZ));
    var ox = (w - (maxX - minX) * s) / 2, oz = (h - (maxZ - minZ) * s) / 2;
    var abb = function (x, z) { return [ox + (x - minX) * s, oz + (z - minZ) * s]; };
    g.clearRect(0, 0, w, h);
    g.fillStyle = "rgba(255,255,255,0.10)";
    (daten.gebaeude || []).forEach(function (b, i) {
      if (i % 2) return;
      var p = abb(b.p[0][0], b.p[0][1]); g.fillRect(p[0] - 1, p[1] - 1, 2.2, 2.2);
    });
    g.lineJoin = "round"; g.lineCap = "round";
    [["rgba(0,0,0,0.35)", w / 30], ["#e9edf3", w / 60]].forEach(function (st) {
      g.strokeStyle = st[0]; g.lineWidth = st[1]; g.beginPath();
      daten.strecke.forEach(function (p, i) { var q = abb(p[0], p[1]); if (i) g.lineTo(q[0], q[1]); else g.moveTo(q[0], q[1]); });
      g.closePath(); g.stroke();
    });
    var st = abb(daten.strecke[0][0], daten.strecke[0][1]);
    g.fillStyle = "#FCC419"; g.fillRect(st[0] - 4, st[1] - 4, 8, 8);
    (punkteExtra || []).forEach(function (p) {
      var q = abb(p.x, p.z);
      g.fillStyle = p.farbe; g.beginPath(); g.arc(q[0], q[1], p.r || w / 40, 0, Math.PI * 2); g.fill();
      g.strokeStyle = "#fff"; g.lineWidth = 2; g.stroke();
    });
  }

  function UI() {
    this.ton = new Ton();
    this.meldungBis = 0;
    var self = this;
    if ("ontouchstart" in window) $("touch").style.display = "block";
    this.touch = {};
    Array.prototype.forEach.call(document.querySelectorAll("#touch button"), function (b) {
      var t = b.getAttribute("data-taste");
      b.addEventListener("touchstart", function (e) { e.preventDefault(); self.touch[t] = true; if (t === "power" && self.onPower) self.onPower(); });
      b.addEventListener("touchend", function (e) { e.preventDefault(); self.touch[t] = false; });
    });
  }

  UI.prototype.zeigeMenue = function (staedte, onStart) {
    $("menue").style.display = "flex"; $("menue").style.opacity = 1;
    $("hud").style.display = "none"; $("ziel").style.display = "none";
    var box = $("staedte"); box.innerHTML = "";
    var self = this;
    staedte.forEach(function (schluessel, i) {
      var d = SF_DATEN[schluessel];
      var karte = document.createElement("button");
      karte.className = "stadt karte";
      var c = document.createElement("canvas"); c.width = 440; c.height = 230;
      var laenge = 0;
      d.strecke.forEach(function (p, k) { var q = d.strecke[(k + 1) % d.strecke.length]; laenge += Math.hypot(q[0] - p[0], q[1] - p[1]); });
      karte.appendChild(c);
      karte.insertAdjacentHTML("beforeend", "<h2>" + d.name + "</h2><p>" + d.untertitel + "</p><div class='zahlen'>" +
        d.gebaeude.length.toLocaleString("de-DE") + " echte Gebäude · " + (laenge / 1000).toFixed(1).replace(".", ",") + " km · " +
        d.wahrzeichen.length + " Wahrzeichen</div>");
      zeichneStrecke(c, d);
      karte.addEventListener("click", function () { self.ton.starte(); onStart(schluessel); });
      karte.addEventListener("mouseenter", function () { if (self.onVorschau) self.onVorschau(schluessel); });
      box.appendChild(karte);
      if (i === 0) setTimeout(function () { karte.focus(); }, 50);
    });
  };

  UI.prototype.starteRennen = function (daten) {
    $("menue").style.display = "none"; $("ziel").style.display = "none"; $("hud").style.display = "block";
    this.daten = daten;
  };

  UI.prototype.update = function (rennen, spieler, autopilot) {
    var runde = rennen.runde(spieler), letzte = rennen.rundenzeiten(spieler);
    $("runde").textContent = runde + "/" + rennen.runden;
    $("zeit").textContent = zeit(rennen.status === "countdown" ? 0 : rennen.zeit);
    $("beste").textContent = letzte.length ? "Beste Runde " + zeit(Math.min.apply(null, letzte)) : (autopilot ? "Autopilot an (P)" : "");
    var p = rennen.platz(spieler);
    $("platz").innerHTML = p + ".<small>/" + rennen.autos.length + "</small>";
    $("kmh").textContent = Math.max(0, Math.round(spieler.tempo * 3.6));
    var pw = spieler.powerup ? POWER[spieler.powerup] : null;
    $("powerSymbol").textContent = pw ? pw[0] : "·";
    $("powerName").innerHTML = pw ? pw[1] + " – <kbd>Leertaste</kbd>" : (spieler.turbo > 0 ? "Turbo!" : "Kiste einsammeln");
    if (this.daten) {
      var farben = ["#FCC419", "#3366ff", "#dd3333", "#33aa55"];
      zeichneStrecke($("minimap"), this.daten, rennen.autos.map(function (a, i) { return { x: a.position.x, z: a.position.z, farbe: farben[i], r: i ? 9 : 12 }; }).reverse());
    }
    if (rennen.status === "countdown") {
      var c = Math.ceil(rennen.countdown);
      this.meldung(String(c), false, 0.3);
    }
    var self = this;
    rennen.ereignisse.forEach(function (e) {
      if (e.art === "piep") self.ton.piep(660, 0.12);
      if (e.art === "los") { self.ton.piep(990, 0.4); self.meldung("LOS!", true, 0.9); }
      if (e.art === "runde" && e.auto === spieler) { var letzteRunde = rennen.runde(spieler) === rennen.runden; self.meldung(letzteRunde ? "Letzte Runde!" : "Runde " + rennen.runde(spieler), letzteRunde, 1.4); self.ton.akkord(); }
      if (e.art === "aufgesammelt" && e.auto === spieler) { self.hinweis(POWER[spieler.powerup][0] + " " + POWER[spieler.powerup][1] + " – Leertaste"); self.ton.ding(); }
      if (e.art === "treffer" && e.auto === spieler) { self.hinweis("💧 Getroffen!"); self.ton.platsch(); }
      if (e.art === "schleudern" && e.auto === spieler) { self.hinweis("🛢️ Ins Schleudern geraten!"); self.ton.platsch(); }
      if (e.art === "benutzt" && e.auto === spieler && e.powerup === "turbo") self.ton.turbo();
    });
    this.ton.motor(rennen.status === "countdown" ? 0 : spieler.tempo, spieler.turbo > 0);
    if (performance.now() > this.meldungBis) $("meldung").classList.remove("zeigen");
  };

  UI.prototype.meldung = function (text, gold, sekunden) {
    var m = $("meldung");
    m.textContent = text; m.classList.toggle("gold", !!gold); m.classList.add("zeigen");
    this.meldungBis = performance.now() + sekunden * 1000;
  };

  UI.prototype.hinweis = function (text) {
    var h = $("hinweis"); h.textContent = text; h.style.opacity = 1;
    clearTimeout(this._hw); this._hw = setTimeout(function () { h.style.opacity = 0; }, 2200);
  };

  UI.prototype.zeigeZiel = function (rennen, spieler, onNochmal, onAndere) {
    this.ton.motor(0);
    var p = rennen.platz(spieler);
    $("zielTitel").innerHTML = p === 1 ? "Sieg! 🏆" : "Ziel – Platz " + p;
    var z = rennen.rundenzeiten(spieler);
    $("zielUnter").textContent = "Gesamtzeit " + zeit(rennen.zeit) + (z.length ? " · beste Runde " + zeit(Math.min.apply(null, z)) : "");
    var html = "";
    rennen.rangliste().forEach(function (a, i) {
      var r = a._r, t = r.fertig ? zeit(r.fertigZeit) : "Runde " + rennen.runde(a);
      html += "<tr class='" + (a === spieler ? "du" : "") + "'><td>" + (i + 1) + ".</td><td>" + a.name + "</td><td style='text-align:right'>" + t + "</td></tr>";
    });
    $("zielTabelle").innerHTML = html;
    $("ziel").style.display = "flex";
    $("nochmal").onclick = onNochmal; $("andere").onclick = onAndere;
    if (p === 1) this.ton.akkord();
  };

  UI.prototype.verstecke = function () { $("hud").style.display = "none"; $("ziel").style.display = "none"; };
  UI.NAMEN = NAMEN;

  // ---------- Ton ----------
  function Ton() { this.an = true; this.ctx = null; }
  Ton.prototype.starte = function () {
    if (this.ctx || !(window.AudioContext || window.webkitAudioContext)) return;
    var c = this.ctx = new (window.AudioContext || window.webkitAudioContext)();
    this.haupt = c.createGain(); this.haupt.gain.value = 0.5; this.haupt.connect(c.destination);
    // Motor: Sägezahn + Rechteck durch Tiefpass
    this.filter = c.createBiquadFilter(); this.filter.type = "lowpass"; this.filter.frequency.value = 700;
    this.motorGain = c.createGain(); this.motorGain.gain.value = 0;
    this.filter.connect(this.motorGain); this.motorGain.connect(this.haupt);
    this.o1 = c.createOscillator(); this.o1.type = "sawtooth"; this.o2 = c.createOscillator(); this.o2.type = "square";
    this.o1.connect(this.filter); this.o2.connect(this.filter);
    this.o1.start(); this.o2.start();
  };
  Ton.prototype.umschalten = function () { this.an = !this.an; if (this.haupt) this.haupt.gain.value = this.an ? 0.5 : 0; return this.an; };
  Ton.prototype.motor = function (tempo, turbo) {
    if (!this.ctx) return;
    var t = this.ctx.currentTime, v = Math.abs(tempo || 0);
    this.o1.frequency.setTargetAtTime(48 + v * 4.2 + (turbo ? 40 : 0), t, 0.05);
    this.o2.frequency.setTargetAtTime(24 + v * 2.1, t, 0.05);
    this.motorGain.gain.setTargetAtTime(v > 0.3 ? 0.05 + Math.min(v, 50) / 900 : 0.012, t, 0.1);
  };
  Ton.prototype.piep = function (freq, dauer) {
    if (!this.ctx) return;
    var o = this.ctx.createOscillator(), g = this.ctx.createGain(), t = this.ctx.currentTime;
    o.frequency.value = freq; o.type = "sine"; g.gain.setValueAtTime(0.25, t); g.gain.exponentialRampToValueAtTime(0.001, t + dauer);
    o.connect(g); g.connect(this.haupt); o.start(t); o.stop(t + dauer);
  };
  Ton.prototype.ding = function () { this.piep(1320, 0.15); var s = this; setTimeout(function () { s.piep(1760, 0.2); }, 90); };
  Ton.prototype.akkord = function () { var s = this; [523, 659, 784, 1047].forEach(function (f, i) { setTimeout(function () { s.piep(f, 0.35); }, i * 90); }); };
  Ton.prototype.turbo = function () { var s = this; [440, 660, 880].forEach(function (f, i) { setTimeout(function () { s.piep(f, 0.12); }, i * 50); }); };
  Ton.prototype.platsch = function () {
    if (!this.ctx) return;
    var c = this.ctx, n = c.sampleRate * 0.35, puffer = c.createBuffer(1, n, c.sampleRate), d = puffer.getChannelData(0);
    for (var i = 0; i < n; i++) d[i] = (Math.random() * 2 - 1) * Math.pow(1 - i / n, 2);
    var q = c.createBufferSource(), f = c.createBiquadFilter(); f.type = "bandpass"; f.frequency.value = 900;
    q.buffer = puffer; q.connect(f); f.connect(this.haupt); q.start();
  };

  SF.UI = UI;
})();
