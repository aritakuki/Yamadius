"""Colab-kernel wrapper for ``fresh-start.sh``.

Run this with ``%run Colab/fresh_start.py`` (not ``!python``).  The shell
starts the game; this file runs in the notebook kernel and can therefore add
the iframe that exposes Colab's loopback port to the browser.
"""

from __future__ import annotations

import os
import subprocess
import time
from pathlib import Path

from google.colab import output


ROOT = Path.cwd()
if not (ROOT / "Colab" / "fresh-start.sh").is_file():
    raise RuntimeError("Run this from the Yamadius repository root.")

port = int(os.environ.get("MONADIUS_PORT", "8765"))
subprocess.run(["bash", "Colab/fresh-start.sh"], check=True)
time.sleep(2)
output.serve_kernel_port_as_iframe(port, height=1250)
