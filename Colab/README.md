# Google Colab interactive run

Japanese step-by-step setup, reconnection, and `pkill` instructions are in
[`COLAB_SETUP_JA.md`](COLAB_SETUP_JA.md).

The Colab adapter keeps Monadius' original Haskell game loop and renders every
game frame with OpenGL on the NVIDIA EGL device.  Browser transport is kept
outside that loop:

```text
browser keys -> Colab bridge -> key file -> Haskell game loop
Lisp/CUDA worker -> complete RGB frame -> in-process C++ double buffer + generation
Haskell frame -> new generation only: OpenGL texture upload -> draw current background
Haskell/OpenGL -> NVIDIA EGL -> asynchronous PBO readback -> JPEG worker
latest completed JPEG -> one continuous stream -> browser latest-frame slot -> Canvas
game BGM/SE calls -> audio event stream -> browser audio elements
```

GPU rendering never waits for JPEG compression or notebook networking.  The
browser keeps one continuous response open, so Colab proxy latency is not paid
again for every frame.  The stream receiver drains incoming frames separately
from Canvas decoding and keeps only one replaceable, not-yet-displayed frame.
When display cannot keep up, intermediate captures are skipped instead of
forming a browser-side frame queue.  Game updates and GPU rendering continue at
their normal 16 ms cadence.

The raytracer runs as an SBCL worker inside the `Main` process.  It owns its
CUDA context and renders continuously without being called by the game loop.
Haskell never waits for a raytraced frame.  When Lisp has not published a new
generation, the OpenGL upload is skipped and the previous complete texture is
drawn again.  The textured quad itself is drawn after every color-buffer clear;
otherwise the previous background would not survive into the next game frame.

The browser receives a one-time Ogg/Opus cache instead of the very large PCM
WAV files used by the native game, and audio Range responses are bounded so a
BGM transfer cannot occupy every notebook-proxy connection.  Input transitions
temporarily preempt replaceable background polls so they cannot wait behind a
full proxy connection pool; interrupted effect polling then resumes from its
previous offset.  If key heartbeats stop reaching the bridge, a held direction
is released automatically instead of remaining stuck.

## Fresh Colab runtime

Select a GPU runtime, then run this shell cell once.  It installs dependencies,
checks out `feature/live-raytraced-background` in both the Monadius and Lisp
repositories, builds the callable SBCL runtime, Effekseer, and Monadius, and
starts the local bridge.  The first build takes longer because SBCL is compiled
once under `/content/monadius-ray-runtime`; its official matching-version
binary is used as the bootstrap compiler so the Colab package version cannot
change the build result:

```bash
!curl -fsSL https://raw.githubusercontent.com/aritakuki/Yamadius/feature/live-raytraced-background/Colab/bootstrap-colab.sh | bash
```

Embed the game from a Python cell:

```python
%cd /content/Yamadius-colab
%env MONADIUS_PORT=8765
%run Colab/fresh_start.py
```

Click the game image once to give it keyboard focus and enable browser audio.
Use arrow keys to move, `A` to shoot/use a missile, `F` to power up, Space to
start, and `G` for self-destruct.  The header reports held keys, the current
engine scene/clock, and the BGM selected by the game.

Use the `別ウィンドウで開く` button to move the game Canvas into a dedicated
browser window.  The authenticated Colab iframe stays in the notebook as the
network owner, so the pop-up does not need a public tunnel and does not create a
second frame or input connection.  Keep the notebook open while playing.  If
the browser blocks the pop-up, allow pop-ups for `colab.research.google.com` and
press the button again.  `セル内へ戻す` closes the game window and restores the
Canvas in the notebook output.

A hosted Colab VM cannot create a native OpenGL window on the user's desktop;
the dedicated browser window is the independent-window mode for the remote GPU
runtime.  Running Monadius locally (or connecting Colab to a local runtime) is
required for the same native window used by the CPU build.

## Updating an existing runtime

Changes to Haskell or C++ require rebuilding `Main`.  Use a new port to avoid
an old iframe response remaining in the notebook output:

```python
%cd /content/Yamadius-colab
!git pull --ff-only
!MONADIUS_COLAB_EGL=1 EFFEKSEER_PREFIX=/content/effekseer-install bash build.sh
%env MONADIUS_PORT=8771
%run Colab/fresh_start.py
```

Changes to the Lisp renderer require pulling its branch and rebuilding the
callable core before restarting `Main`:

```bash
!git -C /content/lisp-raytracer pull --ff-only
!bash Colab/build-ray-background-runtime.sh /content/lisp-raytracer /content/monadius-ray-runtime
```

The default live render size is 800x600.  It can be changed for a restart with
`MONADIUS_RAY_WIDTH` and `MONADIUS_RAY_HEIGHT`; this changes raytracer cadence,
not the Haskell game-loop cadence.

On the first start after this update, the runner may briefly report
`preparing caption fonts` or `preparing browser audio`.  It installs the two
caption font packages when an older live runtime does not have them, then keeps
the converted browser audio under `/tmp/monadius-colab/audio-cache` for later
Fresh Starts in the same VM.

`fresh_start.py` stops prior Monadius/bridge/Xvfb processes, waits for the new
bridge to own the selected port, and embeds it.  Xvfb exists only to initialise
freeglut's stroke-font data; it is not used for rendering or screen capture.

## GPU verification

The runtime log should report NVIDIA through `Colab/egl_probe.cpp`, and
`nvidia-smi` should list `./Main` as a graphics process.  The expected renderer
on the standard Colab GPU runtime is similar to:

```text
EGL_VENDOR=NVIDIA
GL_VENDOR=NVIDIA Corporation
GL_RENDERER=Tesla T4/PCIe/SSE2
```
