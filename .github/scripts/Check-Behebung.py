#!/usr/bin/env python3
"""Prueft Docs/Behebung.json gegen Microsoft Learn (laeuft monatlich in GitHub Actions, nur lesend).

Je Regel:
  - jeder Learn-Link muss erreichbar sein (HTTP 200)
  - geaendert: Learn-Seite seit "checked" aktualisiert (meta updated_at, sonst ms.date)
  - Pfad: jeder Menuename aus "path" (Teile zwischen " > ", ohne Portalname) muss in mindestens einer Learn-Seite der Regel vorkommen
  - alt: "checked" aelter als 180 Tage
Ausgabe: Markdown-Bericht (stdout bzw. Datei aus Argument 1); Exit 0 = alles gut, 1 = etwas zu pruefen, 2 = Datei kaputt.
"""
import datetime, html, json, re, sys, urllib.request

PORTALS = ("Entra admin center", "Intune admin center", "Microsoft Defender portal", "Microsoft 365 admin center", "Teams admin center", "Microsoft Purview portal")
UA = {"User-Agent": "HU-MultiTenant-Behebung-Check"}

def fetch(url):
    req = urllib.request.Request(url.split("#")[0], headers=UA)
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.status, r.read().decode("utf-8", "replace")

def page_date(raw):
    for name in ("updated_at", "ms.date"):
        m = re.search(r'<meta name="%s" content="(\d{4}-\d{2}-\d{2})' % re.escape(name), raw)
        if m:
            return m.group(1)
        m = re.search(r'<meta name="%s" content="(\d{2})/(\d{2})/(\d{4})' % re.escape(name), raw)
        if m:
            return "%s-%s-%s" % (m.group(3), m.group(1), m.group(2))
    return ""

def page_text(raw):
    t = re.sub(r"(?s)<(script|style)[^>]*>.*?</\1>", " ", raw)
    t = re.sub(r"<[^>]+>", " ", t)
    return re.sub(r"\s+", " ", html.unescape(t)).lower()

def path_terms(path):
    out = []
    for part in [p.strip() for p in path.split(">")]:
        if not part or part in PORTALS:
            continue
        part = re.sub(r"\(.*?\)", "", part)                 # Klammern sind Erlaeuterungen
        for piece in re.split(r",", part):
            piece = piece.strip().strip('"').strip()
            piece = re.sub(r'^(Platform|Profile)\s+', "", piece).strip('"').strip()
            if piece and len(piece) > 2:
                out.append(piece)
    return out

def main():
    try:
        data = json.load(open("Docs/Behebung.json", encoding="utf-8"))
        rules = data["rules"]
    except Exception as e:
        print("Docs/Behebung.json nicht lesbar: %s" % e)
        return 2
    today = datetime.date.today()
    findings = []
    cache = {}
    for rid in sorted(rules):
        e = rules[rid]
        checked = e.get("checked", "")
        texts = []
        for l in e.get("learn", []):
            u = l.get("url", "")
            if u not in cache:
                try:
                    cache[u] = fetch(u)
                except Exception as ex:
                    cache[u] = (0, str(ex))
            st, raw = cache[u]
            if st != 200:
                findings.append((rid, "Link nicht erreichbar (%s): %s" % (st or raw[:80], u)))
                continue
            texts.append(page_text(raw))
            d = page_date(raw)
            if d and checked and d > checked:
                findings.append((rid, "Learn-Seite geaendert am %s (geprueft %s): %s" % (d, checked, u)))
        if texts:
            for term in path_terms(e.get("path", "")):
                if not any(term.lower() in t for t in texts):
                    findings.append((rid, "Menuename nicht im Learn-Artikel gefunden: \"%s\"" % term))
        try:
            if (today - datetime.date.fromisoformat(checked)).days > 180:
                findings.append((rid, "zuletzt geprueft %s (aelter als 180 Tage)" % checked))
        except Exception:
            findings.append((rid, "kein gueltiges Pruefdatum"))
    lines = ["Automatische Pruefung von `Docs/Behebung.json` gegen Microsoft Learn (%s)." % today.isoformat(), ""]
    if findings:
        lines.append("Bitte diese Anleitungen pruefen, danach `checked` auf das neue Datum setzen:")
        lines.append("")
        lines += ["- **%s**: %s" % f for f in findings]
    else:
        lines.append("Alles in Ordnung - %d Anleitungen, alle Links erreichbar." % len(rules))
    report = "\n".join(lines)
    if len(sys.argv) > 1:
        open(sys.argv[1], "w", encoding="utf-8").write(report)
    print(report)
    return 1 if findings else 0

if __name__ == "__main__":
    sys.exit(main())
