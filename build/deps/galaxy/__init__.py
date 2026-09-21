"""Ansible collections installed with ansible-galaxy."""

from pathlib import Path

import yaml

REQUIREMENTS = Path(__file__).parent / "requirements.yml"


def load() -> list[str]:
    """Return entries as ansible-galaxy accepts them: name, or name:version."""
    document = yaml.safe_load(REQUIREMENTS.read_text(encoding="utf-8")) or {}
    entries = []
    for entry in document.get("collections", []):
        if isinstance(entry, str):
            entries.append(entry)
            continue
        version = entry.get("version")
        entries.append(f"{entry['name']}:{version}" if version else entry["name"])
    return entries
