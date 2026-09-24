"""Shared sensitive-path policy for both Python launchers."""

import json
from pathlib import Path

_POLICY = json.loads(Path(__file__).with_name("sensitive-paths.json").read_text(encoding="utf-8"))


def sensitive_path(path: str) -> bool:
    parts = [part.casefold() for part in path.replace("\\", "/").split("/") if part]
    if not parts:
        return False
    name = parts[-1]
    return (any(part in _POLICY["directories"] for part in parts)
            or name in _POLICY["names"]
            or any(name.startswith(prefix) for prefix in _POLICY["prefixes"])
            or any(name.endswith(suffix) for suffix in _POLICY["suffixes"])
            or (name.startswith(_POLICY["service_account_prefix"])
                and name.endswith(_POLICY["service_account_suffix"])))
