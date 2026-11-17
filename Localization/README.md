`Localizable.xcstrings` is the source of truth. `scripts/sync-strings.sh` collects
the interface's phrases into it and `--check` (which CI runs) fails when the
catalog has drifted from the code.

## Adding a language

1. Open `Localization/Localizable.xcstrings` in Xcode, or edit it as JSON: add a
   `zh-Hans` (or other) localization to each entry and set `"state" : "translated"`.
2. Only the catalog changes. Don't touch Swift files to translate a phrase — the
   key is the English source text, and looking it up depends on that text.
3. Run `scripts/sync-strings.sh --check` before opening a pull request.

## Choosing the language

macOS settles a bundle's language when the process starts: `Bundle.main` reads the
`AppleLanguages` default, picks the first localization the bundle ships for it, and
every `String(localized:)` and `Text("…")` resolves against that. No supported call
changes it for a process already running, so the picker in **Settings → Appearance →
Language** stores the choice and it is applied by the next launch — with a button to
relaunch straight away.

- *Same as the Mac* removes the app's own `AppleLanguages`, handing the choice back
  to the system language and to the per-app entry in System Settings.
- Any other option writes `AppleLanguages` into MyMole's defaults, which is the same
  key the per-app entry in System Settings writes. The two stay in step.
- The list is read from the bundle's `.lproj` folders, so a new translation appears
  in it — and in `CFBundleLocalizations`, which the packaging script derives from
  those folders — with no code to change.

## What a translation has to preserve

The key doubles as a `printf` format, so a translation must keep the same number
and kind of specifiers. 426 of the keys carry at least one.

| In the key | Means | A translation may |
|---|---|---|
| `%lld`, `%d` | a count | move it with `%1$lld`, but not change it to `%@` |
| `%@` | text: a name, a size, a date | same |
| `%%` | a literal percent sign | must stay `%%` |
| `%1$@` | positional, already in the key when it has two or more arguments | reorder freely, as long as every index still points at the same kind |

Chinese, Japanese and Korean have no plural form, so `1 item` and `3 items` read
the same. Where a key once padded a noun with a suffix through a separate `%@`
argument (`%@ item%@ chosen`, `%lld file%@ couldn't be compared`), that key can't
be translated as it stands: the suffix arrives as an argument of its own. Those
keys are plural substitutions now, and a translation supplies the cases its
language has — one `other` for Chinese, Japanese and Korean.

## Not in the catalog yet

Three kinds of user-visible text never reach a localizing API, so no translation
can cover them:

- `Sources/SystemKit/SystemSnapshot.swift` builds the health card's sentences as
  plain `String` values (`Issue(text:)`), 11 of them at the time of writing.
- `Sources/StorageKit` does the same for the clean-up rows' descriptions and the
  project guard's blockers — 89 of them by count — so they stay in English under
  a translated heading.
- Cleanup history stores a `source` string that is both the row's label and its
  identity — `HistoryView` compares it against `"Optimize"` and `"System Clean"` —
  so history rows stay in English in every language.

All three need a code change, not a catalog entry.

## Compiling the catalog here

An official build has Xcode's `xcstringstool` turn the catalog into `.lproj`
folders. The bundle this fork ships is assembled by hand from SwiftPM's products,
so `scripts/compile-strings.py` does the same work in `scripts/package-app.sh`:
each locale gets a `Localizable.strings`, and a phrase built on a count also gets
a `Localizable.stringsdict` with its plural cases.

## Choosing the language

macOS settles a bundle's language when the process starts: `Bundle.main` reads the
`AppleLanguages` default, picks the first localization the bundle ships for it, and
every `String(localized:)` and `Text("…")` resolves against that. No supported call
changes it for a process already running, so the picker in **Settings → Appearance →
Language** stores the choice and it is applied by the next launch — with a button to
relaunch straight away.

- *Same as the Mac* removes the app's own `AppleLanguages`, handing the choice back
  to the system language and to the per-app entry in System Settings.
- Any other option writes `AppleLanguages` into MyMole's defaults, which is the same
  key the per-app entry in System Settings writes. The two stay in step.
- The list is read from the bundle's `.lproj` folders, so a new translation appears
  in it with no code to change. Naming the languages in `CFBundleLocalizations` as
  well makes the bundle report each one twice, so the folders are the only source.
