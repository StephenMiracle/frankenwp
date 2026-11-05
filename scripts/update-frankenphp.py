#!/usr/bin/env python3
"""Update the Dockerfile pin from a GitHub releases/latest JSON response."""

import json
import os
from pathlib import Path
import re
import sys


def update(release, dockerfile):
    if release.get("draft") or release.get("prerelease"):
        raise ValueError("Expected a stable published release")
    tag = release["tag_name"]
    if not re.fullmatch(r"v?\d+\.\d+\.\d+", tag):
        raise ValueError(f"Unsupported release tag: {tag!r}")
    latest = tag.removeprefix("v")
    pattern = r"^ARG FRANKENPHP_VERSION=(\d+\.\d+\.\d+)$"
    matches = re.findall(pattern, dockerfile, re.MULTILINE)
    if len(matches) != 1:
        raise ValueError("Expected exactly one FrankenPHP version pin")
    current = matches[0]
    version = lambda value: tuple(map(int, value.split(".")))
    if version(latest) <= version(current) or version(latest) < (1, 13, 2):
        return dockerfile, current, latest, False
    updated = re.sub(pattern, f"ARG FRANKENPHP_VERSION={latest}", dockerfile,
                     flags=re.MULTILINE)
    return updated, current, latest, True


if __name__ == "__main__":
    release = json.load(sys.stdin)
    path = Path("Dockerfile")
    updated, current, latest, changed = update(release, path.read_text())
    if changed:
        path.write_text(updated)
    print(f"FrankenPHP: {current} -> {latest}; update={changed}")
    if output := os.environ.get("GITHUB_OUTPUT"):
        with open(output, "a") as stream:
            stream.write(f"current={current}\nlatest={latest}\n")
            stream.write(f"changed={str(changed).lower()}\n")
