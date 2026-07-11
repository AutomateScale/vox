#!/usr/bin/env python3
"""Vox memory — the alien's local, file-based brain, wiki edition.

Storage (~/vox/memory/, local only, nothing leaves the machine):
  journal-YYYY-MM.jsonl   human-readable log, one JSON line per memory
  vox-memory.db           SQLite FTS5 index + entity link graph

Every memory is analyzed on ingest: names, brands, and distinctive terms
become tags; tags that co-occur become links. The result is a wiki of
everything you've ever said, woven automatically.

  mem.py add --text "..." [--app Mail] [--mode dictate]
  mem.py search "query" [-n 5]
  mem.py recent [-n 10]
  mem.py entities [-n 30]         the wiki index (top entities)
  mem.py topic "Entity" [-n 10]   every memory about an entity
  mem.py related "Entity"         what links to it (co-occurrence graph)
  mem.py wiki "Entity"            topic + related, one call
  mem.py weave                    build the browsable HTML wiki + print path
  mem.py ingest <file-or-folder>  absorb .txt/.md documents
  mem.py retag                    rebuild tags/links for all memories
  mem.py stats
  mem.py export                   -> ~/Desktop/vox-brain-<date>.tar.gz
  mem.py import <tarball>         MERGE another alien: memories + learned
                                  vocabulary fuse; links re-weave
"""
import argparse, glob, html, json, os, re, sqlite3, sys, tarfile, time

MEM = os.path.expanduser("~/vox/memory")
DB = os.path.join(MEM, "vox-memory.db")

STOP = set("""The This That Then There These Those They Them Their I You He She
It We And But Also Just Like What When Where Which While With Without From For
Yeah Okay Alright Yes No Not Now Here Once If So My Your His Her Our Its A An
Monday Tuesday Wednesday Thursday Friday Saturday Sunday Today Tomorrow
January February March April May June July August September October November
December Isn't It's I'll I'm I've Don't Doesn't Didn't Can't Won't Wouldn't
Couldn't Shouldn't That's He's She's We're We'll They're You're You'll What's
Let's There's Here's Is Are Was Were Be Been Being Do Does Did Can Will Would
Should Could Get Got Go Going Gonna Make Made Let Say Said See Saw Know Knew
Think Thought Want Wanted Need Needed Very Really Maybe Perhaps Please Thanks
Thank Sorry Hello Hey""".split())
STOP |= {w.lower().capitalize() for w in STOP}


def extract_entities(text):
    """Names, brands, distinctive terms — deterministic, no LLM."""
    found = {}
    # multi-word proper names: "Dr Kornreich", "Jules Bordet"
    for m in re.finditer(r"\b([A-Z][\w'&-]+(?:\s+[A-Z][\w'&-]+)+)\b", text):
        e = m.group(1)
        if not any(w in STOP for w in e.split()):
            found[e.lower()] = e
    # CamelCase / branded tokens: AntiAlienate, GoHighLevel, n8n
    for m in re.finditer(r"\b([A-Za-z]+[a-z][A-Z][\w-]*|[a-z]\d[a-z\d]*)\b", text):
        found[m.group(1).lower()] = m.group(1)
    # single capitalized words not at sentence start
    for m in re.finditer(r"(?<![.!?]\s)(?<!^)\b([A-Z][a-z][\w'-]{2,})\b", text):
        e = m.group(1)
        if e not in STOP and e.lower() not in found:
            found[e.lower()] = e
    return found  # {key: display form}


def con():
    os.makedirs(MEM, exist_ok=True)
    c = sqlite3.connect(DB)
    v = c.execute("PRAGMA user_version").fetchone()[0]
    if v < 2:
        c.execute("CREATE VIRTUAL TABLE IF NOT EXISTS mem_v2 "
                  "USING fts5(text, app, mode, ts, tags)")
        c.execute("CREATE TABLE IF NOT EXISTS entities "
                  "(key TEXT PRIMARY KEY, display TEXT, n INTEGER, last_ts INTEGER)")
        try:  # migrate v1 rows if the old table exists
            for row in c.execute("SELECT text, app, mode, ts FROM mem"):
                tags = " ".join(extract_entities(row[0]).keys())
                c.execute("INSERT INTO mem_v2 VALUES (?,?,?,?,?)", (*row, tags))
            c.execute("DROP TABLE mem")
        except sqlite3.OperationalError:
            pass
        c.execute("PRAGMA user_version = 2")
        c.commit()
    return c


def journal_path(t=None):
    return os.path.join(MEM, time.strftime("journal-%Y-%m.jsonl", time.localtime(t)))


def bump_entities(c, ents, ts):
    for key, disp in ents.items():
        c.execute("INSERT INTO entities VALUES (?,?,1,?) ON CONFLICT(key) DO "
                  "UPDATE SET n = n + 1, last_ts = ?, display = ?",
                  (key, disp, int(ts), int(ts), disp))


def add(text, app="", mode="dictate", ts=None, journal=True):
    text = (text or "").strip()
    if not text:
        return
    ts = ts or time.time()
    c = con()
    ents = extract_entities(text)
    c.execute("INSERT INTO mem_v2 VALUES (?,?,?,?,?)",
              (text, app, mode, str(int(ts)), " ".join(ents.keys())))
    bump_entities(c, ents, ts)
    c.commit()
    if journal:
        with open(journal_path(ts), "a", encoding="utf-8") as f:
            f.write(json.dumps({"ts": int(ts), "app": app, "mode": mode,
                                "text": text}, ensure_ascii=False) + "\n")


def rows_out(rows):
    for text, app, mode, ts in rows:
        print(json.dumps({"ts": int(ts or 0), "app": app, "mode": mode,
                          "text": text}, ensure_ascii=False))


def q_words(q):
    return [w for w in re.sub(r"[^\w\s'-]", " ", q).split() if len(w) > 1]


def search(q, n=5):
    c, words = con(), q_words(q)
    if not words:
        return
    try:
        rows = c.execute("SELECT text, app, mode, ts FROM mem_v2 WHERE mem_v2 "
                         "MATCH ? ORDER BY rank LIMIT ?",
                         (" OR ".join(words), n)).fetchall()
    except sqlite3.OperationalError:
        rows = c.execute("SELECT text, app, mode, ts FROM mem_v2 WHERE text "
                         "LIKE ? ORDER BY ts DESC LIMIT ?",
                         (f"%{words[0]}%", n)).fetchall()
    rows_out(rows)


def recent(n=10):
    rows_out(con().execute("SELECT text, app, mode, ts FROM mem_v2 "
                           "ORDER BY CAST(ts AS INTEGER) DESC LIMIT ?",
                           (n,)).fetchall())


def entities_cmd(n=30):
    for key, disp, cnt, last in con().execute(
            "SELECT key, display, n, last_ts FROM entities "
            "ORDER BY n DESC, last_ts DESC LIMIT ?", (n,)):
        print(json.dumps({"entity": disp, "key": key, "mentions": cnt,
                          "last": last}))


def topic(entity, n=10):
    key = entity.lower().strip()
    c = con()
    rows = c.execute(
        "SELECT text, app, mode, ts FROM mem_v2 WHERE tags MATCH ? "
        "ORDER BY CAST(ts AS INTEGER) DESC LIMIT ?",
        ('"' + key.replace('"', "") + '"', n)).fetchall()
    if not rows and q_words(entity):     # lowercase topic: full-text fallback
        rows = c.execute(
            "SELECT text, app, mode, ts FROM mem_v2 WHERE mem_v2 MATCH ? "
            "ORDER BY rank LIMIT ?",
            (" AND ".join(q_words(entity)), n)).fetchall()
    rows_out(rows)


def related(entity, n=12):
    key = entity.lower().strip()
    co = {}
    c = con()
    for (tags,) in c.execute("SELECT tags FROM mem_v2 WHERE tags MATCH ?",
                             ('"' + key.replace('"', "") + '"',)):
        for t in tags.split():
            if t != key:
                co[t] = co.get(t, 0) + 1
    ranked = sorted(co.items(), key=lambda kv: -kv[1])[:n]
    disp = dict(c.execute("SELECT key, display FROM entities"))
    for k, cnt in ranked:
        print(json.dumps({"entity": disp.get(k, k), "key": k, "shared": cnt}))


def wiki(entity):
    print("## Mentions")
    topic(entity, 8)
    print("## Linked")
    related(entity)


def slug(k):
    return re.sub(r"[^\w-]", "-", k)


def weave():
    """Build a static, browsable HTML wiki of the whole brain."""
    c = con()
    out = os.path.join(MEM, "wiki")
    os.makedirs(out, exist_ok=True)
    ents = c.execute("SELECT key, display, n, last_ts FROM entities "
                     "ORDER BY n DESC").fetchall()
    style = ("<style>body{font-family:-apple-system;max-width:760px;margin:40px auto;"
             "background:#0b0e14;color:#dde3ee;padding:0 20px}a{color:#7ee0c0}"
             "h1{color:#7ee0c0}.m{border-left:3px solid #34d399;padding:8px 14px;"
             "margin:10px 0;background:#11151f;border-radius:6px}.meta{color:#8a93a6;"
             "font-size:12px}.tag{display:inline-block;background:#1a2030;padding:3px 10px;"
             "border-radius:12px;margin:3px;font-size:13px}</style>")
    idx = [style, "<h1>👽 Vox brain</h1><p class=meta>%d entities · woven %s</p>"
           % (len(ents), time.strftime("%Y-%m-%d %H:%M"))]
    for key, disp, cnt, _ in ents:
        idx.append('<span class=tag><a href="e-%s.html">%s</a> ·%d</span>'
                   % (slug(key), html.escape(disp), cnt))
        page = [style, '<p><a href="index.html">← brain</a></p><h1>%s</h1>'
                % html.escape(disp)]
        co = {}
        rows = c.execute("SELECT text, app, ts, tags FROM mem_v2 WHERE tags "
                         "MATCH ? ORDER BY CAST(ts AS INTEGER) DESC LIMIT 50",
                         ('"' + key + '"',)).fetchall()
        page.append("<h3>Linked</h3>")
        for text, app, ts, tags in rows:
            for t in tags.split():
                if t != key:
                    co[t] = co.get(t, 0) + 1
        disp_map = dict(c.execute("SELECT key, display FROM entities"))
        for k2, shared in sorted(co.items(), key=lambda kv: -kv[1])[:15]:
            page.append('<span class=tag><a href="e-%s.html">%s</a> ·%d</span>'
                        % (slug(k2), html.escape(disp_map.get(k2, k2)), shared))
        page.append("<h3>Mentions</h3>")
        for text, app, ts, tags in rows:
            when = time.strftime("%Y-%m-%d %H:%M", time.localtime(int(ts)))
            page.append('<div class=m>%s<div class=meta>%s · %s</div></div>'
                        % (html.escape(text), when, html.escape(app or "")))
        open(os.path.join(out, "e-%s.html" % slug(key)), "w").write("\n".join(page))
    open(os.path.join(out, "index.html"), "w").write("\n".join(idx))
    print(json.dumps({"wiki": os.path.join(out, "index.html"),
                      "entities": len(ents)}))


def ingest(path):
    paths = ([p for ext in ("*.txt", "*.md")
              for p in glob.glob(os.path.join(path, "**", ext), recursive=True)]
             if os.path.isdir(path) else [path])
    count = 0
    for p in paths:
        try:
            body = open(p, encoding="utf-8", errors="ignore").read()
        except OSError:
            continue
        for i in range(0, max(len(body), 1), 1000):
            ch = body[i:i + 1200]
            if ch.strip():
                add(ch, app=os.path.basename(p), mode="ingest")
                count += 1
    print(json.dumps({"ingested_chunks": count, "files": len(paths)}))


def retag():
    c = con()
    rows = c.execute("SELECT rowid, text, ts FROM mem_v2").fetchall()
    c.execute("DELETE FROM entities")
    for rowid, text, ts in rows:
        ents = extract_entities(text)
        c.execute("UPDATE mem_v2 SET tags = ? WHERE rowid = ?",
                  (" ".join(ents.keys()), rowid))
        bump_entities(c, ents, int(ts or 0))
    c.commit()
    print(json.dumps({"retagged": len(rows)}))


def stats():
    c = con()
    print(json.dumps({
        "entries": c.execute("SELECT count(*) FROM mem_v2").fetchone()[0],
        "entities": c.execute("SELECT count(*) FROM entities").fetchone()[0],
        "db_bytes": os.path.getsize(DB) if os.path.exists(DB) else 0,
        "journals": len(glob.glob(os.path.join(MEM, "journal-*.jsonl")))}))


def export():
    out = os.path.expanduser(time.strftime("~/Desktop/vox-brain-%Y%m%d-%H%M.tar.gz"))
    with tarfile.open(out, "w:gz") as t:
        if os.path.isdir(MEM):
            t.add(MEM, arcname="memory",
                  filter=lambda ti: None if "/wiki/" in ti.name else ti)
        for extra in ("~/vox/learned.json", "~/vox/local.lua"):
            p = os.path.expanduser(extra)
            if os.path.exists(p):
                t.add(p, arcname=os.path.basename(p))
    print(json.dumps({"exported": out}))


def merge_learned(path):
    """Fuse another alien's learned vocabulary into this one."""
    mine_p = os.path.expanduser("~/vox/learned.json")
    try:
        theirs = json.load(open(path))
    except (OSError, json.JSONDecodeError):
        return 0
    mine = {}
    if os.path.exists(mine_p):
        try:
            mine = json.load(open(mine_p))
        except json.JSONDecodeError:
            mine = {}
    for w, e in theirs.items():
        if w in mine:
            mine[w]["n"] = mine[w].get("n", 0) + e.get("n", 0)
            mine[w]["cap"] = mine[w].get("cap", 0) + e.get("cap", 0)
            if e.get("cap", 0) > 0:
                mine[w]["form"] = e.get("form", mine[w].get("form", w))
        else:
            mine[w] = e
    json.dump(mine, open(mine_p, "w"))
    return len(theirs)


def do_import(archive):
    tmp = os.path.join(MEM, "import-%d" % int(time.time()))
    os.makedirs(tmp, exist_ok=True)
    with tarfile.open(os.path.expanduser(archive)) as t:
        t.extractall(tmp, filter="data")
    merged = 0
    for j in glob.glob(os.path.join(tmp, "**", "journal-*.jsonl"), recursive=True):
        for line in open(j, encoding="utf-8", errors="ignore"):
            try:
                e = json.loads(line)
                add(e.get("text", ""), e.get("app", ""),
                    e.get("mode", "import"), e.get("ts"))
                merged += 1
            except (json.JSONDecodeError, KeyError):
                continue
    words = 0
    for lj in glob.glob(os.path.join(tmp, "**", "learned.json"), recursive=True):
        words += merge_learned(lj)
    print(json.dumps({"imported_entries": merged, "merged_vocab_words": words}))


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["add", "search", "recent", "entities",
                                    "topic", "related", "wiki", "weave",
                                    "ingest", "retag", "stats", "export",
                                    "import"])
    ap.add_argument("arg", nargs="?", default="")
    ap.add_argument("--text", default="")
    ap.add_argument("--app", default="")
    ap.add_argument("--mode", default="dictate")
    ap.add_argument("-n", type=int, default=0)
    a = ap.parse_args()
    n = a.n
    if a.cmd == "add":
        add(a.text or sys.stdin.read(), a.app, a.mode)
    elif a.cmd == "search":
        search(a.arg, n or 5)
    elif a.cmd == "recent":
        recent(n or 10)
    elif a.cmd == "entities":
        entities_cmd(n or 30)
    elif a.cmd == "topic":
        topic(a.arg, n or 10)
    elif a.cmd == "related":
        related(a.arg, n or 12)
    elif a.cmd == "wiki":
        wiki(a.arg)
    elif a.cmd == "weave":
        weave()
    elif a.cmd == "ingest":
        ingest(os.path.expanduser(a.arg))
    elif a.cmd == "retag":
        retag()
    elif a.cmd == "stats":
        stats()
    elif a.cmd == "export":
        export()
    elif a.cmd == "import":
        do_import(a.arg)
