#!/usr/bin/env python3
"""Vox memory — the alien's local, file-based brain. Wiki edition, v3.

Storage (~/vox/memory/, local only, nothing ever leaves the machine):
  journal-YYYY-MM.jsonl   human-readable log, one JSON line per memory
  vox-memory.db           SQLite (WAL): FTS5 text index + exact tag table +
                          entity registry + emerging-concept counters +
                          dedupe hashes

Every memory is analyzed on ingest: names and brands become entities
immediately; lowercase concepts (e.g. "proton therapy") earn entity status
organically after 3 mentions. Co-occurrence weaves the link graph. Imports
are idempotent — replaying the same brain twice adds nothing twice.

  mem.py add --text "..." [--app Mail] [--mode dictate]
  mem.py search "query" [-n 5]
  mem.py recent [-n 10]
  mem.py entities [-n 30]         the wiki index
  mem.py topic "Entity" [-n 10]   every memory about it (text fallback incl.)
  mem.py related "Entity"         exact co-occurrence links
  mem.py wiki "Entity"            topic + related
  mem.py weave                    build the browsable HTML wiki
  mem.py ingest <file-or-folder>  absorb .txt/.md documents
  mem.py retag                    rebuild tags/entities/concepts from scratch
  mem.py stats
  mem.py export                   -> ~/Desktop/vox-brain-<date>.tar.gz
  mem.py import <tarball>         merge another alien (memories + vocabulary)
"""
import argparse, glob, hashlib, html, json, os, re, shutil, sqlite3, sys
import tarfile, time

MEM = os.path.expanduser("~/vox/memory")
DB = os.path.join(MEM, "vox-memory.db")
SCHEMA = 3
CONCEPT_THRESHOLD = 3          # lowercase bigram becomes an entity at N uses
WEAVE_CAP = 400                # max wiki pages; keeps weave instant at scale

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

FUNC = set("""about after again along around because before being between both
could every first found going great little might never other right should
since some something still their there these thing things think those through
under until using where which while would know what like just want really
yeah gonna kind sort okay alright little basically actually maybe right
thing stuff time times back down over here there very much more some then
they them your mine ours been being have has had does most many when came
come comes said says tell told make makes made need needs want wants
that this with from into onto upon will shall then than them""".split())


# App/window chrome that OCR screen-grabs drag in as fake "entities" — these
# are UI furniture, never things you actually talk about. Kept out of the brain.
UICHROME = set("""Inbox Compose Sent Draft Drafts Starred Snoozed Spam Trash
Labels Label More Archive Reply Forward Search Settings Setting Menu Home Login
Logout Signin Signout Bookmarks Bookmark Chat Meet Mail Gmail Calendar Contacts
Contact Notifications Notification New Edit Delete Cancel Save Submit Send Next
Back Close Open View Share Download Upload Copy Paste Cut Undo Redo Today
Yesterday Tomorrow Online Offline Loading Untitled All None Yes Ok Okay Team
Teams Review Reviews Funnel Dashboard Profile Account Accounts Help Support
About Terms Privacy Toolbar Sidebar Header Footer Button Click Tap Scroll Page
Tab Tabs Window Panel Filter Sort Refresh Reload Update Continue Skip Done
Start Stop Active Inactive Unread Read Deleted Signin Signup Enabled Disabled
Purchases Social Updates Forums Promotions Important Compose Message Messages""".split())


def _entity_ok(e):
    """Reject OCR noise: multi-line blobs, chrome words, stray fragments."""
    if "\n" in e or "\t" in e:
        return False                       # multi-line = a scraped UI column
    e = e.strip()
    if len(e) < 2 or e.isdigit():
        return False
    words = e.split()
    if any(w in STOP or w in UICHROME for w in words):
        return False
    return True


def extract_entities(text):
    """Names, brands, distinctive terms — deterministic, no LLM."""
    found = {}
    # multiword Title Case — spaces/tabs only, so it never welds together
    # separate lines of a scraped menu ("Mail\nChat\nMeet") into one "entity"
    for m in re.finditer(r"\b([A-Z][\w'&-]+(?:[ \t]+[A-Z][\w'&-]+)+)\b", text):
        e = m.group(1)
        if _entity_ok(e):
            found[e.lower()] = e
    for m in re.finditer(r"\b([A-Za-z]+[a-z][A-Z][\w-]*|[a-z]\d[a-z\d]*)\b", text):
        e = m.group(1)
        if _entity_ok(e):
            found[e.lower()] = e
    for m in re.finditer(r"(?<![.!?]\s)(?<!^)\b([A-Z][a-z][\w'-]{2,})\b", text):
        e = m.group(1)
        if e.lower() not in found and _entity_ok(e):
            found[e.lower()] = e
    return found


def categorize(key, display):
    """Bucket an entity so the wiki can group it — structural signals only,
    deterministic, no LLM. (A dictionary check was tried and rejected: too many
    real names — Mark, Chad, Archon — are also common words, so it buried them.)
    name = Title-Case names/places/terms · brand = camelCase/alnum products ·
    acronym = CRM/API/SaaS · concept = emergent lowercase phrases · other."""
    d = display.strip()
    if key == d.lower() and d == d.lower():
        return "concept"                   # lowercase emergent phrase/bigram
    if " " not in d and len(d) >= 16 and re.search(r"[a-z]", d) \
            and re.search(r"[A-Z]", d):
        return "other"                     # long random id/hash, not a topic
    if re.fullmatch(r"[A-Z]{2,6}", d) or re.fullmatch(r"[A-Za-z]{0,3}[A-Z]{2,}", d):
        return "acronym"                   # CRM, API, GHL, SaaS
    if len(d) <= 24 and (re.search(r"[a-z][A-Z]", d)
                         or re.search(r"[A-Za-z][0-9]", d)):
        return "brand"                     # FreelanceKing, PrinterOn, n8n
    words = d.split()
    if words and all(re.fullmatch(r"[A-Z][a-z'’.\-]+", w) for w in words):
        return "name"                      # Title Case: names, places, terms
    return "other"


def extract_bigrams(text):
    """Candidate lowercase concepts: adjacent meaty words."""
    words = re.findall(r"[a-z][a-z'-]{3,}", text.lower())
    out = set()
    for a, b in zip(words, words[1:]):
        if a not in FUNC and b not in FUNC:
            out.add(a + " " + b)
    return out


def con():
    os.makedirs(MEM, exist_ok=True)
    c = sqlite3.connect(DB, timeout=5)
    c.execute("PRAGMA journal_mode=WAL")       # readers never block the writer
    c.execute("PRAGMA busy_timeout=3000")
    v = c.execute("PRAGMA user_version").fetchone()[0]
    if v < SCHEMA:
        c.execute("CREATE VIRTUAL TABLE IF NOT EXISTS mem_v3 "
                  "USING fts5(text, app, mode, ts)")
        c.execute("CREATE TABLE IF NOT EXISTS tags "
                  "(mem_rowid INTEGER, tag TEXT)")
        c.execute("CREATE INDEX IF NOT EXISTS tags_tag ON tags(tag)")
        c.execute("CREATE INDEX IF NOT EXISTS tags_row ON tags(mem_rowid)")
        c.execute("CREATE TABLE IF NOT EXISTS entities "
                  "(key TEXT PRIMARY KEY, display TEXT, n INTEGER, last_ts INTEGER)")
        c.execute("CREATE TABLE IF NOT EXISTS bigrams (key TEXT PRIMARY KEY, n INTEGER)")
        c.execute("CREATE TABLE IF NOT EXISTS hashes (h TEXT PRIMARY KEY)")
        for old in ("mem_v2", "mem"):          # migrate any older schema
            try:
                for text, app, mode, ts in c.execute(
                        f"SELECT text, app, mode, ts FROM {old}"):
                    _insert(c, text, app, mode, int(ts or 0))
                c.execute(f"DROP TABLE {old}")
            except sqlite3.OperationalError:
                pass
        c.execute("PRAGMA user_version = %d" % SCHEMA)
        c.commit()
    return c


def journal_path(t=None):
    return os.path.join(MEM, time.strftime("journal-%Y-%m.jsonl", time.localtime(t)))


def _hash(text, ts):
    return hashlib.sha1((str(int(ts)) + "\x00" + text).encode()).hexdigest()


def _tag_row(c, rowid, key, disp, ts, is_concept=False):
    c.execute("INSERT INTO tags VALUES (?,?)", (rowid, key))
    c.execute("INSERT INTO entities VALUES (?,?,1,?) ON CONFLICT(key) DO "
              "UPDATE SET n = n + 1, last_ts = ?, display = ?",
              (key, disp, int(ts), int(ts),
               disp if not is_concept else disp))


def _insert(c, text, app, mode, ts):
    """Core insert: dedupe, index, tag, grow concepts. Returns rowid or None."""
    h = _hash(text, ts)
    if c.execute("SELECT 1 FROM hashes WHERE h = ?", (h,)).fetchone():
        return None                            # idempotent: seen this memory
    c.execute("INSERT INTO hashes VALUES (?)", (h,))
    cur = c.execute("INSERT INTO mem_v3 VALUES (?,?,?,?)",
                    (text, app, mode, str(int(ts))))
    rowid = cur.lastrowid
    for key, disp in extract_entities(text).items():
        _tag_row(c, rowid, key, disp, ts)
    # lowercase concepts earn their wings through repetition
    known = {k for (k,) in c.execute("SELECT key FROM entities")}
    for bg in extract_bigrams(text):
        if bg in known:
            _tag_row(c, rowid, bg, bg, ts)
            continue
        c.execute("INSERT INTO bigrams VALUES (?,1) ON CONFLICT(key) DO "
                  "UPDATE SET n = n + 1", (bg,))
        n = c.execute("SELECT n FROM bigrams WHERE key = ?", (bg,)).fetchone()[0]
        if n >= CONCEPT_THRESHOLD:
            _tag_row(c, rowid, bg, bg, ts, is_concept=True)
            # retro-tag earlier mentions so the concept's history is complete
            try:
                for (rid,) in c.execute(
                        "SELECT rowid FROM mem_v3 WHERE mem_v3 MATCH ?",
                        ('"' + bg + '"',)):
                    if rid != rowid and not c.execute(
                            "SELECT 1 FROM tags WHERE mem_rowid=? AND tag=?",
                            (rid, bg)).fetchone():
                        c.execute("INSERT INTO tags VALUES (?,?)", (rid, bg))
            except sqlite3.OperationalError:
                pass
    return rowid


def clean_ocr(text):
    """Screen-OCR arrives as a vertical wall of UI furniture — menu items,
    unread counters, truncated edge labels ("Busine", "• Nationa", "68"),
    nav links. That is the word-salad that pollutes the brain AND misleads the
    smart-reply. Keep only lines that read like real content: a full sentence
    (3+ words ending in .?!) or a substantial phrase (5+ word-tokens), and
    mostly letters. Everything else is chrome. Empty result => nothing to keep."""
    good = []
    for ln in text.splitlines():
        s = ln.strip(" \t•·—-–*|>©=()×#").strip()
        if len(s) < 10:
            continue
        letters = sum(c.isalpha() for c in s)
        if letters < len(s) * 0.6:                 # mostly symbols/numbers/urls
            continue
        words = re.findall(r"[A-Za-z]{2,}", s)
        sentence = re.search(r"[.!?][\"')]?$", s) is not None
        if (sentence and len(words) >= 3) or len(words) >= 5:
            good.append(s)
    return " ".join(good).strip()


def add(text, app="", mode="dictate", ts=None, journal=True):
    text = (text or "").strip()
    if mode == "grab":                 # screen-absorb: strip UI salad first
        text = clean_ocr(text)
    if not text or len(text) < 2:
        return
    ts = ts or time.time()
    c = con()
    rowid = _insert(c, text, app, mode, ts)
    c.commit()
    if journal and rowid is not None:
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
        rows = c.execute("SELECT text, app, mode, ts FROM mem_v3 WHERE mem_v3 "
                         "MATCH ? ORDER BY rank LIMIT ?",
                         (" OR ".join(words), n)).fetchall()
    except sqlite3.OperationalError:
        rows = c.execute("SELECT text, app, mode, ts FROM mem_v3 WHERE text "
                         "LIKE ? ORDER BY ts DESC LIMIT ?",
                         (f"%{words[0]}%", n)).fetchall()
    rows_out(rows)


def recent(n=10):
    rows_out(con().execute("SELECT text, app, mode, ts FROM mem_v3 "
                           "ORDER BY CAST(ts AS INTEGER) DESC LIMIT ?",
                           (n,)).fetchall())


def entities_cmd(n=30, sort="mentions", cat=""):
    order = {"mentions": "n DESC, last_ts DESC",
             "recent":   "last_ts DESC, n DESC",
             "name":     "display COLLATE NOCASE ASC"}.get(sort,
             "n DESC, last_ts DESC")
    for key, disp, cnt, last in con().execute(
            "SELECT key, display, n, last_ts FROM entities "
            "ORDER BY " + order + " LIMIT ?", (n,)):
        c = categorize(key, disp)
        if cat and c != cat:
            continue
        print(json.dumps({"entity": disp, "key": key, "mentions": cnt,
                          "last": last, "category": c}))


def _topic_rows(c, entity, n):
    key = entity.lower().strip()
    rows = c.execute(
        "SELECT m.text, m.app, m.mode, m.ts FROM mem_v3 m "
        "JOIN tags t ON t.mem_rowid = m.rowid WHERE t.tag = ? "
        "ORDER BY CAST(m.ts AS INTEGER) DESC LIMIT ?", (key, n)).fetchall()
    if not rows and q_words(entity):
        try:
            rows = c.execute(
                "SELECT text, app, mode, ts FROM mem_v3 WHERE mem_v3 MATCH ? "
                "ORDER BY rank LIMIT ?",
                (" AND ".join(q_words(entity)), n)).fetchall()
        except sqlite3.OperationalError:
            rows = []
    return rows


def topic(entity, n=10):
    rows_out(_topic_rows(con(), entity, n))


def _related_rows(c, entity, n):
    key = entity.lower().strip()
    return c.execute(
        "SELECT e.display, t2.tag, COUNT(*) AS shared FROM tags t1 "
        "JOIN tags t2 ON t1.mem_rowid = t2.mem_rowid AND t2.tag != t1.tag "
        "JOIN entities e ON e.key = t2.tag "
        "WHERE t1.tag = ? GROUP BY t2.tag ORDER BY shared DESC LIMIT ?",
        (key, n)).fetchall()


def related(entity, n=12):
    for disp, key, shared in _related_rows(con(), entity, n):
        print(json.dumps({"entity": disp, "key": key, "shared": shared}))


def wiki(entity):
    print("## Mentions")
    topic(entity, 8)
    print("## Linked")
    related(entity)


def slug(k):
    return re.sub(r"[^\w-]", "-", k)


STYLE = ("<style>body{font-family:-apple-system,system-ui;max-width:820px;"
         "margin:40px auto;background:#0b0e14;color:#dde3ee;padding:0 20px}"
         "a{color:#7ee0c0;text-decoration:none}a:hover{text-decoration:underline}"
         "h1{color:#7ee0c0}h3{color:#9fb0c8;margin:26px 0 6px;font-size:13px;"
         "text-transform:uppercase;letter-spacing:.08em}"
         ".m{border-left:3px solid #34d399;padding:8px 14px;margin:10px 0;"
         "background:#11151f;border-radius:6px}.meta{color:#8a93a6;font-size:12px}"
         ".tag{display:inline-block;background:#1a2030;padding:4px 11px;"
         "border-radius:12px;margin:3px;font-size:13px}.tag .c{color:#8a93a6;"
         "font-size:11px;margin-left:2px}"
         "#bar{position:sticky;top:0;background:#0b0e14;padding:12px 0;"
         "border-bottom:1px solid #1a2030;margin-bottom:8px}"
         "#q{background:#11151f;border:1px solid #26304a;color:#dde3ee;"
         "border-radius:8px;padding:8px 12px;width:60%;font-size:14px}"
         ".sb{background:#1a2030;border:0;color:#9fb0c8;border-radius:8px;"
         "padding:8px 12px;margin-left:6px;font-size:13px;cursor:pointer}"
         ".sb.on{background:#34d399;color:#08130d}"
         "section.empty{display:none}h3.empty{display:none}</style>")

# category -> heading (also fixes section order in the wiki)
CATS = [("name", "🧑 Names & Terms"), ("brand", "🏷️ Brands & Products"),
        ("concept", "💡 Concepts"), ("acronym", "🔤 Acronyms"),
        ("other", "🗂️ Other")]


def weave():
    c = con()
    out = os.path.join(MEM, "wiki")
    shutil.rmtree(out, ignore_errors=True)     # no stale pages, ever
    os.makedirs(out, exist_ok=True)
    ents = c.execute("SELECT key, display, n, last_ts FROM entities "
                     "ORDER BY n DESC LIMIT ?", (WEAVE_CAP,)).fetchall()
    total = c.execute("SELECT count(*) FROM entities").fetchone()[0]

    buckets = {cat: [] for cat, _ in CATS}
    for key, disp, cnt, last in ents:
        buckets.get(categorize(key, disp), buckets["other"]).append(
            (key, disp, cnt, last))

    idx = [STYLE,
           "<h1>👽 Vox brain</h1>",
           "<p class=meta>%d of %d entities · woven %s</p>"
           % (len(ents), total, time.strftime("%Y-%m-%d %H:%M")),
           '<div id=bar>',
           '<input id=q placeholder="filter entities…" '
           'oninput="flt()" autocomplete=off>',
           '<button class="sb on" id=s-mentions onclick="srt(\'mentions\')">'
           'most-mentioned</button>',
           '<button class="sb" id=s-name onclick="srt(\'name\')">A–Z</button>',
           '<button class="sb" id=s-recent onclick="srt(\'recent\')">recent'
           '</button></div>']

    for cat, heading in CATS:
        rows = buckets[cat]
        idx.append('<h3 data-sec="%s">%s <span class=meta>(%d)</span></h3>'
                   % (cat, heading, len(rows)))
        idx.append('<section data-sec="%s">' % cat)
        for key, disp, cnt, last in rows:
            idx.append('<span class=tag data-n="%d" data-t="%d" data-name="%s">'
                       '<a href="e-%s.html">%s</a>'
                       '<span class=c>·%d</span></span>'
                       % (cnt, int(last or 0), html.escape(disp.lower()),
                          slug(key), html.escape(disp), cnt))
        idx.append('</section>')

    idx.append("""<script>
function flt(){var q=document.getElementById('q').value.toLowerCase();
document.querySelectorAll('.tag').forEach(function(t){
t.style.display=t.dataset.name.indexOf(q)>-1?'':'none';});
document.querySelectorAll('section').forEach(function(s){
var vis=[].some.call(s.querySelectorAll('.tag'),function(t){
return t.style.display!=='none';});
s.classList.toggle('empty',!vis);
var h=document.querySelector('h3[data-sec="'+s.dataset.sec+'"]');
if(h)h.classList.toggle('empty',!vis);});}
function srt(k){['mentions','name','recent'].forEach(function(x){
document.getElementById('s-'+x).classList.toggle('on',x===k);});
document.querySelectorAll('section').forEach(function(s){
var t=[].slice.call(s.querySelectorAll('.tag'));
t.sort(function(a,b){
if(k==='name')return a.dataset.name<b.dataset.name?-1:1;
if(k==='recent')return b.dataset.t-a.dataset.t;
return b.dataset.n-a.dataset.n;});
t.forEach(function(x){s.appendChild(x);});});}
</script>""")

    for key, disp, cnt, _ in ents:
        page = [STYLE, '<p><a href="index.html">← brain</a></p><h1>%s</h1>'
                % html.escape(disp),
                '<p class=meta>%s · %d mention%s</p>'
                % (categorize(key, disp), cnt, "" if cnt == 1 else "s"),
                "<h3>Linked</h3>"]
        for d2, k2, shared in _related_rows(c, key, 15):
            page.append('<span class=tag><a href="e-%s.html">%s</a>'
                        '<span class=c>·%d</span></span>'
                        % (slug(k2), html.escape(d2), shared))
        page.append("<h3>Mentions</h3>")
        for text, app, mode, ts in _topic_rows(c, key, 50):
            when = time.strftime("%Y-%m-%d %H:%M", time.localtime(int(ts)))
            page.append('<div class=m>%s<div class=meta>%s · %s</div></div>'
                        % (html.escape(text), when, html.escape(app or "")))
        open(os.path.join(out, "e-%s.html" % slug(key)), "w").write("\n".join(page))
    open(os.path.join(out, "index.html"), "w").write("\n".join(idx))
    print(json.dumps({"wiki": os.path.join(out, "index.html"),
                      "entities": len(ents), "total_entities": total}))


def html_to_text(body):
    body = re.sub(r"(?is)<(script|style|nav|footer|head|header|aside|form|button)"
                  r"[^>]*>.*?</\1>", " ", body)
    body = re.sub(r"(?s)<[^>]+>", "\n", body)
    body = html.unescape(body)
    # drop chrome fragments: short unpunctuated lines are nav labels/buttons
    keep = []
    for ln in body.split("\n"):
        ln = re.sub(r"\s{2,}", " ", ln).strip()
        if ln and (len(ln.split()) > 4 or ln[-1:] in ".!?:"):
            keep.append(ln)
    return "\n".join(keep)


def ingest(path):
    paths = ([p for ext in ("*.txt", "*.md", "*.html")
              for p in glob.glob(os.path.join(path, "**", ext), recursive=True)]
             if os.path.isdir(path) else [path])
    count = 0
    for p in paths:
        try:
            body = open(p, encoding="utf-8", errors="ignore").read()
        except OSError:
            continue
        if p.endswith(".html"):
            body = html_to_text(body)
        for i in range(0, max(len(body), 1), 1000):
            ch = body[i:i + 1200]
            if ch.strip():
                add(ch, app=os.path.basename(p), mode="ingest")
                count += 1
    print(json.dumps({"ingested_chunks": count, "files": len(paths)}))


def forget(mode):
    """Remove every memory of a given mode (e.g. a bad ingest), then retag."""
    c = con()
    rows = [rid for (rid,) in c.execute(
        "SELECT rowid FROM mem_v3 WHERE mode = ?", (mode,))]
    for rid in rows:
        c.execute("DELETE FROM tags WHERE mem_rowid = ?", (rid,))
        c.execute("DELETE FROM mem_v3 WHERE rowid = ?", (rid,))
    c.commit()
    _retag(c)
    print(json.dumps({"forgot": len(rows), "mode": mode}))


def _retag(c):
    """Rebuild tags/entities/concepts from the current mem_v3 rows."""
    rows = c.execute("SELECT rowid, text, ts FROM mem_v3").fetchall()
    c.execute("DELETE FROM tags")
    c.execute("DELETE FROM entities")
    c.execute("DELETE FROM bigrams")
    # two passes: first grow bigram counts so concepts emerge, then tag
    for _, text, _ in rows:
        for bg in extract_bigrams(text):
            c.execute("INSERT INTO bigrams VALUES (?,1) ON CONFLICT(key) DO "
                      "UPDATE SET n = n + 1", (bg,))
    concepts = {k for (k, n) in c.execute("SELECT key, n FROM bigrams")
                if n >= CONCEPT_THRESHOLD}
    for rowid, text, ts in rows:
        for key, disp in extract_entities(text).items():
            _tag_row(c, rowid, key, disp, int(ts or 0))
        for bg in extract_bigrams(text):
            if bg in concepts:
                _tag_row(c, rowid, bg, bg, int(ts or 0))
    c.commit()
    return len(rows), len(concepts)


def retag():
    n, concepts = _retag(con())
    print(json.dumps({"retagged": n, "concepts": concepts}))


def prune():
    """Clean up screen-grab entries retroactively: strip the UI salad in place,
    keeping whatever real content each one had. Entries that were ALL salad
    (nothing survives cleaning) are deleted. Then rebuild the entity graph so
    the wiki reflects reality. New grabs are already cleaned on the way in."""
    c = con()
    removed, rewritten = 0, 0
    for rowid, text, mode in c.execute(
            "SELECT rowid, text, mode FROM mem_v3").fetchall():
        if mode not in ("grab", "api"):
            continue
        cleaned = clean_ocr(text)
        if len(cleaned) < 15:                      # pure salad — drop it
            c.execute("DELETE FROM mem_v3 WHERE rowid = ?", (rowid,))
            c.execute("DELETE FROM tags WHERE mem_rowid = ?", (rowid,))
            removed += 1
        elif cleaned != text:                      # had real content — keep clean
            c.execute("UPDATE mem_v3 SET text = ? WHERE rowid = ?",
                      (cleaned, rowid))
            rewritten += 1
    c.commit()
    _retag(c)
    kept = c.execute("SELECT count(*) FROM mem_v3").fetchone()[0]
    print(json.dumps({"salad_deleted": removed, "cleaned_in_place": rewritten,
                      "entries_kept": kept,
                      "entities": c.execute(
                          "SELECT count(*) FROM entities").fetchone()[0]}))


def stats():
    c = con()
    j = json.dumps({
        "entries": c.execute("SELECT count(*) FROM mem_v3").fetchone()[0],
        "entities": c.execute("SELECT count(*) FROM entities").fetchone()[0],
        "links": c.execute("SELECT count(*) FROM tags").fetchone()[0],
        "db_bytes": os.path.getsize(DB) if os.path.exists(DB) else 0,
        "journals": len(glob.glob(os.path.join(MEM, "journal-*.jsonl")))})
    print(j)


def export():
    c = con()
    manifest = {
        "vox_brain": 1, "schema": SCHEMA,
        "created": int(time.time()),
        "host": os.uname().nodename,
        "entries": c.execute("SELECT count(*) FROM mem_v3").fetchone()[0],
        "entities": c.execute("SELECT count(*) FROM entities").fetchone()[0],
    }
    mpath = os.path.join(MEM, "manifest.json")
    json.dump(manifest, open(mpath, "w"))
    out = os.path.expanduser(time.strftime("~/Desktop/vox-brain-%Y%m%d-%H%M.tar.gz"))

    def keep(ti):
        n = ti.name
        if "/wiki/" in n or "/import-" in n or n.endswith("-wal") or n.endswith("-shm"):
            return None
        return ti

    with tarfile.open(out, "w:gz") as t:
        if os.path.isdir(MEM):
            t.add(MEM, arcname="memory", filter=keep)
        for extra in ("~/vox/learned.json", "~/vox/local.lua",
                      "~/vox/identity.md"):
            p = os.path.expanduser(extra)
            if os.path.exists(p):
                t.add(p, arcname=os.path.basename(p))
    os.remove(mpath)
    manifest["exported"] = out
    print(json.dumps(manifest))


def merge_learned(path):
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
    try:
        with tarfile.open(os.path.expanduser(archive)) as t:
            try:
                t.extractall(tmp, filter="data")
            except TypeError:               # older Python: no filter kwarg
                t.extractall(tmp)
        manifest = {}
        for mp in glob.glob(os.path.join(tmp, "**", "manifest.json"), recursive=True):
            try:
                manifest = json.load(open(mp))
            except (OSError, json.JSONDecodeError):
                pass
        merged, skipped = 0, 0
        for j in glob.glob(os.path.join(tmp, "**", "journal-*.jsonl"),
                           recursive=True):
            c = con()
            for line in open(j, encoding="utf-8", errors="ignore"):
                try:
                    e = json.loads(line)
                    rid = _insert(c, e.get("text", "").strip(),
                                  e.get("app", ""), e.get("mode", "import"),
                                  e.get("ts") or time.time())
                    if rid is None:
                        skipped += 1
                    else:
                        merged += 1
                        with open(journal_path(e.get("ts")), "a",
                                  encoding="utf-8") as f:
                            f.write(json.dumps(e, ensure_ascii=False) + "\n")
                except (json.JSONDecodeError, KeyError, TypeError):
                    continue
            c.commit()
        words = 0
        for lj in glob.glob(os.path.join(tmp, "**", "learned.json"),
                            recursive=True):
            words += merge_learned(lj)
        print(json.dumps({"imported_entries": merged,
                          "duplicates_skipped": skipped,
                          "merged_vocab_words": words,
                          "source": manifest.get("host", "unknown")}))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)   # no residue, ever


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["add", "search", "recent", "entities",
                                    "topic", "related", "wiki", "weave",
                                    "ingest", "retag", "prune", "stats",
                                    "export", "import", "forget"])
    ap.add_argument("arg", nargs="?", default="")
    ap.add_argument("--text", default="")
    ap.add_argument("--app", default="")
    ap.add_argument("--mode", default="dictate")
    ap.add_argument("--sort", default="mentions",
                    choices=["mentions", "recent", "name"])
    ap.add_argument("--cat", default="")
    ap.add_argument("-n", type=int, default=0)
    a = ap.parse_args()
    n = a.n
    {"add": lambda: add(a.text or sys.stdin.read(), a.app, a.mode),
     "search": lambda: search(a.arg, n or 5),
     "recent": lambda: recent(n or 10),
     "entities": lambda: entities_cmd(n or 30, a.sort, a.cat),
     "topic": lambda: topic(a.arg, n or 10),
     "related": lambda: related(a.arg, n or 12),
     "wiki": lambda: wiki(a.arg),
     "weave": weave,
     "ingest": lambda: ingest(os.path.expanduser(a.arg)),
     "retag": retag,
     "prune": prune,
     "stats": stats,
     "export": export,
     "import": lambda: do_import(a.arg),
     "forget": lambda: forget(a.arg)}[a.cmd]()
