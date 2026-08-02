#!/usr/bin/env python3
"""Colab-local browser input and frame viewer for Monadius.

This intentionally exposes only a loopback HTTP service.  Colab's supported
``serve_kernel_port_as_iframe`` helper turns that port into a notebook output;
the service is not a remote desktop and does not accept shell commands.
"""

from __future__ import annotations

import argparse
import http.server
import json
import os
from pathlib import Path
import re
import socketserver
import tempfile
import time
from urllib.parse import parse_qs, urlparse


PAGE = """<!doctype html>
<html><head><meta charset="utf-8"><title>Monadius</title>
<style>
  html, body { margin: 0; background: #080b14; color: #dce8ff; font-family: sans-serif; }
  #help { padding: 8px 12px; }
  #screen { display: block; width: auto; height: auto; max-width: 100%;
            max-height: calc(100vh - 92px); object-fit: contain; outline: none; }
</style></head><body>
<div id="help">Click the game, then use arrow keys, A (shot/missile), F (power-up), Space (start), G (self-destruct). <span id="state">keys: none</span> · <span id="engine">engine: waiting</span> · <span id="audio-state">audio: click game to enable</span></div>
<audio id="bgm" controls loop></audio>
<img id="screen" tabindex="0" alt="Monadius is starting…" src="/stream.mjpg">
<script>
const screen = document.getElementById('screen');
const state = document.getElementById('state');
const engine = document.getElementById('engine');
const bgm = document.getElementById('bgm');
const audioState = document.getElementById('audio-state');
const held = new Set();
const releases = new Map();
const activeSounds = new Map();
let audioOffset = -1;
let audioUnlocked = false;
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
function audioUrl(path) {
  return '/audio?path=' + encodeURIComponent(path);
}
function playEffect(path, gain) {
  if (!audioUnlocked) return;
  let sound = activeSounds.get(path);
  if (!sound) { sound = new Audio(audioUrl(path)); activeSounds.set(path, sound); }
  sound.volume = gain;
  sound.currentTime = 0;
  sound.play().catch(() => {});
}
function stopEffect(path) {
  const sound = activeSounds.get(path);
  if (!sound) return;
  sound.pause(); sound.currentTime = 0;
}
function applyAudioEvent(event) {
  const [action, path, gain = 1.0] = event;
  if (action === 'bgm') {
    const next = audioUrl(path);
    if (bgm.getAttribute('src') !== next) {
      bgm.pause(); bgm.src = next; bgm.load();
    }
    bgm.volume = gain;
    audioState.textContent = 'audio: ' + path;
    if (audioUnlocked) bgm.play().catch(() => {});
  } else if (action === 'stop-bgm') {
    bgm.pause(); bgm.currentTime = 0;
  } else if (action === 'play') {
    playEffect(path, gain);
  } else if (action === 'stop') {
    stopEffect(path);
  }
}
async function pollAudioEvents() {
  try {
    const response = await fetch('/audio-events?offset=' + audioOffset, {cache:'no-store'});
    if (!response.ok) throw new Error('audio event request failed');
    const update = await response.json();
    audioOffset = update.offset;
    for (const event of update.events) applyAudioEvent(event);
  } catch (_) {
    audioState.textContent = 'audio: bridge unavailable';
  }
  setTimeout(pollAudioEvents, 50);
}
screen.addEventListener('click', () => {
  screen.focus();
  audioUnlocked = true;
  if (bgm.src) bgm.play().catch(() => {});
});
// Resend held controls independently of the operating system's key-repeat
// rate.  Frame delivery uses one continuous MJPEG response below.
setInterval(() => { if (held.size) send(); }, 100);
setInterval(() => {
  fetch('/status?t=' + Date.now(), {cache:'no-store'})
    .then(response => response.ok ? response.text() : Promise.reject())
    .then(value => { engine.textContent = 'engine: ' + value; })
    .catch(() => { engine.textContent = 'engine: unavailable'; });
}, 250);
pollAudioEvents();
</script></body></html>"""


class Handler(http.server.BaseHTTPRequestHandler):
    frame_file: Path
    input_file: Path
    asset_root: Path
    audio_event_file: Path
    status_file: Path

    def log_message(self, _format: str, *_args: object) -> None:
        pass

    def do_GET(self) -> None:
        request = urlparse(self.path)
        if request.path == "/":
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Cache-Control", "no-store, no-cache, must-revalidate")
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
            query = parse_qs(request.query, keep_blank_values=True)
            if "keys" in query:
                write_atomically(self.input_file, query["keys"][0])
            self.send_response(200)
            self.send_header("Content-Type", "image/jpeg")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(self.frame_file.read_bytes())
            return
        if request.path == "/stream.mjpg":
            self.send_response(200)
            self.send_header("Content-Type", "multipart/x-mixed-replace; boundary=frame")
            self.send_header("Cache-Control", "no-store, no-cache, must-revalidate")
            self.end_headers()
            self.stream_frames()
            return
        if request.path == "/audio":
            self.serve_audio(request, head_only=False)
            return
        if request.path == "/audio-events":
            self.serve_audio_events(request)
            return
        if request.path == "/status" and self.status_file.is_file():
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(self.status_file.read_bytes())
            return
        self.send_error(404)

    def do_HEAD(self) -> None:
        request = urlparse(self.path)
        if request.path == "/audio":
            self.serve_audio(request, head_only=True)
            return
        self.send_error(404)

    def serve_audio_events(self, request: object) -> None:
        try:
            requested_offset = int(parse_qs(request.query).get("offset", ["-1"])[0])
        except ValueError:
            requested_offset = -1

        complete_data = b""
        next_offset = 0
        if self.audio_event_file.is_file():
            size = self.audio_event_file.stat().st_size
            snapshot = requested_offset < 0 or requested_offset > size
            start = 0 if snapshot else requested_offset
            with self.audio_event_file.open("rb") as stream:
                stream.seek(start)
                data = stream.read()
            last_newline = data.rfind(b"\n")
            if last_newline >= 0:
                complete_data = data[:last_newline + 1]
                next_offset = start + last_newline + 1
            else:
                next_offset = start
        else:
            snapshot = True

        events = parse_audio_events(complete_data)
        if snapshot:
            current_bgm = None
            for action, path, gain in events:
                if action == "bgm":
                    current_bgm = [path, gain]
                elif action == "stop-bgm":
                    current_bgm = None
            events = [["bgm", current_bgm[0], current_bgm[1]]] if current_bgm else []

        payload = json.dumps({"offset": next_offset, "events": events}).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def serve_audio(self, request: object, head_only: bool) -> None:
        relative = parse_qs(request.query).get("path", [""])[0]
        candidate = (self.asset_root / relative).resolve()
        try:
            candidate.relative_to(self.asset_root)
        except ValueError:
            self.send_error(403)
            return
        if candidate.suffix.lower() != ".wav" or not candidate.is_file():
            self.send_error(404)
            return

        size = candidate.stat().st_size
        start, end, status = 0, size - 1, 200
        range_header = self.headers.get("Range")
        if range_header:
            match = re.fullmatch(r"bytes=(\d*)-(\d*)", range_header.strip())
            if not match:
                self.send_error(416)
                return
            first, last = match.groups()
            if first:
                start = int(first)
                end = min(int(last), size - 1) if last else size - 1
            elif last:
                length = min(int(last), size)
                start, end = size - length, size - 1
            if start > end or start >= size:
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{size}")
                self.end_headers()
                return
            status = 206

        length = end - start + 1
        self.send_response(status)
        self.send_header("Content-Type", "audio/wav")
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(length))
        self.send_header("Cache-Control", "public, max-age=3600")
        if status == 206:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        if head_only:
            return
        try:
            with candidate.open("rb") as stream:
                stream.seek(start)
                remaining = length
                while remaining:
                    chunk = stream.read(min(64 * 1024, remaining))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    remaining -= len(chunk)
        except (BrokenPipeError, ConnectionResetError):
            return

    def stream_frames(self) -> None:
        last_modified = -1
        try:
            while True:
                try:
                    modified = self.frame_file.stat().st_mtime_ns
                except FileNotFoundError:
                    time.sleep(0.005)
                    continue
                if modified == last_modified:
                    time.sleep(0.005)
                    continue
                frame = self.frame_file.read_bytes()
                last_modified = modified
                self.wfile.write(b"--frame\r\n")
                self.wfile.write(b"Content-Type: image/jpeg\r\n")
                self.wfile.write(f"Content-Length: {len(frame)}\r\n\r\n".encode("ascii"))
                self.wfile.write(frame)
                self.wfile.write(b"\r\n")
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            return


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


def parse_audio_events(data: bytes) -> list[list[object]]:
    events: list[list[object]] = []
    for raw_line in data.decode("utf-8", errors="replace").splitlines():
        fields = raw_line.split("\t")
        action = fields[0]
        if action in {"bgm", "play", "stop"} and len(fields) >= 2 and fields[1]:
            try:
                gain = max(0.0, min(1.0, float(fields[2]))) if len(fields) >= 3 else 1.0
            except ValueError:
                gain = 1.0
            events.append([action, fields[1], gain])
        elif action == "stop-bgm":
            events.append([action, "", 1.0])
    return events


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--frame-file", type=Path, required=True)
    parser.add_argument("--input-file", type=Path, required=True)
    parser.add_argument("--asset-root", type=Path, required=True)
    parser.add_argument("--audio-event-file", type=Path, required=True)
    parser.add_argument("--status-file", type=Path, required=True)
    parser.add_argument("--ready-file", type=Path)
    args = parser.parse_args()
    Handler.frame_file = args.frame_file
    Handler.input_file = args.input_file
    Handler.asset_root = args.asset_root.resolve()
    Handler.audio_event_file = args.audio_event_file
    Handler.status_file = args.status_file
    write_atomically(args.input_file, "")
    with ReusableTCPServer(("127.0.0.1", args.port), Handler) as server:
        if args.ready_file is not None:
            write_atomically(args.ready_file, "ready\n")
        print(f"Monadius bridge listening on 127.0.0.1:{args.port}", flush=True)
        server.serve_forever()


if __name__ == "__main__":
    main()
