#!/usr/bin/env python3
"""Compile Localization/Localizable.xcstrings into <locale>.lproj/Localizable.strings
and, for phrases with counted nouns, <locale>.lproj/Localizable.stringsdict.

Xcode's xcstringstool does this for an official build. The packaging script here
assembles a bundle by hand, so it has to do the same thing itself:
String(localized:) resolves against Bundle.main, and with no .lproj to find it
falls back to the key, which is the English source. A translation in the catalog
changes nothing on screen until it is compiled in.

A phrase whose catalog entry carries plural substitutions becomes a stringsdict
entry: the catalog's `substitutions` name the variables the format string refers
to, each with the argument it stands for and its plural cases. The catalog keeps
no `NSStringLocalizedFormatKey` of its own — the format string is the entry's
own value, which is what the key would have been — so that is what is written.
Languages that don't count nouns the way English does (Chinese has one case,
`other`) simply declare the cases they have.

Usage: compile-strings.py <Localizable.xcstrings> <Resources directory>
"""
import json
import os
import sys

PLURAL_RULE = "NSStringPluralRuleType"


def escape(text):
    return (text.replace("\\", "\\\\")
                .replace('"', '\\"')
                .replace("\n", "\\n")
                .replace("\t", "\\t"))


def xml_escape(text):
    return (text.replace("&", "&amp;")
                .replace("<", "&lt;")
                .replace(">", "&gt;"))


def plural_cases(localization):
    """The plural cases under each substitution, in the order the catalog has them."""
    out = {}
    for name, substitution in localization.get("substitutions", {}).items():
        cases = (substitution.get("variations", {}).get("plural") or {})
        if not cases:
            continue
        out[name] = (substitution.get("formatSpecifier", "lld"), cases)
    return out


def stringsdict_entry(key, localization):
    """The dictionary for one phrase, or None when it counts nothing.

    The catalog writes the count as `%arg`, which is what Xcode's catalog editor
    shows and what xcstringstool turns into a real specifier when it compiles.
    A .stringsdict has no such notation: left as `%arg`, printf reads it as a
    hexadecimal float (`%a`) followed by "rg". Each substitution's text gets its
    own argument back, positionally, so a phrase that also names an app or a size
    keeps every argument pointing where the source phrase had it.
    """
    cases = plural_cases(localization)
    if not cases:
        return None
    unit = localization.get("stringUnit") or {}
    body = unit.get("value") or key
    entry = {"NSStringLocalizedFormatKey": body}
    for name, (specifier, variants) in cases.items():
        argument = (localization.get("substitutions", {}).get(name) or {}).get("argNum", 1)
        rule = {"NSStringFormatSpecTypeKey": PLURAL_RULE,
                "NSStringFormatValueTypeKey": specifier}
        for case, node in variants.items():
            value = (node.get("stringUnit") or {}).get("value")
            if value is not None:
                rule[case] = value.replace("%arg", f"%{argument}${specifier}")
        entry[name] = rule
    return entry


def plist(entries):
    lines = ['<?xml version="1.0" encoding="UTF-8"?>',
             '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
             '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
             '<plist version="1.0">',
             '<dict>']
    for key, entry in entries.items():
        lines.append(f"\t<key>{xml_escape(key)}</key>")
        lines.append("\t<dict>")
        for field, value in entry.items():
            lines.append(f"\t\t<key>{field}</key>")
            if isinstance(value, dict):
                lines.append("\t\t<dict>")
                for sub_field, sub_value in value.items():
                    lines.append(f"\t\t\t<key>{sub_field}</key>")
                    lines.append(f"\t\t\t<string>{xml_escape(str(sub_value))}</string>")
                lines.append("\t\t</dict>")
            else:
                lines.append(f"\t\t<string>{xml_escape(value)}</string>")
        lines.append("\t</dict>")
    lines += ['</dict>', '</plist>', '']
    return "\n".join(lines)


def main():
    if len(sys.argv) != 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    catalog_path, resources = sys.argv[1], sys.argv[2]

    with open(catalog_path) as handle:
        catalog = json.load(handle)
    source = catalog.get("sourceLanguage", "en")
    strings = catalog.get("strings", {})

    tables = {}       # locale -> key -> text
    dicts = {}        # locale -> key -> stringsdict entry
    for key, entry in strings.items():
        for locale, localization in entry.get("localizations", {}).items():
            counted = stringsdict_entry(key, localization)
            if counted is not None:
                dicts.setdefault(locale, {})[key] = counted
                continue
            unit = localization.get("stringUnit")
            if unit is None:
                continue
            tables.setdefault(locale, {})[key] = unit.get("value", key)

    # The source language's text is the key itself unless the catalog says
    # otherwise, as it does for a phrase with plural forms. Write it out anyway:
    # a bundle whose only .lproj folder is another language offers no English,
    # either in the per-app language list in System Settings or in MyMole's own
    # Language picker, which reads the folders.
    english = {key: key for key in strings if key and key not in dicts.get(source, {})}
    english.update(tables.get(source, {}))
    tables[source] = english

    os.makedirs(resources, exist_ok=True)
    written = 0
    for locale in sorted(set(tables) | set(dicts)):
        table = tables.get(locale, {})
        counted = dicts.get(locale, {})
        if not table and not counted:
            continue
        folder = os.path.join(resources, locale + ".lproj")
        os.makedirs(folder, exist_ok=True)
        if table:
            lines = ["/* Compiled from Localization/Localizable.xcstrings. Do not edit. */"]
            for key, value in table.items():
                lines.append(f'"{escape(key)}" = "{escape(value)}";')
            with open(os.path.join(folder, "Localizable.strings"), "w", encoding="utf-8") as out:
                out.write("\n".join(lines) + "\n")
        if counted:
            with open(os.path.join(folder, "Localizable.stringsdict"), "w", encoding="utf-8") as out:
                out.write(plist(counted))
        print(f"compile-strings: {locale} — {len(table)} strings, {len(counted)} counted")
        written += 1

    if not written:
        print(f"compile-strings: no translations in the catalog (source {source})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
