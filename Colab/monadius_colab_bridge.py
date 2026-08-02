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
import struct
import tempfile
import threading
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
<div id="help">Click the game, then use arrow keys, A (shot/missile), F (power-up), Space (start), G (self-destruct). <span id="state">keys: none</span> · <span id="engine">engine: waiting</span> · <span id="video-state">video: waiting</span> · <span id="audio-state">audio: click game to enable</span></div>
<audio id="bgm" controls loop></audio>
<canvas id="screen" tabindex="0" width="1280" height="1040">Monadius is starting…</canvas>
<script>
const screen = document.getElementById('screen');
const frameContext = screen.getContext('2d', {alpha:false});
frameContext.imageSmoothingEnabled = false;
const state = document.getElementById('state');
const engine = document.getElementById('engine');
const videoState = document.getElementById('video-state');
const bgm = document.getElementById('bgm');
const audioState = document.getElementById('audio-state');
const held = new Set();
const releases = new Map();
const pressedAt = new Map();
const activeSounds = new Map();
const movementTokens = new Set(['left', 'right', 'up', 'down']);
const inputGeneration = Date.now();
let inputSequence = 0;
let audioOffset = -1;
let audioUnlocked = false;
const names = {ArrowLeft:'left', ArrowRight:'right', ArrowUp:'up', ArrowDown:'down',
               ' ':'space', a:'a', A:'a', f:'f', F:'f', g:'g', G:'g'};
function send() {
  const value = [...held].join(' ');
  const sequence = ++inputSequence;
  state.textContent = 'keys: ' + (value || 'none');
  const query = new URLSearchParams({generation:String(inputGeneration),
                                     sequence:String(sequence), value});
  fetch('/keys?' + query.toString(), {cache:'no-store'})
    .catch(() => {
      if (sequence === inputSequence) {
        state.textContent = 'keys: bridge unavailable';
        setTimeout(send, 50);
      }
    });
}
function token(e) {
  if (e.code === 'Space' || e.key === 'Spacebar') return 'space';
  return names[e.key] || (/^[0-9]$/.test(e.key) ? e.key : null);
}
addEventListener('keydown', e => { const k = token(e); if (k) {
  clearTimeout(releases.get(k));
  if (!held.has(k)) {
    held.add(k); pressedAt.set(k, performance.now()); send();
  }
  e.preventDefault();
}});
addEventListener('keyup', e => { const k = token(e); if (k) {
  clearTimeout(releases.get(k));
  const heldFor = performance.now() - (pressedAt.get(k) || 0);
  // Movement must stop at keyup.  Only very short action taps are extended
  // enough for Main's next 16 ms input poll to observe them.
  const delay = movementTokens.has(k) ? 0 : Math.max(0, 80 - heldFor);
  const release = () => { held.delete(k); pressedAt.delete(k); send(); };
  if (delay === 0) release(); else releases.set(k, setTimeout(release, delay));
  e.preventDefault();
}});
addEventListener('blur', () => {
  for (const timeout of releases.values()) clearTimeout(timeout);
  releases.clear(); pressedAt.clear(); held.clear(); send();
});

let displayedFrame = '-1';
let videoFrames = 0;
let videoWindowStarted = performance.now();
const wait = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));
async function displayLatestFrames() {
  while (true) {
    const requestStarted = performance.now();
    try {
      const response = await fetch('/latest-frame?after=' + displayedFrame,
                                   {cache:'no-store'});
      if (response.status === 204) continue;
      if (!response.ok) throw new Error('frame request failed');
      const encoded = await response.arrayBuffer();
      if (encoded.byteLength <= 8) throw new Error('short frame response');
      displayedFrame = new DataView(encoded, 0, 8).getBigUint64(0, false).toString();
      const bitmap = await createImageBitmap(
          new Blob([encoded.slice(8)], {type:'image/jpeg'}));
      if (screen.width !== bitmap.width || screen.height !== bitmap.height) {
        screen.width = bitmap.width; screen.height = bitmap.height;
        frameContext.imageSmoothingEnabled = false;
      }
      frameContext.drawImage(bitmap, 0, 0);
      bitmap.close();

      videoFrames += 1;
      const now = performance.now();
      if (now - videoWindowStarted >= 1000) {
        const fps = (videoFrames * 1000 / (now - videoWindowStarted)).toFixed(1);
        videoState.textContent = 'video: ' + fps + ' fps · ' +
            Math.round(now - requestStarted) + ' ms/frame';
        videoFrames = 0; videoWindowStarted = now;
      }
    } catch (_) {
      videoState.textContent = 'video: reconnecting';
      await wait(100);
    }
  }
}
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
  let retryDelay = 0;
  try {
    const response = await fetch('/audio-events?offset=' + audioOffset, {cache:'no-store'});
    if (!response.ok) throw new Error('audio event request failed');
    const update = await response.json();
    audioOffset = update.offset;
    for (const event of update.events) applyAudioEvent(event);
  } catch (_) {
    audioState.textContent = 'audio: bridge unavailable';
    retryDelay = 250;
  }
  setTimeout(pollAudioEvents, retryDelay);
}
screen.addEventListener('click', () => {
  screen.focus();
  audioUnlocked = true;
  if (bgm.src) bgm.play().catch(() => {});
});
// A retry protects a held direction from a transient proxy request failure;
// ordered sequence numbers prevent an older retry from undoing a newer keyup.
setInterval(() => { if (held.size) send(); }, 250);
setInterval(() => {
  fetch('/status?t=' + Date.now(), {cache:'no-store'})
    .then(response => response.ok ? response.text() : Promise.reject())
    .then(value => { engine.textContent = 'engine: ' + value; })
    .catch(() => { engine.textContent = 'engine: unavailable'; });
}, 500);
send();
displayLatestFrames();
pollAudioEvents();
</script></body></html>"""


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    frame_file: Path
    input_file: Path
    asset_root: Path
    audio_event_file: Path
    status_file: Path
    input_lock = threading.Lock()
    input_generation = -1
    input_sequence = -1

    def log_message(self, _format: str, *_args: object) -> None:
        pass

    def do_GET(self) -> None:
        request = urlparse(self.path)
        if request.path == "/":
            payload = PAGE.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Cache-Control", "no-store, no-cache, must-revalidate")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        if request.path == "/keys":
            self.accept_keys(request)
            return
        if request.path == "/frame.jpg" and self.frame_file.is_file():
            payload = self.frame_file.read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "image/jpeg")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        if request.path == "/latest-frame":
            self.serve_latest_frame(request)
            return
        if request.path == "/audio":
            self.serve_audio(request, head_only=False)
            return
        if request.path == "/audio-events":
            self.serve_audio_events(request)
            return
        if request.path == "/status" and self.status_file.is_file():
            payload = self.status_file.read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        self.send_error(404)

    def accept_keys(self, request: object) -> None:
        query = parse_qs(request.query, keep_blank_values=True)
        try:
            generation = int(query.get("generation", ["-1"])[0])
            sequence = int(query.get("sequence", ["-1"])[0])
        except ValueError:
            self.send_error(400, "Invalid input sequence")
            return
        value = query.get("value", [""])[0]
        with self.input_lock:
            is_newer = generation > self.input_generation or (
                generation == self.input_generation and sequence > self.input_sequence)
            if is_newer:
                write_atomically(self.input_file, value)
                type(self).input_generation = generation
                type(self).input_sequence = sequence
        self.send_response(204)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def serve_latest_frame(self, request: object) -> None:
        try:
            after = int(parse_qs(request.query).get("after", ["-1"])[0])
        except ValueError:
            after = -1
        deadline = time.monotonic() + 10.0
        while True:
            try:
                if self.frame_file.stat().st_mtime_ns > after:
                    with self.frame_file.open("rb") as stream:
                        modified = os.fstat(stream.fileno()).st_mtime_ns
                        if modified > after:
                            frame = stream.read()
                            break
            except FileNotFoundError:
                pass
            if time.monotonic() >= deadline:
                self.send_response(204)
                self.send_header("Cache-Control", "no-store")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            time.sleep(0.004)

        payload = struct.pack(">Q", modified) + frame
        self.send_response(200)
        self.send_header("Content-Type", "application/x-monadius-frame")
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("X-Monadius-Frame", str(modified))
        self.end_headers()
        try:
            self.wfile.write(payload)
        except (BrokenPipeError, ConnectionResetError):
            return

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

        snapshot = requested_offset < 0
        deadline = time.monotonic() + 2.0
        while True:
            complete_data = b""
            next_offset = 0
            if self.audio_event_file.is_file():
                size = self.audio_event_file.stat().st_size
                snapshot = snapshot or requested_offset > size
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
            if snapshot or complete_data or time.monotonic() >= deadline:
                break
            time.sleep(0.01)

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
        try:
            self.wfile.write(payload)
        except (BrokenPipeError, ConnectionResetError):
            return

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
                self.send_header("Content-Length", "0")
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
