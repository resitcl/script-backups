#!/usr/bin/env bash
# status-server.sh — minimal HTTP server that exposes backup_status.json
# so n8n (or any external tool) can poll it.
#
# Usage:  ./status-server.sh [port]   (default: 8099)
# Systemd unit: see status-server.service
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "${SCRIPT_DIR}/.env" ]] && source "${SCRIPT_DIR}/.env"

STATUS_FILE="${STATUS_FILE:-/var/www/backup-status/status.json}"
PORT="${1:-8099}"

require() { command -v "$1" &>/dev/null || { echo "Required: $1"; exit 1; }; }
require python3

echo "Serving backup status on http://0.0.0.0:${PORT}/status"
echo "Status file: ${STATUS_FILE}"

# One-liner HTTP server: always serves STATUS_FILE at GET /status
python3 - "$PORT" "$STATUS_FILE" <<'PYEOF'
import sys, http.server, json, os, pathlib

port        = int(sys.argv[1])
status_path = pathlib.Path(sys.argv[2])

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print(f"[{self.log_date_time_string()}] {self.address_string()} – {fmt % args}")

    def send_json(self, code, body):
        data = json.dumps(body, indent=2).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path not in ("/status", "/status/"):
            self.send_json(404, {"error": "not found"})
            return
        if not status_path.exists():
            self.send_json(503, {"error": "no status file yet", "path": str(status_path)})
            return
        try:
            payload = json.loads(status_path.read_text())
            http_code = 200 if payload.get("overall") == "success" else 503
            self.send_json(http_code, payload)
        except Exception as e:
            self.send_json(500, {"error": str(e)})

    def do_HEAD(self):
        self.do_GET()   # n8n health-check style ping

httpd = http.server.HTTPServer(("0.0.0.0", port), Handler)
httpd.serve_forever()
PYEOF
