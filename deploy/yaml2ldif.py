#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.9"
# dependencies = ["pyyaml>=6"]
# ///
"""Convert LDAP entries written in YAML to RFC 2849 LDIF.

  ./yaml2ldif.py people.yaml                 write LDIF to stdout
  ./yaml2ldif.py people.yaml -o people.ldif  write LDIF to a file
  cat people.yaml | ./yaml2ldif.py           read stdin (or pass "-")
  ./yaml2ldif.py --check people.yaml         validate only

Input is a list of entries, or a mapping with `entries` and an optional `base`, which
is appended to any dn not already under it. Top-level keys starting `x-` are ignored,
so they can hold YAML anchors. Multiple YAML documents are concatenated.

  base: dc=example,dc=org
  x-person: &person
    objectClass: [top, person, inetOrgPerson]
  entries:
    - dn: ou=people
      objectClass: [top, organizationalUnit]
      ou: people
    - <<: *person
      dn: uid=jdoe,ou=people
      cn: Jane Doe
      sn: Doe
      mail: [jdoe@example.org, jane.doe@example.org]
      employeeNumber: 001234
      jpegPhoto: !!binary /9j/4AAQSkZJRg==

Every plain scalar is kept as a string, so 001234, 1.10, 2026-11-05 and `no` reach LDAP
exactly as written. Write LDAP booleans as TRUE or FALSE. `!!binary` gives raw bytes.
Entries are emitted in file order, so list parents before children. Output is add
content only; changetype records are rejected, not passed through.

Exit codes: 0 ok, 2 validation or input error.
"""
import argparse
import base64
import re
import sys
from pathlib import Path

import yaml

ATTR_RE = re.compile(r"^(?:[A-Za-z][A-Za-z0-9-]*|\d+(?:\.\d+)*)(?:;[A-Za-z0-9-]+)*$")
# would turn the entry into a change record if written as an attribute
RESERVED_ATTRS = {"changetype", "control", "version"}
LINE_WIDTH = 76
MERGE_TAG = "tag:yaml.org,2002:merge"


class StringLoader(yaml.SafeLoader):
    """SafeLoader with implicit typing off, except for the `<<` merge key."""

    def construct_mapping(self, node, deep=False):
        seen = set()
        for key_node, _ in node.value:
            if key_node.tag == MERGE_TAG or not isinstance(key_node, yaml.ScalarNode):
                continue
            if key_node.value in seen:
                raise yaml.constructor.ConstructorError(
                    None, None, f"duplicate key {key_node.value!r}", key_node.start_mark
                )
            seen.add(key_node.value)
        return super().construct_mapping(node, deep=deep)


StringLoader.yaml_implicit_resolvers = {
    first: kept
    for first, resolvers in yaml.SafeLoader.yaml_implicit_resolvers.items()
    if (kept := [r for r in resolvers if r[0] == MERGE_TAG])
}


def to_bytes(value):
    """Return an attribute value as bytes, or raise ValueError."""
    if isinstance(value, bytes):
        return value
    if isinstance(value, bool):
        return b"TRUE" if value else b"FALSE"
    if value is None or isinstance(value, (dict, list)):
        raise ValueError(f"unsupported value {value!r}")
    try:
        return str(value).encode("utf-8")
    except UnicodeEncodeError as e:
        raise ValueError(f"value is not valid Unicode: {e}") from None


def is_safe(data):
    """True if RFC 2849 allows data as a plain SAFE-STRING with no trailing space."""
    if not data:
        return True
    if data[0] in b" :<" or data[-1] == 0x20:
        return False
    return all(0 < b < 0x80 and b not in b"\r\n" for b in data)


def fold(line):
    """Fold a line to LINE_WIDTH. Only ever given ASCII, so chars are bytes."""
    if len(line) <= LINE_WIDTH:
        return line
    parts = [line[:LINE_WIDTH]]
    step = LINE_WIDTH - 1  # continuation lines lose a column to the leading space
    parts += [line[i : i + step] for i in range(LINE_WIDTH, len(line), step)]
    return "\n ".join(parts)


def attr_line(name, data):
    if not data:
        return f"{name}:"
    if is_safe(data):
        return fold(f"{name}: {data.decode('ascii')}")
    return fold(f"{name}:: {base64.b64encode(data).decode('ascii')}")


def full_dn(dn, base):
    if not base:
        return dn
    compact = re.sub(r",\s+", ",", dn).lower()
    suffix = re.sub(r",\s+", ",", base).lower()
    if compact == suffix or compact.endswith("," + suffix):
        return dn
    return f"{dn},{base}"


def entry_to_ldif(entry, base):
    """Return (dn, LDIF text) for one entry, or raise ValueError."""
    if not isinstance(entry, dict):
        raise ValueError("entry is not a mapping")
    bad_keys = [k for k in entry if not isinstance(k, str)]
    if bad_keys:
        raise ValueError(f"attribute name is not a string: {bad_keys[0]!r}")
    attrs = dict(entry)
    dn_keys = [k for k in attrs if k.lower() == "dn"]
    if len(dn_keys) != 1:
        raise ValueError("entry needs exactly one dn")
    dn = attrs.pop(dn_keys[0])
    if not isinstance(dn, str) or "=" not in dn:
        raise ValueError(f"bad dn {dn!r}")
    dn = full_dn(dn, base)

    names = {}
    for name in attrs:
        if name.lower() in RESERVED_ATTRS:
            raise ValueError(f"{name}: change records are not supported")
        if not ATTR_RE.match(name):
            raise ValueError(f"bad attribute name {name!r}")
        if name.lower() in names:
            raise ValueError(f"{name} and {names[name.lower()]} are the same attribute")
        names[name.lower()] = name
    if "objectclass" not in names:
        raise ValueError("entry has no objectClass")

    lines = [attr_line("dn", to_bytes(dn))]
    # objectClass first, for readers; the rest in the order written
    ordered = sorted(attrs, key=lambda n: n.lower() != "objectclass")
    for name in ordered:
        raw = attrs[name]
        values = raw if isinstance(raw, list) else [raw]
        if not values:
            raise ValueError(f"{name}: empty list")
        seen = set()
        for value in values:
            try:
                data = to_bytes(value)
            except ValueError as e:
                raise ValueError(f"{name}: {e}") from None
            if data in seen:
                raise ValueError(f"{name}: duplicate value {value!r}")
            seen.add(data)
            lines.append(attr_line(name, data))
    return dn, "\n".join(lines) + "\n"


def doc_entries(doc):
    """Return (entries, base) for one YAML document, or raise ValueError."""
    if doc is None or isinstance(doc, list):
        return doc or [], None
    if not isinstance(doc, dict):
        raise ValueError("document must be a list of entries, or a mapping with `entries`")
    unknown = [k for k in doc if k not in ("base", "entries") and not str(k).startswith("x-")]
    if unknown:
        raise ValueError(f"unknown top-level key {unknown[0]!r}")
    entries, base = doc.get("entries"), doc.get("base")
    if not isinstance(entries, list):
        raise ValueError("`entries` must be a list")
    if base is not None and not isinstance(base, str):
        raise ValueError("`base` must be a string")
    return entries, base


def convert(text):
    """Return (LDIF text, errors). Reports every bad entry, not only the first."""
    blocks, errors, seen_dns = [], [], set()
    try:
        docs = list(yaml.load_all(text, Loader=StringLoader))
    except yaml.YAMLError as e:
        return "", [f"YAML: {e}"]
    for doc_no, doc in enumerate(docs, 1):
        try:
            entries, base = doc_entries(doc)
        except ValueError as e:
            errors.append(f"document {doc_no}: {e}")
            continue
        for entry_no, entry in enumerate(entries, 1):
            where = f"document {doc_no}, entry {entry_no}"
            try:
                dn, block = entry_to_ldif(entry, base)
            except ValueError as e:
                errors.append(f"{where}: {e}")
                continue
            key = re.sub(r",\s+", ",", dn).lower()
            if key in seen_dns:
                errors.append(f"{where}: duplicate dn {dn}")
                continue
            seen_dns.add(key)
            blocks.append(block)
    if not blocks and not errors:
        errors.append("no entries found")
    return "version: 1\n\n" + "\n".join(blocks), errors


def main():
    parser = argparse.ArgumentParser(description="Convert LDAP entries in YAML to LDIF.")
    parser.add_argument("input", nargs="?", default="-", help="YAML file, or - for stdin")
    parser.add_argument("-o", "--output", help="LDIF file (default: stdout)")
    parser.add_argument("--check", action="store_true", help="validate only, write nothing")
    args = parser.parse_args()
    try:
        raw = sys.stdin.buffer.read() if args.input == "-" else Path(args.input).read_bytes()
    except OSError as e:
        print(f"yaml2ldif: {e}", file=sys.stderr)
        return 2
    ldif, errors = convert(raw)
    for error in errors:
        print(f"yaml2ldif: {error}", file=sys.stderr)
    if errors:
        return 2
    if args.check:
        return 0
    if args.output:
        Path(args.output).write_text(ldif, encoding="ascii")
    else:
        sys.stdout.write(ldif)
    return 0


if __name__ == "__main__":
    sys.exit(main())
