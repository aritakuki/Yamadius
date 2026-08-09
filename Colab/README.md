# Google Colab interactive run

Japanese step-by-step setup, reconnection, and `pkill` instructions are in
[`COLAB_SETUP_JA.md`](COLAB_SETUP_JA.md).

The Colab adapter keeps Monadius' original Haskell game loop and renders every
game frame with OpenGL on the NVIDIA EGL device.  Browser transport is kept
outside that loop:

```text
browser keys -> Colab bridge -> key file -> Haskell game loop
Lisp/CUDA process -> complete RGB frame -> anonymous shared-RAM triple buffer + generation
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

The raytracer runs as a separate SBCL process and owns its CUDA context. `Main`
creates an anonymous Linux `memfd` (RAM, not an image file), maps it, and passes
the inherited descriptor to SBCL. Both processes map the same three RGBA slots.
Lisp publishes only a completely converted slot and increments its generation;
Haskell never waits for a raytraced frame. When the generation is unchanged,
the OpenGL upload is skipped and the previous complete texture is drawn again.
The third slot and a short-lived reader claim prevent Lisp from overwriting the
slot while OpenGL is consuming it. If `Main` is killed, Linux also kills its
SBCL child so the CUDA renderer cannot remain orphaned.

The browser receives a one-time Ogg/Opus cache instead of the very large PCM
WAV files used by the native game, and audio Range responses are bounded so a
BGM transfer cannot occupy every notebook-proxy connection.  Input transitions
temporarily preempt replaceable background polls so they cannot wait behind a
full proxy connection pool; interrupted effect polling then resumes from its
previous offset.  If key heartbeats stop reaching the bridge, a held direction
is released automatically instead of remaining stuck.

## Fresh Colab runtime

Select a GPU runtime, then run this shell cell once.  It installs dependencies,
checks out `feature/shared-memory-ray-background` in both the Monadius and Lisp
repositories, prepares cl-cuda and the small shared-memory library, builds
Effekseer and Monadius, and starts the local bridge. The packaged Colab SBCL is
used only in its own process; no custom SBCL runtime is compiled or loaded into
`Main`:

```bash
!curl -fsSL https://raw.githubusercontent.com/aritakuki/Yamadius/feature/shared-memory-ray-background/Colab/bootstrap-colab.sh | bash
```

The bootstrap already started one game. Embed that existing game from a Python
cell; do not run `fresh_start.py` immediately after bootstrap:

```python
%cd /content/Yamadius-colab
from google.colab import output
output.serve_kernel_port_as_iframe(8765, height=1100)
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

Changes to the Lisp renderer or the shared-memory C library require pulling its
branch and rebuilding the small producer library before restarting `Main`:

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
The restart path escalates from SIGTERM to SIGKILL only if an older `Main`
refuses to exit, which also prevents two game instances from alternating.

## GPU verification

The runtime log should report NVIDIA through `Colab/egl_probe.cpp`, and
`nvidia-smi` should list `./Main` for graphics and `sbcl` for CUDA compute. The expected renderer
on the standard Colab GPU runtime is similar to:

```text
EGL_VENDOR=NVIDIA
GL_VENDOR=NVIDIA Corporation
GL_RENDERER=Tesla T4/PCIe/SSE2
```
