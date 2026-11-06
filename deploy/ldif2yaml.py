#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.9"
# dependencies = ["pyyaml>=6"]
# ///
"""Convert RFC 2849 LDIF content records to YAML that yaml2ldif.py reads back.

  ./ldif2yaml.py people.ldif                 write YAML to stdout
  ./ldif2yaml.py people.ldif -o people.yaml  write YAML to a file
  cat people.ldif | ./ldif2yaml.py           read stdin (or pass "-")

Base64 values that decode to UTF-8 become strings; anything else becomes `!!binary`.
Repeated attributes are grouped under the first spelling of the name. Comments, line
folding and which values were base64 in the input are not kept.

Change records and `attr:< URL` values are rejected.

Exit codes: 0 ok, 2 parse or input error.
"""
import argparse
import base64
import binascii
import re
import sys
from pathlib import Path

import yaml

ATTR_RE = re.compile(rb"^([A-Za-z0-9][A-Za-z0-9;.-]*)(::?|:<)[ ]*(.*)$", re.DOTALL)


def logical_lines(raw):
    """Yield unfolded lines, with None for each blank line and comments dropped."""
    current = None
    for line in re.split(rb"\r?\n", raw):
        if line.startswith(b" ") and current is not None:
            current += line[1:]
            continue
        if current is not None and not current.startswith(b"#"):
            yield current
        if line:
            current = line
        else:
            current = None
            yield None
    if current is not None and not current.startswith(b"#"):
        yield current


def parse_value(line):
    """Return (name, bytes value) for one logical line, or raise ValueError."""
    match = ATTR_RE.match(line)
    if not match:
        raise ValueError(f"cannot parse line {line[:60]!r}")
    name, sep, value = match.groups()
    name = name.decode("ascii")
    if sep == b":<":
        raise ValueError(f"{name}: URL values are not supported")
    if sep == b"::":
        try:
            value = base64.b64decode(value, validate=True)
        except binascii.Error as e:
            raise ValueError(f"{name}: bad base64: {e}") from None
    return name, value


def text_or_bytes(data):
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        return data


def add_entry(entries, records):
    dn_name, dn = records[0]
    if dn_name.lower() != "dn":
        raise ValueError(f"record starts with {dn_name}, not dn")
    attrs, spelling = {}, {}
    for name, value in records[1:]:
        if name.lower() in ("changetype", "control"):
            raise ValueError(f"{name}: change records are not supported")
        attrs.setdefault(spelling.setdefault(name.lower(), name), []).append(text_or_bytes(value))
    dn = text_or_bytes(dn)
    if isinstance(dn, bytes):
        raise ValueError("dn is not UTF-8")
    entry = {"dn": dn}
    for name, values in attrs.items():
        entry[name] = values[0] if len(values) == 1 else values
    entries.append(entry)


def parse_ldif(raw):
    """Return a list of entries, or raise ValueError."""
    entries, records = [], []
    for line in logical_lines(raw):
        if line is None:
            if records:
                add_entry(entries, records)
                records = []
            continue
        if not records and not entries and re.fullmatch(rb"version:\s*\d+", line):
            continue
        records.append(parse_value(line))
    if records:
        add_entry(entries, records)
    if not entries:
        raise ValueError("no entries found")
    return entries


class Dumper(yaml.SafeDumper):
    """SafeDumper that escapes Unicode line breaks.

    Written raw, these are line breaks to a YAML reader, and folding turns them to spaces.
    """


def represent_str(dumper, value):
    style = '"' if re.search("[\x85  ]", value) else None
    return dumper.represent_scalar("tag:yaml.org,2002:str", value, style=style)


Dumper.add_representer(str, represent_str)


def main():
    parser = argparse.ArgumentParser(description="Convert LDIF content records to YAML.")
    parser.add_argument("input", nargs="?", default="-", help="LDIF file, or - for stdin")
    parser.add_argument("-o", "--output", help="YAML file (default: stdout)")
    args = parser.parse_args()
    try:
        raw = sys.stdin.buffer.read() if args.input == "-" else Path(args.input).read_bytes()
        entries = parse_ldif(raw)
    except (OSError, ValueError) as e:
        print(f"ldif2yaml: {e}", file=sys.stderr)
        return 2
    text = yaml.dump(
        entries,
        Dumper=Dumper,
        allow_unicode=True,
        sort_keys=False,
        default_flow_style=False,
        width=10**6,
    )
    if args.output:
        Path(args.output).write_text(text, encoding="utf-8")
    else:
        sys.stdout.reconfigure(encoding="utf-8")
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
