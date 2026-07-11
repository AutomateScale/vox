#!/usr/bin/env python3
"""Vox memory — the alien's local, file-based brain.

Everything lives in ~/vox/memory/: a human-readable monthly journal
(journal-YYYY-MM.jsonl) plus a SQLite FTS5 index for instant recall.
Local only. Nothing leaves the machine.

  mem.py add --text "..." [--app Mail] [--mode dictate]
  mem.py search "query" [-n 5]        JSON lines, best match first
  mem.py recent [-n 10]
  mem.py ingest <file-or-folder>      pull .txt/.md documents into memory
  mem.py stats
  mem.py export                       -> ~/Desktop/vox-brain-<date>.tar.gz
  mem.py import <vox-brain-*.tar.gz>  merge another alien's brain into this one
"""
import argparse, glob, json, os, sqlite3, sys, tarfile, time

MEM = os.path.expanduser("~/vox/memory")
DB = os.path.join(MEM, "vox-memory.db")


def con():
    os.makedirs(MEM, exist_ok=True)
    c = sqlite3.connect(DB)
    c.execute("CREATE VIRTUAL TABLE IF NOT EXISTS mem USING fts5(text, app, mode, ts)")
    return c


def journal_path(t=None):
    return os.path.join(MEM, time.strftime("journal-%Y-%m.jsonl", time.localtime(t)))


def add(text, app="", mode="dictate", ts=None, index_only=False):
    text = (text or "").strip()
    if not text:
        return
    ts = ts or time.time()
    c = con()
    c.execute("INSERT INTO mem VALUES (?,?,?,?)", (text, app, mode, str(int(ts))))
    c.commit()
    if not index_only:
        with open(journal_path(ts), "a", encoding="utf-8") as f:
            f.write(json.dumps({"ts": int(ts), "app": app, "mode": mode,
                                "text": text}, ensure_ascii=False) + "\n")


def rows_out(rows):
    for text, app, mode, ts in rows:
        print(json.dumps({"ts": int(ts or 0), "app": app, "mode": mode,
                          "text": text}, ensure_ascii=False))


def search(q, n=5):
    c = con()
    words = [w for w in "".join(ch if ch.isalnum() else " " for ch in q).split() if len(w) > 1]
    if not words:
        return
    match = " OR ".join(words)
    try:
        rows = c.execute(
            "SELECT text, app, mode, ts FROM mem WHERE mem MATCH ? "
            "ORDER BY rank LIMIT ?", (match, n)).fetchall()
    except sqlite3.OperationalError:
        like = f"%{words[0]}%"
        rows = c.execute(
            "SELECT text, app, mode, ts FROM mem WHERE text LIKE ? "
            "ORDER BY ts DESC LIMIT ?", (like, n)).fetchall()
    rows_out(rows)


def recent(n=10):
    rows_out(con().execute(
        "SELECT text, app, mode, ts FROM mem ORDER BY CAST(ts AS INTEGER) DESC "
        "LIMIT ?", (n,)).fetchall())


def ingest(path):
    paths = []
    if os.path.isdir(path):
        for ext in ("*.txt", "*.md"):
            paths += glob.glob(os.path.join(path, "**", ext), recursive=True)
    else:
        paths = [path]
    count = 0
    for p in paths:
        try:
            body = open(p, encoding="utf-8", errors="ignore").read()
        except OSError:
            continue
        # chunk long documents so recall returns focused passages
        chunks = [body[i:i + 1200] for i in range(0, len(body), 1000)] or [body]
        for ch in chunks:
            if ch.strip():
                add(ch, app=os.path.basename(p), mode="ingest")
                count += 1
    print(json.dumps({"ingested_chunks": count, "files": len(paths)}))


def stats():
    c = con()
    total = c.execute("SELECT count(*) FROM mem").fetchone()[0]
    size = os.path.getsize(DB) if os.path.exists(DB) else 0
    print(json.dumps({"entries": total, "db_bytes": size,
                      "journals": len(glob.glob(os.path.join(MEM, "journal-*.jsonl")))}))


def export():
    out = os.path.expanduser(time.strftime("~/Desktop/vox-brain-%Y%m%d-%H%M.tar.gz"))
    with tarfile.open(out, "w:gz") as t:
        if os.path.isdir(MEM):
            t.add(MEM, arcname="memory")
        for extra in ("~/vox/learned.json", "~/vox/local.lua"):
            p = os.path.expanduser(extra)
            if os.path.exists(p):
                t.add(p, arcname=os.path.basename(p))
    print(json.dumps({"exported": out}))


def do_import(archive):
    tmp = os.path.join(MEM, "import-%d" % time.time())
    os.makedirs(tmp, exist_ok=True)
    with tarfile.open(os.path.expanduser(archive)) as t:
        t.extractall(tmp, filter="data")
    merged = 0
    for j in glob.glob(os.path.join(tmp, "**", "journal-*.jsonl"), recursive=True):
        for line in open(j, encoding="utf-8", errors="ignore"):
            try:
                e = json.loads(line)
                add(e.get("text", ""), e.get("app", ""), e.get("mode", "import"),
                    e.get("ts"))
                merged += 1
            except (json.JSONDecodeError, KeyError):
                continue
    print(json.dumps({"imported_entries": merged}))


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["add", "search", "recent", "ingest",
                                    "stats", "export", "import"])
    ap.add_argument("arg", nargs="?", default="")
    ap.add_argument("--text", default="")
    ap.add_argument("--app", default="")
    ap.add_argument("--mode", default="dictate")
    ap.add_argument("-n", type=int, default=5)
    a = ap.parse_args()
    if a.cmd == "add":
        add(a.text or sys.stdin.read(), a.app, a.mode)
    elif a.cmd == "search":
        search(a.arg, a.n)
    elif a.cmd == "recent":
        recent(a.n if a.n != 5 else 10)
    elif a.cmd == "ingest":
        ingest(os.path.expanduser(a.arg))
    elif a.cmd == "stats":
        stats()
    elif a.cmd == "export":
        export()
    elif a.cmd == "import":
        do_import(a.arg)
