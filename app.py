#!/usr/bin/env python3
# PATH: backend/app.py
#
# WHAT: Flask REST API serving boot_audit.db to the GitHub Pages frontend.
#       Mirrors the receipts-ocr backend pattern: Flask + flask-cors,
#       read-only SQLite access via volume mount, per-request timing logs.
#
# WHY:  GitHub Pages can only serve static files. The boot_audit.db lives
#       on the user's local machine. A local Docker container bridges the
#       gap: Pages frontend (static, hosted) connects to localhost:5002
#       (this container, local). Identical to the receipts-ocr pattern
#       confirmed from README verbatim:
#         "The GitHub Pages demo connects to YOUR local Docker backend at localhost:5001"
#       We use 5002 to avoid conflict with receipts-ocr.
#
# MENTAL MODEL BEFORE: DB is a local file, inaccessible to the Pages frontend.
# MENTAL MODEL AFTER:  DB is served as JSON over HTTP on localhost:5002;
#       the Pages frontend reads it as if it were any REST API.
#
# FAILURE MODE: if DB file is absent or unreadable, /health returns
#       {"status":"error","reason":"..."} — never a silent 500.
#       All endpoints return {"error":"..."} with HTTP 500 on DB failure.
#
# VERIFIES WITH: curl http://localhost:5002/health returns
#       {"status":"ok","row_count":N} where N >= 1.
#
# Source (Tier 2): Flask documentation — "A micro web framework written in Python."
#   https://flask.palletsprojects.com/en/3.0.x/
# Source (Tier 2): flask-cors documentation — "A Flask extension for CORS."
#   https://flask-cors.readthedocs.io/en/latest/
# Source (Tier 4): swipswaps/receipts-ocr backend/app.py — Flask+CORS pattern.
#   https://github.com/swipswaps/receipts-ocr/blob/main/backend/app.py

import logging
import os
import sqlite3
import time
from datetime import datetime
from pathlib import Path
from typing import Any

from flask import Flask, jsonify, request
from flask_cors import CORS

###############################################################################
# Logging setup
###############################################################################

# WHAT: configure structured logging to stdout with ISO timestamps.
# WHY:  Docker captures stdout; structured format makes grep-able.
# Source (Tier 2): Python logging docs — "basicConfig sets the root logger."
#   https://docs.python.org/3/library/logging.html#logging.basicConfig
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S",
)
log = logging.getLogger("boot-audit-api")

###############################################################################
# App + CORS
###############################################################################

app = Flask(__name__)

# WHAT: allow CORS from localhost (dev) and the GitHub Pages origin.
# WHY:  the Pages frontend at swipswaps.github.io makes fetch() calls to
#       localhost:5002. Without CORS headers the browser blocks the request.
# FAILURE MODE: if origins list is wrong, browser shows "CORS error" in console
#       and all API calls fail silently from the frontend's perspective.
# VERIFIES WITH: curl -H "Origin: https://swipswaps.github.io"
#       http://localhost:5002/health — response includes Access-Control-Allow-Origin.
# Source (Tier 2): MDN CORS — "Cross-Origin Resource Sharing."
#   https://developer.mozilla.org/en-US/docs/Web/HTTP/CORS
CORS(app, origins=[
    "http://localhost:5173",
    "http://localhost:3000",
    "http://127.0.0.1:5173",
    "https://swipswaps.github.io",
])

###############################################################################
# Database path resolution
###############################################################################

# WHAT: resolve DB path from env var with a sensible default.
# WHY:  the Docker container mounts the DB at /data/boot_audit.db via volume.
#       The env var allows overriding for local dev without Docker.
# FAILURE MODE: if the path is wrong, all DB calls fail with OperationalError.
#       /health detects and reports this explicitly.
# Source (Tier 2): os.environ.get docs.
#   https://docs.python.org/3/library/os.html#os.environ
_DEFAULT_DB = str(
    Path.home() / ".local" / "share" / "boot-audit" / "boot_audit.db"
)
DB_PATH = os.environ.get("BOOT_AUDIT_DB", _DEFAULT_DB)
log.info("ENTER app-init: DB_PATH=%s", DB_PATH)

###############################################################################
# Database helpers
###############################################################################

def _get_conn() -> sqlite3.Connection:
    """
    WHAT: open a read-only SQLite connection to the boot_audit.db.
    WHY:  read-only prevents accidental writes from the API; the DB is
          owned by boot-audit-db.sh and must not be modified by the UI layer.
    FAILURE MODE: raises sqlite3.OperationalError if file absent or locked.
    VERIFIES WITH: conn.execute("SELECT 1") succeeds without exception.
    Source (Tier 2): sqlite3 URI docs — "mode=ro opens read-only."
      https://docs.python.org/3/library/sqlite3.html#sqlite3.connect
    """
    log.info("ENTER _get_conn: DB_PATH=%s", DB_PATH)
    uri = f"file:{DB_PATH}?mode=ro"
    conn = sqlite3.connect(uri, uri=True)
    conn.row_factory = sqlite3.Row
    log.info("EXIT _get_conn: connection opened")
    return conn


def _rows_to_list(rows: list[sqlite3.Row]) -> list[dict[str, Any]]:
    """
    WHAT: convert sqlite3.Row objects to plain dicts for jsonify().
    WHY:  sqlite3.Row is not JSON-serialisable directly.
    VERIFIES WITH: json.dumps(result) succeeds without TypeError.
    Source (Tier 2): Python sqlite3 — "Row objects support mapping access."
      https://docs.python.org/3/library/sqlite3.html#sqlite3.Row
    """
    return [dict(row) for row in rows]


def _timed_query(sql: str, params: tuple = ()) -> tuple[list[dict], float]:
    """
    WHAT: execute a SELECT query, return rows and elapsed seconds.
    WHY:  every endpoint logs elapsed ms so slow queries are visible.
    FAILURE MODE: raises sqlite3.OperationalError on bad SQL or missing table.
          Caller must handle and return {"error":"..."}.
    VERIFIES WITH: elapsed > 0 always; rows may be empty list.
    Source (Tier 2): Python time.monotonic — "monotonic clock for elapsed time."
      https://docs.python.org/3/library/time.html#time.monotonic
    """
    log.info("ENTER _timed_query: sql=%s params=%s", sql[:80], params)
    t0 = time.monotonic()
    conn = _get_conn()
    try:
        rows = _rows_to_list(conn.execute(sql, params).fetchall())
    finally:
        conn.close()
    elapsed = time.monotonic() - t0
    log.info("EXIT _timed_query: rows=%d elapsed=%.3fs", len(rows), elapsed)
    return rows, elapsed

###############################################################################
# Request logging middleware
###############################################################################

@app.before_request
def _log_request() -> None:
    """
    WHAT: log every incoming request method and path before processing.
    WHY:  Rule L requires every entry point to be logged. Middleware covers
          all endpoints without repeating the log call in each function.
    Source (Tier 2): Flask docs — "before_request runs before each request."
      https://flask.palletsprojects.com/en/3.0.x/api/#flask.Flask.before_request
    """
    log.info("REQUEST: %s %s from=%s", request.method, request.path,
             request.remote_addr)


@app.after_request
def _log_response(response):
    """
    WHAT: log the HTTP status code of every response.
    WHY:  correlates request log with outcome; catches silent 4xx/5xx.
    Source (Tier 2): Flask docs — "after_request runs after each response."
      https://flask.palletsprojects.com/en/3.0.x/api/#flask.Flask.after_request
    """
    log.info("RESPONSE: %s %s -> %d", request.method, request.path,
             response.status_code)
    return response

###############################################################################
# Endpoints
###############################################################################

@app.route("/health")
def health():
    """
    WHAT: liveness + readiness check — confirms DB is readable and has rows.
    WHY:  the frontend polls /health on load to decide whether to show the
          "Docker offline" banner or live data.
    MENTAL MODEL BEFORE: frontend doesn't know if Docker is running.
    MENTAL MODEL AFTER:  frontend receives {"status":"ok","row_count":N}
          and switches to live-data mode.
    FAILURE MODE: if DB is absent, returns {"status":"error","reason":"..."}
          with HTTP 503 — frontend shows offline banner gracefully.
    VERIFIES WITH: curl http://localhost:5002/health | python3 -m json.tool
    Source (Tier 2): Flask docs — jsonify returns application/json response.
      https://flask.palletsprojects.com/en/3.0.x/api/#flask.json.jsonify
    """
    log.info("ENTER health")
    t0 = time.monotonic()
    try:
        rows, _ = _timed_query(
            "SELECT COUNT(*) AS n FROM boot_snapshots"
        )
        count = rows[0]["n"] if rows else 0
        result = {
            "status": "ok",
            "db_path": DB_PATH,
            "db_exists": Path(DB_PATH).exists(),
            "row_count": count,
            "timestamp": datetime.utcnow().isoformat() + "Z",
        }
        log.info("EXIT health: status=ok row_count=%d elapsed=%.3fs",
                 count, time.monotonic() - t0)
        return jsonify(result)
    except Exception as exc:
        log.error("EXIT health: ERROR %s", exc)
        return jsonify({"status": "error", "reason": str(exc)}), 503


@app.route("/boots")
def boots():
    """
    WHAT: return all boot_snapshots rows, newest first.
    WHY:  the Boot History page displays this table with colour-coded
          amdgpu_status (bound=green, failed=red, absent=orange).
    FAILURE MODE: empty list returned if table has no rows.
          DB error returns {"error":"..."} with HTTP 500.
    VERIFIES WITH: curl http://localhost:5002/boots | python3 -m json.tool
          shows array with id, ts, amdgpu_status, boot_type fields.
    Source (Tier 2): SQLite ORDER BY docs.
      https://www.sqlite.org/lang_select.html
    """
    log.info("ENTER boots")
    t0 = time.monotonic()
    try:
        rows, elapsed = _timed_query(
            "SELECT * FROM boot_snapshots ORDER BY id DESC"
        )
        log.info("EXIT boots: rows=%d elapsed=%.3fs", len(rows), elapsed)
        return jsonify({"boots": rows, "count": len(rows)})
    except Exception as exc:
        log.error("EXIT boots: ERROR %s", exc)
        return jsonify({"error": str(exc)}), 500


@app.route("/boots/<int:boot_id>")
def boot_by_id(boot_id: int):
    """
    WHAT: return a single boot_snapshot by primary key.
    WHY:  the diff page fetches two individual rows by ID to compare.
    FAILURE MODE: 404 if ID not found; 500 on DB error.
    VERIFIES WITH: curl http://localhost:5002/boots/2 returns the row
          with id=2 from document 18 (amdgpu_status=bound).
    Source (Tier 2): SQLite WHERE clause docs.
      https://www.sqlite.org/lang_select.html
    """
    log.info("ENTER boot_by_id: boot_id=%d", boot_id)
    t0 = time.monotonic()
    try:
        rows, elapsed = _timed_query(
            "SELECT * FROM boot_snapshots WHERE id = ?", (boot_id,)
        )
        if not rows:
            log.info("EXIT boot_by_id: not found id=%d", boot_id)
            return jsonify({"error": f"boot id {boot_id} not found"}), 404
        log.info("EXIT boot_by_id: found id=%d elapsed=%.3fs",
                 boot_id, elapsed)
        return jsonify(rows[0])
    except Exception as exc:
        log.error("EXIT boot_by_id: ERROR %s", exc)
        return jsonify({"error": str(exc)}), 500


@app.route("/working")
def working():
    """
    WHAT: return all working_states rows, newest first.
    WHY:  the Boot History page marks rows that match a working state
          with a gold star; the diff page uses the latest working state
          as the reference point.
    VERIFIES WITH: curl http://localhost:5002/working returns row with
          id=2, kernel=6.19.10-200.fc43.x86_64 (from document 18).
    Source (Tier 2): SQLite docs. https://www.sqlite.org/lang_select.html
    """
    log.info("ENTER working")
    t0 = time.monotonic()
    try:
        rows, elapsed = _timed_query(
            "SELECT * FROM working_states ORDER BY id DESC"
        )
        log.info("EXIT working: rows=%d elapsed=%.3fs", len(rows), elapsed)
        return jsonify({"working_states": rows, "count": len(rows)})
    except Exception as exc:
        log.error("EXIT working: ERROR %s", exc)
        return jsonify({"error": str(exc)}), 500


@app.route("/failures")
def failures():
    """
    WHAT: return all known_failures rows, newest first.
    WHY:  the Failures page shows severity badges (CATASTROPHIC=red,
          MODERATE=orange, etc.) with verbatim evidence lines.
    VERIFIES WITH: curl http://localhost:5002/failures shows MODERATE rows
          for simpledrm and DC fault (detected in document 18).
    Source (Tier 2): SQLite docs. https://www.sqlite.org/lang_select.html
    """
    log.info("ENTER failures")
    t0 = time.monotonic()
    try:
        rows, elapsed = _timed_query(
            "SELECT * FROM known_failures ORDER BY id DESC"
        )
        log.info("EXIT failures: rows=%d elapsed=%.3fs", len(rows), elapsed)
        return jsonify({"failures": rows, "count": len(rows)})
    except Exception as exc:
        log.error("EXIT failures: ERROR %s", exc)
        return jsonify({"error": str(exc)}), 500


@app.route("/diff/<int:id_a>/<int:id_b>")
def diff(id_a: int, id_b: int):
    """
    WHAT: field-by-field diff between two boot_snapshot rows.
    WHY:  the Diff page lets the user select a failed boot and a working
          boot and see exactly which fields changed. This is the primary
          diagnostic tool: "what was different when the GPU failed?"
    MENTAL MODEL BEFORE: user sees two boot rows but must compare manually.
    MENTAL MODEL AFTER:  every changed field is highlighted as
          {"field":"X","was":"Y","now":"Z"} in the response.
    FAILURE MODE: 404 if either ID is not found.
    VERIFIES WITH: curl http://localhost:5002/diff/1/2 returns list of
          changed fields between the two document-18 boot rows.
    Source (Tier 2): Python dict comparison — standard library.
      https://docs.python.org/3/library/stdtypes.html#dict
    """
    log.info("ENTER diff: id_a=%d id_b=%d", id_a, id_b)
    t0 = time.monotonic()

    # Fields to exclude from diff (internal metadata, not diagnostic)
    SKIP_FIELDS = {"id", "ts", "is_working_state", "shutdown_clean", "notes"}

    try:
        rows_a, _ = _timed_query(
            "SELECT * FROM boot_snapshots WHERE id = ?", (id_a,)
        )
        rows_b, _ = _timed_query(
            "SELECT * FROM boot_snapshots WHERE id = ?", (id_b,)
        )
        if not rows_a:
            return jsonify({"error": f"boot id {id_a} not found"}), 404
        if not rows_b:
            return jsonify({"error": f"boot id {id_b} not found"}), 404

        a, b = rows_a[0], rows_b[0]
        changed = []
        same = []

        all_keys = set(a.keys()) | set(b.keys())
        for key in sorted(all_keys):
            if key in SKIP_FIELDS:
                continue
            val_a = a.get(key)
            val_b = b.get(key)
            if val_a != val_b:
                changed.append({
                    "field": key,
                    "boot_a": val_a,
                    "boot_b": val_b,
                })
            else:
                same.append({"field": key, "value": val_a})

        result = {
            "boot_a": {"id": id_a, "ts": a.get("ts")},
            "boot_b": {"id": id_b, "ts": b.get("ts")},
            "changed_count": len(changed),
            "same_count": len(same),
            "changed": changed,
            "same": same,
        }
        log.info("EXIT diff: changed=%d same=%d elapsed=%.3fs",
                 len(changed), len(same), time.monotonic() - t0)
        return jsonify(result)

    except Exception as exc:
        log.error("EXIT diff: ERROR %s", exc)
        return jsonify({"error": str(exc)}), 500


@app.route("/prompt/latest")
def prompt_latest():
    """
    WHAT: return the contents of the most recent diagnostic prompt file
          from ~/boot-audit-prompts/.
    WHY:  the Prompt page displays this so the user can copy it into
          a new Claude session without leaving the browser.
    FAILURE MODE: 404 if no prompt files exist yet; 500 on read error.
    VERIFIES WITH: curl http://localhost:5002/prompt/latest returns the
          text from ~/boot-audit-prompts/diagnostic-prompt-*.txt.
    Source (Tier 2): Python pathlib — "glob returns matching paths."
      https://docs.python.org/3/library/pathlib.html#pathlib.Path.glob
    """
    log.info("ENTER prompt_latest")
    t0 = time.monotonic()
    try:
        prompt_dir = Path.home() / "boot-audit-prompts"
        # SUPPRESS-REASON: glob raises no exception on empty dir — returns [].
        #   The empty list is handled by the "not files" branch below.
        files = sorted(prompt_dir.glob("diagnostic-prompt-*.txt"))
        if not files:
            log.info("EXIT prompt_latest: no prompt files found")
            return jsonify({
                "error": "no prompt files found",
                "hint": "run: bash boot-audit-db.sh --prompt-only",
            }), 404
        latest = files[-1]
        content = latest.read_text(encoding="utf-8")
        log.info("EXIT prompt_latest: file=%s chars=%d elapsed=%.3fs",
                 latest.name, len(content), time.monotonic() - t0)
        return jsonify({
            "filename": latest.name,
            "path": str(latest),
            "content": content,
            "char_count": len(content),
        })
    except Exception as exc:
        log.error("EXIT prompt_latest: ERROR %s", exc)
        return jsonify({"error": str(exc)}), 500


@app.route("/grub")
def grub():
    """
    WHAT: return all grub_snapshots rows, newest first.
    WHY:  shows GRUB cmdline history — useful for detecting when a kernel
          parameter change coincided with a GPU failure.
    Source (Tier 2): SQLite docs. https://www.sqlite.org/lang_select.html
    """
    log.info("ENTER grub")
    t0 = time.monotonic()
    try:
        rows, elapsed = _timed_query(
            "SELECT * FROM grub_snapshots ORDER BY id DESC"
        )
        log.info("EXIT grub: rows=%d elapsed=%.3fs", len(rows), elapsed)
        return jsonify({"grub_snapshots": rows, "count": len(rows)})
    except Exception as exc:
        log.error("EXIT grub: ERROR %s", exc)
        return jsonify({"error": str(exc)}), 500


###############################################################################
# Main
###############################################################################

if __name__ == "__main__":
    # WHAT: start Flask dev server on all interfaces at port 5002.
    # WHY:  Docker exposes 5002; debug=False in production container.
    #       In development (python app.py directly), debug=True is fine.
    # FAILURE MODE: if port 5002 is in use, Flask raises OSError —
    #   "Address already in use". Fix: stop conflicting process.
    # VERIFIES WITH: curl http://localhost:5002/health returns {"status":"ok"}.
    # Source (Tier 2): Flask docs — app.run() parameters.
    #   https://flask.palletsprojects.com/en/3.0.x/api/#flask.Flask.run
    debug = os.environ.get("FLASK_DEBUG", "0") == "1"
    log.info("ENTER __main__: port=5002 debug=%s DB_PATH=%s", debug, DB_PATH)
    app.run(host="0.0.0.0", port=5002, debug=debug)
