/* main.js – Renderer, Licht, Verfolgerkamera, Spielschleife, Tastatur/Touch, Stadtwahl, Autopilot und Vorführmodus. */
window.SF = window.SF || {};

(function () {
  "use strict";
  var STAEDTE = ["muenchen", "hamburg", "berlin", "koeln"];
  var FARBEN = [0xFCC419, 0x3366ff, 0xdd3333, 0x33aa55];
  var KOENNEN = [1, 0.95, 0.92, 0.89];

  var renderer, scene, kamera, sonne, hemi, ui;
  var welt = null, rennen = null, autos = [], stadt = null;
  var modus = "menue";              // menue | rennen | ziel
  var autopilot = false;
  var tasten = {};
  var kamPos = new THREE.Vector3(), kamBlick = new THREE.Vector3();
  var parameter = new URLSearchParams(location.search);

  function init() {
    renderer = new THREE.WebGLRenderer({ antialias: true, powerPreference: "high-performance" });
    renderer.setPixelRatio(Math.min(2, window.devicePixelRatio || 1));
    renderer.setSize(window.innerWidth, window.innerHeight);
    renderer.shadowMap.enabled = true;
    renderer.shadowMap.type = THREE.PCFSoftShadowMap;
    document.getElementById("spiel").appendChild(renderer.domElement);

    scene = new THREE.Scene();
    kamera = new THREE.PerspectiveCamera(62, window.innerWidth / window.innerHeight, 0.3, 3000);
    hemi = new THREE.HemisphereLight(0xffffff, 0x8a7f70, 0.95);
    scene.add(hemi);
    sonne = new THREE.DirectionalLight(0xfff4e0, 0.85);
    sonne.castShadow = true;
    sonne.shadow.mapSize.set(2048, 2048);
    var sc = sonne.shadow.camera; sc.left = sc.bottom = -45; sc.right = sc.top = 45; sc.near = 10; sc.far = 260;
    scene.add(sonne, sonne.target);

    ui = new SF.UI();
    ui.onVorschau = function (s) { if (modus === "menue" && s !== stadt) ladeStadt(s, true); };
    ui.onPower = function () { if (rennen && rennen.status === "laeuft") rennen.benutze(autos[0]); };

    window.addEventListener("resize", function () {
      kamera.aspect = window.innerWidth / window.innerHeight; kamera.updateProjectionMatrix();
      renderer.setSize(window.innerWidth, window.innerHeight);
    });
    window.addEventListener("keydown", function (e) {
      tasten[e.code] = true;
      if (["ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", "Space"].indexOf(e.code) >= 0) e.preventDefault();
      if (e.code === "Space" && rennen && rennen.status === "laeuft") rennen.benutze(autos[0]);
      if (e.code === "KeyP") { autopilot = !autopilot; ui.hinweis(autopilot ? "🤖 Autopilot an" : "Autopilot aus – du fährst"); }
      if (e.code === "KeyT") ui.hinweis(ui.ton.umschalten() ? "🔊 Ton an" : "🔇 Ton aus");
      if (e.code === "KeyM" && modus !== "menue") zumMenue();
      if (e.code === "KeyR" && autos[0] && modus === "rennen") autos[0].setzeAufStrecke(welt.kurve, autos[0].fortschritt, 0);
    });
    window.addEventListener("keyup", function (e) { tasten[e.code] = false; });

    // ?stadt=berlin&demo=1 startet direkt (Vorführung, Autopilot)
    var start = STAEDTE.indexOf(parameter.get("stadt")) >= 0 ? parameter.get("stadt") : "muenchen";
    if (parameter.get("demo")) { autopilot = true; starteRennen(start); } else zumMenue(start);
    var letzte = performance.now();
    function schleife(jetzt) {
      var dt = Math.min(0.05, (jetzt - letzte) / 1000); letzte = jetzt;
      schritt(dt);
      renderer.render(scene, kamera);
      requestAnimationFrame(schleife);
    }
    requestAnimationFrame(schleife);
  }

  // Stadt (neu) bauen: alte Objekte entfernen, Himmel und Nebel in Stadtfarben
  function ladeStadt(s, mitAutos) {
    if (rennen) rennen.entferne();
    if (welt) { scene.remove(welt.gruppe); welt.gruppe.traverse(function (o) { if (o.geometry) o.geometry.dispose(); }); }
    stadt = s;
    var daten = SF_DATEN[s], himmel = new THREE.Color(daten.farben.himmel);
    scene.background = himmel;
    scene.fog = new THREE.Fog(himmel, 260, 1500);
    welt = SF.baueWelt(scene, daten);
    autos = FARBEN.map(function (f, i) { return new SF.Auto({ farbe: f, name: SF.UI.NAMEN[i], koennen: KOENNEN[i] }); });
    rennen = new SF.Rennen({ strecke: { kurve: welt.kurve, breite: welt.breite }, autos: autos, runden: 3, scene: scene });
    if (mitAutos) { rennen.status = "laeuft"; rennen.countdown = 0; }   // Vorführung im Menü: alle fahren per KI
    kamPos.set(0, 400, 600);
  }

  function zumMenue(start) {
    modus = "menue";
    ladeStadt(start || stadt || "muenchen", true);
    ui.zeigeMenue(STAEDTE, starteRennen);
  }

  function starteRennen(s) {
    ladeStadt(s, false);
    modus = "rennen";
    ui.starteRennen(SF_DATEN[s]);
    var a = autos[0], v = new THREE.Vector3(Math.sin(a.richtung), 0, Math.cos(a.richtung));
    kamPos.copy(a.position).addScaledVector(v, -9).add(new THREE.Vector3(0, 4, 0));
  }

  function eingabe() {
    if (autopilot || modus !== "rennen") return autos[0].kiEingabe(rennen.strecke);
    var t = ui.touch;
    var links = tasten.ArrowLeft || tasten.KeyA || t.links, rechts = tasten.ArrowRight || tasten.KeyD || t.rechts;
    return {
      gas: (tasten.ArrowUp || tasten.KeyW || t.gas) ? 1 : 0,
      bremse: (tasten.ArrowDown || tasten.KeyS || t.bremse) ? 1 : 0,
      lenkung: (rechts ? 1 : 0) - (links ? 1 : 0)
    };
  }

  function schritt(dt) {
    if (!rennen) return;
    // Physik in festen kleinen Schritten – gleich schnell bei 30 oder 120 Bildern pro Sekunde
    var rest = dt;
    while (rest > 0.0001) {
      var d = Math.min(1 / 120, rest);
      if (modus === "menue") rennen.update(d, autos[0].kiEingabe(rennen.strecke)); else rennen.update(d, eingabe());
      rest -= d;
      if (modus === "rennen") ui.update(rennen, autos[0], autopilot);
    }
    if (modus === "rennen" && rennen.status === "ziel") {
      modus = "ziel";
      setTimeout(function () {
        ui.zeigeZiel(rennen, autos[0], function () { starteRennen(stadt); }, function () { zumMenue(stadt); });
      }, 1200);
    }
    kameraFolgen(dt);
  }

  function kameraFolgen(dt) {
    var a = autos[0];
    if (modus === "menue") {
      // Vorführung: Kamera kreist langsam um das führende Auto, hoch genug für die Stadt
      var fuehrer = rennen.rangliste()[0], w = performance.now() / 9000;
      var ziel = fuehrer.position.clone().add(new THREE.Vector3(Math.cos(w) * 70, 38, Math.sin(w) * 70));
      kamPos.lerp(ziel, 1 - Math.exp(-dt * 1.5));
      kamera.position.copy(kamPos);
      kamBlick.lerp(fuehrer.position, 1 - Math.exp(-dt * 3));
      kamera.lookAt(kamBlick);
    } else {
      var vor = new THREE.Vector3(Math.sin(a.richtung), 0, Math.cos(a.richtung));
      // Etwas höher als das Auto, damit Verfolger direkt dahinter nicht die Sicht verdecken
      var soll = a.position.clone().addScaledVector(vor, -8).add(new THREE.Vector3(0, 4.3, 0));
      kamPos.lerp(soll, 1 - Math.exp(-dt * 6));
      kamera.position.copy(kamPos);
      kamBlick.copy(a.position).addScaledVector(vor, 7).add(new THREE.Vector3(0, 1.4, 0));
      kamera.lookAt(kamBlick);
      var fov = 62 + Math.min(1.4, Math.max(0, a.tempo) / 38) * 12 + (a.turbo > 0 ? 6 : 0);
      if (Math.abs(kamera.fov - fov) > 0.1) { kamera.fov += (fov - kamera.fov) * Math.min(1, dt * 4); kamera.updateProjectionMatrix(); }
    }
    // Sonne folgt der Kamera, damit die Autos immer scharfe Schatten werfen
    var mitte = modus === "menue" ? kamBlick : a.position;
    sonne.position.set(mitte.x + 60, mitte.y + 110, mitte.z + 35);
    sonne.target.position.copy(mitte);
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init); else init();
})();
