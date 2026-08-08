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
import sys
import tempfile
import threading
import time
from urllib.parse import parse_qs, urlparse


FRAME_STREAM_INTERVAL_SECONDS = 1.0 / 30.0
AUDIO_RANGE_CHUNK_BYTES = 256 * 1024
MAX_EFFECT_EVENT_AGE_MILLISECONDS = 1000
INPUT_LEASE_SECONDS = 1.0


PAGE = """<!doctype html>
<html><head><meta charset="utf-8"><title>Monadius</title>
<style>
  html, body { margin: 0; background: #080b14; color: #dce8ff; font-family: sans-serif; }
  #help { padding: 8px 12px; }
  #open-window { margin-right: 8px; padding: 5px 10px; cursor: pointer; }
  #detached-message { display: none; min-height: 360px; box-sizing: border-box;
                      padding: 120px 24px; text-align: center; color: #aebbd2; }
  #screen { display: block; width: auto; height: auto; max-width: 100%;
            max-height: calc(100vh - 92px); object-fit: contain; outline: none; }
  body.detached #screen, body.detached #bgm { display: none; }
  body.detached #detached-message { display: block; }
</style></head><body>
<div id="help"><button id="open-window" type="button">別ウィンドウで開く</button>Click the game, then use arrow keys, A (shot/missile), F (power-up), Space (start), G (self-destruct). <span id="state">keys: none</span> · <span id="engine">engine: waiting</span> · <span id="video-state">video: waiting</span> · <span id="audio-state">audio: click game to enable</span></div>
<audio id="bgm" controls loop preload="auto"></audio>
<canvas id="screen" tabindex="0" width="1280" height="1040">Monadius is starting…</canvas>
<div id="detached-message">ゲームは別ウィンドウで実行中です。上のボタンでゲーム画面を前面に戻せます。</div>
<script>
const inlineScreen = document.getElementById('screen');
const inlineFrameContext = inlineScreen.getContext('2d', {alpha:false});
let activeScreen = inlineScreen;
let frameContext = inlineFrameContext;
frameContext.imageSmoothingEnabled = false;
const openWindowButton = document.getElementById('open-window');
const state = document.getElementById('state');
const engine = document.getElementById('engine');
const videoState = document.getElementById('video-state');
const bgm = document.getElementById('bgm');
const audioState = document.getElementById('audio-state');
let gameWindow = null;
let gameWindowScreen = null;
const held = new Set();
const releases = new Map();
const pressedAt = new Map();
const activeSounds = new Map();
const movementTokens = new Set(['left', 'right', 'up', 'down']);
const inputGeneration = Date.now();
let inputSequence = 0;
let pendingInput = null;
let inputInFlight = null;
let inputFlushTimer = null;
let audioOffset = -1;
let audioUnlocked = false;
const names = {ArrowLeft:'left', ArrowRight:'right', ArrowUp:'up', ArrowDown:'down',
               ' ':'space', a:'a', A:'a', f:'f', F:'f', g:'g', G:'g'};
function inputValue() {
  return [...held].join(' ');
}
function scheduleInputFlush(delay) {
  if (inputFlushTimer !== null) clearTimeout(inputFlushTimer);
  inputFlushTimer = setTimeout(() => {
    inputFlushTimer = null;
    flushInput();
  }, delay);
}
function send() {
  const value = inputValue();
  const next = {sequence: ++inputSequence, value};
  pendingInput = next;
  state.textContent = 'keys: ' + (value || 'none');

  // A release or changed direction must not wait behind the old snapshot.
  // Heartbeats with the same value leave the current request alone.
  if (inputInFlight !== null && inputInFlight.value !== value) {
    inputInFlight.controller.abort();
  }
  scheduleInputFlush(0);
}
async function flushInput() {
  if (inputInFlight !== null || pendingInput === null) return;
  const snapshot = pendingInput;
  pendingInput = null;
  const controller = new AbortController();
  inputInFlight = {...snapshot, controller};
  const timeout = setTimeout(() => controller.abort(), 1500);
  let retryDelay = 0;
  try {
    const query = new URLSearchParams({generation:String(inputGeneration),
                                       sequence:String(snapshot.sequence),
                                       value:snapshot.value});
    const response = await fetch('/keys?' + query.toString(), {
      cache:'no-store', signal:controller.signal, priority:'high'
    });
    if (!response.ok) throw new Error('input request failed');
    if (pendingInput === null && inputValue() === snapshot.value) {
      state.textContent = 'keys: ' + (snapshot.value || 'none');
    }
  } catch (_) {
    // Keep only the newest unsent snapshot.  An aborted request may already
    // have reached the bridge; repeating its sequence is safe and bounded.
    const hasNewerSnapshot = pendingInput !== null &&
                             pendingInput.sequence > snapshot.sequence;
    if (pendingInput === null || pendingInput.sequence < snapshot.sequence) {
      pendingInput = snapshot;
    }
    state.textContent = 'keys: ' + (inputValue() || 'none') + ' · retrying';
    retryDelay = hasNewerSnapshot ? 0 : 50;
  } finally {
    clearTimeout(timeout);
    if (inputInFlight !== null && inputInFlight.sequence === snapshot.sequence) {
      inputInFlight = null;
    }
    if (pendingInput !== null) scheduleInputFlush(retryDelay);
  }
}
function token(e) {
  if (e.code === 'Space' || e.key === 'Spacebar') return 'space';
  return names[e.key] || (/^[0-9]$/.test(e.key) ? e.key : null);
}
function handleKeyDown(e) { const k = token(e); if (k) {
  clearTimeout(releases.get(k));
  if (!held.has(k)) {
    held.add(k); pressedAt.set(k, performance.now()); send();
  }
  e.preventDefault();
}}
function handleKeyUp(e) { const k = token(e); if (k) {
  clearTimeout(releases.get(k));
  const heldFor = performance.now() - (pressedAt.get(k) || 0);
  // Movement must stop at keyup.  Only very short action taps are extended
  // enough for Main's next 16 ms input poll to observe them.
  const delay = movementTokens.has(k) ? 0 : Math.max(0, 80 - heldFor);
  const release = () => { held.delete(k); pressedAt.delete(k); send(); };
  if (delay === 0) release(); else releases.set(k, setTimeout(release, delay));
  e.preventDefault();
}}
function releaseAllKeys() {
  for (const timeout of releases.values()) clearTimeout(timeout);
  releases.clear(); pressedAt.clear(); held.clear(); send();
}
function attachInput(targetWindow) {
  targetWindow.addEventListener('keydown', handleKeyDown);
  targetWindow.addEventListener('keyup', handleKeyUp);
  targetWindow.addEventListener('blur', releaseAllKeys);
}
attachInput(window);

let pendingFrame = null;
let frameWaiter = null;
let displayedFrames = 0;
let droppedFrames = 0;
let videoWindowStarted = performance.now();
const wait = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));
const headerBreak = new Uint8Array([13, 10, 13, 10]);
const headerDecoder = new TextDecoder('ascii');
function findBytes(haystack, needle) {
  outer: for (let i = 0; i <= haystack.length - needle.length; ++i) {
    for (let j = 0; j < needle.length; ++j) {
      if (haystack[i + j] !== needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}
function appendBytes(first, second) {
  if (first.length === 0) return second;
  const joined = new Uint8Array(first.length + second.length);
  joined.set(first); joined.set(second, first.length);
  return joined;
}
function queueLatestFrame(sequence, jpeg) {
  if (pendingFrame !== null) droppedFrames += 1;
  pendingFrame = {sequence, jpeg};
  if (frameWaiter !== null) {
    const wake = frameWaiter;
    frameWaiter = null;
    wake();
  }
}
async function takeLatestFrame() {
  while (pendingFrame === null) {
    await new Promise(resolve => { frameWaiter = resolve; });
  }
  const frame = pendingFrame;
  pendingFrame = null;
  return frame;
}
async function receiveFrameStream() {
  while (true) {
    try {
      const response = await fetch('/frame-stream?t=' + Date.now(), {cache:'no-store'});
      if (!response.ok || response.body === null) throw new Error('frame stream failed');
      const reader = response.body.getReader();
      let buffered = new Uint8Array(0);
      while (true) {
        const update = await reader.read();
        if (update.done) throw new Error('frame stream ended');
        buffered = appendBytes(buffered, update.value);
        while (true) {
          const headerEnd = findBytes(buffered, headerBreak);
          if (headerEnd < 0) {
            if (buffered.length > 8192) throw new Error('invalid frame header');
            break;
          }
          const header = headerDecoder.decode(buffered.subarray(0, headerEnd));
          const lengthMatch = /Content-Length:\s*(\d+)/i.exec(header);
          const sequenceMatch = /X-Monadius-Frame:\s*(\d+)/i.exec(header);
          if (!lengthMatch || !sequenceMatch) throw new Error('invalid frame metadata');
          const length = Number(lengthMatch[1]);
          if (!Number.isSafeInteger(length) || length <= 0 || length > 32 * 1024 * 1024) {
            throw new Error('invalid frame length');
          }
          const jpegStart = headerEnd + headerBreak.length;
          const jpegEnd = jpegStart + length;
          if (buffered.length < jpegEnd + 2) break;
          queueLatestFrame(sequenceMatch[1], buffered.slice(jpegStart, jpegEnd));
          buffered = buffered.slice(jpegEnd + 2);
        }
      }
    } catch (_) {
      videoState.textContent = 'video: reconnecting';
      await wait(100);
    }
  }
}
async function displayLatestFrames() {
  while (true) {
    const frame = await takeLatestFrame();
    try {
      const bitmap = await createImageBitmap(new Blob([frame.jpeg], {type:'image/jpeg'}));
      if (activeScreen.width !== bitmap.width || activeScreen.height !== bitmap.height) {
        activeScreen.width = bitmap.width; activeScreen.height = bitmap.height;
        frameContext.imageSmoothingEnabled = false;
      }
      frameContext.drawImage(bitmap, 0, 0);
      bitmap.close();

      displayedFrames += 1;
      const now = performance.now();
      if (now - videoWindowStarted >= 1000) {
        const fps = (displayedFrames * 1000 / (now - videoWindowStarted)).toFixed(1);
        videoState.textContent = 'video: ' + fps + ' fps · dropped ' + droppedFrames;
        displayedFrames = 0; droppedFrames = 0; videoWindowStarted = now;
      }
    } catch (_) {
      videoState.textContent = 'video: decode error';
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
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 3000);
  try {
    const response = await fetch('/audio-events?offset=' + audioOffset,
                                 {cache:'no-store', signal:controller.signal});
    if (!response.ok) throw new Error('audio event request failed');
    const update = await response.json();
    audioOffset = update.offset;
    for (const event of update.events) applyAudioEvent(event);
  } catch (_) {
    audioState.textContent = 'audio: bridge unavailable';
    retryDelay = controller.signal.aborted ? 50 : 250;
  } finally {
    clearTimeout(timeout);
  }
  setTimeout(pollAudioEvents, retryDelay);
}
async function pollStatus() {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 1000);
  const retryDelay = 500;
  try {
    const response = await fetch('/status?t=' + Date.now(),
                                 {cache:'no-store', signal:controller.signal});
    if (!response.ok) throw new Error('status request failed');
    engine.textContent = 'engine: ' + await response.text();
  } catch (_) {
    if (!controller.signal.aborted) engine.textContent = 'engine: unavailable';
  } finally {
    clearTimeout(timeout);
  }
  setTimeout(pollStatus, retryDelay);
}
function enableAudio() {
  audioUnlocked = true;
  if (bgm.src) bgm.play().catch(() => {});
}
inlineScreen.addEventListener('click', () => {
  inlineScreen.focus();
  enableAudio();
});
function closeGameWindowState(closingWindow) {
  if (gameWindow !== closingWindow) return;
  releaseAllKeys();
  gameWindow = null;
  gameWindowScreen = null;
  activeScreen = inlineScreen;
  frameContext = inlineFrameContext;
  frameContext.imageSmoothingEnabled = false;
  document.body.classList.remove('detached');
  openWindowButton.textContent = '別ウィンドウで開く';
}
function syncGameWindowStatus() {
  if (gameWindow === null) return;
  if (gameWindow.closed) {
    closeGameWindowState(gameWindow);
    return;
  }
  const popupDocument = gameWindow.document;
  popupDocument.getElementById('popup-state').textContent = state.textContent;
  popupDocument.getElementById('popup-engine').textContent = engine.textContent;
  popupDocument.getElementById('popup-video').textContent = videoState.textContent;
  popupDocument.getElementById('popup-audio').textContent = audioState.textContent;
}
function openGameWindow() {
  enableAudio();
  if (gameWindow !== null && !gameWindow.closed) {
    gameWindow.focus();
    if (gameWindowScreen !== null) gameWindowScreen.focus();
    return;
  }
  const width = Math.min(1320, Math.max(760, window.screen.availWidth - 80));
  const height = Math.min(1120, Math.max(700, window.screen.availHeight - 80));
  const opened = window.open('', 'monadius-game',
      `popup=yes,width=${width},height=${height},resizable=yes`);
  if (opened === null) {
    openWindowButton.textContent = 'ポップアップを許可して再試行';
    return;
  }
  opened.document.open();
  opened.document.write(`<!doctype html><html><head><meta charset="utf-8"><title>Monadius</title>
    <style>
      html, body { margin: 0; width: 100%; height: 100%; overflow: hidden;
                   background: #080b14; color: #dce8ff; font-family: sans-serif; }
      #popup-help { box-sizing: border-box; min-height: 68px; padding: 8px 12px;
                    font-size: 13px; line-height: 1.45; }
      #close-window { float: right; margin-left: 12px; padding: 5px 10px; cursor: pointer; }
      #game-screen { display: block; margin: 0 auto; width: auto; height: auto;
                     max-width: 100vw; max-height: calc(100vh - 68px);
                     object-fit: contain; outline: none; }
    </style></head><body>
    <div id="popup-help"><button id="close-window" type="button">セル内へ戻す</button>
      Arrow keys: move · A: shot/missile · F: power-up · Space: start · G: self-destruct<br>
      <span id="popup-state">keys: none</span> · <span id="popup-engine">engine: waiting</span> ·
      <span id="popup-video">video: waiting</span> · <span id="popup-audio">audio: waiting</span>
    </div><canvas id="game-screen" tabindex="0"></canvas></body></html>`);
  opened.document.close();

  const popupScreen = opened.document.getElementById('game-screen');
  popupScreen.width = inlineScreen.width;
  popupScreen.height = inlineScreen.height;
  const popupContext = popupScreen.getContext('2d', {alpha:false});
  popupContext.imageSmoothingEnabled = false;
  popupContext.drawImage(inlineScreen, 0, 0);

  gameWindow = opened;
  gameWindowScreen = popupScreen;
  activeScreen = popupScreen;
  frameContext = popupContext;
  attachInput(opened);
  // Chrome may throttle timers in the notebook tab while this pop-up is in
  // front.  Schedule a second lease heartbeat on the active game window so a
  // genuinely held direction cannot expire merely because the opener is hidden.
  opened.setInterval(() => { if (held.size) send(); }, 250);
  opened.addEventListener('beforeunload', () => closeGameWindowState(opened));
  popupScreen.addEventListener('click', () => { popupScreen.focus(); enableAudio(); });
  opened.document.getElementById('close-window').addEventListener('click', () => opened.close());
  document.body.classList.add('detached');
  openWindowButton.textContent = 'ゲーム画面を前面に戻す';
  syncGameWindowStatus();
  opened.focus();
  popupScreen.focus();
}
openWindowButton.addEventListener('click', openGameWindow);
setInterval(syncGameWindowStatus, 250);
// A retry protects a held direction from a transient proxy request failure;
// coalescing guarantees that heartbeats never create an unbounded queue.
setInterval(() => { if (held.size) send(); }, 250);
send();
receiveFrameStream();
displayLatestFrames();
pollAudioEvents();
pollStatus();
</script></body></html>"""


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    frame_file: Path
    input_file: Path
    asset_root: Path
    audio_cache_root: Path | None
    audio_event_file: Path
    status_file: Path
    input_lock = threading.Lock()
    input_generation = -1
    input_sequence = -1
    input_last_seen = 0.0
    input_value = ""

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
        if request.path == "/frame-stream":
            self.stream_frames()
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
                type(self).input_last_seen = time.monotonic()
                type(self).input_value = value
        self.send_response(204)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def stream_frames(self) -> None:
        boundary = b"monadiusframe"
        self.send_response(200)
        self.send_header(
            "Content-Type",
            "multipart/x-mixed-replace; boundary=" + boundary.decode("ascii"),
        )
        self.send_header(
            "Cache-Control", "no-store, no-cache, must-revalidate, no-transform"
        )
        self.send_header("Transfer-Encoding", "chunked")
        self.send_header("X-Accel-Buffering", "no")
        self.end_headers()

        last_modified = -1
        next_frame_time = 0.0
        try:
            while True:
                delay = next_frame_time - time.monotonic()
                if delay > 0:
                    time.sleep(min(delay, 0.01))
                    continue
                try:
                    if self.frame_file.stat().st_mtime_ns <= last_modified:
                        time.sleep(0.002)
                        continue
                    with self.frame_file.open("rb") as stream:
                        modified = os.fstat(stream.fileno()).st_mtime_ns
                        if modified <= last_modified:
                            continue
                        frame = stream.read()
                except FileNotFoundError:
                    time.sleep(0.004)
                    continue

                part = (
                    b"--" + boundary + b"\r\n"
                    b"Content-Type: image/jpeg\r\n"
                    + f"Content-Length: {len(frame)}\r\n".encode("ascii")
                    + f"X-Monadius-Frame: {modified}\r\n\r\n".encode("ascii")
                    + frame
                    + b"\r\n"
                )
                chunk = f"{len(part):x}\r\n".encode("ascii") + part + b"\r\n"
                self.wfile.write(chunk)
                self.wfile.flush()
                last_modified = modified
                next_frame_time = time.monotonic() + FRAME_STREAM_INTERVAL_SECONDS
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            self.close_connection = True
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
            for action, path, gain, _emitted_at in events:
                if action == "bgm":
                    current_bgm = [path, gain]
                elif action == "stop-bgm":
                    current_bgm = None
            events = [["bgm", current_bgm[0], current_bgm[1]]] if current_bgm else []
        else:
            now_milliseconds = int(time.time() * 1000)
            events = [
                [action, path, gain]
                for action, path, gain, emitted_at in events
                if not (
                    action == "play"
                    and emitted_at is not None
                    and now_milliseconds - emitted_at
                    > MAX_EFFECT_EVENT_AGE_MILLISECONDS
                )
            ]

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
            source_relative = candidate.relative_to(self.asset_root)
        except ValueError:
            self.send_error(403)
            return
        if candidate.suffix.lower() != ".wav" or not candidate.is_file():
            self.send_error(404)
            return

        content_type = "audio/wav"
        if self.audio_cache_root is not None:
            cached = (self.audio_cache_root / source_relative).with_suffix(".ogg").resolve()
            try:
                cached.relative_to(self.audio_cache_root)
            except ValueError:
                cached = candidate
            if cached.is_file():
                candidate = cached
                content_type = "audio/ogg"

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
                requested_end = min(int(last), size - 1) if last else size - 1
                end = min(requested_end, start + AUDIO_RANGE_CHUNK_BYTES - 1)
            elif last:
                length = min(int(last), size)
                length = min(length, AUDIO_RANGE_CHUNK_BYTES)
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
        self.send_header("Content-Type", content_type)
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
    request_queue_size = 64

    def handle_error(self, request: object, client_address: object) -> None:
        # Aborted key retries, timed-out polls, and closed audio elements all
        # reset HTTP/1.1 connections during normal play.  Keep those expected
        # disconnects out of bridge.log while preserving unexpected tracebacks.
        error = sys.exc_info()[1]
        if isinstance(
            error, (BrokenPipeError, ConnectionResetError, ConnectionAbortedError)
        ):
            return
        super().handle_error(request, client_address)


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
            try:
                emitted_at = int(fields[3]) if len(fields) >= 4 else None
            except ValueError:
                emitted_at = None
            events.append([action, fields[1], gain, emitted_at])
        elif action == "stop-bgm":
            try:
                emitted_at = int(fields[3]) if len(fields) >= 4 else None
            except ValueError:
                emitted_at = None
            events.append([action, "", 1.0, emitted_at])
    return events


def expire_stale_input(stop_event: threading.Event) -> None:
    """Release a browser key if its heartbeat stops reaching the bridge."""
    while not stop_event.wait(0.05):
        with Handler.input_lock:
            expired = (
                bool(Handler.input_value)
                and time.monotonic() - Handler.input_last_seen > INPUT_LEASE_SECONDS
            )
            if expired:
                write_atomically(Handler.input_file, "")
                Handler.input_value = ""


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--frame-file", type=Path, required=True)
    parser.add_argument("--input-file", type=Path, required=True)
    parser.add_argument("--asset-root", type=Path, required=True)
    parser.add_argument("--audio-cache-root", type=Path)
    parser.add_argument("--audio-event-file", type=Path, required=True)
    parser.add_argument("--status-file", type=Path, required=True)
    parser.add_argument("--ready-file", type=Path)
    args = parser.parse_args()
    Handler.frame_file = args.frame_file
    Handler.input_file = args.input_file
    Handler.asset_root = args.asset_root.resolve()
    Handler.audio_cache_root = (
        args.audio_cache_root.resolve() if args.audio_cache_root is not None else None
    )
    Handler.audio_event_file = args.audio_event_file
    Handler.status_file = args.status_file
    Handler.input_generation = -1
    Handler.input_sequence = -1
    Handler.input_last_seen = time.monotonic()
    Handler.input_value = ""
    write_atomically(args.input_file, "")
    input_watchdog_stop = threading.Event()
    input_watchdog = threading.Thread(
        target=expire_stale_input, args=(input_watchdog_stop,), daemon=True
    )
    input_watchdog.start()
    with ReusableTCPServer(("127.0.0.1", args.port), Handler) as server:
        try:
            if args.ready_file is not None:
                write_atomically(args.ready_file, "ready\n")
            print(f"Monadius bridge listening on 127.0.0.1:{args.port}", flush=True)
            server.serve_forever()
        finally:
            input_watchdog_stop.set()
            input_watchdog.join(timeout=1.0)


if __name__ == "__main__":
    main()
