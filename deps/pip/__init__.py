"""Python packages installed into the ansible venv."""

from pathlib import Path

REQUIREMENTS = Path(__file__).parent / "requirements.txt"


def load() -> list[str]:
    lines = REQUIREMENTS.read_text(encoding="utf-8").splitlines()
    return [
        stripped
        for line in lines
        if (stripped := line.strip()) and not stripped.startswith("#")
    ]
