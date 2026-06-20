#!/usr/bin/env python3
"""
unify_and_clean_imports.py

Walks through a directory recursively, finds all .sol files,
unifies named imports from the same file path into a single import with sorted symbols,
removes duplicate import statements, and also deduplicates & sorts symbols within a single import.
"""

import os
import re
import argparse
from collections import OrderedDict

# Regex to match named import statements: import {a, b} from "path";
IMPORT_REGEX = re.compile(r'^\s*import\s*{([^}]*)}\s*from\s*["\']([^"\']+)["\'];')


def process_file(path: str):
    """
    Reads a .sol file, unifies named imports, removes duplicate imports and duplicate symbols,
    sorts symbols within a single import, and writes back if changes were made.
    """
    with open(path, 'r', encoding='utf-8') as f:
        lines = f.readlines()

    imports = OrderedDict()  # import_path -> { 'symbols': list, 'first_index': int }
    duplicates_in_line = False
    unsorted_in_line = False

    # First pass: collect named imports, detect intra-line duplicates & unsorted
    for idx, line in enumerate(lines):
        m = IMPORT_REGEX.match(line)
        if not m:
            continue

        raw_symbols = [s.strip() for s in m.group(1).split(',') if s.strip()]
        # detect duplicate symbols within this import
        if len(raw_symbols) != len(set(raw_symbols)):
            duplicates_in_line = True

        # detect out-of-order symbols within this import
        if raw_symbols != sorted(raw_symbols):
            unsorted_in_line = True

        imp_path = m.group(2)
        if imp_path not in imports:
            imports[imp_path] = {'symbols': [], 'first_index': idx}
        # accumulate unique symbols
        for sym in raw_symbols:
            if sym not in imports[imp_path]['symbols']:
                imports[imp_path]['symbols'].append(sym)

    # Count how many import statements per path
    occurrences = {imp_path: 0 for imp_path in imports}
    for line in lines:
        m = IMPORT_REGEX.match(line)
        if m and m.group(2) in occurrences:
            occurrences[m.group(2)] += 1

    # If nothing to unify (no multi-line duplicates), no intra-line duplicates, and everything already sorted → done
    if not any(count > 1 for count in occurrences.values()) \
       and not duplicates_in_line \
       and not unsorted_in_line:
        return

    # Build unified import lines (sorted symbols)
    unified_import_lines = {}
    for imp_path, data in imports.items():
        symbols_sorted = sorted(data['symbols'])
        unified_import_lines[imp_path] = (
            f"import {{{', '.join(symbols_sorted)}}} from \"{imp_path}\";\n"
        )

    # Second pass: write new lines, replacing first occurrence (or only occurrence)
    output = []
    printed = set()
    for idx, line in enumerate(lines):
        m = IMPORT_REGEX.match(line)
        if m:
            imp_path = m.group(2)
            # on the first import for this path, print the unified version
            if imp_path not in printed and idx == imports[imp_path]['first_index']:
                output.append(unified_import_lines[imp_path])
                printed.add(imp_path)
            # skip any other import lines for this path
            else:
                continue
        else:
            output.append(line)

    # Write back if changed
    with open(path, 'w', encoding='utf-8') as f:
        f.writelines(output)
    print(f"Unified, sorted, and cleaned imports in: {path}")


def walk_and_clean(root_dir: str):
    for dirpath, _, filenames in os.walk(root_dir):
        for file in filenames:
            if file.endswith('.sol'):
                process_file(os.path.join(dirpath, file))


def main():
    parser = argparse.ArgumentParser(
        description="Unify named imports and remove duplicates/sort symbols in Solidity (.sol) files."
    )
    parser.add_argument('directory',
        help='Root directory to scan for Solidity files'
    )
    args = parser.parse_args()

    if not os.path.isdir(args.directory):
        print(f"Error: '{args.directory}' is not a valid directory.")
        exit(1)

    walk_and_clean(args.directory)


if __name__ == '__main__':
    main()
