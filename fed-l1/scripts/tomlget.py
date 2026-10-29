#!/usr/bin/env python3
"""Minimal reader for the TOML files forge's vm.writeToml produces (python 3.9 has no tomllib).

Usage: tomlget.py FILE dotted.key   -> prints the value (strings unquoted)
"""
import re
import sys


def parse(text):
    root, cur = {}, None
    cur = root
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        m = re.match(r"^\[([^\]]+)\]$", line)
        if m:
            cur = root
            for part in m.group(1).split("."):
                cur = cur.setdefault(part.strip().strip('"'), {})
            continue
        if "=" not in line:
            continue
        k, v = line.split("=", 1)
        cur[k.strip().strip('"')] = v.strip()
    return root


def main():
    data = parse(open(sys.argv[1]).read())
    node = data
    for part in sys.argv[2].split("."):
        node = node[part]
    if isinstance(node, dict):
        sys.exit(f"{sys.argv[2]} is a table")
    v = node
    if len(v) >= 2 and v[0] == '"' and v[-1] == '"':
        v = v[1:-1]
    print(v)


if __name__ == "__main__":
    main()
