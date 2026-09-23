"""IaC binaries copied out of upstream's build stage."""

import tomllib
from pathlib import Path

TOOLS = Path(__file__).parent / "tools.toml"


def load() -> list[dict[str, str]]:
    document = tomllib.loads(TOOLS.read_text(encoding="utf-8"))
    return [
        {"src": f"/tmp/{name}", "dest": "/usr/local/bin/", "flags": ""}
        for name, enabled in document.get("tools", {}).items()
        if enabled
    ]
