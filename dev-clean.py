#!/usr/bin/env python3
"""Free WSL disk by deleting redownloadable folders (.venv, node_modules, caches) in ~/dev projects dup is not working on.

    python3 dev-clean.py                 # report every project, write the candidate list, delete nothing
    python3 dev-clean.py --delete        # delete exactly the folders in the list file (edit it first)

A project is a candidate when it has no state file (dev.claude/<name>/NOW.md, a sources.toml alias of it, or a
NOW.md symlink in the repo) AND nothing uses it: no running process, systemd user unit, Claude Desktop or Claude
Code MCP config, or ~/.claude skill/rule names its path. The list file holds one folder per line, relative to
~/dev; delete a line to keep that folder. Run the compact script afterwards so Windows gets the space back.
"""
from __future__ import annotations

import glob
import json
import os
import re
import shutil
import subprocess
import sys
import tomllib
from pathlib import Path

DEV = Path.home() / "dev"
DEV_CLAUDE = Path("/mnt/c/Users/dup/dev.claude")
LIST = Path(__file__).resolve().parent / "dev-clean-list.txt"
JUNK = {"node_modules", ".venv", "venv", "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache", ".tox",
        ".next", ".parcel-cache", ".turbo", ".uv"}


def in_use() -> set[str]:
    text = subprocess.run(["ps", "-eo", "args"], capture_output=True, text=True).stdout
    files = glob.glob(os.path.expanduser("~/.config/systemd/user/*.service"))
    files += ["/mnt/c/Users/dup/AppData/Roaming/Claude/claude_desktop_config.json", os.path.expanduser("~/.claude/settings.json")]
    files += glob.glob(os.path.expanduser("~/.claude/skills/*/SKILL.md")) + glob.glob(os.path.expanduser("~/.claude/rules/*.md"))
    for f in files:
        try:
            text += Path(f).read_text(encoding="utf-8", errors="replace")
        except OSError:
            pass
    try:  # only the MCP server entries: the rest of ~/.claude.json names every project ever opened
        cj = json.loads(Path("~/.claude.json").expanduser().read_text(encoding="utf-8"))
        text += json.dumps(cj.get("mcpServers", {}))
        text += "".join(json.dumps(p.get("mcpServers", {})) for p in cj.get("projects", {}).values())
    except (OSError, ValueError):
        pass
    return set(re.findall(r"(?:/home/dup|~)/dev/([^/\"' :\n]+)", text))


def has_state(d: Path, aliases: dict, state_dirs: set[str]) -> bool:
    key = re.sub(r"[^a-z0-9]+", "-", d.name.lower()).strip("-")
    return d.name.lower() in state_dirs or aliases.get(key, "") in state_dirs or (d / "NOW.md").is_symlink()


def junk_dirs(root: Path) -> list[tuple[Path, int]]:
    out = []
    for dp, dn, _ in os.walk(root):
        dn[:] = [d for d in dn if d != ".git" and not os.path.islink(os.path.join(dp, d))]
        for d in list(dn):
            full = Path(dp, d)
            if d in JUNK or (d == "target" and (Path(dp) / "Cargo.toml").exists()):
                size = int(subprocess.run(["du", "-sb", str(full)], capture_output=True, text=True).stdout.split()[0])
                out.append((full, size))
                dn.remove(d)
    return out


def scan() -> None:
    aliases = tomllib.load(open(DEV / "surreal-state/config/sources.toml", "rb"))["projects"]["aliases"]
    state_dirs = {p.name.lower() for p in DEV_CLAUDE.iterdir() if (p / "NOW.md").exists()}
    used = in_use()
    candidates, total = [], 0
    print(f"{'project':32} {'state':6} {'in use':7} {'last commit':11} {'junk GB':>7}")
    for d in sorted(DEV.iterdir(), key=lambda p: p.name.lower()):
        if not d.is_dir() or d.is_symlink():
            continue
        state, use = has_state(d, aliases, state_dirs), d.name in used
        last = subprocess.run(["git", "-C", str(d), "log", "-1", "--format=%cs"], capture_output=True, text=True).stdout.strip() or "-"
        junk = junk_dirs(d)
        size = sum(s for _, s in junk)
        mark = "  <- candidate" if junk and not state and not use else ""
        print(f"{d.name[:32]:32} {'yes' if state else '-':6} {'yes' if use else '-':7} {last:11} {size / 1e9:7.2f}{mark}")
        if mark:
            candidates += [(p, s) for p, s in junk]
            total += size
    LIST.write_text("".join(f"{p.relative_to(DEV)}\n" for p, _ in candidates), encoding="utf-8")
    print(f"\n{len(candidates)} folders, {total / 1e9:.2f} GB, listed in {LIST}")
    for p, s in candidates:
        print(f"  {s / 1e9:6.2f} GB  {p.relative_to(DEV)}")
    print("Edit the list (delete a line to keep it), then: python3 dev-clean.py --delete")


def delete() -> None:
    lines = [l.strip() for l in LIST.read_text(encoding="utf-8").splitlines() if l.strip() and not l.startswith("#")]
    for rel in lines:
        p = (DEV / rel).resolve()
        if DEV.resolve() not in p.parents or p.name not in JUNK | {"target"}:
            print(f"skipped (not a junk folder inside ~/dev): {rel}")
            continue
        if p.is_dir():
            shutil.rmtree(p)
            print(f"deleted {rel}")
    print("Done. Run the compact script (compactwsl) so Windows gets the space back.")


if __name__ == "__main__":
    delete() if "--delete" in sys.argv else scan()
