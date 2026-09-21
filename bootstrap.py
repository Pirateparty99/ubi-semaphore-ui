#!/usr/bin/env python3
"""Create the project venv with uv. Stdlib only: runs before the venv exists."""

import shutil
import subprocess
import sys
import tomllib
import venv
from pathlib import Path

ROOT = Path(__file__).resolve().parent
VENV = ROOT / ".venv"
PYPROJECT = ROOT / "pyproject.toml"


def bin_dir(root: Path) -> Path:
    return root / ("Scripts" if sys.platform == "win32" else "bin")


def run(*cmd: str) -> None:
    subprocess.run(cmd, check=True)


def dependencies() -> list[str]:
    with PYPROJECT.open("rb") as handle:
        return tomllib.load(handle)["project"].get("dependencies", [])


def ensure_uv() -> str:
    """Return a uv executable, installing it into the venv if the host lacks one."""
    found = shutil.which("uv")
    if found:
        run(found, "venv", str(VENV))
        return found

    # A system pip install would hit PEP 668, so uv goes inside the venv.
    venv.EnvBuilder(with_pip=True, clear=True).create(VENV)
    pip = bin_dir(VENV) / "pip"
    run(str(pip), "install", "--quiet", "--upgrade", "uv")
    return str(bin_dir(VENV) / "uv")


def main() -> int:
    if not PYPROJECT.is_file():
        print(f"error: {PYPROJECT} not found", file=sys.stderr)
        return 1

    uv = ensure_uv()
    python = bin_dir(VENV) / "python"

    deps = dependencies()
    if deps:
        run(uv, "pip", "install", "--quiet", "--python", str(python), *deps)

    print(f"venv:     {VENV}")
    print(f"activate: source {VENV.name}/bin/activate")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
