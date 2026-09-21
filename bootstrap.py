#!/usr/bin/env python3
"""Install build tooling (uv), then create the build venv.

Stdlib only: this runs before any venv exists.
"""

import argparse
import shutil
import subprocess
import sys
import tomllib
import venv
from pathlib import Path

ROOT = Path(__file__).resolve().parent
TOOLS = ROOT / ".tools"
VENV = ROOT / ".venv"
PYPROJECT = ROOT / "pyproject.toml"


def bin_dir(root: Path) -> Path:
    return root / ("Scripts" if sys.platform == "win32" else "bin")


def run(*cmd: str) -> None:
    subprocess.run(cmd, check=True)


def pyproject() -> dict:
    with PYPROJECT.open("rb") as handle:
        return tomllib.load(handle)


def install_tools(config: dict, reuse_host: bool = True) -> str:
    """Return a uv executable, installing it if the host has none.

    PEP 668 blocks a system pip install, so tooling goes in its own venv
    rather than alongside the build dependencies.
    """
    if reuse_host:
        found = shutil.which("uv")
        if found:
            print(f"uv:    {found} (host)")
            return found

    tools = config.get("tool", {}).get("bootstrap", {}).get("tools", ["uv"])
    venv.EnvBuilder(with_pip=True, clear=True).create(TOOLS)
    run(str(bin_dir(TOOLS) / "pip"), "install", "--quiet", "--upgrade", *tools)

    uv = bin_dir(TOOLS) / "uv"
    print(f"uv:    {uv} ({' '.join(tools)})")
    return str(uv)


def create_venv(uv: str, dependencies: list[str]) -> Path:
    """Build venv holds only what build_image.py imports."""
    # --allow-existing: uv errors on a pre-existing venv, which breaks re-runs.
    run(uv, "venv", "--quiet", "--allow-existing", str(VENV))
    python = bin_dir(VENV) / "python"

    if dependencies:
        run(uv, "pip", "install", "--quiet", "--python", str(python), *dependencies)

    return python


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--no-host-uv", action="store_true",
                        help="install uv into .tools even if the host has one")
    args = parser.parse_args()

    if not PYPROJECT.is_file():
        print(f"error: {PYPROJECT} not found", file=sys.stderr)
        return 1

    config = pyproject()
    dependencies = config["project"].get("dependencies", [])

    try:
        uv = install_tools(config, reuse_host=not args.no_host_uv)
        python = create_venv(uv, dependencies)
    except subprocess.CalledProcessError as error:
        print(f"\nerror: command failed: {' '.join(error.cmd)}", file=sys.stderr)
        return 1

    print(f"venv:  {VENV} ({', '.join(dependencies) or 'no dependencies'})")
    print(f"\nBuild with:\n    {python.relative_to(Path.cwd())} build/build_image.py")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
