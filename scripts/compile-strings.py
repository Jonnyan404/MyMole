#!/usr/bin/env python3
"""Compile Localization/Localizable.xcstrings into <locale>.lproj/Localizable.strings.

Xcode's xcstringstool does this for an official build. The packaging script here
assembles a bundle by hand, so it has to do the same thing itself:
String(localized:) resolves against Bundle.main, and with no .lproj to find it
falls back to the key, which is the English source. A translation in the catalog
changes nothing on screen until it is compiled in.

Plural variations are deliberately not compiled here. Turning a catalog entry
into a .stringsdict means inventing the NSStringLocalizedFormatKey and the
variable name around which each case is built, and the catalog doesn't carry
those. Entries with variations are counted and reported instead, so they are
loudly missing rather than quietly wrong.

Usage: compile-strings.py <Localizable.xcstrings> <Resources directory>
"""
import json
import os
import sys


def escape(text):
    return (text.replace("\\", "\\\\")
                .replace('"', '\\"')
                .replace("\n", "\\n")
                .replace("\t", "\\t"))


def main():
    if len(sys.argv) != 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    catalog_path, resources = sys.argv[1], sys.argv[2]

    with open(catalog_path) as handle:
        catalog = json.load(handle)
    source = catalog.get("sourceLanguage", "en")

    per_locale = {}
    unhandled = 0
    for key, entry in catalog.get("strings", {}).items():
        for locale, localization in entry.get("localizations", {}).items():
            unit = localization.get("stringUnit")
            if unit is None:
                if "variations" in localization:
                    unhandled += 1
                continue
            per_locale.setdefault(locale, {})[key] = unit.get("value", key)

    os.makedirs(resources, exist_ok=True)
    written = 0
    for locale, table in sorted(per_locale.items()):
        if not table:
            continue
        folder = os.path.join(resources, locale + ".lproj")
        os.makedirs(folder, exist_ok=True)
        lines = ["/* Compiled from Localization/Localizable.xcstrings. Do not edit. */"]
        for key, value in table.items():
            lines.append(f'"{escape(key)}" = "{escape(value)}";')
        with open(os.path.join(folder, "Localizable.strings"), "w", encoding="utf-8") as out:
            out.write("\n".join(lines) + "\n")
        print(f"compile-strings: {locale} — {len(table)} strings")
        written += 1

    if not written:
        print(f"compile-strings: no translations in the catalog (source {source})")
    if unhandled:
        print(f"compile-strings: skipped {unhandled} plural variation entries "
              f"(they need .stringsdict, which this step doesn't build)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
