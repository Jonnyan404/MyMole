# Translating MyMole

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
and kind of specifiers. 426 of the keys carry at least one.

| In the key | Means | A translation may |
|---|---|---|
| `%lld`, `%d` | a count | move it with `%1$lld`, but not change it to `%@` |
| `%@` | text: a name, a size, a date | same |
| `%%` | a literal percent sign | must stay `%%` |
| `%1$@` | positional, already in the key when it has two or more arguments | reorder freely, as long as every index still points at the same kind |

Chinese, Japanese and Korean have no plural form, so `1 item` and `3 items` read
the same. Where a key pads a noun with a suffix through a separate `%@` argument
(`%@ item%@ chosen`, `%lld file%@ couldn't be compared`), that key can't be
translated as it stands: the suffix arrives as an argument of its own. Those keys
are being moved to plural variations in the catalog, and the translation supplies
one case (`other`) once they are.

## Not in the catalog yet

Two kinds of user-visible text never reach a localizing API, so no translation can
cover them:

- `Sources/SystemKit/SystemSnapshot.swift` builds the health card's sentences as
  plain `String` values (`Issue(text:)`), 11 of them at the time of writing.
- Cleanup history stores a `source` string that is both the row's label and its
  identity — `HistoryView` compares it against `"Optimize"` and `"System Clean"` —
  so history rows stay in English in every language.

Both need a code change, not a catalog entry.
