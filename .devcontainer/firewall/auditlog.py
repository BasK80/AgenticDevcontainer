#!/usr/bin/env python3
"""
Long-term audit-log writer for the firewall container.

Squid writes every proxied request (allowed and denied) to access.log in the
custom 'egress' format:

    %tl %>a %Ss/%03>Hs %rm %ru
    09/Jun/2026:12:34:56 +0200 172.20.0.2 TCP_DENIED/403 CONNECT evil.com:443

This daemon tails that file and appends every parsed line to a SQLite database
on the dedicated `auditlog` volume, giving a queryable long-term history that
survives container restarts. It:

  * remembers its position in access.log via a cursor file, so a restart never
    re-imports or skips lines (truncation/rotation is detected by size shrink);
  * prunes rows older than AUDIT_RETENTION_DAYS once per day (default 60);
  * uses only the Python standard library (sqlite3) — no extra dependencies.

The control container mounts the same volume read-only and serves queries +
CSV downloads from it; the `fw audit` CLI queries it locally. This process is
the single writer.
"""

import os
import sqlite3
import sys
import time
from datetime import datetime, timedelta, timezone

# ---------------------------------------------------------------------------
# Config (paths/retention overridable via env — used by the test harness too)
# ---------------------------------------------------------------------------
LOG_FILE   = os.environ.get("LOG_FILE",   "/var/log/squid/access.log")
DB_FILE    = os.environ.get("AUDIT_DB",   "/auditlog/audit.db")
CURSOR_FILE = os.environ.get("AUDIT_CURSOR", "/auditlog/audit.cursor")

try:
    RETENTION_DAYS = int(os.environ.get("AUDIT_RETENTION_DAYS", "60"))
except ValueError:
    RETENTION_DAYS = 60
if RETENTION_DAYS < 1:
    RETENTION_DAYS = 60

POLL_INTERVAL  = 1.0          # seconds between reads when no new data
BATCH_MAX      = 1000         # flush after this many parsed rows
PRUNE_INTERVAL = 24 * 3600    # prune once per day

# Squid local timestamp, e.g. "09/Jun/2026:12:34:56 +0200"
_TS_FMT = "%d/%b/%Y:%H:%M:%S %z"


# ---------------------------------------------------------------------------
# Parsing
# ---------------------------------------------------------------------------
def parse_line(raw):
    """
    Parse one Squid 'egress' log line into a row tuple, or None if it doesn't
    match. Returns:
        (ts_epoch, ts_text, client_ip, squid_status, http_code, method, url, host)
    """
    raw = raw.strip()
    if not raw:
        return None
    # %tl is "DD/Mon/YYYY:HH:MM:SS +ZZZZ" — two space-separated tokens — so we
    # split into exactly 6 logical fields: date, tz, client, status/code, method, url
    parts = raw.split()
    if len(parts) < 6:
        return None
    ts_text = parts[0] + " " + parts[1]
    client = parts[2]
    status_code = parts[3]
    method = parts[4]
    url = parts[5]

    if "/" not in status_code:
        return None
    squid_status, _, code_str = status_code.partition("/")
    try:
        http_code = int(code_str)
    except ValueError:
        http_code = None

    try:
        dt = datetime.strptime(ts_text, _TS_FMT)
        ts_epoch = int(dt.timestamp())
    except ValueError:
        return None

    host = extract_host(method, url)
    return (ts_epoch, ts_text, client, squid_status, http_code, method, url, host)


def extract_host(method, url):
    if method == "CONNECT":
        # url is host:port or [ipv6]:port
        if url.startswith("["):
            end = url.find("]")
            return url[1:end] if end != -1 else url
        return url.rsplit(":", 1)[0]
    # Regular proxied request: strip scheme/path with a minimal parser so we
    # avoid importing urllib for this hot path.
    s = url
    if "://" in s:
        s = s.split("://", 1)[1]
    s = s.split("/", 1)[0]          # drop path
    s = s.split("@", 1)[-1]         # drop userinfo
    if s.startswith("["):           # [ipv6]:port
        end = s.find("]")
        return s[1:end] if end != -1 else s
    return s.rsplit(":", 1)[0] if ":" in s else s


# ---------------------------------------------------------------------------
# Database
# ---------------------------------------------------------------------------
def open_db():
    os.makedirs(os.path.dirname(DB_FILE), exist_ok=True)
    db = sqlite3.connect(DB_FILE)
    db.execute("PRAGMA journal_mode=WAL")      # concurrent reads from control
    db.execute("PRAGMA synchronous=NORMAL")
    db.execute("""
        CREATE TABLE IF NOT EXISTS audit_log (
            id           INTEGER PRIMARY KEY,
            ts           INTEGER NOT NULL,
            ts_text      TEXT    NOT NULL,
            client_ip    TEXT,
            squid_status TEXT,
            http_code    INTEGER,
            method       TEXT,
            url          TEXT,
            host         TEXT
        )
    """)
    db.execute("CREATE INDEX IF NOT EXISTS audit_log_ts ON audit_log(ts)")
    db.execute("CREATE INDEX IF NOT EXISTS audit_log_host ON audit_log(host)")
    db.commit()
    return db


def insert_rows(db, rows):
    if not rows:
        return
    db.executemany(
        "INSERT INTO audit_log "
        "(ts, ts_text, client_ip, squid_status, http_code, method, url, host) "
        "VALUES (?,?,?,?,?,?,?,?)",
        rows,
    )
    db.commit()


def prune(db):
    cutoff_dt = datetime.now(timezone.utc) - timedelta(days=RETENTION_DAYS)
    cutoff = int(cutoff_dt.timestamp())
    cur = db.execute("DELETE FROM audit_log WHERE ts < ?", (cutoff,))
    db.commit()
    if cur.rowcount:
        log(f"pruned {cur.rowcount} rows older than {RETENTION_DAYS}d")


# ---------------------------------------------------------------------------
# Query (shared semantics with the control dashboard's /api/audit)
# ---------------------------------------------------------------------------
def parse_date_local(s, end_of_day=False):
    """
    Parse a user-supplied date/datetime filter into a UTC epoch int.

    Bare dates ('2026-06-01') resolve against the container's *local* timezone
    (TZ env), matching how Squid logs and the dashboard display time. A bare
    date used as `--to` covers the whole day (23:59:59) unless a time is given.
    Accepts 'YYYY-MM-DD' and 'YYYY-MM-DD HH:MM[:SS]' (also with 'T').
    """
    s = s.strip().replace("T", " ")
    fmt = "%Y-%m-%d %H:%M:%S" if " " in s else "%Y-%m-%d"
    if " " in s and s.count(":") == 1:
        fmt = "%Y-%m-%d %H:%M"
    dt = datetime.strptime(s, fmt)
    if " " not in s and end_of_day:
        dt = dt.replace(hour=23, minute=59, second=59)
    # Interpret naive dt in the local timezone, convert to epoch.
    return int(dt.astimezone().timestamp())


def build_query(frm=None, to=None, host=None, status=None, limit=200,
                order="DESC"):
    """Return (sql, params) for an audit query. `status` is 'denied'|'allowed'."""
    where, params = [], []
    if frm is not None:
        where.append("ts >= ?")
        params.append(int(frm))
    if to is not None:
        where.append("ts <= ?")
        params.append(int(to))
    if host:
        where.append("host LIKE ?")
        params.append(f"%{host}%")
    if status == "denied":
        where.append("squid_status LIKE '%DENIED%'")
    elif status == "allowed":
        where.append("squid_status NOT LIKE '%DENIED%'")
    sql = "SELECT ts, ts_text, client_ip, squid_status, http_code, method, url, host FROM audit_log"
    if where:
        sql += " WHERE " + " AND ".join(where)
    sql += f" ORDER BY ts {order}, id {order}"
    if limit is not None:
        sql += " LIMIT ?"
        params.append(int(limit))
    return sql, params


def query_db(db, **kw):
    sql, params = build_query(**kw)
    return db.execute(sql, params).fetchall()


# ---------------------------------------------------------------------------
# Cursor persistence
# ---------------------------------------------------------------------------
def read_cursor():
    try:
        with open(CURSOR_FILE) as fh:
            return int(fh.read().strip() or "0")
    except (OSError, ValueError):
        return 0


def write_cursor(offset):
    tmp = CURSOR_FILE + ".tmp"
    try:
        with open(tmp, "w") as fh:
            fh.write(str(offset))
        os.replace(tmp, CURSOR_FILE)
    except OSError as e:
        log(f"WARN could not persist cursor: {e}")


def log(msg):
    print(f"[auditlog] {msg}", flush=True)


# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
def main():
    log(f"db={DB_FILE} retention={RETENTION_DAYS}d source={LOG_FILE}")
    db = open_db()
    prune(db)
    last_prune = time.monotonic()

    # Wait for Squid to create the log on first boot.
    while not os.path.isfile(LOG_FILE):
        time.sleep(1)

    offset = read_cursor()
    # If the log is smaller than our saved offset, it was rotated/truncated —
    # restart from the beginning of the new file.
    try:
        if os.path.getsize(LOG_FILE) < offset:
            log("access.log shrank (rotation/truncation) — resetting cursor")
            offset = 0
    except OSError:
        offset = 0

    fh = open(LOG_FILE, "rb")
    fh.seek(offset)
    buf = b""
    batch = []

    try:
        while True:
            chunk = fh.read(65536)
            if chunk:
                buf += chunk
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    row = parse_line(line.decode("utf-8", errors="replace"))
                    if row:
                        batch.append(row)
                if len(batch) >= BATCH_MAX:
                    insert_rows(db, batch)
                    batch.clear()
                    write_cursor(fh.tell() - len(buf))
            else:
                # No new bytes: flush whatever we have and persist position.
                if batch:
                    insert_rows(db, batch)
                    batch.clear()
                write_cursor(fh.tell() - len(buf))

                # Detect truncation/rotation while idle.
                try:
                    if os.path.getsize(LOG_FILE) < fh.tell() - len(buf):
                        log("access.log shrank — reopening from start")
                        fh.close()
                        fh = open(LOG_FILE, "rb")
                        buf = b""
                        write_cursor(0)
                        continue
                except OSError:
                    pass

                now = time.monotonic()
                if now - last_prune >= PRUNE_INTERVAL:
                    prune(db)
                    last_prune = now

                time.sleep(POLL_INTERVAL)
    except KeyboardInterrupt:
        pass
    finally:
        if batch:
            insert_rows(db, batch)
        try:
            write_cursor(fh.tell() - len(buf))
        except Exception:
            pass
        fh.close()
        db.close()


# ---------------------------------------------------------------------------
# CLI: `auditlog.py query [opts]`  (backs `fw audit`)
# ---------------------------------------------------------------------------
def cli_query(argv):
    import argparse
    p = argparse.ArgumentParser(
        prog="fw audit",
        description="Query the long-term firewall audit log.",
    )
    p.add_argument("--from", dest="frm", metavar="DATE",
                   help="start (YYYY-MM-DD or 'YYYY-MM-DD HH:MM:SS', local time)")
    p.add_argument("--to", dest="to", metavar="DATE",
                   help="end   (YYYY-MM-DD or 'YYYY-MM-DD HH:MM:SS', local time)")
    p.add_argument("--host", metavar="PATTERN",
                   help="substring match on the destination host")
    p.add_argument("--status", choices=("denied", "allowed"),
                   help="restrict to denied or allowed requests")
    p.add_argument("--limit", type=int, default=50,
                   help="max rows (default 50; use 0 for no limit)")
    args = p.parse_args(argv)

    try:
        frm = parse_date_local(args.frm) if args.frm else None
        to  = parse_date_local(args.to, end_of_day=True) if args.to else None
    except ValueError:
        print("error: dates must be YYYY-MM-DD or 'YYYY-MM-DD HH:MM:SS'",
              file=sys.stderr)
        return 2

    if not os.path.isfile(DB_FILE):
        print("audit log is empty (no database yet)", file=sys.stderr)
        return 0

    db = sqlite3.connect(f"file:{DB_FILE}?mode=ro", uri=True)
    try:
        rows = query_db(db, frm=frm, to=to, host=args.host, status=args.status,
                        limit=(None if args.limit == 0 else args.limit),
                        order="ASC")
    finally:
        db.close()

    if not rows:
        print("no matching audit entries")
        return 0

    # Reconstruct the original Squid 'egress' log-line style (consistent with
    # `fw blocks` / `fw log`): ts  client  STATUS/code  method  url
    for ts, ts_text, client, status, code, method, url, host in rows:
        code_s = code if code is not None else "-"
        print(f"{ts_text}  {client}  {status}/{code_s}  {method}  {url}")
    return 0


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "query":
        sys.exit(cli_query(sys.argv[2:]))
    sys.exit(main())
