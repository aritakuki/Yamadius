#!/usr/bin/env python3
"""Colab-local browser input and frame viewer for Monadius.

This intentionally exposes only a loopback HTTP service.  Colab's supported
``serve_kernel_port_as_iframe`` helper turns that port into a notebook output;
the service is not a remote desktop and does not accept shell commands.
"""

from __future__ import annotations

import argparse
import http.server
import os
from pathlib import Path
import socketserver
import tempfile
from urllib.parse import parse_qs, urlparse


PAGE = """<!doctype html>
<html><head><meta charset="utf-8"><title>Monadius</title>
<style>
  html, body { margin: 0; background: #080b14; color: #dce8ff; font-family: sans-serif; }
  #help { padding: 8px 12px; } #screen { display: block; width: 100%; max-width: 1280px; outline: none; }
</style></head><body>
<div id="help">Click the game, then use arrow keys, A (shot/missile), F (power-up), Space (start), G (self-destruct). <span id="state">keys: none</span></div>
<audio id="bgm" controls loop src="/bgm.wav"></audio>
<img id="screen" tabindex="0" alt="Monadius is starting…" src="/frame.jpg">
<script>
const screen = document.getElementById('screen');
const state = document.getElementById('state');
const bgm = document.getElementById('bgm');
const held = new Set();
const releases = new Map();
const names = {ArrowLeft:'left', ArrowRight:'right', ArrowUp:'up', ArrowDown:'down',
               ' ':'space', a:'a', A:'a', f:'f', F:'f', g:'g', G:'g'};
function send() {
  const value = [...held].join(' ');
  state.textContent = 'keys: ' + (value || 'none');
  fetch('/keys?value=' + encodeURIComponent(value), {cache:'no-store'})
    .catch(() => { state.textContent = 'keys: bridge unavailable'; });
}
function token(e) {
  if (e.code === 'Space' || e.key === 'Spacebar') return 'space';
  return names[e.key] || (/^[0-9]$/.test(e.key) ? e.key : null);
}
// Main polls a file once per frame, unlike GLUT's native key-down callback.
// Retain a released key briefly so a normal tap (especially Space on title)
// cannot occur entirely between two polls.  Held movement keys remain held.
addEventListener('keydown', e => { const k = token(e); if (k) {
  clearTimeout(releases.get(k)); held.add(k); send(); e.preventDefault();
}});
addEventListener('keyup', e => { const k = token(e); if (k) {
  releases.set(k, setTimeout(() => { held.delete(k); send(); }, 120)); e.preventDefault();
}});
addEventListener('blur', () => { held.clear(); send(); });
screen.addEventListener('click', () => { screen.focus(); bgm.play().catch(() => {}); });
// Do not depend on the browser's key-repeat rate.  Colab's iframe proxy also
// transfers JPEG frames, so resend held controls while the key is down.
setInterval(() => { if (held.size) send(); }, 100);
setInterval(() => { screen.src = '/frame.jpg?t=' + Date.now(); }, 1000 / 20);
</script></body></html>"""


class Handler(http.server.BaseHTTPRequestHandler):
    frame_file: Path
    input_file: Path
    audio_file: Path

    def log_message(self, _format: str, *_args: object) -> None:
        pass

    def do_GET(self) -> None:
        request = urlparse(self.path)
        if request.path == "/":
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(PAGE.encode("utf-8"))
            return
        if request.path == "/keys":
            value = parse_qs(request.query).get("value", [""])[0]
            write_atomically(self.input_file, value)
            self.send_response(204)
            self.end_headers()
            return
        if request.path == "/frame.jpg" and self.frame_file.is_file():
            self.send_response(200)
            self.send_header("Content-Type", "image/jpeg")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(self.frame_file.read_bytes())
            return
        if request.path == "/bgm.wav" and self.audio_file.is_file():
            self.send_response(200)
            self.send_header("Content-Type", "audio/wav")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(self.audio_file.read_bytes())
            return
        self.send_error(404)


class ReusableTCPServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    # Fresh Start can replace a bridge whose TCP connection has only just
    # closed.  Without this, Linux may reject the replacement with EADDRINUSE
    # while the old socket is in TIME_WAIT.
    allow_reuse_address = True
    daemon_threads = True


def write_atomically(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", dir=path.parent, delete=False) as stream:
        stream.write(content)
        temporary_name = stream.name
    os.replace(temporary_name, path)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--frame-file", type=Path, required=True)
    parser.add_argument("--input-file", type=Path, required=True)
    parser.add_argument("--audio-file", type=Path, required=True)
    parser.add_argument("--ready-file", type=Path)
    args = parser.parse_args()
    Handler.frame_file = args.frame_file
    Handler.input_file = args.input_file
    Handler.audio_file = args.audio_file
    write_atomically(args.input_file, "")
    with ReusableTCPServer(("127.0.0.1", args.port), Handler) as server:
        if args.ready_file is not None:
            write_atomically(args.ready_file, "ready\n")
        print(f"Monadius bridge listening on 127.0.0.1:{args.port}", flush=True)
        server.serve_forever()


if __name__ == "__main__":
    main()
