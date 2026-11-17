#!/usr/bin/env python3
"""The translation check refuses incomplete languages and broken arguments."""
import json
import subprocess
import sys
from pathlib import Path

checker = Path(__file__).resolve().parent / "check-translations.py"


def unit(value, state="translated"):
    return {"stringUnit": {"state": state, "value": value}}


def plural(one, other):
    return {"variations": {"plural": {"one": unit(one), "other": unit(other)}}}


def catalog(strings):
    return {"sourceLanguage": "en", "version": "1.0", "strings": strings}


def phrases(sv=None, **extra):
    """Two phrases, translated into Swedish unless `sv` says otherwise."""
    sv = sv or {}
    strings = {
        "Scan": {"localizations": {"sv": sv.get("Scan", unit("Sök igenom"))}},
        "Moved %@ to the Trash in %lld runs": {"localizations": {
            "sv": sv.get("Moved", unit("Flyttade %1$@ till papperskorgen i %2$lld körningar"))}},
    }
    strings.update(extra)
    return strings


failures = []


def check(label, strings, expected, raw=None):
    text = raw if raw is not None else json.dumps(catalog(strings))
    result = subprocess.run([sys.executable, "-I", str(checker), "/dev/stdin"],
                            input=text, capture_output=True, text=True)
    if result.returncode != expected:
        failures.append(label)
        print(f"Failed: {label} (exit {result.returncode}, expected {expected})\n{result.stderr}")
    else:
        print(f"Verified: {label}")


check("no translations yet", {"Scan": {}}, 0)
check("a complete language", phrases(), 0)
check("arguments in another order", phrases(sv={"Moved": unit("I %2$lld körningar flyttades %1$@ till papperskorgen")}), 0)
check("a missing phrase", phrases(**{"Stop": {}}), 1)
check("a stale phrase isn't required", phrases(**{"Gone": {"extractionState": "stale"}}), 0)
check("a phrase marked not to translate", phrases(**{"MyMole": {"shouldTranslate": False}}), 0)
check("a translation needing review", phrases(sv={"Scan": unit("Sök", state="needs_review")}), 1)
check("an argument of the wrong kind", phrases(sv={"Moved": unit("Flyttade %1$@ till papperskorgen i %2$@ körningar")}), 1)
check("an argument left out", phrases(sv={"Moved": unit("Flyttade %@ till papperskorgen")}), 1)
check("an argument that doesn't exist", phrases(sv={"Scan": unit("Sök %@")}), 1)
check("a plural translation", phrases(sv={"Moved": {
    "stringUnit": {"state": "translated", "value": "Flyttade %1$@ till papperskorgen i %#@runs@"},
    "substitutions": {"runs": {"argNum": 2, "formatSpecifier": "lld",
                               **plural("%arg körning", "%arg körningar")}}}}), 0)
check("a plural on a text argument", phrases(sv={"Moved": {
    "stringUnit": {"state": "translated", "value": "Flyttade %#@what@ i %2$lld körningar"},
    "substitutions": {"what": {"argNum": 1, "formatSpecifier": "lld",
                               **plural("%arg sak", "%arg saker")}}}}), 1)
check("an unfinished plural form", phrases(sv={"Moved": {
    "stringUnit": {"state": "translated", "value": "Flyttade %1$@ till papperskorgen i %#@runs@"},
    "substitutions": {"runs": {"argNum": 2, "formatSpecifier": "lld", "variations": {"plural": {
        "one": unit("%arg körning", state="new"), "other": unit("%arg körningar")}}}}}}), 1)
check("an English plural that fits", {"%lld runs": {"localizations": {"en": {
    "stringUnit": {"state": "new", "value": "%#@n@"},
    "substitutions": {"n": {"argNum": 1, "formatSpecifier": "lld", **plural("%arg run", "%arg runs")}}}}}}, 0)
check("an English plural on a missing argument", {"%lld runs": {"localizations": {"en": {
    "stringUnit": {"state": "translated", "value": "%#@n@"},
    "substitutions": {"n": {"argNum": 2, "formatSpecifier": "lld", **plural("%arg run", "%arg runs")}}}}}}, 1)
check("an unreadable catalog", {}, 2, raw="{broken")
check("a catalog without phrases", {}, 2, raw='{"sourceLanguage": "en"}')

if failures:
    sys.exit(1)
