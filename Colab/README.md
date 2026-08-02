# Google Colab interactive run

The Colab adapter keeps Monadius' original Haskell game loop and renders every
game frame with OpenGL on the NVIDIA EGL device.  Browser transport is kept
outside that loop:

```text
browser keys -> Colab bridge -> key file -> Haskell game loop
Haskell/OpenGL -> NVIDIA EGL -> asynchronous PBO readback -> JPEG worker -> MJPEG
game BGM/SE calls -> audio event stream -> browser audio elements
```

GPU rendering never waits for JPEG compression or notebook networking.  When
transport cannot keep up, an old capture is replaced by the newest completed
capture; game updates and GPU rendering continue at their normal 16 ms cadence.

## Fresh Colab runtime

Select a GPU runtime, then run this shell cell once.  It installs dependencies,
checks out `feature/colab-interactive-monadius`, builds Effekseer and Monadius,
and starts the local bridge:

```bash
!curl -fsSL https://raw.githubusercontent.com/aritakuki/Yamadius/feature/colab-interactive-monadius/Colab/bootstrap-colab.sh | bash
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
