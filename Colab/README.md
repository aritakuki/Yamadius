# Google Colab interactive run

`Main` already renders its game scene through OpenGL.  This adapter preserves
that game loop and adds a small Colab-only transport around it:

```text
browser key events -> Colab bridge -> MONADIUS_INPUT_FILE -> Main/GLUT game loop
OpenGL/GLUT window -> Xvfb framebuffer -> JPEG -> Colab bridge -> browser image
```

The browser receives only pixels and sends only the held game keys.  It does
not expose a terminal, desktop, shell, or VNC session.

## Notebook cells

Clone the repository, install the native libraries required by the existing
GLUT/OpenGL/ALUT build, and download the exact Effekseer runtime release used
by this project.  `build.sh` accepts `EFFEKSEER_ROOT`, so it no longer depends
on a workstation-specific absolute path.

```bash
!apt-get -qq update
!apt-get -qq install -y xvfb ffmpeg x11-apps mesa-utils freeglut3-dev libgl1-mesa-dev \
  libglu1-mesa-dev libalut-dev libfreetype6-dev libglew-dev libglfw3-dev \
  libxrandr-dev libxinerama-dev libxi-dev libxxf86vm-dev libxcursor-dev \
  ghc cabal-install
!git clone https://github.com/aritakuki/Yamadius.git
%cd Yamadius
!wget -q https://github.com/effekseer/Effekseer/releases/download/160e/EffekseerRuntime160e.zip
!unzip -q EffekseerRuntime160e.zip -d /content
```

Install the Haskell packages from Hackage.  Colab's Ubuntu image does not
consistently provide a Debian package for `ALUT`.  Monadius uses JuicyPixels
for texture loading, avoiding HIP's old SVGFonts dependency.

```bash
!cabal update
!cabal install --lib OpenGL GLUT ALUT JuicyPixels vector
```

The Effekseer release is source-only on Linux, so build its two static runtime
libraries before building Monadius.

```bash
!chmod +x Colab/build-effekseer.sh
!Colab/build-effekseer.sh /content/EffekseerRuntime160e /content/effekseer-install
```

Build the existing application, then start the bridge.  The command keeps its
processes alive while the cell is running.

```bash
!chmod +x Colab/run-colab.sh
!EFFEKSEER_PREFIX=/content/effekseer-install bash build.sh && Colab/run-colab.sh
```

In a second cell, embed the bridge.  Click the image once before typing.

```python
from google.colab import output
output.serve_kernel_port_as_iframe(8765, height=1100)
```

Controls: arrow keys to move, `A` to shoot/use missile, `F` to power up,
Space to start, and `G` for self-destruct.  The image transport is deliberately
20 fps; the native simulation still retains its 16 ms timer.  The label at the
top of the game frame changes from `keys: none` while a key is held; if it does
not, click the frame again so the iframe receives keyboard focus.

## GPU verification

This adapter makes the existing OpenGL game runnable headlessly, but `Xvfb`
alone can fall back to Mesa's CPU renderer.  It must not be described as GPU
rendering until the Colab session reports an NVIDIA OpenGL renderer.  Before
using it for GPU measurements, run `glxinfo -B` inside the same display and
verify that the renderer is NVIDIA rather than `llvmpipe`.  CUDA availability
does not by itself guarantee that a GLUT/GLX window uses CUDA's GPU.
