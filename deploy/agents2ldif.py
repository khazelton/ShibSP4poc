#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.9"
# dependencies = ["pyyaml>=6"]
# ///
"""Convert a hub flat-file agent list (agents.txt) to RFC 2849 LDIF.

  ./agents2ldif.py agents.txt --base-dn ou=agents,dc=example,dc=org
  ./agents2ldif.py agents.txt --base-dn ... -o agents.ldif
  cat agents.txt | ./agents2ldif.py --base-dn ...
  ./agents2ldif.py agents.txt --base-dn ... --check          validate only

agents.txt has no DN, object classes or LDAP attribute names, so these come from flags:

  --base-dn DN         parent of every entry (required)
  --rdn-attr ATTR      attribute used in the DN (default cn); must have one value
  --object-class NAME  repeatable (default top, extensibleObject)
  --map FIELD=ATTR     agent field to LDAP attribute, repeatable
                       (default id=cn, username=uid; others keep their own name)
  --default ATTR=VAL   extra attribute on every entry, repeatable

The file is read as the hub's FlatFileExternalAgentResolver reads it: one `field: value`
per line, a blank line ends a record, and `#` starts a comment only at line start, so a
trailing `# note` stays in the value. The hub logs and skips bad lines and records, but
here they are errors, so a typo can't quietly drop a username.

The server must define every attribute written. allowedRange, issuer and authority have
no standard LDAP attribute, so map them to ones your schema has. No secrets are written.

Exit codes: 0 ok, 2 validation or input error.
"""
import argparse
import re
import sys
from pathlib import Path

from yaml2ldif import entry_to_ldif

SINGLE_FIELDS = {"id", "issuer", "authority"}
FIELDS = SINGLE_FIELDS | {"allowedRange", "username"}
DEFAULT_MAP = {"id": "cn", "username": "uid"}
DEFAULT_OBJECT_CLASSES = ("top", "extensibleObject")


def parse_agents(text):
    """Return (records, errors). Each record is (first line number, {field: [values]})."""
    records, errors = [], []
    fields, start = {}, 0
    # the final "" closes a last record that has no blank line after it
    for number, raw in enumerate(text.split("\n") + [""], 1):
        line = raw.rstrip("\r")
        if not line.strip():
            if fields and "id" in fields:
                records.append((start, fields))
            elif fields:
                errors.append(f"line {start}: record has no id")
            fields = {}
            continue
        if line.startswith("#"):
            continue
        name, colon, value = line.partition(":")
        value = value.strip()
        if not colon or name not in FIELDS:
            errors.append(f"line {number}: unrecognized line {line!r}")
        elif not value:
            errors.append(f"line {number}: {name} has no value")
        elif name in SINGLE_FIELDS and name in fields:
            errors.append(f"line {number}: repeated {name}")
        else:
            if not fields:
                start = number
            fields.setdefault(name, []).append(value)
    return records, errors


def escape_rdn_value(value):
    """Escape a DN attribute value per RFC 4514."""
    escaped = re.sub(r'([\\,+"<>;=])', r"\\\1", value)
    if escaped[0] in "# ":
        escaped = "\\" + escaped
    if escaped.endswith(" "):
        escaped = escaped[:-1] + "\\ "
    return escaped


def record_to_entry(fields, base_dn, rdn_attr, object_classes, attr_map, defaults):
    """Return the entry mapping yaml2ldif writes for one record, or raise ValueError."""
    attrs = {"objectClass": list(object_classes)}
    for field, values in fields.items():
        attrs.setdefault(attr_map.get(field, field), []).extend(values)
    for attr, values in defaults.items():
        attrs.setdefault(attr, []).extend(values)
    if any(name.lower() == "dn" for name in attrs):
        raise ValueError("dn can't be used as an attribute name")
    rdn_values = attrs.get(rdn_attr, [])
    if len(rdn_values) != 1:
        raise ValueError(f"{rdn_attr} needs exactly one value for the DN, has {len(rdn_values)}")
    return {"dn": f"{rdn_attr}={escape_rdn_value(rdn_values[0])},{base_dn}", **attrs}


def agents_to_ldif(text, base_dn, rdn_attr="cn", object_classes=DEFAULT_OBJECT_CLASSES,
                   attr_map=None, defaults=None):
    """Return (LDIF text, errors). Reports every bad record, not only the first."""
    attr_map = {**DEFAULT_MAP, **(attr_map or {})}
    defaults = defaults or {}
    records, errors = parse_agents(text)
    blocks, seen_dns, username_owners = [], set(), {}
    for start, fields in records:
        agent = fields["id"][0]
        where = f"line {start} ({agent})"
        for username in fields.get("username", []):
            owner = username_owners.setdefault(username, agent)
            if owner != agent:
                errors.append(f"{where}: username {username} is also on {owner}")
        try:
            entry = record_to_entry(fields, base_dn, rdn_attr, object_classes, attr_map, defaults)
            dn, block = entry_to_ldif(entry, None)
        except ValueError as e:
            errors.append(f"{where}: {e}")
            continue
        key = dn.lower()
        if key in seen_dns:
            errors.append(f"{where}: duplicate dn {dn}")
            continue
        seen_dns.add(key)
        blocks.append(block)
    if not blocks and not errors:
        errors.append("no agents found")
    return "version: 1\n\n" + "\n".join(blocks), errors


def pair(text):
    """Split a NAME=VALUE flag."""
    name, sep, value = text.partition("=")
    if not (name and sep and value):
        raise argparse.ArgumentTypeError(f"expected NAME=VALUE, got {text!r}")
    return name, value


def main():
    parser = argparse.ArgumentParser(description="Convert a hub agents.txt to LDIF.")
    parser.add_argument("input", nargs="?", default="-", help="agent file, or - for stdin")
    parser.add_argument("--base-dn", required=True, help="parent DN of every entry")
    parser.add_argument("--rdn-attr", default="cn", help="attribute used in the DN (default cn)")
    parser.add_argument("--object-class", action="append", metavar="NAME",
                        help="repeatable (default top, extensibleObject)")
    parser.add_argument("--map", action="append", default=[], type=pair, metavar="FIELD=ATTR",
                        help="agent field to LDAP attribute, repeatable")
    parser.add_argument("--default", action="append", default=[], type=pair, metavar="ATTR=VAL",
                        help="extra attribute on every entry, repeatable")
    parser.add_argument("-o", "--output", help="LDIF file (default: stdout)")
    parser.add_argument("--check", action="store_true", help="validate only, write nothing")
    args = parser.parse_args()

    attr_map = dict(args.map)
    unknown = sorted(set(attr_map) - FIELDS)
    if unknown:
        print(f"agents2ldif: unknown field in --map: {unknown[0]}", file=sys.stderr)
        return 2
    defaults = {}
    for attr, value in args.default:
        defaults.setdefault(attr, []).append(value)

    try:
        raw = sys.stdin.buffer.read() if args.input == "-" else Path(args.input).read_bytes()
        text = raw.decode("utf-8")
    except (OSError, UnicodeDecodeError) as e:
        print(f"agents2ldif: {e}", file=sys.stderr)
        return 2
    ldif, errors = agents_to_ldif(text, args.base_dn, args.rdn_attr,
                                  args.object_class or DEFAULT_OBJECT_CLASSES, attr_map, defaults)
    for error in errors:
        print(f"agents2ldif: {error}", file=sys.stderr)
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
