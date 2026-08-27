#!/usr/bin/env python3
"""Dump an .xlsx/.xlsm workbook as a plain-text cell listing (stdlib only).

Wrapper-side preprocessing for the Essence interview (META.md §2.1.4-2):
the read-only interview session cannot parse binary workbooks (the Read
tool handles text/images only, and Bash is confined to the handoff heredoc
— G-T2), so the Essence interview pre-dumps every Excel asset under
PROJECT_ROOT/essences/ into the handoff dir as text the session can Read.
This runs on the trusted human side BEFORE the session starts: the
session's permission surface is unchanged (I-027), the originals stay
human-only (I-004), and the dumps die with the handoff dir.

Usage: xlsx-dump.py <workbook.xlsx> <out.txt> [<display-label>]

Output format (one file per workbook):
  # header lines (label, format note, sheet inventory)
  ## sheet: <name> (dimension <ref>)
  <cell>\t<value>              e.g.  B4\t縦軸(複数指定)
  <cell>\t<value>\t=<formula>  formula cells: cached value, then formula
  ## merged: <ref> <ref> ...   merged ranges, when present

Values are the cached results stored in the file; empty cells are omitted.
Rows beyond MAX_ROWS_PER_SHEET are truncated with an explicit notice — the
guidance/layout sheets the interview needs stay far below the cap, only
bulk data sheets truncate. Exit nonzero on an unreadable workbook; the
wrapper treats that as a warning and continues without the dump.
"""

import sys
import xml.etree.ElementTree as ET
import zipfile

MAIN_NS = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
REL_ATTR = (
    "{http://schemas.openxmlformats.org/officeDocument/2006/relationships}id"
)
PKG_REL_NS = "http://schemas.openxmlformats.org/package/2006/relationships"

MAX_ROWS_PER_SHEET = 500


def q(tag):
    return f"{{{MAIN_NS}}}{tag}"


def col_letter(index):
    """1-based column index -> A1-style letters."""
    letters = ""
    while index > 0:
        index, rem = divmod(index - 1, 26)
        letters = chr(ord("A") + rem) + letters
    return letters


def col_index(ref):
    """A1-style cell ref -> 1-based column index."""
    index = 0
    for ch in ref:
        if ch.isalpha():
            index = index * 26 + (ord(ch.upper()) - ord("A") + 1)
        else:
            break
    return index


def text_of(si):
    """Concatenated text of every <t> under a shared-string / inline item."""
    return "".join(t.text or "" for t in si.iter(q("t")))


def load_shared_strings(zf):
    try:
        data = zf.read("xl/sharedStrings.xml")
    except KeyError:
        return []
    root = ET.fromstring(data)
    return [text_of(si) for si in root.findall(q("si"))]


def load_sheets(zf):
    """[(name, zip path)] in workbook order."""
    workbook = ET.fromstring(zf.read("xl/workbook.xml"))
    rels = ET.fromstring(zf.read("xl/_rels/workbook.xml.rels"))
    target_by_id = {}
    for rel in rels.findall(f"{{{PKG_REL_NS}}}Relationship"):
        target = rel.get("Target", "")
        if target.startswith("/"):
            target = target.lstrip("/")
        else:
            target = f"xl/{target}"
        target_by_id[rel.get("Id")] = target
    sheets = []
    for sheet in workbook.iter(q("sheet")):
        target = target_by_id.get(sheet.get(REL_ATTR))
        if target and target in zf.namelist():
            sheets.append((sheet.get("name", "?"), target))
    return sheets


def cell_value(cell, shared):
    ctype = cell.get("t", "n")
    v = cell.find(q("v"))
    raw = v.text if v is not None and v.text is not None else ""
    if ctype == "s":
        try:
            return shared[int(raw)]
        except (ValueError, IndexError):
            return raw
    if ctype == "inlineStr":
        is_el = cell.find(q("is"))
        return text_of(is_el) if is_el is not None else ""
    if ctype == "b":
        return "TRUE" if raw == "1" else "FALSE"
    return raw  # n / str / e — numbers, formula strings, #REF! errors


def sanitize(value):
    """Keep the dump line-oriented: no control chars, TAB/NL become spaces."""
    return "".join(ch if ch.isprintable() else " " for ch in value)


def dump_sheet(zf, name, target, shared, out):
    dimension = ""
    merged = []
    rows_seen = 0
    truncated_at = None
    lines = []
    # iterparse so a 20k-row data sheet can stop at the cap without
    # materializing the whole tree.
    with zf.open(target) as fh:
        row_num = 0
        for _, el in ET.iterparse(fh):
            if el.tag == q("dimension"):
                dimension = el.get("ref", "")
            elif el.tag == q("mergeCell"):
                merged.append(el.get("ref", ""))
            elif el.tag == q("row"):
                row_num = int(el.get("r", row_num + 1))
                rows_seen += 1
                if truncated_at is None:
                    if rows_seen > MAX_ROWS_PER_SHEET:
                        truncated_at = row_num
                    else:
                        col = 0
                        for cell in el.findall(q("c")):
                            ref = cell.get("r")
                            col = col_index(ref) if ref else col + 1
                            if not ref:
                                ref = f"{col_letter(col)}{row_num}"
                            value = sanitize(cell_value(cell, shared))
                            f_el = cell.find(q("f"))
                            formula = (
                                sanitize(f_el.text)
                                if f_el is not None and f_el.text
                                else ""
                            )
                            if formula:
                                lines.append(f"{ref}\t{value}\t={formula}")
                            elif value != "":
                                lines.append(f"{ref}\t{value}")
                el.clear()
    dim_note = f" (dimension {dimension})" if dimension else ""
    out.write(f"\n## sheet: {sanitize(name)}{dim_note}\n")
    if not lines:
        out.write("(no non-empty cells)\n")
    out.writelines(line + "\n" for line in lines)
    if truncated_at is not None:
        out.write(
            f"## (truncated: rows from {truncated_at} on omitted — "
            f"{rows_seen} rows total, showing the first "
            f"{MAX_ROWS_PER_SHEET}; open the workbook itself for the rest)\n"
        )
    if merged:
        out.write(f"## merged: {' '.join(merged)}\n")


def main(argv):
    if len(argv) < 3:
        print(
            f"usage: {sys.argv[0].rsplit('/', 1)[-1]} <workbook.xlsx> <out.txt> [<label>]",
            file=sys.stderr,
        )
        return 2
    src, dest = argv[1], argv[2]
    label = argv[3] if len(argv) > 3 else src
    with zipfile.ZipFile(src) as zf:
        shared = load_shared_strings(zf)
        sheets = load_sheets(zf)
        with open(dest, "w", encoding="utf-8") as out:
            out.write(
                f"# xlsx dump: {label} — read-only derived text; "
                "the workbook itself is the authority (I-004)\n"
                "# format: <cell>\\t<value> per non-empty cell; "
                "formula cells add \\t=<formula> (value = cached result)\n"
                f"# sheets: {' | '.join(sanitize(n) for n, _ in sheets)}\n"
            )
            for name, target in sheets:
                dump_sheet(zf, name, target, shared, out)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
