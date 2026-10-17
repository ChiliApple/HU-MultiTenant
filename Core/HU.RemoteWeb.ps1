#Requires -Version 5.1
<#
.SYNOPSIS
    Handy-Fernbedienung: Webseite (PWA) - HTML, Design, Skript, Service Worker, Manifest.
.DESCRIPTION
    Get-HURemoteWebFiles liefert alle Dateien fuer den Webserver (Pfad -> Typ + Bytes). Die Seite setzt Daten nur als
    Text ein (textContent), nie als HTML; Skript und Design kommen aus eigenen Dateien (strenge CSP ohne Inline-Code).
    Responsiv: Handy (1 Spalte), Foldable/Tablet (2-3 Spalten), Querformat.
.NOTES
    Zielmaschine: der PC, auf dem HU-MultiTenant laeuft. Wird in der Oberflaeche und im Webserver-Runspace geladen.
#>

$script:HURemoteHtml = @'
<!doctype html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="theme-color" content="#1e1e2e">
<meta name="color-scheme" content="dark">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<meta name="apple-mobile-web-app-title" content="HU-MultiTenant">
<meta name="referrer" content="no-referrer">
<link rel="manifest" href="/manifest.webmanifest">
<link rel="icon" href="/icon-192.png">
<link rel="apple-touch-icon" href="/icon-192.png">
<link rel="stylesheet" href="/app.css">
<title>HU-MultiTenant</title>
<script src="/app.js" defer></script>
</head>
<body>
<header class="top">
  <img class="logo" src="/icon-192.png" alt="">
  <div class="ttl"><div class="name">HU-MultiTenant</div><div class="sub" id="pcName">Fernbedienung</div></div>
  <span class="dot" id="conn" role="img" aria-label="Verbindung"></span>
</header>
<div class="banner hidden" id="banner" role="alert"></div>

<main>
  <!-- Koppeln -->
  <section class="view hidden" id="vPair">
    <div class="card">
      <div class="row between"><h2>1. Zertifikat</h2><span class="pill" id="certState">wird geprueft ...</span></div>
      <p class="muted small">Zuerst einmal das Zertifikat dieses PCs installieren - dann laeuft die Verbindung ohne Warnung und die App kann auf den Startbildschirm. Ist das HUMig-Zertifikat dieses PCs schon installiert, ist nichts zu tun.</p>
      <a class="btn wide" href="/ca.cer" download="HU-Fernbedienung-CA.cer">Zertifikat laden</a>
      <details><summary>Android</summary><ol>
        <li><b>Zertifikat laden</b> antippen.</li>
        <li>Einstellungen &rsaquo; Sicherheit &rsaquo; (Weitere Einstellungen &rsaquo;) Verschluesselung &amp; Anmeldedaten &rsaquo; <b>Zertifikat installieren</b> &rsaquo; <b>CA-Zertifikat</b> &rsaquo; die geladene Datei waehlen.</li>
        <li>Diese Seite neu laden, dann im Browser-Menue <b>App installieren</b>.</li>
      </ol></details>
      <details><summary>iPhone / iPad</summary><ol>
        <li>In <b>Safari</b> &rsaquo; <b>Zertifikat laden</b> &rsaquo; <i>Zulassen</i>.</li>
        <li>Einstellungen &rsaquo; <b>Profil geladen</b> &rsaquo; <i>Installieren</i>.</li>
        <li>Einstellungen &rsaquo; Allgemein &rsaquo; Info &rsaquo; <b>Zertifikatsvertrauenseinstellungen</b> &rsaquo; <i>HUMig Fernbedienung CA</i> einschalten.</li>
        <li>Seite neu laden, dann <b>Teilen</b> &rsaquo; <b>Zum Home-Bildschirm</b>. Erst <b>in der App</b> koppeln (Safari und App sind getrennt).</li>
      </ol></details>
      <p class="muted small">Sicherheit: den SHA-256-Fingerabdruck in den Zertifikatsdetails am Handy mit dem im Fenster <b>Remote FB</b> am PC vergleichen.</p>
    </div>
    <div class="card hero">
      <h1>2. Koppeln</h1>
      <p class="muted">Code aus HU-MultiTenant eingeben (Knopf <b>Remote FB</b> &rsaquo; <b>Handy koppeln</b>).</p>
      <label class="lbl" for="pCode">Kopplungscode</label>
      <input id="pCode" class="code" inputmode="numeric" autocomplete="one-time-code" maxlength="7" placeholder="000000">
      <label class="lbl" for="pName">Name dieses Geraets</label>
      <input id="pName" class="txt" maxlength="40" placeholder="Handy">
      <button class="btn primary wide" id="pBtn">Koppeln</button>
      <p class="err hidden" id="pErr" role="alert"></p>
    </div>
  </section>

  <!-- Liste -->
  <section class="view hidden" id="vList">
    <div class="seg" role="tablist">
      <button data-k="snippet" class="on" role="tab">Snippets</button>
      <button data-k="ext" role="tab">Erweiterungen</button>
      <button data-k="teams" role="tab">Meldungen</button>
    </div>
    <input id="lFind" class="txt find" type="search" placeholder="Suchen ..." aria-label="Suchen">
    <div class="busy hidden" id="lBusy"></div>
    <div class="grid" id="lBody"></div>
  </section>

  <!-- Start: Tenants, Parameter, Ziel -->
  <section class="view hidden" id="vStart">
    <button class="btn small back" id="sBack">&lsaquo; Zurueck</button>
    <h1 id="sTitle"></h1>
    <p class="muted small" id="sDesc"></p>
    <div class="pill" id="sMode"></div>
    <div id="sTenBox">
      <div class="row between"><h2>Tenants</h2><span><button class="btn mini" id="sAll">alle</button> <button class="btn mini" id="sNone">keiner</button></span></div>
      <div class="chips" id="sTen"></div>
    </div>
    <p class="muted small hidden" id="sFixed"></p>
    <div id="sParBox"><h2>Parameter</h2><div id="sPar"></div></div>
    <div id="sTgtBox" class="hidden"><h2>Senden an</h2><select id="sTgt" class="txt"></select></div>
    <p class="err hidden" id="sErr" role="alert"></p>
    <button class="btn primary wide big" id="sGo">Pruefen</button>
  </section>

  <!-- Bestaetigung (eigener Schritt, Review 031 B6) -->
  <section class="view hidden" id="vConfirm">
    <div class="warnbox hidden" id="cWarn" role="alert"><span class="ico">&#9888;</span><span id="cWarnT"></span></div>
    <div class="okbox hidden" id="cSafe"><span class="ico">&#10003;</span><span id="cSafeT">Probelauf / nur lesend - aendert nichts</span></div>
    <div class="card">
      <div class="kv"><span>Was</span><b id="cWhat"></b></div>
      <div class="kv"><span>Wo</span><b id="cWhere"></b></div>
      <div class="kv hidden" id="cTeamsRow"><span>Teams</span><b id="cTeams"></b></div>
      <div class="kv"><span>Am PC</span><b id="cBy"></b></div>
      <div id="cPar"></div>
    </div>
    <p class="muted small" id="cHint"></p>
    <div id="cLive" class="hidden">
      <label class="lbl" for="cCode">Kuerzel abtippen: <b class="short" id="cShort"></b></label>
      <input id="cCode" class="txt code4" maxlength="4" autocomplete="off" autocapitalize="characters" spellcheck="false">
      <label class="lbl" for="cPin">Fernbedienungs-PIN</label>
      <input id="cPin" class="txt code4" type="password" inputmode="numeric" maxlength="12" autocomplete="off">
    </div>
    <p class="muted small" id="cTime"></p>
    <p class="err hidden" id="cErr" role="alert"></p>
    <div class="row two">
      <button class="btn big" id="cBack">Zurueck</button>
      <button class="btn primary big" id="cGo">Starten</button>
    </div>
  </section>

  <!-- Lauf -->
  <section class="view hidden" id="vRun">
    <div class="card run">
      <span class="pulse hidden" id="rDot" aria-hidden="true"></span>
      <div class="jinfo">
        <div class="jtitle" id="rTitle">Kein Lauf</div>
        <div class="muted" id="rStatus"></div>
        <div class="muted small" id="rTime"></div>
      </div>
    </div>
    <div id="rDone"></div>
    <button class="btn danger wide hidden" id="rCancel">Abbrechen</button>
    <div class="row between runhead"><h2>Ausgabe</h2><span class="row tools"><input id="rFind" class="find-s" type="search" placeholder="Filter" aria-label="Ausgabe filtern" autocomplete="off"><button class="ibtn" id="rAgain" title="Letzten Lauf wiederholen" aria-label="Letzten Lauf wiederholen (mit Bestaetigung)" disabled>&#8635;</button><button class="ibtn" id="rCopy" title="Alles kopieren" aria-label="Ausgabe in die Zwischenablage kopieren">&#10697;</button><button class="ibtn" id="rClear" title="Leeren" aria-label="Ausgabe leeren">&#128465;</button><label class="muted small"><input type="checkbox" id="rFollow" checked> mitlaufen</label></span></div>
    <p class="muted small hidden" id="rLost"></p>
    <div class="console" id="rCon" aria-live="polite"></div>
  </section>

  <!-- Intune: Apps und Wartung -->
  <section class="view hidden" id="vIntune">
    <div class="seg" id="iSeg" role="tablist">
      <button data-a="app" class="on" role="tab">Apps</button>
      <button data-a="rem" role="tab">Wartung</button>
    </div>
    <label class="lbl" for="iTen">Tenant</label>
    <select id="iTen" class="txt"></select>
    <div class="row between runhead"><input id="iFind" class="txt find" type="search" placeholder="Suchen ..." aria-label="Suchen"><button class="ibtn" id="iReload" title="Neu laden" aria-label="Neu laden">&#8635;</button></div>
    <p class="muted small" id="iAt"></p>
    <p class="err hidden" id="iErr" role="alert"></p>
    <div class="grid" id="iBody"></div>
  </section>

  <section class="view hidden" id="vIObj">
    <button class="btn small back" id="oBack">&lsaquo; Zurueck</button>
    <h1 id="oTitle"></h1>
    <p class="muted small" id="oDesc"></p>
    <div class="card">
      <div class="kv"><span>Tenant</span><b id="oTen"></b></div>
      <div class="kv"><span>Stand</span><b id="oSum">-</b></div>
    </div>
    <button class="btn wide" id="oDevBtn">Geraete anzeigen</button>
    <p class="muted small hidden" id="oDevHint"></p>
    <input id="oDevFind" class="txt find hidden" type="search" placeholder="Geraet, Benutzer oder Status filtern ..." aria-label="Geraete filtern" autocomplete="off">
    <div id="oDev"></div>
    <div class="row between"><h2>Zuweisungen</h2><button class="ibtn" id="oReload" title="Neu laden" aria-label="Neu laden">&#8635;</button></div>
    <div id="oAsg"></div>
    <h2>Zuweisen</h2>
    <label class="lbl" for="oKind">Ziel</label>
    <select id="oKind" class="txt"><option value="group">Gruppe</option><option value="exclude">Ausschluss (Gruppe)</option><option value="allDevices">Alle Geraete</option><option value="allUsers">Alle Benutzer</option></select>
    <div id="oGrpBox">
      <input id="oGrpFind" class="txt find" type="search" placeholder="Gruppe suchen (Gruppen werden geladen) ..." aria-label="Gruppe suchen" autocomplete="off">
      <div id="oGrpList"></div>
      <p class="muted small" id="oGrpSel">Keine Gruppe gewaehlt</p>
    </div>
    <div id="oIntBox"><label class="lbl" for="oIntent">Art</label>
      <select id="oIntent" class="txt"><option value="required">Erforderlich</option><option value="available">Verfuegbar</option><option value="uninstall">Deinstallieren</option></select></div>
    <div id="oSchBox"><label class="lbl" for="oSch">Zeitplan</label>
      <select id="oSch" class="txt"><option value="daily">taeglich</option><option value="hourly">stuendlich</option><option value="once">einmalig</option></select>
      <div class="row two"><div><label class="lbl" for="oIv" id="oIvL">alle ... Tage</label><input id="oIv" class="txt" type="number" min="1" max="30" value="1"></div>
        <div id="oTimeBox"><label class="lbl" for="oTime">Uhrzeit</label><input id="oTime" class="txt" type="time" value="08:00"></div></div>
      <div id="oDateBox" class="hidden"><label class="lbl" for="oDate">Datum</label><input id="oDate" class="txt" type="date"></div>
    </div>
    <p class="err hidden" id="oErr" role="alert"></p>
    <button class="btn primary wide big" id="oGo">Pruefen</button>
  </section>

  <!-- Mehr -->
  <section class="view hidden" id="vMore">
    <h1>Dieses Geraet</h1>
    <div class="card">
      <div class="kv"><span>Gekoppelt als</span><b id="mDev">-</b></div>
      <div class="kv"><span>PC</span><b id="mPc">-</b></div>
      <div class="kv"><span>HU-MultiTenant</span><b id="mVer">-</b></div>
      <div class="kv"><span>PIN fuer echte Laeufe</span><b id="mPin">-</b></div>
      <div class="kv"><span>Verbindung</span><b id="mCert">-</b></div>
    </div>
    <div class="card">
      <div class="kv"><span>Benachrichtigungen</span><b id="nState">-</b></div>
      <p class="muted small" id="nHint"></p>
      <button class="btn primary wide hidden" id="nBtn">Einschalten</button>
    </div>
    <a class="btn wide" href="/ca.cer" download="HU-Fernbedienung-CA.cer">Zertifikat erneut laden</a>
    <button class="btn danger wide" id="mUnpair">Dieses Handy entkoppeln</button>
    <p class="muted small">Gestartet wird am PC - HU-MultiTenant muss dort offen und die Fernbedienung an sein. Client Secrets und Webhook-Adressen bleiben am PC; was ein Skript selbst ausgibt, erscheint hier.</p>
  </section>
</main>

<nav class="tabs hidden" id="tabs">
  <button data-tab="vList" class="on"><span class="ico">&#9776;</span>Starten</button>
  <button data-tab="vIntune" id="tIntune" class="hidden"><span class="ico">&#9638;</span>Intune</button>
  <button data-tab="vRun"><span class="ico">&#9654;</span>Lauf<span class="badge hidden" id="tRun"></span></button>
  <button data-tab="vMore"><span class="ico">&#8942;</span>Mehr</button>
</nav>

<div class="modal hidden" id="modal">
  <div class="mbox" role="dialog" aria-modal="true" aria-labelledby="mTitle">
    <h2 id="mTitle"></h2>
    <p id="mText"></p>
    <div class="row end"><button class="btn" id="mNo">Nein</button><button class="btn danger" id="mYes">Ja</button></div>
  </div>
</div>
</body>
</html>
'@

$script:HURemoteCss = @'
:root{--bg:#1e1e2e;--mantle:#181825;--crust:#11111b;--s0:#313244;--s1:#45475a;--s2:#585b70;--tx:#cdd6f4;--sub:#a6adc8;--ov:#6c7086;
--blue:#89b4fa;--green:#a6e3a1;--peach:#fab387;--red:#f38ba8;--yellow:#f9e2af;--mauve:#cba6f7;--teal:#94e2d5;
--r:16px;--safe-b:env(safe-area-inset-bottom,0px);--safe-t:env(safe-area-inset-top,0px)}
*{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
html,body{margin:0;background:var(--bg);color:var(--tx);font:16px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif}
body{min-height:100vh;padding-bottom:calc(76px + var(--safe-b))}
h1{font-size:22px;margin:6px 0 10px}h2{font-size:16px;margin:4px 0 8px}
.hidden{display:none!important}.muted{color:var(--sub)}.small{font-size:13px}
.top{position:sticky;top:0;z-index:5;display:flex;align-items:center;gap:12px;padding:calc(10px + var(--safe-t)) 16px 10px;
background:linear-gradient(180deg,var(--mantle),rgba(24,24,37,.92));backdrop-filter:blur(10px);border-bottom:1px solid var(--s0)}
.logo{width:38px;height:38px;border-radius:50%}
.ttl{flex:1;min-width:0}.name{font-weight:700;letter-spacing:.3px}.sub{color:var(--sub);font-size:13px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.dot{width:12px;height:12px;border-radius:50%;background:var(--ov);box-shadow:0 0 0 3px rgba(108,112,134,.25);transition:background .3s}
.dot.ok{background:var(--green);box-shadow:0 0 0 3px rgba(166,227,161,.25)}.dot.bad{background:var(--red);box-shadow:0 0 0 3px rgba(243,139,168,.25)}
.banner{margin:10px 16px 0;padding:10px 14px;border-radius:12px;background:rgba(243,139,168,.15);border:1px solid rgba(243,139,168,.4);color:var(--red);font-size:14px}
main{padding:8px 16px}
.view{animation:fade .25s ease}@keyframes fade{from{opacity:0;transform:translateY(6px)}to{opacity:1;transform:none}}
.card{background:var(--mantle);border:1px solid var(--s0);border-radius:var(--r);padding:14px 16px;margin:12px 0;box-shadow:0 6px 18px rgba(0,0,0,.25)}
.hero{background:radial-gradient(120% 140% at 0% 0%,rgba(137,180,250,.18),transparent 55%),var(--mantle)}
.row{display:flex;align-items:center;gap:10px}.between{justify-content:space-between}.end{justify-content:flex-end}
.lbl{display:block;font-size:13px;color:var(--sub);margin:12px 0 6px}
input.txt,input.code{width:100%;padding:12px 14px;border-radius:12px;border:1px solid var(--s1);background:var(--crust);color:var(--tx);font-size:17px;outline:none}
input.code{font-size:28px;letter-spacing:10px;text-align:center;font-variant-numeric:tabular-nums}
input:focus{border-color:var(--blue);box-shadow:0 0 0 3px rgba(137,180,250,.25)}
.btn{display:inline-flex;align-items:center;justify-content:center;gap:6px;padding:11px 16px;border-radius:12px;border:1px solid var(--s1);
background:var(--s0);color:var(--tx);font-size:15px;font-weight:600;text-decoration:none;cursor:pointer;transition:transform .08s,filter .2s}
.btn:active{transform:scale(.97)}.btn.small{padding:7px 12px;font-size:13px}.btn.wide{width:100%;margin-top:12px}
.btn.primary{background:linear-gradient(135deg,var(--blue),var(--mauve));color:var(--crust);border:0}
.btn.danger{background:rgba(243,139,168,.15);border-color:rgba(243,139,168,.5);color:var(--red)}
.btn[disabled]{opacity:.5}
.err{color:var(--red);margin:10px 0 0}
.pill{font-size:12px;padding:4px 10px;border-radius:99px;background:var(--s0);color:var(--sub)}
.pill.ok{background:rgba(166,227,161,.15);color:var(--green)}.pill.warn{background:rgba(250,179,135,.15);color:var(--peach)}
details{margin-top:12px;border-top:1px solid var(--s0);padding-top:8px}summary{cursor:pointer;font-weight:600;padding:6px 0}
ol{margin:6px 0 4px 18px;padding:0;color:var(--sub)}li{margin:6px 0}
.sec{margin:18px 0 6px;font-size:12px;letter-spacing:1.2px;color:var(--ov);font-weight:700;text-transform:uppercase}
.item{display:flex;gap:12px;align-items:flex-start;background:var(--mantle);border:1px solid var(--s0);border-radius:14px;padding:12px 14px;margin:8px 0}
.lv{flex:none;width:10px;height:10px;border-radius:50%;margin-top:7px;background:var(--ov)}
.lv.OK{background:var(--green)}.lv.Warning{background:var(--peach)}.lv.Error{background:var(--red)}.lv.Info{background:var(--blue)}
.item .t{font-weight:600}.item .s{color:var(--sub);font-size:13px;margin-top:2px;word-break:break-word}
.item.Error{border-color:rgba(243,139,168,.45);background:linear-gradient(90deg,rgba(243,139,168,.10),var(--mantle) 40%)}
.item.Warning{border-color:rgba(250,179,135,.35)}
.empty{color:var(--sub);font-size:14px;padding:6px 2px}
.job{display:flex;align-items:center;gap:18px}
.ring{position:relative;width:118px;height:118px;flex:none}.ring svg{width:100%;height:100%;transform:rotate(-90deg)}
.ring circle{fill:none;stroke-width:10}.ring .track{stroke:var(--s0)}
.ring .bar{stroke:var(--green);stroke-linecap:round;stroke-dasharray:326.7;stroke-dashoffset:326.7;transition:stroke-dashoffset .6s ease}

.pct{position:absolute;inset:0;display:flex;align-items:center;justify-content:center;font-size:24px;font-weight:700;font-variant-numeric:tabular-nums}
.mt{display:flex;align-items:center;gap:12px;padding:8px 0;border-bottom:1px solid var(--s0)}.mt:last-child{border:0}
.mt>div{flex:1;min-width:0}.ml{font-size:11px;font-weight:600;color:var(--sub);letter-spacing:.03em}
.mv{font-size:17px;font-weight:700;font-variant-numeric:tabular-nums;word-break:break-word}.ms{font-size:12px;color:var(--ov);word-break:break-word}
.spark{flex:none;width:120px;height:36px;background:var(--crust);border-radius:6px}.spark polyline{fill:none;stroke-width:1.5;vector-effect:non-scaling-stroke}
.spark .wr{stroke:var(--blue)}.spark .rd{stroke:var(--ov)}.spark .cpu{stroke:var(--green)}.spark .ram{stroke:var(--mauve)}
.item .s.ml{white-space:pre-line;font-weight:400;line-height:1.45}
.item .act{margin-top:8px}.btn.mini{padding:5px 12px;font-size:13px;border-radius:9px}
#jSchedMsg{margin:4px 0 8px}#jSchedMsg.ok{color:var(--green)}#jSchedMsg.bad{color:var(--red)}
.jinfo{min-width:0}.jtitle{font-size:18px;font-weight:700;word-break:break-word}
.console{background:var(--crust);border:1px solid var(--s0);border-radius:14px;padding:10px 12px;height:46vh;overflow:auto;
font:12.5px/1.5 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;white-space:pre-wrap;word-break:break-word}
.console .ln{color:var(--tx)}.console .z{color:var(--sub);margin-right:6px}
.console .Success{color:var(--green)}.console .Warning{color:var(--peach)}.console .Error{color:var(--red)}.console .Debug{color:var(--ov)}.console .Header{color:var(--blue);font-weight:700}
.kv{display:flex;justify-content:space-between;gap:12px;padding:8px 0;border-bottom:1px solid var(--s0)}.kv:last-child{border:0}.kv span{color:var(--sub)}
.kv b{text-align:right;word-break:break-word}
.tabs{position:fixed;left:0;right:0;bottom:0;z-index:6;display:flex;padding:6px 8px calc(6px + var(--safe-b));
background:rgba(17,17,27,.92);backdrop-filter:blur(12px);border-top:1px solid var(--s0)}
.tabs button{flex:1;position:relative;display:flex;flex-direction:column;align-items:center;gap:2px;padding:8px 0;border:0;background:none;color:var(--sub);font-size:12px;font-weight:600;border-radius:12px}
.tabs button .ico{font-size:20px;line-height:1}.tabs button.on{color:var(--blue);background:rgba(137,180,250,.10)}
.badge{position:absolute;top:4px;right:calc(50% - 26px);min-width:9px;height:9px;border-radius:9px;background:var(--green);animation:pulse 1.4s infinite}
@keyframes pulse{0%{box-shadow:0 0 0 0 rgba(166,227,161,.6)}70%{box-shadow:0 0 0 8px rgba(166,227,161,0)}100%{box-shadow:0 0 0 0 rgba(166,227,161,0)}}
.modal{position:fixed;inset:0;z-index:10;background:rgba(17,17,27,.7);backdrop-filter:blur(4px);display:flex;align-items:flex-end;justify-content:center;padding:16px}
.mbox{width:100%;max-width:440px;background:var(--mantle);border:1px solid var(--s1);border-radius:20px;padding:18px;margin-bottom:var(--safe-b);animation:up .2s ease}
@keyframes up{from{transform:translateY(30px);opacity:0}to{transform:none;opacity:1}}
.mbox .row{margin-top:14px}.mbox .btn{flex:1}
@media (min-width:700px){main{max-width:720px;margin:0 auto}}
.seg{display:flex;gap:6px;background:var(--crust);border:1px solid var(--s0);border-radius:14px;padding:4px;margin:6px 0 10px}
.seg button{flex:1;min-height:44px;border:0;border-radius:10px;background:none;color:var(--sub);font-size:14px;font-weight:600}
.seg button.on{background:var(--s0);color:var(--tx)}
.find{margin-bottom:6px}
.grid{display:grid;grid-template-columns:1fr;gap:8px}
.tile{display:flex;gap:12px;align-items:flex-start;text-align:left;width:100%;min-height:56px;background:var(--mantle);border:1px solid var(--s0);border-radius:14px;padding:12px 14px;color:var(--tx);font:inherit;cursor:pointer}
.tile:active{transform:scale(.99)}
.tile .t{font-weight:600}.tile .s{color:var(--sub);font-size:13px;margin-top:2px;word-break:break-word}
.tag{display:inline-block;font-size:11px;font-weight:700;padding:2px 8px;border-radius:99px;margin-left:6px;vertical-align:middle}
.tag.read{background:rgba(166,227,161,.15);color:var(--green)}.tag.write{background:rgba(243,139,168,.15);color:var(--red)}
.tag.cat{background:var(--s0);color:var(--sub)}
.chips{display:flex;flex-wrap:wrap;gap:8px;margin:6px 0 10px}
.chip{min-height:44px;padding:8px 14px;border-radius:99px;border:1px solid var(--s1);background:var(--crust);color:var(--sub);font-size:15px;font-weight:600}
.chip.on{background:rgba(137,180,250,.18);border-color:var(--blue);color:var(--tx)}
.chip.on::before{content:"\2713  "}
.par{margin:10px 0}.par label{display:block;font-size:13px;color:var(--sub);margin-bottom:6px}
.par .sw{display:flex;align-items:center;gap:10px;min-height:44px;font-size:15px;color:var(--tx)}
.par .sw input{width:22px;height:22px}
.par.dry .sw{color:var(--peach);font-weight:600}
select.txt{appearance:none;-webkit-appearance:none;font-size:16px}
.btn.big{min-height:52px;font-size:16px}.btn.back{margin:4px 0 0}
.row.two{gap:12px;margin-top:14px}.row.two .btn{flex:1}
.warnbox,.okbox{display:flex;gap:12px;align-items:center;border-radius:16px;padding:16px;margin:8px 0;font-weight:700;font-size:17px}
.warnbox{background:rgba(243,139,168,.16);border:2px solid var(--red);color:var(--red)}
.okbox{background:rgba(166,227,161,.12);border:1px solid rgba(166,227,161,.5);color:var(--green);font-size:15px}
.warnbox .ico,.okbox .ico{font-size:26px;line-height:1}
input.code4{font-size:24px;letter-spacing:6px;text-align:center;text-transform:uppercase}
.short{font-family:ui-monospace,Menlo,Consolas,monospace;font-size:18px;letter-spacing:4px;color:var(--yellow)}
.kv .chg{color:var(--yellow)}
.run{display:flex;align-items:center;gap:14px}
.pulse{flex:none;width:16px;height:16px;border-radius:50%;background:var(--green);animation:pulse 1.4s infinite}
.done{display:flex;flex-wrap:wrap;gap:6px;margin:4px 0 8px}
.done span{font-size:13px;padding:4px 10px;border-radius:99px;background:var(--s0)}
.done .ok{color:var(--green)}.done .error{color:var(--red)}.done .cancel{color:var(--peach)}
.console .Info{color:var(--tx)}.console .OK{color:var(--green)}.console .Warn{color:var(--peach)}.console .Error{color:var(--red)}.console .Head{color:var(--blue);font-weight:700}
.console .z{color:var(--sub);margin-right:6px}
.busy{margin:6px 0;padding:10px 14px;border-radius:12px;background:rgba(250,179,135,.12);color:var(--peach);font-size:14px}
@media (min-width:600px){.grid{grid-template-columns:1fr 1fr}}
@media (min-width:1000px){.grid{grid-template-columns:1fr 1fr 1fr}main{max-width:1100px}}
@media (min-width:700px) and (max-width:999px){main{max-width:900px}}
@media (orientation:landscape) and (max-height:500px){.console{height:60vh}.top{padding-top:6px;padding-bottom:6px}}
@media (prefers-reduced-motion:reduce){*{animation:none!important;transition:none!important}}
.ok-t{color:var(--green)}
.ibtn{min-width:36px;min-height:36px;padding:0 8px;border:1px solid var(--s0);border-radius:10px;background:none;color:var(--ov);font-size:16px;line-height:1;cursor:pointer}
.gl{display:flex;justify-content:space-between;gap:10px;width:100%;text-align:left;min-height:44px;padding:8px 12px;margin:4px 0;border:1px solid var(--s0);border-radius:10px;background:var(--crust);color:var(--tx);font-size:14px}.gl small{color:var(--sub)}.gl.on{border-color:var(--blue)}
.asg{display:flex;align-items:center;gap:10px;padding:8px 12px;margin:6px 0;border:1px solid var(--s0);border-radius:12px;background:var(--mantle)}.asg div{flex:1;min-width:0}.asg .s{color:var(--sub);font-size:13px}
.dev{padding:6px 2px;border-bottom:1px solid var(--s0);font-size:14px}.dev .s{color:var(--sub);font-size:12px}#iFind{flex:1;margin:0}
.runhead{margin:14px 0 8px}.runhead h2{margin:0}.tools{gap:6px;flex-wrap:nowrap}
.find-s{width:110px;min-height:36px;padding:0 10px;border-radius:10px;border:1px solid var(--s0);background:var(--crust);color:var(--tx);font-size:14px;outline:none}
.find-s:focus{border-color:var(--blue);width:150px}@media (max-width:430px){.runhead{flex-wrap:wrap;gap:6px}.find-s{width:84px}.find-s:focus{width:120px}}.console .ln.f{display:none}.console mark{background:rgba(249,226,175,.35);color:inherit;border-radius:3px}.ibtn:active{background:var(--s0)}.ibtn[disabled]{opacity:.35}.ibtn.done{color:var(--green);border-color:var(--green)}
'@

$script:HURemoteJs = @'
'use strict';
(function () {
  var $ = function (id) { return document.getElementById(id); };
  var S = { token: null, seq: 0, tab: 'vList', timer: null, busy: false, running: false, follow: true, secure: null, info: {},
    cat: null, catVer: -1, kind: 'snippet', item: null, ia: 'app', iten: '', ilist: null, ilistKey: '', iobjId: '', iobj: null, igroups: {}, igSel: null, iqTok: {}, backTo: '', sel: {}, prep: null, prepUntil: 0, cdTimer: null, lastJobEnd: '' };
  try { S.token = localStorage.getItem('hu_token'); } catch (e) { S.token = null; }

  function el(tag, cls, text) { var e = document.createElement(tag); if (cls) { e.className = cls; } if (text !== undefined && text !== null) { e.textContent = String(text); } return e; }
  function clear(n) { while (n.firstChild) { n.removeChild(n.firstChild); } }
  function show(id, on) { $(id).classList.toggle('hidden', !on); }
  function banner(t) { var b = $('banner'); if (t) { b.textContent = t; b.classList.remove('hidden'); } else { b.classList.add('hidden'); } }
  function setConn(ok) { var d = $('conn'); d.classList.toggle('ok', ok === true); d.classList.toggle('bad', ok === false); d.setAttribute('aria-label', ok ? 'verbunden' : 'keine Verbindung'); }
  function guessName() { var u = navigator.userAgent || ''; if (/iPhone/.test(u)) { return 'iPhone'; } if (/iPad/.test(u)) { return 'iPad'; } if (/Android/.test(u)) { return 'Android-Handy'; } return 'Handy'; }
  function fmtDur(s) { s = Math.max(0, s | 0); var m = Math.floor(s / 60), x = s % 60; return m + ':' + String(x).padStart(2, '0'); }
  function err(id, t) { $(id).textContent = t || ''; show(id, !!t); }

  function api(method, path, body) {
    var o = { method: method, headers: {}, cache: 'no-store', credentials: 'omit' };
    if (S.token) { o.headers.Authorization = 'Bearer ' + S.token; }
    if (body !== undefined) { o.headers['Content-Type'] = 'application/json'; o.body = JSON.stringify(body); }
    return fetch(path, o).then(function (r) {
      return r.json().catch(function () { return {}; }).then(function (j) { j.__status = r.status; return j; });
    });
  }

  // --- Ansicht merken (Seite, Art, Eintrag): Herunterziehen/Neuladen bleibt dort. localStorage, weil
  // sessionStorage in der installierten App beim Neuladen nicht immer erhalten bleibt; gilt 30 Minuten.
  function memo() {
    var v = S.tab === 'vConfirm' ? (S.backTo === 'vIObj' ? 'vIObj' : 'vStart') : S.tab;
    try { localStorage.setItem('hu_nav', JSON.stringify({ v: v, k: S.kind, i: S.item ? S.item.id : '', ia: S.ia, it: S.iten, io: S.iobjId || '', t: Date.now() })); } catch (e) { }
  }
  function recall() {
    try { var n = JSON.parse(localStorage.getItem('hu_nav') || 'null'); if (n && Date.now() - (n.t || 0) < 1800000) { return n; } } catch (e) { }
    return null;
  }
  function setKind(k) {
    S.kind = k;
    Array.prototype.forEach.call(document.querySelectorAll('.seg button'), function (x) { x.classList.toggle('on', x.getAttribute('data-k') === k); });
  }
  // --- Ansicht
  var VIEWS = ['vPair', 'vList', 'vStart', 'vConfirm', 'vRun', 'vMore', 'vIntune', 'vIObj'];
  function setView(v) {
    VIEWS.forEach(function (x) { show(x, x === v); });
    show('tabs', v !== 'vPair');
    S.tab = v;
    // Ansicht merken: Herunterziehen (Neuladen) bleibt auf dieser Seite
    if (v !== 'vPair') { memo(); }
    var tabOf = (v === 'vStart' || v === 'vConfirm') ? (S.backTo === 'vIObj' && v === 'vConfirm' ? 'vIntune' : 'vList') : (v === 'vIObj' ? 'vIntune' : v);
    Array.prototype.forEach.call(document.querySelectorAll('.tabs button'), function (b) { var on = b.getAttribute('data-tab') === tabOf; b.classList.toggle('on', on); if (on) { b.setAttribute('aria-current', 'page'); } else { b.removeAttribute('aria-current'); } });
    if (v === 'vRun' && S.follow) { var c = $('rCon'); c.scrollTop = c.scrollHeight; }
    if (v === 'vMore') { pushState(); }
    if (v === 'vIntune') { iShow(); }
    if (v === 'vIObj' && S.iobjId) { oLoad(false); }
    if (v !== 'vConfirm') { clearInterval(S.cdTimer); }
    window.scrollTo(0, 0);
    schedule(50);
  }
  function needPair(msg) {
    S.token = null; try { localStorage.removeItem('hu_token'); } catch (e) { }
    kv('readwrite', function (st) { st.clear(); }).catch(function () { });
    pushSub().then(function (s) { if (s) { s.unsubscribe(); } }).catch(function () { });
    clearTimeout(S.timer);
    setView('vPair');
    if (msg) { err('pErr', msg); }
  }

  // --- Koppeln
  function pair() {
    var code = ($('pCode').value || '').replace(/\D/g, '');
    if (code.length !== 6) { err('pErr', 'Bitte den 6-stelligen Code vom PC eingeben.'); return; }
    $('pBtn').disabled = true; err('pErr', '');
    api('POST', '/api/pair', { code: code, name: ($('pName').value || '').trim() || guessName() }).then(function (j) {
      $('pBtn').disabled = false;
      if (j.ok && j.token) {
        S.token = j.token; try { localStorage.setItem('hu_token', j.token); } catch (e) { }
        $('pCode').value = ''; S.seq = 0; clear($('rCon')); S.catVer = -1;
        setView('vList'); poll();
      } else { err('pErr', j.error || 'Kopplung fehlgeschlagen.'); }
    }).catch(function () { $('pBtn').disabled = false; err('pErr', 'PC nicht erreichbar.'); });
  }

  // --- Daten holen
  function schedule(ms) {
    clearTimeout(S.timer);
    if (!S.token || document.hidden) { return; }
    S.timer = setTimeout(poll, ms);
  }
  function poll() {
    if (!S.token || S.busy) { return; }
    S.busy = true;
    api('GET', '/api/state?since=' + S.seq).then(function (j) {
      S.busy = false;
      if (j.__status === 401) { needPair('Dieses Handy ist nicht (mehr) gekoppelt - Code vom PC eingeben.'); return; }
      if (!j.ok) { setConn(false); banner(j.error || 'Fehler beim Lesen'); schedule(10000); return; }
      setConn(true); banner(''); S.lastOk = Date.now();
      render(j);
      if (j.catVer !== S.catVer) { loadCatalog(); }
      schedule(S.running || S.tab === 'vRun' ? 1200 : 10000);
    }).catch(function () {
      S.busy = false; setConn(false);
      var t = S.lastOk ? new Date(S.lastOk).toLocaleTimeString().slice(0, 5) : '';
      banner('PC nicht erreichbar' + (t ? ' seit ' + t : '') + ' - Ruhezustand, App geschlossen oder VPN getrennt? Ein laufender Lauf laeuft am PC weiter.');
      schedule(8000);
    });
  }
  function loadCatalog() {
    api('GET', '/api/catalog').then(function (j) {
      if (!j.ok) { return; }
      S.cat = j; S.catVer = j.ver;
      var hasI = (j.items || []).some(function (x) { return x.kind === 'intune'; });
      show('tIntune', hasI);
      if (!hasI && (S.tab === 'vIntune' || S.tab === 'vIObj')) { setView('vList'); }
      if (S.tab === 'vIntune') { iShow(); }
      renderList();
      if (S.restoreItem) {
        var it = (j.items || []).filter(function (x) { return x.id === S.restoreItem; })[0];
        S.restoreItem = null;
        if (it && S.tab === 'vList') { openItem(it); }
      }
    }).catch(function () { });
  }

  // --- Anzeige: Zustand
  function render(j) {
    S.info = j;
    $('pcName').textContent = (j.pc || '') + (j.version ? '  ·  v' + j.version : '');
    document.title = 'HU-MultiTenant - ' + (j.pc || '');
    $('mDev').textContent = j.device || '-'; $('mPc').textContent = j.pc || '-'; $('mVer').textContent = j.version || '-';
    $('mPin').textContent = j.pin ? 'eingerichtet' : 'fehlt - am PC festlegen';
    if (j.locked) { banner('Dieses Handy ist gesperrt (zu viele falsche PINs) - am PC unter Remote FB entsperren.'); }
    $('lBusy').textContent = j.busy ? 'Am PC laeuft gerade: ' + j.busy + ' - Start erst danach moeglich.' : '';
    show('lBusy', !!j.busy);
    renderJob(j.job || {});
    if (j.lost) { $('rLost').textContent = j.lost + ' Zeilen nicht mehr im Puffer - vollstaendig am PC in Logs\\Remote'; show('rLost', true); }
    var lines = j.lines || [];
    if (lines.length) {
      var c = $('rCon'), atEnd = c.scrollTop + c.clientHeight >= c.scrollHeight - 30;
      lines.forEach(function (l) {
        var d = el('div', 'ln ' + (l.l || 'Info'));
        d.appendChild(el('span', 'z', l.t || '')); d.appendChild(document.createTextNode(l.z || ''));
        fitLine(d, ($('rFind').value || '').trim().toLowerCase());
        c.appendChild(d);
      });
      while (c.childNodes.length > 1500) { c.removeChild(c.firstChild); }
      if (S.follow && (atEnd || S.tab !== 'vRun')) { c.scrollTop = c.scrollHeight; }
      S.seq = j.seq;
    } else if (j.seq < S.seq) { S.seq = j.seq; }
  }
  function renderJob(job) {
    S.running = !!job.running;
    show('tRun', S.running); show('rDot', S.running); show('rCancel', S.running);
    $('rAgain').disabled = !!(S.running || !S.lastBody);
    $('rTitle').textContent = job.title || 'Kein Lauf';
    $('rStatus').textContent = job.running ? 'laeuft' + (job.live ? ' - ECHTER LAUF' : '') + (job.by ? ' (von ' + job.by + ')' : '') : (job.result || '');
    $('rStatus').className = job.running ? 'muted' : (job.level === 'OK' ? 'ok-t' : job.level === 'Error' ? 'err' : 'muted');
    $('rTime').textContent = job.started ? 'Start ' + job.started + ', Dauer ' + fmtDur(job.seconds) + (job.tenants && job.tenants.length ? ' - ' + job.tenants.join(', ') : '') : '';
    var d = $('rDone'); clear(d);
    if ((job.done || []).length) {
      var w = el('div', 'done');
      job.done.forEach(function (x) { var m = /: (ok|error|cancel)$/.exec(x); var s = el('span', m ? m[1] : '', x.replace(/: ok$/, ' ✓').replace(/: error$/, ' ✗ Fehler').replace(/: cancel$/, ' abgebrochen')); w.appendChild(s); });
      d.appendChild(w);
    }
  }

  // --- Liste
  function renderList() {
    var b = $('lBody'); clear(b);
    if (!S.cat) { return; }
    var q = ($('lFind').value || '').toLowerCase();
    var items = (S.cat.items || []).filter(function (x) { return x.kind === S.kind && (!q || (x.name + ' ' + (x.desc || '') + ' ' + (x.cat || '')).toLowerCase().indexOf(q) >= 0); });
    if (!items.length) {
      b.appendChild(el('div', 'empty', S.kind === 'teams' ? 'Keine gespeicherten Meldungen.' : 'Nichts fuers Handy freigegeben - am PC unter Remote FB > Freigaben fuers Handy markieren.'));
      return;
    }
    items.forEach(function (x) {
      var t = el('button', 'tile');
      var w = el('div');
      var h = el('div', 't', x.name);
      if (x.kind !== 'teams') { h.appendChild(el('span', 'tag ' + (x.mode === 'read' ? 'read' : 'write'), x.mode === 'read' ? 'liest' : 'aendert')); }
      if (x.cat) { h.appendChild(el('span', 'tag cat', x.cat)); }
      w.appendChild(h);
      if (x.desc) { w.appendChild(el('div', 's', x.desc)); }
      t.appendChild(w);
      t.addEventListener('click', function () { openItem(x); });
      b.appendChild(t);
    });
  }

  // --- Start-Formular
  function openItem(x) {
    S.item = x; S.sel = {};
    (x.tenants || []).forEach(function (k) { S.sel[k] = true; });
    $('sTitle').textContent = x.name; $('sDesc').textContent = x.desc || '';
    var m = $('sMode');
    if (x.kind === 'teams') { m.textContent = 'sendet an: ' + (x.targets || '-'); m.className = 'pill'; }
    else { m.textContent = x.mode === 'read' ? 'nur lesend' : 'aendert Daten (ohne Probelauf = echter Lauf)'; m.className = 'pill ' + (x.mode === 'read' ? 'ok' : 'warn'); }
    var tb = $('sTen'); clear(tb);
    (S.cat.tenants || []).forEach(function (t) {
      var c = el('button', 'chip' + (S.sel[t.key] ? ' on' : ''), t.name);
      c.setAttribute('aria-pressed', S.sel[t.key] ? 'true' : 'false');
      c.addEventListener('click', function () { S.sel[t.key] = !S.sel[t.key]; c.classList.toggle('on', !!S.sel[t.key]); c.setAttribute('aria-pressed', S.sel[t.key] ? 'true' : 'false'); });
      tb.appendChild(c);
    });
    var pb = $('sPar'); clear(pb);
    (x.params || []).forEach(function (p) {
      var d = el('div', 'par' + (/^(DryRun|WhatIf|Probelauf)$/i.test(p.name) && p.type === 'bool' ? ' dry' : ''));
      var id = 'p_' + p.name;
      if (p.type === 'bool') {
        var l = el('label', 'sw'); var i = el('input'); i.type = 'checkbox'; i.id = id; i.checked = /^(true|1|ja|yes|\$true|wahr)$/i.test(String(p.def || ''));
        l.appendChild(i); l.appendChild(document.createTextNode(p.label)); d.appendChild(l);
      } else {
        var lb = el('label', '', p.label); lb.setAttribute('for', id); d.appendChild(lb);
        var f;
        if (p.type === 'choice') { f = el('select', 'txt'); (p.choices || []).forEach(function (c) { var o = el('option', '', c); o.value = c; if (c === p.def) { o.selected = true; } f.appendChild(o); }); }
        else { f = el('input', 'txt'); f.value = p.def || ''; if (p.type === 'int') { f.inputMode = 'numeric'; f.pattern = '-?[0-9]*'; } else { f.maxLength = 256; } }
        f.id = id; d.appendChild(f);
      }
      pb.appendChild(d);
    });
    show('sParBox', (x.params || []).length > 0);
    var tg = $('sTgt'); clear(tg);
    if (x.kind === 'teams') {
      var o0 = el('option', '', 'wie an der Meldung (' + (x.targets || '-') + ')'); o0.value = ''; tg.appendChild(o0);
      (S.cat.targets || []).forEach(function (t) { var o = el('option', '', 'einmalig nur an: ' + t.name); o.value = t.id; tg.appendChild(o); });
    }
    show('sTgtBox', x.kind === 'teams');
    err('sErr', '');
    setView('vStart');
  }
  function formValues() {
    var v = {};
    (S.item.params || []).forEach(function (p) {
      var f = $('p_' + p.name); if (!f) { return; }
      v[p.name] = p.type === 'bool' ? !!f.checked : String(f.value);
    });
    return v;
  }
  function prepare(again) {
    var body;
    if (again && S.lastBody) { body = S.lastBody; }
    else {
      var ten = Object.keys(S.sel).filter(function (k) { return S.sel[k]; });
      if (!ten.length) { err('sErr', 'Bitte mindestens einen Tenant waehlen.'); return; }
      body = { id: S.item.id, tenants: ten, params: formValues() };
      S.backTo = '';
      if (S.item.kind === 'teams' && $('sTgt').value) { body.target = $('sTgt').value; }
    }
    $('sGo').disabled = true; err('sErr', '');
    api('POST', '/api/prepare', body).then(function (j) {
      $('sGo').disabled = false;
      if (j.__status === 401) { needPair('Nicht mehr gekoppelt.'); return; }
      if (!j.ok) { if (again) { banner(j.error || 'Wiederholen nicht moeglich'); return; } err('sErr', j.error || 'Nicht moeglich'); if (j.__status === 404) { S.catVer = -1; } return; }
      S.prep = j; S.prepUntil = Date.now() + (j.seconds || 120) * 1000;
      S.lastBody = body; S.lastItem = S.item;
      showConfirm(j);
    }).catch(function () { $('sGo').disabled = false; if (again) { banner('PC nicht erreichbar.'); } else { err('sErr', 'PC nicht erreichbar.'); } });
  }
  // Wiederholen: dieselbe Auswahl wie beim letzten Start, wieder ueber die Bestaetigung (Kuerzel/PIN bei echtem Lauf)
  function again() {
    if (!S.lastBody || S.running) { return; }
    var it = ((S.cat && S.cat.items) || []).filter(function (x) { return x.id === S.lastBody.id; })[0];
    if (!it) { banner('Eintrag nicht mehr vorhanden.'); return; }
    S.item = it; S.fromAgain = true; S.backTo = S.lastBody.intune ? 'vIObj' : ''; prepare(true);
  }

  // --- Bestaetigung
  function showConfirm(j) {
    var s = j.summary || {};
    var isTeams = !!(S.item && S.item.kind === 'teams');
    show('cWarn', !!s.live); show('cSafe', !s.live);
    $('cSafeT').textContent = isTeams ? 'Sendet jetzt eine Teams-Meldung' + (s.teams ? ' an ' + s.teams : '') : 'Probelauf / nur lesend - aendert nichts';
    $('cWarnT').textContent = 'Echter Lauf - aendert Daten in ' + (s.tenants || []).length + ' Tenant' + ((s.tenants || []).length === 1 ? '' : 's');
    $('cWhat').textContent = s.title || '';
    $('cWhere').textContent = (s.tenants || []).join(', ');
    $('cTeams').textContent = s.teams || ''; show('cTeamsRow', !!s.teams);
    $('cBy').textContent = 'gestartet von ' + (S.info.device || 'diesem Handy');
    var p = $('cPar'); clear(p);
    (s.params || []).forEach(function (x) { var r = el('div', 'kv'); r.appendChild(el('span', '', x.label)); r.appendChild(el('b', x.changed ? 'chg' : '', x.value)); p.appendChild(r); });
    $('cHint').textContent = s.hint || '';
    show('cLive', !!s.live);
    $('cShort').textContent = j.code || ''; $('cCode').value = ''; $('cPin').value = '';
    $('cGo').textContent = s.live ? 'Echt starten (' + (s.tenants || []).length + ')' : (isTeams ? 'Jetzt senden' : 'Starten');
    $('cGo').className = 'btn big ' + (s.live ? 'danger' : 'primary');
    err('cErr', '');
    setView('vConfirm');
    clearInterval(S.cdTimer);
    var tick = function () {
      var left = Math.max(0, Math.round((S.prepUntil - Date.now()) / 1000));
      $('cTime').textContent = left ? 'Bestaetigung gilt noch ' + left + ' s' : 'Bestaetigung abgelaufen - Zurueck und neu pruefen (Auswahl bleibt erhalten)';
      if (!left) { clearInterval(S.cdTimer); }
      checkGo();
    };
    tick(); S.cdTimer = setInterval(tick, 1000);
    if (s.live) { $('cCode').focus(); }
  }
  function checkGo() {
    var s = (S.prep && S.prep.summary) || {};
    var ok = Date.now() < S.prepUntil;
    if (s.live) { ok = ok && $('cCode').value.trim().toUpperCase() === String(S.prep.code) && /^\d{4,12}$/.test($('cPin').value); }
    $('cGo').disabled = !ok;
  }
  function run() {
    var s = (S.prep && S.prep.summary) || {};
    $('cGo').disabled = true; err('cErr', '');
    var body = { nonce: S.prep.nonce };
    if (s.live) { body.code = $('cCode').value.trim().toUpperCase(); body.pin = $('cPin').value; }
    api('POST', '/api/run', body).then(function (j) {
      $('cPin').value = '';
      if (j.__status === 401) { needPair('Nicht mehr gekoppelt.'); return; }
      if (!j.ok) {
        // kein stiller Neuversuch (Review 031 B7): zurueck zum Formular, Auswahl bleibt
        S.prepUntil = 0; err('cErr', j.error || 'Start nicht moeglich'); checkGo();
        return;
      }
      S.prep = null; S.seq = S.seq; setView('vRun'); schedule(300);
    }).catch(function () { err('cErr', 'PC nicht erreichbar - Zurueck und neu pruefen.'); S.prepUntil = 0; checkGo(); });
  }

  // --- Intune: Apps und Wartung (lesen ohne PIN; Zuweisen/Aufheben ueber Pruefen + Kuerzel + PIN)
  function iItem() { return ((S.cat && S.cat.items) || []).filter(function (x) { return x.kind === 'intune' && x.area === S.ia; })[0]; }
  function tName(k) { var t = ((S.cat && S.cat.tenants) || []).filter(function (x) { return x.key === k; })[0]; return t ? t.name : k; }
  // Abfrage beim PC; liest der PC noch ("pending"), wird nachgefragt. slot: nur die letzte Abfrage je Platz zaehlt
  function iq(slot, q, force, cb, tries) {
    tries = tries || 0;
    if (!tries) { S.iqTok[slot] = (S.iqTok[slot] || 0) + 1; }
    var tok = S.iqTok[slot];
    q.tenant = S.iten; if (force && !tries) { q.force = true; } else { delete q.force; }
    api('POST', '/api/intune', q).then(function (j) {
      if (tok !== S.iqTok[slot]) { return; }
      if (j.__status === 401) { needPair('Nicht mehr gekoppelt.'); return; }
      if (j.ok && j.pending) { if (tries > 240) { cb({ ok: false, error: 'Keine Antwort vom PC (Zeitlimit)' }); return; } setTimeout(function () { iq(slot, q, false, cb, tries + 1); }, 1500); return; }
      cb(j);
    }).catch(function () { if (tok === S.iqTok[slot]) { cb({ ok: false, error: 'PC nicht erreichbar.' }); } });
  }
  function iShow() {
    var sel = $('iTen'), ts = (S.cat && S.cat.tenants) || [];
    if (sel.options.length !== ts.length) {
      clear(sel); ts.forEach(function (t) { var o = el('option', '', t.name); o.value = t.key; sel.appendChild(o); });
    }
    if (!S.iten || !ts.some(function (t) { return t.key === S.iten; })) { S.iten = ts.length ? ts[0].key : ''; }
    sel.value = S.iten;
    Array.prototype.forEach.call(document.querySelectorAll('#iSeg button'), function (x) { x.classList.toggle('on', x.getAttribute('data-a') === S.ia); });
    iLoad(false);   // PC antwortet aus dem Zwischenspeicher; nach einer Aenderung kommt der neue Stand
  }
  function iLoad(force) {
    if (!S.iten) { return; }
    S.ilistKey = S.ia + '|' + S.iten; S.ilist = null; err('iErr', '');
    var b = $('iBody'); clear(b); b.appendChild(el('div', 'empty', 'Lade ' + (S.ia === 'app' ? 'Apps' : 'Wartungsskripte') + ' aus ' + tName(S.iten) + ' ...'));
    $('iAt').textContent = '';
    iq('list', { op: 'list', area: S.ia }, force, function (j) {
      if (!j.ok || j.error) { clear(b); err('iErr', j.error || 'Nicht lesbar'); return; }
      S.ilist = j.data || []; $('iAt').textContent = 'Stand ' + (j.at || '') + ' - ' + S.ilist.length + ' Eintraege';
      iRender();
    });
  }
  function iRender() {
    var b = $('iBody'); clear(b);
    if (!S.ilist) { return; }
    var q = ($('iFind').value || '').toLowerCase();
    var rows = S.ilist.filter(function (x) { return !q || (x.name + ' ' + (x.sub || '')).toLowerCase().indexOf(q) >= 0; });
    if (!rows.length) { b.appendChild(el('div', 'empty', q ? 'Nichts gefunden.' : 'Keine Eintraege.')); return; }
    rows.slice(0, 300).forEach(function (x) {
      var t = el('button', 'tile'), w = el('div'), h = el('div', 't', x.name);
      h.appendChild(el('span', 'tag ' + (x.n > 0 ? 'write' : 'cat'), x.n < 0 ? '?' : (x.n > 0 ? x.n + ' zugewiesen' : 'nicht zugewiesen')));
      w.appendChild(h); if (x.sub) { w.appendChild(el('div', 's', x.sub)); }
      t.appendChild(w); t.addEventListener('click', function () { oOpen(x); }); b.appendChild(t);
    });
  }
  function oOpen(x) {
    S.iobjId = x.id; S.iobj = { name: x.name };
    $('oTitle').textContent = x.name; $('oDesc').textContent = ''; S.igSel = null;
    $('oGrpFind').value = ''; clear($('oGrpList')); $('oGrpSel').textContent = 'Keine Gruppe gewaehlt';
    clear($('oDev')); show('oDevHint', false); show('oDevFind', false); $('oDevFind').value = ''; S.idev = null; err('oErr', '');
    setView('vIObj');
  }
  function oForm() {
    var k = $('oKind').value, app = S.ia === 'app', st = $('oSch').value;
    show('oGrpBox', k === 'group' || k === 'exclude');
    show('oIntBox', app);
    show('oSchBox', !app && k !== 'exclude');
    show('oTimeBox', st !== 'hourly'); show('oDateBox', st === 'once');
    $('oIvL').textContent = st === 'hourly' ? 'alle ... Stunden' : 'alle ... Tage';
    show('oIv', st !== 'once'); show('oIvL', st !== 'once');
    if ((k === 'group' || k === 'exclude') && !S.igroups[S.iten]) { gLoad(); }
  }
  function oLoad(force) {
    $('oTen').textContent = tName(S.iten); $('oSum').textContent = 'wird gelesen ...';
    var a = $('oAsg'); clear(a); a.appendChild(el('div', 'empty', 'Lade Zuweisungen ...'));
    oForm();
    iq('detail', { op: 'detail', area: S.ia, id: S.iobjId }, force, function (j) {
      clear(a);
      if (!j.ok || j.error || !j.data) { $('oSum').textContent = '-'; err('oErr', j.error || 'Nicht lesbar'); return; }
      var d = j.data; S.iobj = d;
      $('oTitle').textContent = d.name; $('oDesc').textContent = d.desc || '';
      $('oSum').textContent = (d.summary || 'keine Angaben') + ' (' + (j.at || '') + ')';
      var rows = d.asg || [];
      if (!rows.length) { a.appendChild(el('div', 'empty', 'Nicht zugewiesen.')); }
      rows.forEach(function (r) {
        var row = el('div', 'asg'), w = el('div');
        w.appendChild(el('div', '', r.ziel)); if (r.info) { w.appendChild(el('div', 's', r.info)); }
        var x = el('button', 'ibtn', '\u2715'); x.title = 'Zuweisung aufheben'; x.setAttribute('aria-label', 'Zuweisung ' + r.ziel + ' aufheben');
        x.addEventListener('click', function () { iPrepare({ op: 'unassign', id: S.iobjId, name: d.name, keys: [r.key] }); });
        row.appendChild(w); row.appendChild(x); a.appendChild(row);
      });
    });
  }
  function oDevices() {
    var b = $('oDev'); clear(b); show('oDevHint', true); show('oDevFind', false); S.idev = null;
    $('oDevHint').textContent = S.ia === 'app' ? 'Intune erstellt den Geraetebericht - das kann eine Minute dauern ...' : 'Lade Geraete ...';
    iq('dev', { op: 'devices', area: S.ia, id: S.iobjId }, true, function (j) {
      if (!j.ok || j.error) { $('oDevHint').textContent = j.error || 'Nicht lesbar'; return; }
      S.idev = j.data || []; S.idevAt = j.at || '';
      show('oDevFind', S.idev.length > 0);
      dRender();
    });
  }
  // Geraeteliste filtern (Name, Benutzer, Status, Version/Hinweis)
  function dRender() {
    var b = $('oDev'); clear(b);
    if (!S.idev) { return; }
    var q = ($('oDevFind').value || '').toLowerCase().trim();
    var rows = S.idev.filter(function (r) { return !q || [r.d, r.u, r.s, r.x].join(' ').toLowerCase().indexOf(q) >= 0; });
    $('oDevHint').textContent = (q ? rows.length + ' von ' : '') + S.idev.length + ' Geraet(e), Stand ' + S.idevAt;
    rows.slice(0, 500).forEach(function (r) { var d = el('div', 'dev'); d.appendChild(el('div', '', (r.d || '-') + ' - ' + (r.s || ''))); var s = [r.u, r.x].filter(function (z) { return z; }).join(' - '); if (s) { d.appendChild(el('div', 's', s)); } b.appendChild(d); });
    if (rows.length > 500) { b.appendChild(el('div', 'empty', 'Weitere ' + (rows.length - 500) + ' - Filter verfeinern.')); }
  }
  function gLoad() {
    var ten = S.iten; $('oGrpSel').textContent = 'Lade Gruppen ...';
    iq('grp', { op: 'groups' }, false, function (j) {
      if (!j.ok || j.error) { $('oGrpSel').textContent = j.error || 'Gruppen nicht lesbar'; return; }
      S.igroups[ten] = j.data || []; $('oGrpSel').textContent = S.igSel ? 'Gewaehlt: ' + S.igSel.name : (S.igroups[ten].length + ' Gruppen - suchen und antippen');
      gRender();
    });
  }
  function gRender() {
    var b = $('oGrpList'); clear(b);
    var all = S.igroups[S.iten] || [], q = ($('oGrpFind').value || '').toLowerCase();
    if (!q) { return; }
    all.filter(function (g) { return g.name.toLowerCase().indexOf(q) >= 0; }).slice(0, 25).forEach(function (g) {
      var x = el('button', 'gl' + (S.igSel && S.igSel.id === g.id ? ' on' : '')); x.appendChild(el('span', '', g.name)); x.appendChild(el('small', '', g.typ));
      x.addEventListener('click', function () { S.igSel = g; $('oGrpSel').textContent = 'Gewaehlt: ' + g.name; $('oGrpFind').value = ''; clear(b); });
      b.appendChild(x);
    });
  }
  function oGo() {
    var k = $('oKind').value, q = { op: 'assign', id: S.iobjId, name: (S.iobj && S.iobj.name) || '', kind: k };
    if (k === 'group' || k === 'exclude') { if (!S.igSel) { err('oErr', 'Bitte eine Gruppe suchen und antippen.'); return; } q.groupId = S.igSel.id; q.groupName = S.igSel.name; }
    if (S.ia === 'app') { q.intent = $('oIntent').value; }
    else if (k !== 'exclude') {
      q.schedule = { type: $('oSch').value, interval: parseInt($('oIv').value, 10) || 1, time: $('oTime').value || '08:00', date: $('oDate').value || '' };
    }
    iPrepare(q);
  }
  function iPrepare(q) {
    var it = iItem(); if (!it) { err('oErr', 'Apps/Wartung sind am PC ausgeschaltet.'); return; }
    S.item = it; S.backTo = 'vIObj'; S.fromAgain = false; err('oErr', '');
    var body = { id: it.id, tenants: [S.iten], intune: q };
    $('oGo').disabled = true;
    api('POST', '/api/prepare', body).then(function (j) {
      $('oGo').disabled = false;
      if (j.__status === 401) { needPair('Nicht mehr gekoppelt.'); return; }
      if (!j.ok) { err('oErr', j.error || 'Nicht moeglich'); return; }
      S.prep = j; S.prepUntil = Date.now() + (j.seconds || 120) * 1000;
      S.lastBody = body; S.lastItem = it;
      showConfirm(j);
    }).catch(function () { $('oGo').disabled = false; err('oErr', 'PC nicht erreichbar.'); });
  }

  // --- Push (wie HUMig): Abo im Browser, Inhalt holt der Service Worker beim PC
  function pushOk() { return ('serviceWorker' in navigator) && ('PushManager' in window) && ('Notification' in window) && S.secure === true; }
  function kv(mode, fn) {
    return new Promise(function (res, rej) {
      if (!window.indexedDB) { rej(new Error('kein IndexedDB')); return; }
      var o = indexedDB.open('humt', 1);
      o.onupgradeneeded = function () { o.result.createObjectStore('kv'); };
      o.onerror = function () { rej(o.error); };
      o.onsuccess = function () {
        var db = o.result, tx = db.transaction('kv', mode), r = fn(tx.objectStore('kv'));
        tx.oncomplete = function () { db.close(); res(r ? r.result : undefined); };
        tx.onerror = function () { db.close(); rej(tx.error); };
      };
    });
  }
  function pushSub() {
    if (!('serviceWorker' in navigator) || !('PushManager' in window)) { return Promise.resolve(null); }
    return navigator.serviceWorker.getRegistration('/').then(function (r) { return r ? r.pushManager.getSubscription() : null; });
  }
  function b64u(s) {
    s = String(s || '').replace(/-/g, '+').replace(/_/g, '/'); while (s.length % 4) { s += '='; }
    var b = atob(s), a = new Uint8Array(b.length); for (var i = 0; i < b.length; i++) { a[i] = b.charCodeAt(i); } return a;
  }
  function sameKey(s, key) {
    try {
      var k = s.options && s.options.applicationServerKey; if (!k) { return true; }
      var a = new Uint8Array(k), b = b64u(key); if (a.length !== b.length) { return false; }
      for (var i = 0; i < a.length; i++) { if (a[i] !== b[i]) { return false; } }
      return true;
    } catch (e) { return true; }
  }
  function pushUi(state, hint, btn) {
    $('nState').textContent = state; $('nHint').textContent = hint || '';
    show('nBtn', !!btn); if (btn) { $('nBtn').textContent = btn; $('nBtn').disabled = false; }
  }
  function pushState() {
    if (!S.token) { return; }
    if (!pushOk()) {
      var ios = /iPhone|iPad/.test(navigator.userAgent || '');
      pushUi('nicht moeglich', S.secure !== true ? 'Erst das Zertifikat installieren (App-Modus), dann geht es.' :
        (ios ? 'iPhone/iPad: ueber Teilen > "Zum Home-Bildschirm" hinzufuegen und von dort oeffnen (ab iOS 16.4).' : 'Dieser Browser kann keine Push-Meldungen.'), '');
      return;
    }
    api('GET', '/api/push').then(function (j) {
      S.pushKey = j.key || '';
      if (!j.ok || !S.pushKey) { pushUi('nicht verfuegbar', 'Am PC nicht verfuegbar.', ''); return; }
      if (Notification.permission === 'denied') { pushUi('blockiert', 'In den Website-Einstellungen des Browsers Benachrichtigungen fuer diese Adresse erlauben.', ''); return; }
      pushSub().then(function (s) {
        S.pushOn = !!(j.on && s && sameKey(s, S.pushKey));
        if (S.pushOn) { kv('readwrite', function (st) { st.put(S.token, 'tok'); st.put(S.info.pc || '', 'pc'); }).catch(function () { }); }
        if (S.pushOn) { pushUi('an', 'Meldung mit Ergebnis, wenn ein Lauf am PC endet - auch wenn die App zu ist (Inhalt nur, wenn das Handy den PC erreicht: Heimnetz oder VPN).', 'Ausschalten'); }
        else { pushUi('aus', 'Meldung aufs Handy, wenn ein Lauf am PC endet. Laeuft ueber den Push-Dienst des Browsers.', 'Einschalten'); }
      });
    }).catch(function () { pushUi('-', 'PC nicht erreichbar.', ''); });
  }
  function pushToggle() {
    $('nBtn').disabled = true;
    if (S.pushOn) {
      pushSub().then(function (s) { return s ? s.unsubscribe() : true; }).catch(function () { })
        .then(function () { return api('POST', '/api/push/off', {}); })
        .then(function () { return kv('readwrite', function (st) { st.clear(); }).catch(function () { }); })
        .then(pushState, pushState);
      return;
    }
    Notification.requestPermission().then(function (p) {
      if (p !== 'granted') { pushState(); return; }
      return navigator.serviceWorker.ready.then(function (reg) {
        var opt = { userVisibleOnly: true, applicationServerKey: b64u(S.pushKey) };
        return reg.pushManager.getSubscription().then(function (o) { return (o && !sameKey(o, S.pushKey)) ? o.unsubscribe() : true; })
          .then(function () { return reg.pushManager.subscribe(opt); }).catch(function () {
            return reg.pushManager.getSubscription().then(function (o) { return o ? o.unsubscribe() : true; }).then(function () { return reg.pushManager.subscribe(opt); });
          });
      }).then(function (sub) {
        return kv('readwrite', function (st) { st.put(S.token, 'tok'); st.put(S.info.pc || '', 'pc'); }).catch(function () { })
          .then(function () { return api('POST', '/api/push', { endpoint: sub.endpoint }); });
      }).then(function (j) {
        if (j && !j.ok) { banner(j.error || 'Einschalten nicht moeglich'); }
        pushState();
      });
    }).catch(function () { banner('Benachrichtigungen konnten nicht eingeschaltet werden'); pushState(); });
  }

  // --- Aktionen
  function ask(title, text, yes) {
    return new Promise(function (res) {
      $('mTitle').textContent = title; $('mText').textContent = text; show('modal', true);
      $('mYes').textContent = yes || 'Ja';
      var done = function (v) { show('modal', false); $('mYes').onclick = null; $('mNo').onclick = null; res(v); };
      $('mYes').onclick = function () { done(true); }; $('mNo').onclick = function () { done(false); };
    });
  }
  function cancelRun() {
    var j = S.info.job || {};
    ask('Abbrechen?', '"' + (j.title || 'Lauf') + '" abbrechen? Der laufende Tenant wird gestoppt, die restlichen nicht mehr gestartet. Was schon geaendert ist, bleibt geaendert.', 'Ja, abbrechen').then(function (ok) {
      if (!ok) { return; }
      $('rCancel').disabled = true;
      api('POST', '/api/cancel', { confirm: true }).then(function (r) {
        $('rCancel').disabled = false;
        if (!r.ok) { banner(r.error || 'Abbrechen nicht moeglich'); }
        schedule(300);
      }).catch(function () { $('rCancel').disabled = false; banner('PC nicht erreichbar'); });
    });
  }
  function unpair() {
    ask('Entkoppeln?', 'Dieses Handy entkoppeln? Danach ist wieder ein Code vom PC noetig.', 'Ja, entkoppeln').then(function (ok) {
      if (!ok) { return; }
      api('POST', '/api/unpair', {}).then(function () { needPair(''); }).catch(function () { needPair(''); });
    });
  }

  // --- Ausgabe filtern (blendet nicht passende Zeilen aus)
  function fitLine(d, q) { var hit = !q || (d.textContent || '').toLowerCase().indexOf(q) >= 0; d.classList.toggle('f', !hit); }
  function applyFind() {
    var q = ($('rFind').value || '').trim().toLowerCase();
    Array.prototype.forEach.call($('rCon').childNodes, function (d) { fitLine(d, q); });
    if (q) { var first = Array.prototype.filter.call($('rCon').childNodes, function (d) { return !d.classList.contains('f'); })[0]; if (first) { first.scrollIntoView({ block: 'nearest' }); } }
  }

  // --- Ausgabe kopieren (Zwischenablage; ohne sichere Verbindung ueber ein verstecktes Textfeld)
  function copyOut() {
    var txt = Array.prototype.filter.call($('rCon').childNodes, function (d) { return !d.classList.contains('f'); }).map(function (d) { return d.textContent; }).join('\n');
    var ok = function () { var b = $('rCopy'); b.classList.add('done'); setTimeout(function () { b.classList.remove('done'); }, 1200); };
    var old = function () {
      var ta = el('textarea'); ta.value = txt; ta.setAttribute('readonly', ''); ta.style.position = 'fixed'; ta.style.opacity = '0';
      document.body.appendChild(ta); ta.select();
      try { if (document.execCommand('copy')) { ok(); } else { banner('Kopieren nicht moeglich'); } } catch (e) { banner('Kopieren nicht moeglich'); }
      document.body.removeChild(ta);
    };
    if (navigator.clipboard && window.isSecureContext) { navigator.clipboard.writeText(txt).then(ok, old); } else { old(); }
  }

  // --- Zertifikat / App
  function certState(ok) {
    S.secure = ok;
    var p = $('certState');
    p.textContent = ok ? 'vertrauenswuerdig' : 'noch nicht installiert';
    p.className = 'pill ' + (ok ? 'ok' : 'warn');
    $('mCert').textContent = ok ? 'verschluesselt, Zertifikat vertraut' : 'verschluesselt, Zertifikat nicht installiert';
  }
  function initSw() {
    if (!('serviceWorker' in navigator) || !window.isSecureContext) { certState(false); return; }
    navigator.serviceWorker.register('/sw.js', { scope: '/' }).then(function () { certState(true); }).catch(function () { certState(false); });
  }

  document.addEventListener('DOMContentLoaded', function () {
    $('pName').value = guessName();
    var m = /[#&]c=(\d{6})/.exec(location.hash || '');
    if (m) { $('pCode').value = m[1]; try { history.replaceState(null, '', location.pathname); } catch (e) { } }
    $('pBtn').addEventListener('click', pair);
    $('pCode').addEventListener('keydown', function (e) { if (e.key === 'Enter') { pair(); } });
    Array.prototype.forEach.call(document.querySelectorAll('.seg button'), function (b) {
      b.addEventListener('click', function () {
        setKind(b.getAttribute('data-k'));
        renderList(); memo();
      });
    });
    $('lFind').addEventListener('input', renderList);
    $('sBack').addEventListener('click', function () { setView('vList'); });
    Array.prototype.forEach.call(document.querySelectorAll('#iSeg button'), function (b) {
      b.addEventListener('click', function () { S.ia = b.getAttribute('data-a'); iShow(); memo(); });
    });
    $('iTen').addEventListener('change', function () { S.iten = $('iTen').value; S.igSel = null; iShow(); memo(); });
    $('iFind').addEventListener('input', iRender);
    $('iReload').addEventListener('click', function () { iLoad(true); });
    $('oBack').addEventListener('click', function () { setView('vIntune'); });
    $('oReload').addEventListener('click', function () { oLoad(true); });
    $('oDevBtn').addEventListener('click', oDevices);
    $('oDevFind').addEventListener('input', dRender);
    $('oKind').addEventListener('change', oForm);
    $('oSch').addEventListener('change', oForm);
    $('oGrpFind').addEventListener('input', gRender);
    $('oGrpFind').addEventListener('focus', function () { if (!S.igroups[S.iten]) { gLoad(); } });
    $('oGo').addEventListener('click', oGo);
    $('sAll').addEventListener('click', function () { (S.cat.tenants || []).forEach(function (t) { S.sel[t.key] = true; }); Array.prototype.forEach.call($('sTen').childNodes, function (c) { c.classList.add('on'); c.setAttribute('aria-pressed', 'true'); }); });
    $('sNone').addEventListener('click', function () { S.sel = {}; Array.prototype.forEach.call($('sTen').childNodes, function (c) { c.classList.remove('on'); c.setAttribute('aria-pressed', 'false'); }); });
    $('sGo').addEventListener('click', function () { S.fromAgain = false; prepare(false); });
    $('rAgain').addEventListener('click', again);
    $('cBack').addEventListener('click', function () { S.prep = null; setView(S.fromAgain ? 'vRun' : (S.backTo || 'vStart')); });
    $('cGo').addEventListener('click', run);
    $('cCode').addEventListener('input', checkGo);
    $('cPin').addEventListener('input', checkGo);
    $('rCancel').addEventListener('click', cancelRun);
    $('rFollow').addEventListener('change', function () { S.follow = $('rFollow').checked; });
    $('rCopy').addEventListener('click', copyOut);
    $('rFind').addEventListener('input', applyFind);
    $('rClear').addEventListener('click', function () { clear($('rCon')); show('rLost', false); });
    $('mUnpair').addEventListener('click', unpair);
    $('nBtn').addEventListener('click', pushToggle);
    Array.prototype.forEach.call(document.querySelectorAll('.tabs button'), function (b) { b.addEventListener('click', function () { setView(b.getAttribute('data-tab')); }); });
    document.addEventListener('visibilitychange', function () { if (!document.hidden) { schedule(50); } else { clearTimeout(S.timer); } });
    initSw();
    if (S.token) {
      var n = recall() || {}, v = n.v || 'vList';
      if (n.k === 'snippet' || n.k === 'ext' || n.k === 'teams') { setKind(n.k); }
      if (n.ia === 'app' || n.ia === 'rem') { S.ia = n.ia; } if (n.it) { S.iten = n.it; }
      if (v === 'vIObj') { if (n.io) { S.iobjId = n.io; } else { v = 'vIntune'; } }
      if (v === 'vStart') { S.restoreItem = n.i || null; v = 'vList'; }
      if (['vList', 'vRun', 'vMore', 'vIntune', 'vIObj'].indexOf(v) < 0) { v = 'vList'; }
      setView(v); poll();
    } else { setView('vPair'); }
  });
})();
'@

$script:HURemoteSw = @'
'use strict';
var CACHE = 'humt-{{VERSION}}';
var SHELL = ['/', '/app.js', '/app.css', '/manifest.webmanifest', '/icon-192.png', '/icon-512.png'];
self.addEventListener('install', function (e) {
  e.waitUntil(caches.open(CACHE).then(function (c) { return c.addAll(SHELL); }).then(function () { return self.skipWaiting(); }));
});
self.addEventListener('activate', function (e) {
  e.waitUntil(caches.keys().then(function (ks) {
    return Promise.all(ks.filter(function (k) { return k !== CACHE; }).map(function (k) { return caches.delete(k); }));
  }).then(function () { return self.clients.claim(); }));
});
function kvGet(k) {
  return new Promise(function (res) {
    try {
      var o = indexedDB.open('humt', 1);
      o.onupgradeneeded = function () { o.result.createObjectStore('kv'); };
      o.onerror = function () { res(''); };
      o.onsuccess = function () {
        var db = o.result, r;
        try { r = db.transaction('kv', 'readonly').objectStore('kv').get(k); } catch (x) { db.close(); res(''); return; }
        r.onsuccess = function () { db.close(); res(r.result || ''); };
        r.onerror = function () { db.close(); res(''); };
      };
    } catch (x) { res(''); }
  });
}
// Push kommt ohne Inhalt; das Ergebnis holt der Service Worker beim PC (Heimnetz/VPN), sonst allgemeine Meldung
self.addEventListener('push', function (e) {
  var pc = '';
  var shown = Promise.all([kvGet('tok'), kvGet('pc')]).then(function (v) {
    pc = v[1] || '';
    if (!v[0]) { throw new Error('kein Token'); }
    var ctl = ('AbortController' in self) ? new AbortController() : null;
    var t = setTimeout(function () { if (ctl) { ctl.abort(); } }, 6000);
    return fetch('/api/state?since=2147483647', { headers: { Authorization: 'Bearer ' + v[0] }, cache: 'no-store', credentials: 'omit', signal: ctl ? ctl.signal : undefined })
      .then(function (r) { return r.json(); }).then(function (j) { clearTimeout(t); return j; }, function (x) { clearTimeout(t); throw x; });
  }).then(function (j) {
    var job = (j && j.job) || {};
    var body = job.running ? (String(job.title || 'Lauf') + ' laeuft') : (String(job.title || 'Lauf') + ' - ' + String(job.result || 'fertig') + (job.tenants && job.tenants.length ? ' (' + job.tenants.join(', ') + ')' : ''));
    return self.registration.showNotification('HU-MultiTenant ' + String((j && j.pc) || pc), { body: body, icon: '/icon-192.png', tag: 'humt-job', renotify: true });
  }).catch(function () {
    return self.registration.showNotification('HU-MultiTenant ' + pc, { body: 'Lauf am PC beendet - Ergebnis in der App (Heimnetz oder VPN)', icon: '/icon-192.png', tag: 'humt-job', renotify: true });
  });
  e.waitUntil(shown);
});
self.addEventListener('notificationclick', function (e) {
  e.notification.close();
  e.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(function (cs) {
    for (var i = 0; i < cs.length; i++) { if ('focus' in cs[i]) { return cs[i].focus(); } }
    return self.clients.openWindow('/');
  }));
});
self.addEventListener('fetch', function (e) {
  var u = new URL(e.request.url);
  if (u.origin !== location.origin || u.pathname.indexOf('/api/') === 0 || u.pathname === '/ca.cer' || e.request.method !== 'GET') { return; }
  e.respondWith(fetch(e.request).then(function (r) {
    if (r && r.ok && SHELL.indexOf(u.pathname) >= 0) { var cp = r.clone(); caches.open(CACHE).then(function (c) { c.put(e.request, cp); }); }
    return r;
  }).catch(function () { return caches.match(e.request).then(function (m) { return m || caches.match('/'); }); }));
});
'@

# Alle Dateien der Webseite. Icons: PNG-Bytes (192/512), Ca: CA-Zertifikat (DER) oder leer
function Get-HURemoteWebFiles {
    param([string]$Version = '', [string]$Pc = '', [byte[]]$Icon192 = $null, [byte[]]$Icon512 = $null, [byte[]]$Ca = $null)
    $u8 = New-Object System.Text.UTF8Encoding $false
    $man = [ordered]@{
        name = "HU-MultiTenant $Pc".Trim(); short_name = 'HU-MultiTenant'; description = 'HU-MultiTenant Fernbedienung'; id = '/'; start_url = '/'; scope = '/'
        display = 'standalone'; background_color = '#1e1e2e'; theme_color = '#1e1e2e'; lang = 'de'
        icons = @(
            [ordered]@{ src = '/icon-192.png'; sizes = '192x192'; type = 'image/png'; purpose = 'any' }
            [ordered]@{ src = '/icon-512.png'; sizes = '512x512'; type = 'image/png'; purpose = 'any' }
            [ordered]@{ src = '/icon-512.png'; sizes = '512x512'; type = 'image/png'; purpose = 'maskable' }
        )
    }
    # Cache-Name mit Inhalts-Pruefsumme: geaenderte Seite/Skripte werden auch ohne neue Versionsnummer frisch geladen
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $cv = ([BitConverter]::ToString($sha.ComputeHash($u8.GetBytes($script:HURemoteHtml + $script:HURemoteCss + $script:HURemoteJs))) -replace '-', '').Substring(0, 10) } finally { $sha.Dispose() }
    $Version = "$($Version -replace '[^0-9A-Za-z.\-]', '')-$cv"
    $f = @{
        '/index.html'           = @{ Type = 'text/html; charset=utf-8'; Bytes = $u8.GetBytes($script:HURemoteHtml) }
        '/app.css'              = @{ Type = 'text/css; charset=utf-8'; Bytes = $u8.GetBytes($script:HURemoteCss) }
        '/app.js'               = @{ Type = 'application/javascript; charset=utf-8'; Bytes = $u8.GetBytes($script:HURemoteJs) }
        '/sw.js'                = @{ Type = 'application/javascript; charset=utf-8'; Bytes = $u8.GetBytes(($script:HURemoteSw -replace '\{\{VERSION\}\}', ($Version -replace '[^0-9A-Za-z.\-]', ''))); NoStore = $true }
        '/manifest.webmanifest' = @{ Type = 'application/manifest+json; charset=utf-8'; Bytes = $u8.GetBytes((ConvertTo-Json -InputObject $man -Depth 4)) }
    }
    if ($Icon192) { $f['/icon-192.png'] = @{ Type = 'image/png'; Bytes = $Icon192 } }
    if ($Icon512) { $f['/icon-512.png'] = @{ Type = 'image/png'; Bytes = $Icon512 } }
    if ($Ca) { $f['/ca.cer'] = @{ Type = 'application/x-x509-ca-cert'; Bytes = $Ca; NoStore = $true; Disposition = 'attachment; filename="HU-Fernbedienung-CA.cer"' } }
    return $f
}
