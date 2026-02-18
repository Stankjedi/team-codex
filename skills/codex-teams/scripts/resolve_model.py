#!/usr/bin/env python3
"""Resolve Codex model from layered config.toml files.

Resolution order (highest first):
1) role-specific override: [codex_teams] <role>_model
2) profile model: [profiles.<profile>].model
3) codex_teams default: [codex_teams].model
4) top-level model

Supported roles:
- director, lead
- worker, reviewer, utility

Project config (.codex/config.toml) overrides user config (~/.codex/config.toml).
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

try:
    import tomllib  # py311+
except ModuleNotFoundError:  # pragma: no cover
    print("python3.11+ with tomllib is required", file=sys.stderr)
    raise


def load_toml(path: Path) -> dict:
    if not path.exists() or not path.is_file():
        return {}
    with path.open("rb") as f:
        return tomllib.load(f)


def read_nested(d: dict, keys: list[str]) -> str | None:
    cur: object = d
    for key in keys:
        if not isinstance(cur, dict) or key not in cur:
            return None
        cur = cur[key]
    return cur if isinstance(cur, str) and cur.strip() else None


def resolve_model(config: dict, profile: str | None, role: str | None) -> str | None:
    if role:
        value = read_nested(config, ["codex_teams", f"{role}_model"])
        if value:
            return value

    if profile:
        value = read_nested(config, ["profiles", profile, "model"])
        if value:
            return value

    value = read_nested(config, ["codex_teams", "model"])
    if value:
        return value

    return read_nested(config, ["model"])


def main() -> int:
    parser = argparse.ArgumentParser(description="Resolve Codex model from config files")
    parser.add_argument("--project-root", default=os.getcwd(), help="project root for .codex/config.toml")
    parser.add_argument("--profile", default=None)
    parser.add_argument(
        "--role",
        choices=["director", "lead", "worker", "reviewer", "utility"],
        default=None,
    )
    parser.add_argument("--print-source", action="store_true", help="print source file with model")
    args = parser.parse_args()

    project_root = Path(args.project_root).resolve()
    files = [
        Path.home() / ".codex" / "config.toml",
        project_root / ".codex" / "config.toml",
    ]

    selected_model: str | None = None
    selected_source: Path | None = None
    for path in files:
        config = load_toml(path)
        if not config:
            continue
        model = resolve_model(config, args.profile, args.role)
        if model:
            selected_model = model
            selected_source = path

    if not selected_model:
        return 1

    if args.print_source and selected_source is not None:
        print(f"{selected_model}\t{selected_source}")
    else:
        print(selected_model)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
