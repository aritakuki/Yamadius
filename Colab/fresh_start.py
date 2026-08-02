"""Start a verified fresh Colab session and expose its iframe.

Run with ``%run Colab/fresh_start.py`` from the repository root.
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

from google.colab import output


ROOT = Path.cwd()
if not (ROOT / "Colab" / "fresh-start.sh").is_file():
    raise RuntimeError("Run this from the Yamadius repository root.")

port = int(os.environ.get("MONADIUS_PORT", "8765"))
subprocess.run(["bash", "Colab/fresh-start.sh"], check=True)
output.serve_kernel_port_as_iframe(port, height=1100)
