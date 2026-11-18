#!/usr/bin/env python3
"""Keeps half-finished languages out of a release.

Every language in the string catalog other than the source language must
translate every phrase the code still uses, and each translation must use
the same format arguments as its phrase: the same kind for each argument,
in any order. The source language's own texts, such as its plural forms,
are held to the same arguments. A language that isn't complete stays out of the catalog until
it is.

Usage: scripts/check-translations.py [--missing LANGUAGE] [catalog]
  --missing  lists every phrase LANGUAGE still lacks or gets wrong, one per
             line, instead of the summary: the to-do list for a translator.
Exit status: 0 when every language is complete, 1 when one isn't, 2 when the
catalog can't be read.
"""
import json
import re
import sys
from pathlib import Path

SPECIFIER = re.compile(r"%(?:(\d+)\$)?(#@\w+@|lld|ld|d|@|arg|%)")
KINDS = {"lld": "number", "ld": "number", "d": "number", "@": "object"}


def arguments(key):
    return [KINDS[m.group(2)] for m in SPECIFIER.finditer(key) if m.group(2) != "%"]


def leaves(node, path):
    """Each translated text under a localization or variation, with where it is."""
    if "stringUnit" in node:
        yield path, node["stringUnit"]
    for kind, cases in node.get("variations", {}).items():
        for case, child in cases.items():
            yield from leaves(child, f"{path}/{kind}.{case}")


def problems(key, loc, translated=True):
    args = arguments(key)
    subs = loc.get("substitutions", {})
    found = []

    def check(path, text, in_substitution):
        seen, position = set(), 0
        for m in SPECIFIER.finditer(text):
            explicit, kind = m.group(1), m.group(2)
            if kind == "%":
                continue
            if kind == "arg":
                if not in_substitution:
                    found.append(f"{path}: %arg outside a substitution")
                continue
            position += 1
            index = int(explicit) if explicit else position
            if kind.startswith("#@"):
                name = kind[2:-1]
                if name not in subs:
                    found.append(f"{path}: no substitution named {name}")
                    continue
                index = subs[name].get("argNum", index)
                kind = subs[name].get("formatSpecifier", "")
            if not 1 <= index <= len(args):
                found.append(f"{path}: argument {index} doesn't exist; the phrase has {len(args)}")
            elif KINDS.get(kind) != args[index - 1]:
                found.append(f"{path}: argument {index} must be a {args[index - 1]}, not %{kind}")
            seen.add(index)
        return seen

    top = list(leaves(loc, ""))
    if not top:
        found.append("no text")
    for path, unit in top:
        if translated and unit.get("state") != "translated":
            found.append(f"{path or 'text'}: state is {unit.get('state')}")
        seen = check(path or "text", unit.get("value", ""), False)
        missing = sorted(set(range(1, len(args) + 1)) - seen)
        if not subs and "variations" not in loc and missing:
            found.append(f"text: argument {', '.join(map(str, missing))} is left out")
    for name, sub in subs.items():
        for path, unit in leaves(sub, f"substitution {name}"):
            if translated and unit.get("state") != "translated":
                found.append(f"{path}: state is {unit.get('state')}")
            check(path, unit.get("value", ""), True)
    return found


def main(argv):
    args = argv[1:]
    only = None
    if args[:1] == ["--missing"]:
        if len(args) < 2:
            print("check-translations: --missing needs a language", file=sys.stderr)
            return 2
        only, args = args[1], args[2:]
    path = Path(args[0] if args else "Localization/Localizable.xcstrings")
    try:
        catalog = json.loads(path.read_text())
        source = catalog["sourceLanguage"]
        strings = catalog["strings"]
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"check-translations: can't read {path}: {error}", file=sys.stderr)
        return 2
    used = {k: v for k, v in strings.items()
            if v.get("extractionState") != "stale" and v.get("shouldTranslate", True)}
    languages = sorted({lang for v in strings.values() for lang in v.get("localizations", {})} - {source})
    if only is not None:
        todo = [(k, ["missing"]) for k, v in used.items() if only not in v.get("localizations", {})]
        todo += [(k, p) for k, v in used.items() if only in v.get("localizations", {})
                 for p in [problems(k, v["localizations"][only])] if p]
        for key, found in sorted(todo):
            print(f"{json.dumps(key, ensure_ascii=False)}\t{'; '.join(found)}")
        print(f"Translations: {only} needs {len(todo)} of {len(used)} phrases.", file=sys.stderr)
        return 1 if todo else 0
    failed = False
    for key, v in strings.items():
        found = problems(key, v["localizations"][source], translated=False) if source in v.get("localizations", {}) else []
        if found:
            failed = True
            print(f"Translations: the {source} text of {key!r} doesn't fit its phrase: {'; '.join(found)}", file=sys.stderr)
    for lang in languages:
        missing = [k for k, v in used.items() if lang not in v.get("localizations", {})]
        wrong = {k: p for k, v in used.items() if lang in v.get("localizations", {})
                 for p in [problems(k, v["localizations"][lang])] if p}
        if not missing and not wrong:
            print(f"Translations: {lang} covers all {len(used)} phrases.")
            continue
        failed = True
        done = len(used) - len(missing) - len(wrong)
        print(f"Translations: {lang} is complete for {done} of {len(used)} phrases, so it can't ship.", file=sys.stderr)
        for key in missing[:10]:
            print(f"  missing: {key!r}", file=sys.stderr)
        for key, found in list(wrong.items())[:10]:
            print(f"  {key!r}: {'; '.join(found)}", file=sys.stderr)
        rest = max(0, len(missing) - 10) + max(0, len(wrong) - 10)
        if rest:
            print(f"  … and {rest} more", file=sys.stderr)
    if not languages:
        print(f"Translations: none yet; {len(used)} phrases in {source}.")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
