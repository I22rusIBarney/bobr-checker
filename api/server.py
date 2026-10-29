#!/usr/bin/env python3
"""
Bobr Checker — Group Management API
Lightweight microservice to manage group display names persistently.
Zero third-party dependencies (Python 3 standard library only).
"""

import json
import os
import re
import sys
from http.server import HTTPServer, BaseHTTPRequestHandler

DATA_DIR = os.environ.get("DATA_DIR", "/data")
GROUPS_FILE = os.path.join(DATA_DIR, "groups.json")

VALID_IDS = {"my", "friend1", "friend2"}

DEFAULT_GROUPS = [
    {"id": "my", "name": "Моя группа"},
    {"id": "friend1", "name": "Друг 1"},
    {"id": "friend2", "name": "Друг 2"},
]

def ensure_data_dir():
    try:
        os.makedirs(DATA_DIR, exist_ok=True)
    except Exception as e:
        print(f"[ERROR] Failed to create data dir {DATA_DIR}: {e}", file=sys.stderr)

def read_groups():
    ensure_data_dir()
    if not os.path.exists(GROUPS_FILE):
        write_groups(DEFAULT_GROUPS)
        return DEFAULT_GROUPS
    try:
        with open(GROUPS_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
            if isinstance(data, list) and len(data) > 0:
                # Ensure all valid IDs are present
                existing_ids = {g.get("id") for g in data if isinstance(g, dict)}
                updated = list(data)
                for default_g in DEFAULT_GROUPS:
                    if default_g["id"] not in existing_ids:
                        updated.append(default_g)
                return updated
    except Exception as e:
        print(f"[WARN] Error reading {GROUPS_FILE}: {e}", file=sys.stderr)
    return DEFAULT_GROUPS

def write_groups(groups):
    ensure_data_dir()
    tmp_file = GROUPS_FILE + ".tmp"
    try:
        with open(tmp_file, "w", encoding="utf-8") as f:
            json.dump(groups, f, ensure_ascii=False, indent=2)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp_file, GROUPS_FILE)
        return True
    except Exception as e:
        print(f"[ERROR] Failed to save {GROUPS_FILE}: {e}", file=sys.stderr)
        if os.path.exists(tmp_file):
            try:
                os.remove(tmp_file)
            except Exception:
                pass
        return False

class GroupHandler(BaseHTTPRequestHandler):
    def send_cors_headers(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, Authorization")

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_cors_headers()
        self.end_headers()

    def do_GET(self):
        path = self.path.split("?")[0].rstrip("/")
        if path == "/health":
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_cors_headers()
            self.end_headers()
            self.wfile.write(b'{"status":"ok"}')
            return

        if path in ("/api/groups", "/groups"):
            groups = read_groups()
            payload = json.dumps({"success": True, "groups": groups}, ensure_ascii=False)
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Cache-Control", "no-cache, no-store, must-revalidate")
            self.send_cors_headers()
            self.end_headers()
            self.wfile.write(payload.encode("utf-8"))
            return

        self.send_response(404)
        self.send_cors_headers()
        self.end_headers()
        self.wfile.write(b'{"success":false,"error":"Not Found"}')

    def do_POST(self):
        path = self.path.split("?")[0].rstrip("/")
        if path not in ("/api/groups", "/groups"):
            self.send_response(404)
            self.send_cors_headers()
            self.end_headers()
            self.wfile.write(b'{"success":false,"error":"Not Found"}')
            return

        content_len = int(self.headers.get("Content-Length", 0))
        if content_len <= 0 or content_len > 16384:
            self.send_response(400)
            self.send_cors_headers()
            self.end_headers()
            self.wfile.write(b'{"success":false,"error":"Invalid content length"}')
            return

        try:
            body = self.rfile.read(content_len).decode("utf-8")
            data = json.loads(body)
        except Exception:
            self.send_response(400)
            self.send_cors_headers()
            self.end_headers()
            self.wfile.write(b'{"success":false,"error":"Invalid JSON"}')
            return

        target_id = str(data.get("id", "")).strip()
        new_name = str(data.get("name", "")).strip()

        if target_id not in VALID_IDS:
            self.send_response(400)
            self.send_cors_headers()
            self.end_headers()
            msg = f"Unknown group ID '{target_id}'. Valid IDs: {', '.join(sorted(VALID_IDS))}"
            self.wfile.write(json.dumps({"success": False, "error": msg}, ensure_ascii=False).encode("utf-8"))
            return

        if not new_name:
            self.send_response(400)
            self.send_cors_headers()
            self.end_headers()
            self.wfile.write(b'{"success":false,"error":"Group name cannot be empty"}')
            return

        if len(new_name) > 40:
            self.send_response(400)
            self.send_cors_headers()
            self.end_headers()
            self.wfile.write(b'{"success":false,"error":"Group name too long (max 40 characters)"}')
            return

        # Sanitize name: remove control characters and forbidden HTML/script chars
        new_name = re.sub(r'[\x00-\x1f\x7f<>"\']', '', new_name).strip()
        if not new_name:
            self.send_response(400)
            self.send_cors_headers()
            self.end_headers()
            self.wfile.write(b'{"success":false,"error":"Group name contains invalid characters"}')
            return

        groups = read_groups()
        found = False
        for g in groups:
            if g.get("id") == target_id:
                g["name"] = new_name
                found = True
                break

        if not found:
            groups.append({"id": target_id, "name": new_name})

        if write_groups(groups):
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_cors_headers()
            self.end_headers()
            resp = json.dumps({"success": True, "updated": target_id, "name": new_name, "groups": groups}, ensure_ascii=False)
            self.wfile.write(resp.encode("utf-8"))
        else:
            self.send_response(500)
            self.send_cors_headers()
            self.end_headers()
            self.wfile.write(b'{"success":false,"error":"Failed to write groups file on server"}')

    def log_message(self, format, *args):
        # Keep logs concise
        sys.stderr.write("[API] " + (format % args) + "\n")

def run():
    ensure_data_dir()
    port = int(os.environ.get("PORT", "8080"))
    server_address = ("0.0.0.0", port)
    httpd = HTTPServer(server_address, GroupHandler)
    print(f"[INFO] Bobr Group API server running on port {port}, data file: {GROUPS_FILE}", flush=True)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()

if __name__ == "__main__":
    run()
