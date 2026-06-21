#!/usr/bin/env python3
"""
Firewall management dashboard for the control container.

Single-file, stdlib-only HTTP server.  Bound to 0.0.0.0:8088; the host
publish (127.0.0.1:8088:8088 in docker-compose) restricts real exposure to
loopback.  Every mutating API call shells out to the existing allow/deny/feature
scripts so the CLI (fw / allow / deny / feature) and the web UI share one
source of truth.
"""

import json
import os
import re
import sqlite3
import subprocess
import time
import urllib.parse
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# ---------------------------------------------------------------------------
# Config  (paths overridable via env — used by the test harness)
# ---------------------------------------------------------------------------
PORT        = 8088
PERM_FILE   = os.environ.get("PERM_FILE",     "/policy/allowlist.acl.perm")
TTL_FILE    = os.environ.get("TTL_FILE",      "/policy/ttl.tsv")
DEFS_DIR    = os.environ.get("FEATURE_DEFS",  "/policy/features.defs")
STATE_FILE  = os.environ.get("FEATURE_STATE", "/policy/features.state")
LOG_FILE    = os.environ.get("LOG_FILE",      "/var/log/squid/access.log")
AUDIT_DB    = os.environ.get("AUDIT_DB",      "/auditlog/audit.db")
ALLOW_CMD   = os.environ.get("ALLOW_CMD",     "/usr/local/bin/allow")
DENY_CMD    = os.environ.get("DENY_CMD",      "/usr/local/bin/deny")
FEATURE_CMD = os.environ.get("FEATURE_CMD",   "/usr/local/bin/feature")
MAX_BODY    = 4096   # bytes — cap on POST body
AUDIT_MAX_ROWS = 1000   # server-side cap on /api/audit (download is uncapped)

# ---------------------------------------------------------------------------
# Security helpers
# ---------------------------------------------------------------------------
_ALLOWED_HOSTS = frozenset({
    "127.0.0.1",       f"127.0.0.1:{PORT}",
    "localhost",        f"localhost:{PORT}",
    "[::1]",            f"[::1]:{PORT}",
})

# Valid bare domain or wildcard-parent (.example.com).
# Rejects shell metacharacters, path separators, spaces, etc.
_DOMAIN_RE = re.compile(
    r'^\.?(?!-)[A-Za-z0-9-]{1,63}(?<!-)'
    r'(\.(?!-)[A-Za-z0-9-]{1,63}(?<!-))+$'
)
_FEATURE_RE = re.compile(r'^[A-Za-z0-9_-]{1,40}$')

def _valid_domain(d):
    return isinstance(d, str) and bool(_DOMAIN_RE.match(d))

def _valid_feature(n):
    return isinstance(n, str) and bool(_FEATURE_RE.match(n))

# ---------------------------------------------------------------------------
# Policy readers
# ---------------------------------------------------------------------------
def _read_allowlist():
    permanent = []
    if os.path.isfile(PERM_FILE):
        with open(PERM_FILE) as fh:
            for line in fh:
                line = line.strip()
                if line and not line.startswith("#"):
                    permanent.append(line)

    temporary = []
    now = int(time.time())
    if os.path.isfile(TTL_FILE):
        with open(TTL_FILE) as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                parts = line.split("\t", 1)
                if len(parts) != 2:
                    continue
                try:
                    exp = int(parts[0])
                except ValueError:
                    continue
                domain = parts[1].strip()
                if exp > now:
                    temporary.append({
                        "domain": domain,
                        "expires_at": exp,
                        "seconds_remaining": max(0, exp - now),
                    })

    return {"permanent": sorted(set(permanent)), "temporary": temporary}

# --- Feature-sets -----------------------------------------------------------
def _read_feature_defs():
    """Parse /policy/features.defs/*.list -> ({name: {domains, depends}}, baseline_domains)."""
    defs, baseline = {}, []
    if not os.path.isdir(DEFS_DIR):
        return defs, baseline
    for fn in sorted(os.listdir(DEFS_DIR)):
        if not fn.endswith(".list"):
            continue
        name = fn[:-5]
        domains, depends = [], []
        try:
            with open(os.path.join(DEFS_DIR, fn)) as fh:
                for line in fh:
                    s = line.strip()
                    if not s:
                        continue
                    if s.startswith("#"):
                        m = re.match(r'#\s*depends:\s*(.+)$', s)
                        if m:
                            depends += [d for d in re.split(r'[,\s]+', m.group(1)) if d]
                        continue
                    domains.append(s)
        except OSError:
            continue
        if name == "_baseline":
            baseline = domains
        else:
            defs[name] = {"domains": domains, "depends": depends}
    return defs, baseline

def _read_state(defs):
    state = {n: False for n in defs}
    if os.path.isfile(STATE_FILE):
        with open(STATE_FILE) as fh:
            for line in fh:
                s = line.strip()
                if not s or s.startswith("#") or "=" not in s:
                    continue
                k, v = s.split("=", 1)
                k, v = k.strip(), v.strip().lower()
                if k in state:
                    state[k] = (v == "on")
    return state

def _closure(defs, names):
    """Transitive closure of `names` over their depends (only real features)."""
    seen, queue = set(), list(names)
    while queue:
        f = queue.pop()
        if f in seen or f not in defs:
            continue
        seen.add(f)
        queue.extend(defs[f]["depends"])
    return seen

def _read_features():
    defs, baseline = _read_feature_defs()
    state = _read_state(defs)
    enabled = {n for n, on in state.items() if on}
    effective = _closure(defs, enabled)
    required_by = {n: [] for n in defs}
    for e in sorted(enabled):
        for d in sorted(_closure(defs, {e})):
            if d != e and d not in enabled:
                required_by[d].append(e)
    features = []
    for name in sorted(defs):
        features.append({
            "name":        name,
            "enabled":     name in enabled,
            "effective":   name in effective,
            "depends":     defs[name]["depends"],
            "required_by": required_by.get(name, []),
            "domains":     defs[name]["domains"],
        })
    return {"baseline": sorted(set(baseline)), "features": features}

# ---------------------------------------------------------------------------
# Log parser
# ---------------------------------------------------------------------------
# logformat egress  %tl %>a %Ss/%03>Hs %rm %ru
# Example: 09/Jun/2026:12:34:56 +0200 172.20.0.2 TCP_DENIED/403 CONNECT evil.com:443
_LOG_RE = re.compile(
    r'^(\d{2}/\w+/\d{4}:\d{2}:\d{2}:\d{2} [+-]\d{4})\s+'
    r'(\S+)\s+'
    r'([A-Z_]+)/(\d{3})\s+'
    r'(\S+)\s+'
    r'(\S+)$'
)

def _extract_host(method, url):
    if method == "CONNECT":
        # url is host:port or [ipv6]:port
        if url.startswith("["):
            end = url.find("]")
            return url[1:end] if end != -1 else url
        return url.rsplit(":", 1)[0]
    try:
        return urllib.parse.urlsplit(url).hostname or url
    except Exception:
        return url

def _parse_log_line(raw):
    m = _LOG_RE.match(raw.strip())
    if not m:
        return None
    ts, client, squid_status, code, method, url = m.groups()
    return {
        "ts":       ts,
        "client":   client,
        "decision": "denied" if "DENIED" in squid_status else "allowed",
        "code":     code,
        "method":   method,
        "host":     _extract_host(method, url),
        "raw":      raw.strip(),
    }

def _read_blocks(limit=200):
    if not os.path.isfile(LOG_FILE):
        return []
    try:
        with open(LOG_FILE, "rb") as fh:
            fh.seek(0, 2)
            size = fh.tell()
            fh.seek(max(0, size - 524288))   # last ~512 KB
            data = fh.read().decode("utf-8", errors="replace")
    except OSError:
        return []

    by_host = {}
    for line in data.splitlines():
        p = _parse_log_line(line)
        if not p or p["decision"] != "denied":
            continue
        h = p["host"]
        if h not in by_host:
            by_host[h] = {"domain": h, "last_seen": p["ts"], "count": 0}
        by_host[h]["count"] += 1
        by_host[h]["last_seen"] = p["ts"]

    result = sorted(by_host.values(), key=lambda x: x["last_seen"], reverse=True)
    return result[:limit]

# ---------------------------------------------------------------------------
# Audit log (read-only SQLite on the `auditlog` volume; written by the
# firewall container's auditlog.py). Query semantics mirror `fw audit`.
# ---------------------------------------------------------------------------
def _parse_date_local(s, end_of_day=False):
    """Parse 'YYYY-MM-DD' / 'YYYY-MM-DD HH:MM[:SS]' (local tz) -> epoch int.

    Bare dates resolve in the container's local timezone to match how the logs
    and dashboard display time. A bare `to` date covers the whole day.
    """
    s = s.strip().replace("T", " ")
    if " " in s:
        fmt = "%Y-%m-%d %H:%M:%S" if s.count(":") == 2 else "%Y-%m-%d %H:%M"
    else:
        fmt = "%Y-%m-%d"
    dt = datetime.strptime(s, fmt)
    if " " not in s and end_of_day:
        dt = dt.replace(hour=23, minute=59, second=59)
    return int(dt.astimezone().timestamp())

def _audit_query(frm=None, to=None, host=None, status=None, limit=200):
    """Run a filtered query against the audit DB. Returns a list of dict rows
    (most-recent first). Raises sqlite3.Error if the DB is unreadable."""
    if not os.path.isfile(AUDIT_DB):
        return []
    where, params = [], []
    if frm is not None:
        where.append("ts >= ?"); params.append(int(frm))
    if to is not None:
        where.append("ts <= ?"); params.append(int(to))
    if host:
        where.append("host LIKE ?"); params.append("%" + host + "%")
    if status == "denied":
        where.append("squid_status LIKE '%DENIED%'")
    elif status == "allowed":
        where.append("squid_status NOT LIKE '%DENIED%'")
    sql = ("SELECT ts, ts_text, client_ip, squid_status, http_code, "
           "method, url, host FROM audit_log")
    if where:
        sql += " WHERE " + " AND ".join(where)
    sql += " ORDER BY ts DESC, id DESC"
    if limit is not None:
        sql += " LIMIT ?"; params.append(int(limit))

    db = sqlite3.connect("file:" + AUDIT_DB + "?mode=ro", uri=True, timeout=5)
    try:
        cur = db.execute(sql, params)
        cols = [c[0] for c in cur.description]
        return [dict(zip(cols, row)) for row in cur.fetchall()]
    finally:
        db.close()

def _audit_params(qs):
    """Translate a parsed query string (dict of lists) into _audit_query kwargs.
    Returns (kwargs, error_message). error_message is None on success."""
    def one(name):
        v = qs.get(name, [None])[0]
        return v.strip() if isinstance(v, str) else v

    kw = {}
    try:
        frm = one("from")
        to  = one("to")
        kw["frm"] = _parse_date_local(frm) if frm else None
        kw["to"]  = _parse_date_local(to, end_of_day=True) if to else None
    except ValueError:
        return None, "dates must be YYYY-MM-DD or 'YYYY-MM-DD HH:MM:SS'"

    host = one("host")
    if host:
        if len(host) > 253 or any(c in host for c in " \t\r\n'\";\\"):
            return None, "invalid host filter"
        kw["host"] = host

    status = one("status")
    if status in ("denied", "allowed"):
        kw["status"] = status
    elif status:
        return None, "status must be 'denied' or 'allowed'"

    return kw, None

# ---------------------------------------------------------------------------
# Embedded single-page UI
# ---------------------------------------------------------------------------
_HTML = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Firewall Dashboard</title>
<style>
:root{
  --bg:#f4f4f5;--surface:#fff;--border:#e4e4e7;
  --text:#18181b;--muted:#71717a;--accent:#2563eb;
  --green:#16a34a;--red:#dc2626;
  --green-dim:rgba(22,163,74,.07);--red-dim:rgba(220,38,38,.07);
  --radius:6px
}
@media(prefers-color-scheme:dark){:root{
  --bg:#09090b;--surface:#18181b;--border:#27272a;
  --text:#fafafa;--muted:#a1a1aa;--accent:#60a5fa;
  --green:#4ade80;--red:#f87171;
  --green-dim:rgba(74,222,128,.07);--red-dim:rgba(248,113,113,.09)
}}
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:system-ui,-apple-system,BlinkMacSystemFont,sans-serif;
     background:var(--bg);color:var(--text);font-size:14px;line-height:1.5}
.dot{width:9px;height:9px;border-radius:50%;background:var(--muted);
     transition:background .4s;flex-shrink:0}
.dot.ok{background:var(--green)}.dot.err{background:var(--red)}
/* App shell: fixed sidebar + scrolling content */
.shell{display:grid;grid-template-columns:220px 1fr;min-height:100vh}
/* Sidebar */
.sidebar{position:sticky;top:0;align-self:start;height:100vh;
         background:var(--surface);border-right:1px solid var(--border);
         display:flex;flex-direction:column;gap:4px;padding:14px 10px;overflow-y:auto}
.brand{display:flex;align-items:center;gap:8px;padding:6px 8px 14px;
       font-size:14px;font-weight:600;color:var(--text);
       border-bottom:1px solid var(--border);margin-bottom:6px}
.brand .dot{margin-left:auto}
.nav-group{font-size:10px;font-weight:700;text-transform:uppercase;
           letter-spacing:.07em;color:var(--muted);padding:12px 8px 4px}
.nav-item{display:flex;align-items:center;gap:8px;padding:7px 10px;
          border-radius:5px;font-size:13px;font-weight:500;color:var(--muted);
          cursor:pointer;border:none;background:none;width:100%;text-align:left;
          font-family:inherit;transition:background .12s,color .12s}
.nav-item:hover{background:var(--bg);color:var(--text);opacity:1}
.nav-item.active{background:var(--accent);color:#fff;font-weight:600}
.nav-item.active:hover{background:var(--accent);color:#fff}
.nav-item .nav-dot{margin-left:auto}
/* Content area: one view visible at a time */
.content{min-width:0;padding:20px;display:block}
.view{max-width:1100px;margin:0 auto;
      flex-direction:column;gap:16px}
.view{display:none}
.view.active{display:flex}
/* Cards */
.card{background:var(--surface);border:1px solid var(--border);
      border-radius:var(--radius);overflow:hidden}
.card-hdr{display:flex;align-items:center;gap:8px;padding:10px 14px;
          border-bottom:1px solid var(--border)}
.card-hdr h2{font-size:11px;font-weight:700;text-transform:uppercase;
             letter-spacing:.06em;color:var(--muted);flex:1}
/* Buttons */
button{padding:4px 10px;border:1px solid var(--border);border-radius:4px;
       background:var(--surface);color:var(--text);cursor:pointer;
       font-size:12px;font-family:inherit;transition:opacity .15s}
button:hover{opacity:.75}
.btn-sm{padding:2px 8px;font-size:11px}
.btn-icon{padding:2px 6px;line-height:1}
.btn-primary{background:var(--accent);border-color:var(--accent);color:#fff}
.btn-success{background:var(--green);border-color:var(--green);color:#fff}
.btn-danger{background:var(--red);border-color:var(--red);color:#fff}
/* Inputs */
input[type=text],input[type=number],input[type=date]{
  padding:4px 8px;border:1px solid var(--border);border-radius:4px;
  background:var(--surface);color:var(--text);font-size:12px;font-family:inherit}
input:focus{outline:2px solid var(--accent);outline-offset:1px}
/* Stream list */
#stream-list{height:280px;overflow-y:auto;padding:6px;
             display:flex;flex-direction:column;gap:2px;
             font-family:ui-monospace,monospace;font-size:11.5px}
.s-entry{padding:3px 8px;border-radius:3px;border-left:3px solid transparent;
         display:flex;gap:6px;align-items:baseline}
.s-entry.allowed{border-left-color:var(--green)}
.s-entry.denied{border-left-color:var(--red);background:var(--red-dim)}
.s-icon{font-size:10px;width:13px;flex-shrink:0}
.s-method{color:var(--muted);font-size:10px;width:46px;flex-shrink:0}
.s-host{font-weight:500;flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.s-ts{color:var(--muted);font-size:10px;flex-shrink:0;white-space:nowrap}
/* Sub-labels */
.sub-label{font-size:11px;font-weight:600;text-transform:uppercase;
           letter-spacing:.05em;color:var(--muted);padding:8px 14px 4px}
/* Tables */
table{width:100%;border-collapse:collapse}
th,td{padding:7px 12px;text-align:left;border-bottom:1px solid var(--border);font-size:13px}
th{font-size:10px;font-weight:700;text-transform:uppercase;letter-spacing:.05em;
   color:var(--muted);background:var(--bg)}
tr:last-child td{border-bottom:none}
.td-domain{font-family:ui-monospace,monospace;font-size:12px}
.td-ts{font-size:11px;color:var(--muted)}
.td-count{font-size:12px;color:var(--muted);text-align:right}
.act-group{display:flex;gap:4px;flex-wrap:wrap;align-items:center}
.countdown{font-family:ui-monospace,monospace;font-size:11px;color:var(--muted)}
.empty-td{color:var(--muted);font-style:italic;text-align:center;padding:16px !important}
/* Traffic page: Active Allowlist above Recently Blocked, stacked */
.traffic-stack{display:flex;flex-direction:column;gap:16px}
/* Collapsible Active Allowlist card */
.allowlist-details{display:block}
.allowlist-summary{cursor:pointer;list-style:none;user-select:none}
.allowlist-summary::-webkit-details-marker{display:none}
.allowlist-summary h2{pointer-events:none}
.allowlist-summary::after{content:'▾';font-size:12px;color:var(--muted);margin-left:auto;
  transition:transform .15s}
.allowlist-details:not([open])>.allowlist-summary::after{content:'▸'}
/* Resolved (allowed) blocked row */
tr.resolved td{background:var(--green-dim)}
tr.resolved .td-domain{opacity:.75}
.resolved-badge{display:inline-flex;align-items:center;gap:5px;font-size:11px;
                font-weight:600;color:var(--green)}
.resolved-badge .countdown{color:var(--green)}
/* Manual add-domain row in the Allowlist panel */
.allow-add{display:flex;gap:6px;align-items:center;flex-wrap:wrap;
           padding:10px 14px;border-bottom:1px solid var(--border)}
.allow-add select{padding:4px 6px;border:1px solid var(--border);border-radius:4px;
                  background:var(--surface);color:var(--text);font-size:12px;font-family:inherit}
/* Collapsible baseline section */
.baseline-details{border-top:1px solid var(--border)}
.baseline-details>summary{cursor:pointer;list-style:revert;
   font-size:11px;font-weight:600;text-transform:uppercase;letter-spacing:.05em;
   color:var(--muted);padding:8px 14px}
.baseline-details>summary:hover{color:var(--text)}
/* Audit log */
.audit-form{display:flex;flex-wrap:wrap;gap:8px;align-items:center;
            padding:10px 14px;border-bottom:1px solid var(--border)}
.audit-form label{font-size:11px;color:var(--muted);display:flex;
                  align-items:center;gap:4px}
.audit-form select{padding:4px 6px;border:1px solid var(--border);
                   border-radius:4px;background:var(--surface);
                   color:var(--text);font-size:12px;font-family:inherit}
.au-dec{font-size:10px;font-weight:700;text-transform:uppercase;
        letter-spacing:.04em;padding:1px 6px;border-radius:4px}
.au-dec.allowed{background:var(--green);color:#fff}
.au-dec.denied{background:var(--red);color:#fff}
.td-url{font-family:ui-monospace,monospace;font-size:11px;color:var(--muted);
        max-width:340px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
/* Feature sets */
#featBody td{vertical-align:top}
.feat-name{font-weight:600;font-size:13px}
.feat-meta{font-size:11px;color:var(--muted);margin-top:2px}
.feat-doms{display:flex;flex-wrap:wrap;gap:4px;margin-top:4px}
.chip{font-family:ui-monospace,monospace;font-size:11px;padding:1px 6px;
      border:1px solid var(--border);border-radius:10px;color:var(--muted)}
.badge{display:inline-block;font-size:10px;font-weight:700;text-transform:uppercase;
       letter-spacing:.04em;padding:1px 6px;border-radius:4px;margin-left:6px}
.badge.on{background:var(--green);color:#fff}
.badge.dep{background:var(--accent);color:#fff}
.badge.off{background:var(--border);color:var(--muted)}
.tog{min-width:64px;text-align:center}
/* Toasts */
#toasts{position:fixed;bottom:16px;right:16px;display:flex;
        flex-direction:column;gap:6px;z-index:999}
.toast{padding:9px 14px;border-radius:6px;font-size:13px;min-width:200px;
       max-width:320px;box-shadow:0 4px 14px rgba(0,0,0,.2);animation:fin .2s}
.toast.ok{background:var(--green);color:#fff}
.toast.err{background:var(--red);color:#fff}
@keyframes fin{from{opacity:0;transform:translateY(6px)}to{opacity:1;transform:translateY(0)}}
/* Narrow screens: sidebar becomes a horizontal nav row above the content */
@media(max-width:700px){
  .shell{grid-template-columns:1fr}
  .sidebar{position:static;height:auto;flex-direction:row;flex-wrap:wrap;
           align-items:center;gap:4px;border-right:none;
           border-bottom:1px solid var(--border)}
  .brand{border-bottom:none;margin:0;padding:6px 8px;width:100%}
  .nav-group{display:none}
  .nav-item{width:auto}
  .nav-item .nav-dot{display:none}
}
</style>
</head>
<body>

<div class="shell">

  <!-- Sidebar navigation -->
  <nav class="sidebar">
    <div class="brand">
      Firewall
      <span class="dot" id="dot" title="Live stream connection"></span>
    </div>
    <button class="nav-item" data-view="traffic">Traffic
      <span class="dot nav-dot" id="navDot" title="Live stream connection"></span>
    </button>
    <button class="nav-item" data-view="audit">Audit Log</button>
    <button class="nav-item" data-view="features">Feature Sets</button>
  </nav>

  <!-- Content: one view visible at a time -->
  <main class="content">

    <!-- ===== Traffic: live stream + Recently Blocked <-> Active Allowlist ===== -->
    <section class="view" id="view-traffic">
      <div class="card" id="streamCard">
        <div class="card-hdr">
          <h2>Live Traffic</h2>
          <input type="text" id="streamFilter" placeholder="Filter by host&#8230;" style="width:160px">
          <button id="btnPause">Pause</button>
          <button id="btnClear">Clear</button>
        </div>
        <div id="stream-list"></div>
      </div>

      <div class="traffic-stack">
        <div class="card">
          <details id="allowlistDetails" class="allowlist-details" open>
            <summary class="card-hdr allowlist-summary"><h2>Active Allowlist</h2></summary>
            <div class="allow-add">
              <input type="text" id="addDomain" placeholder="domain to allow&#8230;" style="flex:1;min-width:110px">
              <select id="addTTL">
                <option value="">permanent</option>
                <option value="300">5m</option>
                <option value="900">15m</option>
                <option value="3600">1h</option>
              </select>
              <button id="addBtn" class="btn-sm btn-success">Add</button>
            </div>
            <div style="font-size:11px;color:var(--muted);padding:2px 14px 6px">
              <code>example.com</code> &mdash; exact host &nbsp;|&nbsp; <code>.example.com</code> &mdash; all subdomains of example.com
            </div>
            <div class="sub-label">Manual (permanent)</div>
            <table>
              <thead><tr><th>Domain</th><th></th></tr></thead>
              <tbody id="permBody"></tbody>
            </table>
            <div class="sub-label" style="margin-top:4px">Temporary</div>
            <table>
              <thead><tr><th>Domain</th><th>Expires in</th><th></th></tr></thead>
              <tbody id="tempBody"></tbody>
            </table>
            <details class="baseline-details">
              <summary>Baseline (always on)</summary>
              <table>
                <thead><tr><th>Domain</th><th></th></tr></thead>
                <tbody id="baseBody"></tbody>
              </table>
            </details>
          </details>
        </div>

        <div class="card">
          <div class="card-hdr"><h2>Recently Blocked</h2>
            <span class="feat-meta">allow a domain &mdash; it appears in the Allowlist above</span>
          </div>
          <table>
            <thead><tr><th>Domain</th><th>Last seen</th><th style="text-align:right">Count</th><th>Action</th></tr></thead>
            <tbody id="blocksBody"></tbody>
          </table>
        </div>
      </div>
    </section>

    <!-- ===== Audit log ===== -->
    <section class="view" id="view-audit">
      <div class="card">
        <div class="card-hdr"><h2>Audit Log</h2>
          <span class="feat-meta">long-term history of all proxied traffic &mdash; query a period, then download as CSV</span>
        </div>
        <div class="audit-form">
          <label>From <input type="date" id="auFrom" style="width:150px"></label>
          <label>To <input type="date" id="auTo" style="width:150px"></label>
          <label>Host <input type="text" id="auHost" placeholder="substring&#8230;" style="width:150px"></label>
          <label>Status
            <select id="auStatus">
              <option value="">all</option>
              <option value="denied">denied</option>
              <option value="allowed">allowed</option>
            </select>
          </label>
          <button id="auQuery" class="btn-primary">Query</button>
          <button id="auReset">Reset</button>
          <span style="flex:1"></span>
          <button id="auDownload" class="btn-success">Download CSV</button>
        </div>
        <div id="auMeta" class="sub-label"></div>
        <table>
          <thead><tr><th>Time</th><th>Decision</th><th>Code</th><th>Method</th><th>Host</th><th>URL</th></tr></thead>
          <tbody id="auditBody"></tbody>
        </table>
      </div>
    </section>

    <!-- ===== Feature sets ===== -->
    <section class="view" id="view-features">
      <div class="card">
        <div class="card-hdr"><h2>Feature sets</h2>
          <span class="feat-meta">toggle the domain groups this project needs &mdash; disable the agentic frameworks you don't use</span>
        </div>
        <table>
          <thead><tr><th>Feature</th><th>Domains</th><th class="tog">State</th></tr></thead>
          <tbody id="featBody"></tbody>
        </table>
      </div>
    </section>

  </main>
</div><!-- .shell -->

<div id="toasts"></div>

<script>
// ---- Constants / keys ----
var LS_FILTER = 'fw.streamFilter';
var MAX_ENTRIES = 500;
var VIEWS = ['traffic', 'audit', 'features'];

// ---- State ----
var entries = [];
var paused  = false;
var hovering = false;
var filter  = localStorage.getItem(LS_FILTER) || '';
var sse     = null;
var currentView = 'traffic';

// ---- Elements ----
var dot     = document.getElementById('dot');
var navDot  = document.getElementById('navDot');
var sList   = document.getElementById('stream-list');
var sFilt   = document.getElementById('streamFilter');
var btnP    = document.getElementById('btnPause');
var btnC    = document.getElementById('btnClear');
var featB   = document.getElementById('featBody');
var permB   = document.getElementById('permBody');
var tempB   = document.getElementById('tempBody');
var baseB   = document.getElementById('baseBody');
var blkB    = document.getElementById('blocksBody');
var toastsEl = document.getElementById('toasts');
var auFrom  = document.getElementById('auFrom');
var auTo    = document.getElementById('auTo');
var auHost  = document.getElementById('auHost');
var auStatus = document.getElementById('auStatus');
var auBody  = document.getElementById('auditBody');
var auMeta  = document.getElementById('auMeta');
var addDomain = document.getElementById('addDomain');
var addTTL  = document.getElementById('addTTL');
var addBtn  = document.getElementById('addBtn');
var navItems = Array.prototype.slice.call(document.querySelectorAll('.nav-item'));

// ---- Shared state for the blocked<->allowlist join ----
// renderBlocks marks a blocked row "resolved" when its exact domain has a
// manual permanent or temporary allow entry, so we cache both data sets.
var currentAllowlist = { permanent: [], temporary: [] };
var lastBlocks = [];

// ---- Restore persisted preferences ----
sFilt.value = filter;

// ---- Utilities ----
function esc(s) {
  return String(s)
    .replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;')
    .replace(/"/g,'&quot;').replace(/'/g,'&#x27;');
}

function toast(msg, ok) {
  var el = document.createElement('div');
  el.className = 'toast ' + (ok !== false ? 'ok' : 'err');
  el.textContent = msg;
  toastsEl.appendChild(el);
  setTimeout(function(){ el.remove(); }, 3500);
}

function post(url, body) {
  return fetch(url, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'X-Requested-With': 'XMLHttpRequest'
    },
    body: JSON.stringify(body)
  }).then(function(r) {
    return r.text().then(function(txt) {
      if (!r.ok) throw new Error(txt || r.statusText);
      return txt;
    });
  });
}

function fmtTTL(sec) {
  if (sec <= 0) return 'expired';
  var h = Math.floor(sec / 3600);
  var m = Math.floor((sec % 3600) / 60);
  var s = sec % 60;
  if (h) return h + 'h ' + String(m).padStart(2,'0') + 'm';
  return String(m).padStart(2,'0') + ':' + String(s).padStart(2,'0');
}

// Convert "21/Jun/2026:13:02:43 +0200" -> "2026-06-21 13:02:43"
function fmtSquidTs(raw) {
  if (!raw) return raw;
  // Format: DD/Mon/YYYY:HH:MM:SS +HHMM
  var m = raw.match(/^(\d{2})\/(\w{3})\/(\d{4}):(\d{2}:\d{2}:\d{2}) [+-]\d{4}$/);
  if (!m) return raw;
  var months = {Jan:'01',Feb:'02',Mar:'03',Apr:'04',May:'05',Jun:'06',
                Jul:'07',Aug:'08',Sep:'09',Oct:'10',Nov:'11',Dec:'12'};
  var mon = months[m[2]] || m[2];
  return m[3] + '-' + mon + '-' + m[1] + ' ' + m[4];
}

// ---- Stream ----
function matches(e) {
  return !filter || e.host.toLowerCase().includes(filter.toLowerCase());
}

function makeRow(e) {
  var d = document.createElement('div');
  d.className = 's-entry ' + e.decision;
  d.innerHTML =
    '<span class="s-icon">' + (e.decision === 'allowed' ? '&#10003;' : '&#10007;') + '</span>'
    + '<span class="s-method">' + esc(e.method) + '</span>'
    + '<span class="s-host">' + esc(e.host) + '</span>'
    + '<span class="s-ts">' + esc(fmtSquidTs(e.ts)) + '</span>';
  return d;
}

function rebuildList() {
  sList.innerHTML = '';
  var visible = entries.filter(matches).slice(-MAX_ENTRIES);
  var frag = document.createDocumentFragment();
  visible.forEach(function(e){ frag.appendChild(makeRow(e)); });
  sList.appendChild(frag);
  if (!paused && !hovering) sList.scrollTop = sList.scrollHeight;
}

function pushEntry(e) {
  entries.push(e);
  if (entries.length > MAX_ENTRIES) entries = entries.slice(-MAX_ENTRIES);
  if (!matches(e)) return;
  sList.appendChild(makeRow(e));
  while (sList.children.length > MAX_ENTRIES) sList.removeChild(sList.firstChild);
  if (!paused && !hovering) sList.scrollTop = sList.scrollHeight;
}

sFilt.addEventListener('input', function() {
  filter = sFilt.value;
  localStorage.setItem(LS_FILTER, filter);
  rebuildList();
});

btnP.addEventListener('click', function() {
  paused = !paused;
  btnP.textContent = paused ? 'Resume' : 'Pause';
  if (!paused) sList.scrollTop = sList.scrollHeight;
});

btnC.addEventListener('click', function() {
  entries = [];
  sList.innerHTML = '';
});

sList.addEventListener('mouseenter', function(){ hovering = true; });
sList.addEventListener('mouseleave', function(){
  hovering = false;
  if (!paused) sList.scrollTop = sList.scrollHeight;
});

// ---- SSE ----
function setDot(cls) {
  if (dot)    dot.className    = 'dot ' + cls;
  if (navDot) navDot.className = 'dot nav-dot ' + cls;
}
function connectSSE() {
  if (sse) sse.close();
  sse = new EventSource('/api/stream');
  sse.addEventListener('open', function(){ setDot('ok'); });
  sse.addEventListener('entry', function(ev) {
    try { pushEntry(JSON.parse(ev.data)); } catch(_){}
  });
  sse.addEventListener('error', function() {
    setDot('err');
    sse.close();
    setTimeout(connectSSE, 3000);
  });
}
connectSSE();

// ---- Feature sets rendering ----
function renderFeatures(data) {
  var feats = data.features || [];
  if (!feats.length) {
    featB.innerHTML = '<tr><td class="empty-td" colspan="3">No feature definitions found</td></tr>';
  } else {
    featB.innerHTML = feats.map(function(f) {
      var badge, meta = '';
      if (f.enabled) {
        badge = '<span class="badge on">on</span>';
      } else if (f.effective) {
        badge = '<span class="badge dep">via dep</span>';
        meta = 'required by ' + esc((f.required_by || []).join(', '));
      } else {
        badge = '<span class="badge off">off</span>';
      }
      if (f.depends && f.depends.length) {
        meta += (meta ? ' &middot; ' : '') + 'depends: ' + esc(f.depends.join(', '));
      }
      var chips = (f.domains || []).map(function(d) {
        return '<span class="chip">' + esc(d) + '</span>';
      }).join('');
      // Toggle reflects the *explicit* state; dependency-pulled features can
      // still be turned on explicitly (or left off and pulled implicitly).
      var btnCls = f.enabled ? 'btn-sm btn-danger' : 'btn-sm btn-success';
      var btnTxt = f.enabled ? 'Disable' : 'Enable';
      return '<tr data-feature="' + esc(f.name) + '" data-enabled="' + (f.enabled ? '1' : '0') + '">'
        + '<td><span class="feat-name">' + esc(f.name) + '</span>' + badge
        + (meta ? '<div class="feat-meta">' + meta + '</div>' : '') + '</td>'
        + '<td><div class="feat-doms">' + chips + '</div></td>'
        + '<td class="tog"><button class="' + btnCls + '" data-action="toggle">' + btnTxt + '</button></td>'
        + '</tr>';
    }).join('');
  }

  var base = data.baseline || [];
  if (!base.length) {
    baseB.innerHTML = '<tr><td class="empty-td" colspan="2">No baseline entries</td></tr>';
  } else {
    baseB.innerHTML = base.map(function(d) {
      return '<tr><td class="td-domain">' + esc(d) + '</td>'
        + '<td class="td-ts">always on</td></tr>';
    }).join('');
  }
}

// ---- Allowlist rendering ----
function renderAllowlist(data) {
  // Cache for the blocked<->allowlist join, then re-render blocks so a row's
  // resolved state always reflects the latest allowlist.
  currentAllowlist = { permanent: data.permanent || [], temporary: data.temporary || [] };

  if (!data.permanent.length) {
    permB.innerHTML = '<tr><td class="empty-td" colspan="2">No manual entries</td></tr>';
  } else {
    permB.innerHTML = data.permanent.map(function(d) {
      return '<tr data-domain="' + esc(d) + '">'
        + '<td class="td-domain">' + esc(d) + '</td>'
        + '<td><button class="btn-sm btn-danger" data-action="deny">Remove</button></td>'
        + '</tr>';
    }).join('');
  }

  if (!data.temporary.length) {
    tempB.innerHTML = '<tr><td class="empty-td" colspan="3">No temporary entries</td></tr>';
  } else {
    tempB.innerHTML = data.temporary.map(function(e) {
      return '<tr data-domain="' + esc(e.domain) + '">'
        + '<td class="td-domain">' + esc(e.domain) + '</td>'
        + '<td><span class="countdown" data-exp="' + e.expires_at + '">'
        + fmtTTL(e.seconds_remaining) + '</span></td>'
        + '<td><button class="btn-sm btn-danger" data-action="deny">Remove</button></td>'
        + '</tr>';
    }).join('');
  }

  renderBlocks(lastBlocks);
}

// Look up how a domain is currently allowed (exact match against the manual
// permanent + temporary allowlist). Returns null, or {kind, expires_at?}.
function allowState(domain) {
  if (currentAllowlist.permanent.indexOf(domain) !== -1) {
    return { kind: 'permanent' };
  }
  var t = currentAllowlist.temporary;
  for (var i = 0; i < t.length; i++) {
    if (t[i].domain === domain) return { kind: 'temporary', expires_at: t[i].expires_at };
  }
  return null;
}

function renderBlocks(data) {
  lastBlocks = data || [];
  if (!lastBlocks.length) {
    blkB.innerHTML = '<tr><td class="empty-td" colspan="4">No blocked requests recorded yet</td></tr>';
    return;
  }
  blkB.innerHTML = lastBlocks.map(function(b) {
    var st = allowState(b.domain);
    var actionCell;
    if (st) {
      // Resolved: show a badge (with live countdown for temp) + Remove allow.
      var badge = st.kind === 'permanent'
        ? '<span class="resolved-badge">&#10003; Allowed &middot; permanent</span>'
        : '<span class="resolved-badge">&#10003; Allowed &middot; '
            + '<span class="countdown" data-exp="' + st.expires_at + '">'
            + fmtTTL(Math.max(0, st.expires_at - Math.floor(Date.now()/1000))) + '</span></span>';
      actionCell = '<div class="act-group">' + badge
        + '<button class="btn-sm btn-danger" data-action="remove-allow">Remove allow</button>'
        + '</div>';
    } else {
      // Collapsed by default to one button; the options expand inline on click.
      actionCell = '<div class="act-group">'
        + '<button class="btn-sm btn-success" data-action="expand">Allow &#9662;</button>'
        + '</div>';
    }
    return '<tr data-domain="' + esc(b.domain) + '"' + (st ? ' class="resolved"' : '') + '>'
      + '<td class="td-domain">' + esc(b.domain) + '</td>'
      + '<td class="td-ts">' + esc(fmtSquidTs(b.last_seen)) + '</td>'
      + '<td class="td-count">' + b.count + '</td>'
      + '<td>' + actionCell + '</td>'
      + '</tr>';
  }).join('');
}

// ---- Audit log ----
function auditQS() {
  var p = [];
  if (auFrom.value.trim())  p.push('from='   + encodeURIComponent(auFrom.value.trim()));
  if (auTo.value.trim())    p.push('to='     + encodeURIComponent(auTo.value.trim()));
  if (auHost.value.trim())  p.push('host='   + encodeURIComponent(auHost.value.trim()));
  if (auStatus.value)       p.push('status=' + encodeURIComponent(auStatus.value));
  return p;
}

function renderAudit(data) {
  var rows = (data && data.entries) || [];
  if (!rows.length) {
    auBody.innerHTML = '<tr><td class="empty-td" colspan="6">No matching audit entries</td></tr>';
    auMeta.textContent = '';
    return;
  }
  auMeta.textContent = 'Showing ' + rows.length + ' entr' + (rows.length === 1 ? 'y' : 'ies')
    + (data.count >= data.limit ? ' (capped at ' + data.limit + ' \u2014 narrow the range or download CSV for all)' : '');
  auBody.innerHTML = rows.map(function(r) {
    var dec = (r.squid_status && r.squid_status.indexOf('DENIED') >= 0) ? 'denied' : 'allowed';
    return '<tr>'
      + '<td class="td-ts">' + esc(fmtSquidTs(r.ts_text)) + '</td>'
      + '<td><span class="au-dec ' + dec + '">' + dec + '</span></td>'
      + '<td class="td-count" style="text-align:left">' + esc(r.http_code == null ? '-' : r.http_code) + '</td>'
      + '<td>' + esc(r.method || '') + '</td>'
      + '<td class="td-domain">' + esc(r.host || '') + '</td>'
      + '<td class="td-url" title="' + esc(r.url || '') + '">' + esc(r.url || '') + '</td>'
      + '</tr>';
  }).join('');
}

function refreshAudit() {
  var qs = auditQS();
  fetch('/api/audit' + (qs.length ? '?' + qs.join('&') : '')).then(function(r) {
    return r.json().then(function(j) {
      if (!r.ok) throw new Error(j.error || r.statusText);
      renderAudit(j);
    });
  }).catch(function(e) {
    auBody.innerHTML = '<tr><td class="empty-td" colspan="6">Error: ' + esc(e.message) + '</td></tr>';
    auMeta.textContent = '';
  });
}

document.getElementById('auQuery').addEventListener('click', refreshAudit);
document.getElementById('auReset').addEventListener('click', function() {
  auFrom.value = ''; auTo.value = ''; auHost.value = ''; auStatus.value = '';
  refreshAudit();
});
document.getElementById('auDownload').addEventListener('click', function() {
  var qs = auditQS();
  window.location.href = '/api/audit/download' + (qs.length ? '?' + qs.join('&') : '');
});
[auFrom, auTo, auHost].forEach(function(el) {
  el.addEventListener('keydown', function(ev) { if (ev.key === 'Enter') refreshAudit(); });
});
auStatus.addEventListener('change', refreshAudit);

// ---- Event delegation ----
function delegate(tbody, handler) {
  tbody.addEventListener('click', function(ev) {
    var btn = ev.target.closest('button[data-action]');
    if (!btn) return;
    var tr = btn.closest('tr');
    if (!tr) return;
    handler(btn, tr, btn.dataset.action, btn.dataset.ttl);
  });
}

featB.addEventListener('click', function(ev) {
  var btn = ev.target.closest('button[data-action="toggle"]');
  if (!btn) return;
  var tr = btn.closest('tr');
  if (!tr || !tr.dataset.feature) return;
  doToggleFeature(tr.dataset.feature, tr.dataset.enabled !== '1');
});

delegate(permB, function(btn, tr, action) {
  if (action === 'deny' && tr.dataset.domain) doRemove(tr.dataset.domain);
});
delegate(tempB, function(btn, tr, action) {
  if (action === 'deny' && tr.dataset.domain) doRemove(tr.dataset.domain);
});
delegate(blkB, function(btn, tr, action, ttl) {
  var domain = tr.dataset.domain;
  if (!domain) return;
  if      (action === 'allow-perm')   doAllow(domain, null);
  else if (action === 'allow-ttl')    doAllow(domain, parseInt(ttl, 10));
  else if (action === 'expand')       expandAllow(btn, domain);
  else if (action === 'custom')       showCustom(btn, domain);
  else if (action === 'collapse')     refreshBlocks();
  else if (action === 'remove-allow') doRemove(domain);
});

// ---- Manual add (Allowlist panel) ----
function doManualAdd() {
  var domain = (addDomain.value || '').trim();
  if (!domain) { toast('Enter a domain', false); return; }
  var ttl = addTTL.value ? parseInt(addTTL.value, 10) : null;
  doAllow(domain, ttl);
  addDomain.value = '';
}
addBtn.addEventListener('click', doManualAdd);
addDomain.addEventListener('keydown', function(ev) {
  if (ev.key === 'Enter') doManualAdd();
});

// Expand the single "Allow" button into the full set of choices, inline.
function expandAllow(triggerBtn, domain) {
  var grp = triggerBtn.closest('.act-group');
  grp.innerHTML =
    '<button class="btn-sm btn-success" data-action="allow-perm">Permanent</button>'
    + '<button class="btn-sm" data-action="allow-ttl" data-ttl="300">5m</button>'
    + '<button class="btn-sm" data-action="allow-ttl" data-ttl="900">15m</button>'
    + '<button class="btn-sm" data-action="allow-ttl" data-ttl="3600">1h</button>'
    + '<button class="btn-sm" data-action="custom">Custom&#8230;</button>'
    + '<button class="btn-sm btn-icon" data-action="collapse" title="Cancel">&#10005;</button>';
}

function showCustom(triggerBtn, domain) {
  var grp = triggerBtn.closest('.act-group');
  grp.innerHTML =
    '<input type="number" min="1" placeholder="seconds" style="width:75px" class="csec">'
    + '<button class="btn-sm btn-primary cok">Allow</button>'
    + '<button class="btn-sm ccancel">Cancel</button>';
  var inp = grp.querySelector('.csec');
  inp.focus();
  function submit() {
    var v = parseInt(inp.value, 10);
    if (!v || v < 1) { toast('Enter a positive number of seconds', false); return; }
    doAllow(domain, v);
  }
  grp.querySelector('.cok').addEventListener('click', submit);
  grp.querySelector('.ccancel').addEventListener('click', function(){ refreshBlocks(); });
  inp.addEventListener('keydown', function(ev) {
    if (ev.key === 'Enter')  submit();
    if (ev.key === 'Escape') refreshBlocks();
  });
}

// ---- API actions ----
function doAllow(domain, ttl) {
  var body = { domain: domain };
  if (ttl !== null && ttl !== undefined) body.ttl_seconds = ttl;
  post('/api/allow', body).then(function() {
    toast('Allowed ' + domain + (ttl ? ' (' + ttl + 's)' : ' permanently'));
    var det = document.getElementById('allowlistDetails');
    if (det) det.open = true;
    refreshAll();
  }).catch(function(e){ toast('Error: ' + e.message, false); });
}

function doRemove(domain) {
  post('/api/deny', { domain: domain }).then(function() {
    toast('Removed ' + domain);
    var det = document.getElementById('allowlistDetails');
    if (det) det.open = true;
    refreshAll();
  }).catch(function(e){ toast('Error: ' + e.message, false); });
}

function doToggleFeature(name, enabled) {
  post('/api/feature', { name: name, enabled: enabled }).then(function() {
    toast('Feature ' + name + ' ' + (enabled ? 'enabled' : 'disabled'));
    refreshFeatures();
    refreshAllowlist();
  }).catch(function(e){ toast('Error: ' + e.message, false); });
}

// ---- Polling ----
function refreshFeatures() {
  fetch('/api/features').then(function(r){
    if (r.ok) r.json().then(renderFeatures);
  }).catch(function(){});
}
function refreshAllowlist() {
  fetch('/api/allowlist').then(function(r){
    if (r.ok) r.json().then(renderAllowlist);
  }).catch(function(){});
}
function refreshBlocks() {
  fetch('/api/blocks').then(function(r){
    if (r.ok) r.json().then(renderBlocks);
  }).catch(function(){});
}
function refreshAll() { refreshFeatures(); refreshAllowlist(); refreshBlocks(); }

// Traffic view needs both blocked + allowlist (the resolved-row join).
function refreshTraffic() { refreshAllowlist(); refreshBlocks(); }

// Refresh only the data the active view needs (Audit queries on demand only).
function refreshActiveView() {
  if      (currentView === 'traffic')   refreshTraffic();
  else if (currentView === 'features')  refreshFeatures();
}

function tickCountdowns() {
  var now = Math.floor(Date.now() / 1000);
  document.querySelectorAll('.countdown[data-exp]').forEach(function(el) {
    el.textContent = fmtTTL(Math.max(0, parseInt(el.dataset.exp, 10) - now));
  });
  // Re-arm: if any temporary allow has elapsed, resync so it drops from the
  // allowlist and its blocked row reverts to Allow buttons.
  var expired = currentAllowlist.temporary.some(function(e){ return e.expires_at <= now; });
  if (expired) refreshTraffic();
}

// ---- View router (hash-based) ----
function showView(name) {
  if (VIEWS.indexOf(name) === -1) name = 'traffic';
  currentView = name;
  VIEWS.forEach(function(v) {
    var el = document.getElementById('view-' + v);
    if (el) el.classList.toggle('active', v === name);
  });
  navItems.forEach(function(b) {
    b.classList.toggle('active', b.dataset.view === name);
  });
  if (location.hash !== '#' + name) {
    history.replaceState(null, '', '#' + name);
  }
  // Fetch fresh data for the view we just switched to.
  if      (name === 'traffic')   refreshTraffic();
  else if (name === 'features')  refreshFeatures();
  else if (name === 'audit')     refreshAudit();
  // Keep the live stream pinned to the latest when returning to Traffic.
  if (name === 'traffic' && !paused) sList.scrollTop = sList.scrollHeight;
}

navItems.forEach(function(b) {
  b.addEventListener('click', function(){ showView(b.dataset.view); });
});
window.addEventListener('hashchange', function() {
  showView((location.hash || '').replace('#', '') || 'traffic');
});

// ---- Boot ----
showView((location.hash || '').replace('#', '') || 'traffic');
setInterval(refreshActiveView, 5000);
setInterval(tickCountdowns, 1000);
</script>
</body>
</html>"""

# ---------------------------------------------------------------------------
# HTTP handler
# ---------------------------------------------------------------------------
class _Handler(BaseHTTPRequestHandler):

    def log_message(self, *_args):
        pass  # silence default stdout access log

    def _ok_host(self):
        return self.headers.get("Host", "") in _ALLOWED_HOSTS

    def _send(self, code, ctype, body):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _json(self, data, code=200):
        self._send(code, "application/json", json.dumps(data).encode())

    def _read_body(self):
        try:
            n = int(self.headers.get("Content-Length", 0))
        except ValueError:
            n = 0
        return self.rfile.read(min(max(n, 0), MAX_BODY))

    def _run_cmd(self, cmd):
        """Run a management command; emit a JSON response. Returns nothing."""
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
        except subprocess.TimeoutExpired:
            self._json({"error": "Command timed out"}, 500)
            return
        if r.returncode != 0:
            self._json({"error": (r.stderr or r.stdout or "command failed").strip()}, 500)
            return
        self._json({"ok": True, "message": r.stdout.strip()})

    # ------------------------------------------------------------------
    def do_GET(self):
        if not self._ok_host():
            self._json({"error": "Forbidden"}, 403)
            return
        path = urllib.parse.urlsplit(self.path).path
        if path == "/":
            body = _HTML.encode()
            self._send(200, "text/html; charset=utf-8", body)
        elif path == "/api/allowlist":
            self._json(_read_allowlist())
        elif path == "/api/features":
            self._json(_read_features())
        elif path == "/api/blocks":
            self._json(_read_blocks())
        elif path == "/api/audit":
            self._audit_json()
        elif path == "/api/audit/download":
            self._audit_csv()
        elif path == "/api/stream":
            self._sse()
        else:
            self._json({"error": "Not found"}, 404)

    # ------------------------------------------------------------------
    def do_POST(self):
        if not self._ok_host():
            self._json({"error": "Forbidden"}, 403)
            return
        ct = self.headers.get("Content-Type", "")
        if not ct.startswith("application/json"):
            self._json({"error": "Content-Type must be application/json"}, 415)
            return
        path = urllib.parse.urlsplit(self.path).path
        try:
            body = json.loads(self._read_body())
        except (json.JSONDecodeError, UnicodeDecodeError, ValueError):
            self._json({"error": "Invalid JSON"}, 400)
            return

        if path == "/api/allow":
            domain = body.get("domain", "")
            if not _valid_domain(domain):
                self._json({"error": "Invalid domain"}, 400)
                return
            ttl = body.get("ttl_seconds")
            cmd = [ALLOW_CMD, domain]
            if ttl is not None:
                if not isinstance(ttl, int) or ttl < 1:
                    self._json({"error": "ttl_seconds must be a positive integer"}, 400)
                    return
                cmd.append(str(ttl))
            self._run_cmd(cmd)

        elif path == "/api/deny":
            domain = body.get("domain", "")
            if not _valid_domain(domain):
                self._json({"error": "Invalid domain"}, 400)
                return
            self._run_cmd([DENY_CMD, domain])

        elif path == "/api/feature":
            name = body.get("name", "")
            enabled = body.get("enabled")
            if not _valid_feature(name):
                self._json({"error": "Invalid feature name"}, 400)
                return
            if not isinstance(enabled, bool):
                self._json({"error": "'enabled' must be a boolean"}, 400)
                return
            self._run_cmd([FEATURE_CMD, name, "on" if enabled else "off"])

        else:
            self._json({"error": "Not found"}, 404)

    # ------------------------------------------------------------------
    def _audit_json(self):
        qs = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
        kw, err = _audit_params(qs)
        if err:
            self._json({"error": err}, 400)
            return
        # limit: default 200, capped at AUDIT_MAX_ROWS
        try:
            limit = int(qs.get("limit", ["200"])[0])
        except (ValueError, TypeError):
            limit = 200
        limit = max(1, min(limit, AUDIT_MAX_ROWS))
        kw["limit"] = limit
        try:
            rows = _audit_query(**kw)
        except sqlite3.Error as e:
            self._json({"error": "audit db unavailable: " + str(e)}, 503)
            return
        self._json({"entries": rows, "limit": limit, "count": len(rows)})

    def _audit_csv(self):
        qs = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
        kw, err = _audit_params(qs)
        if err:
            self._json({"error": err}, 400)
            return
        kw["limit"] = None   # download is uncapped
        try:
            rows = _audit_query(**kw)
        except sqlite3.Error as e:
            self._json({"error": "audit db unavailable: " + str(e)}, 503)
            return

        import csv, io
        sio = io.StringIO()
        w = csv.writer(sio)
        w.writerow(["timestamp", "client_ip", "squid_status", "http_code",
                    "method", "url", "host"])
        for r in rows:
            w.writerow([r["ts_text"], r["client_ip"], r["squid_status"],
                        r["http_code"], r["method"], r["url"], r["host"]])
        body = sio.getvalue().encode("utf-8")
        fname = "audit-" + time.strftime("%Y%m%d-%H%M%S") + ".csv"
        self.send_response(200)
        self.send_header("Content-Type", "text/csv; charset=utf-8")
        self.send_header("Content-Disposition",
                         'attachment; filename="' + fname + '"')
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    # ------------------------------------------------------------------
    def _sse(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("X-Accel-Buffering", "no")
        self.send_header("Connection", "keep-alive")
        self.end_headers()

        POLL   = 0.25   # seconds between reads when no new data
        KA_INT = 15.0   # keepalive comment interval

        last_ka = time.monotonic()
        buf     = b""

        try:
            # Wait for log file (container may have just started)
            while not os.path.isfile(LOG_FILE):
                time.sleep(1)
                now = time.monotonic()
                if now - last_ka >= KA_INT:
                    self.wfile.write(b": waiting for log\n\n")
                    self.wfile.flush()
                    last_ka = now

            with open(LOG_FILE, "rb") as fh:
                fh.seek(0, 2)   # start at EOF — no log replay on connect
                while True:
                    chunk = fh.read(65536)
                    if chunk:
                        buf += chunk
                        while b"\n" in buf:
                            line, buf = buf.split(b"\n", 1)
                            raw    = line.decode("utf-8", errors="replace")
                            parsed = _parse_log_line(raw)
                            if parsed:
                                msg = ("event: entry\ndata: "
                                       + json.dumps(parsed) + "\n\n")
                                self.wfile.write(msg.encode())
                                self.wfile.flush()
                                last_ka = time.monotonic()
                    else:
                        now = time.monotonic()
                        if now - last_ka >= KA_INT:
                            self.wfile.write(b": keepalive\n\n")
                            self.wfile.flush()
                            last_ka = now
                        time.sleep(POLL)

        except (BrokenPipeError, ConnectionResetError, OSError):
            pass   # client disconnected — normal

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    server = ThreadingHTTPServer(("0.0.0.0", PORT), _Handler)
    print(f"[dashboard] http://127.0.0.1:{PORT}/", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
