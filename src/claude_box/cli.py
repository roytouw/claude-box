"""`claude-box` command: runs the bundled bash launcher with the same arguments."""

import os
import sys
from pathlib import Path

LAUNCHER = Path(__file__).resolve().parent / "data" / "bin" / "claude-box"


def main() -> None:
    os.execv("/bin/bash", ["/bin/bash", str(LAUNCHER), *sys.argv[1:]])
