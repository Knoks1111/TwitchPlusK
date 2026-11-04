"""Embed UTF-8 .strings tables in the dylib as Objective-C dictionaries."""
import argparse
import json
from pathlib import Path
import re


def parse_strings(text):
    decoder = json.JSONDecoder()
    position = 0
    entries = {}

    def skip():
        nonlocal position
        while position < len(text):
            if text[position].isspace():
                position += 1
            elif text.startswith("//", position):
                end = text.find("\n", position)
                position = len(text) if end < 0 else end + 1
            elif text.startswith("/*", position):
                end = text.find("*/", position + 2)
                if end < 0:
                    raise ValueError("Unterminated comment")
                position = end + 2
            else:
                break

    def string():
        nonlocal position
        skip()
        if position >= len(text) or text[position] != '"':
            raise ValueError(f"Expected a string at position {position}")
        value, position = decoder.raw_decode(text, position)
        return value

    def punctuation(expected):
        nonlocal position
        skip()
        if position >= len(text) or text[position] != expected:
            raise ValueError(f"Expected {expected!r} at position {position}")
        position += 1

    skip()
    while position < len(text):
        key = string()
        punctuation("=")
        value = string()
        punctuation(";")
        if key in entries:
            raise ValueError(f"Duplicate key: {key}")
        entries[key] = value
        skip()
    return entries


def render_tables(directory):
    tables = {}
    for path in sorted(directory.glob("*.strings")):
        if not re.fullmatch(r"[a-z]{2,3}(?:-[A-Za-z0-9]+)*", path.stem):
            raise ValueError(f"Invalid language code: {path.name}")
        try:
            tables[path.stem] = parse_strings(path.read_text(encoding="utf-8-sig"))
        except ValueError as error:
            raise ValueError(f"{path.name}: {error}") from error
    if not {"fr", "en"}.issubset(tables):
        raise ValueError("The fr.strings and en.strings tables are required")
    quote = lambda value: "@" + json.dumps(value, ensure_ascii=False)
    lines = ["// Generated from Languages/*.strings; do not edit.",
             "static NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *TPKLocalizationTables(void) {",
             "    return @{"]
    for language, entries in tables.items():
        lines.append(f"        {quote(language)}: @{{")
        for key, value in entries.items():
            lines.append(f"            {quote(key)}: {quote(value)},")
        lines.append("        },")
    lines.extend(["    };", "}", ""])
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    try:
        content = render_tables(args.input)
    except (OSError, ValueError) as error:
        parser.exit(1, f"Localizations: {error}\n")
    encoded = content.encode("utf-8")
    if not args.output.exists() or args.output.read_bytes() != encoded:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_bytes(encoded)


if __name__ == "__main__":
    main()
