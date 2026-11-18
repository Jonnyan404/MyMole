`Localizable.xcstrings` is the source of truth. `scripts/sync-strings.sh` collects
the interface's phrases into it and `--check` (which CI runs) fails when the
catalog has drifted from the code.

## Adding a language

1. Open `Localization/Localizable.xcstrings` in Xcode, or edit it as JSON: add a
   `zh-Hans` (or other) localization to each entry and set `"state" : "translated"`.
2. Only the catalog changes. Don't touch Swift files to translate a phrase — the
   key is the English source text, and looking it up depends on that text.
3. Run `scripts/sync-strings.sh --check` before opening a pull request.

## What a translation has to preserve

The key doubles as a `printf` format, so a translation must keep the same number
and kind of specifiers. 457 of the 2,075 keys carry at least one.

| In the key | Means | A translation may |
|---|---|---|
| `%lld`, `%d` | a count | move it with `%1$lld`, but not change it to `%@` |
| `%@` | text: a name, a size, a date | same |
| `%%` | a literal percent sign | must stay `%%` |
| `%1$@` | positional, already in the key when it has two or more arguments | reorder freely, as long as every index still points at the same kind |

Chinese, Japanese and Korean have no plural form, so `1 item` and `3 items` read
the same. A phrase built on a count is a plural substitution, and a translation
supplies the cases its language has — one `other` for Chinese, Japanese and
Korean.

## Checking your work

- `python3 -I scripts/check-translations.py` lists phrases that are missing,
  unfinished or use the wrong arguments. CI runs it on every change.
- `python3 -I scripts/check-translations.py --missing <language>` lists every
  phrase your language still needs, one per line: the work left after the
  English text changes.
- `scripts/sync-strings.sh --check` confirms the catalog matches the code.
  It needs Xcode.
- Check the result in the app on macOS 26: a text that fits in English can
  run longer in another language.

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
