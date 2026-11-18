# Translating MyMole

MyMole's interface text lives in one string catalog,
`Localization/Localizable.xcstrings`. English is the source language. A
language ships when every phrase in the catalog is translated; until then it
stays out of the catalog.

## What a translation changes

- Only `Localization/Localizable.xcstrings`. Xcode's string catalog editor
  works, and so does editing the JSON by hand.
- Add a localization for your language to each phrase. Don't change the
  phrase itself: it is the key the code looks up, and it is also the English
  text.
- Mark each text as translated once it is done. A text that still needs
  review counts as missing.

## Arguments

- A phrase like `Moved %lld items (%@) to the Trash` has two arguments: a
  number (`%lld`) and a text (`%@`). Your translation uses the same
  arguments, each of the same kind, and leaves none out.
- To change the order, number them: `%2$@ … %1$lld` uses the second argument
  first.
- `%%` is a literal percent sign.

## Plurals

- Phrases that depend on a count, such as `Moved %lld items (%@) to the
  Trash`, have English plural forms in the catalog. Give your language the
  plural forms it needs (`one`, `few`, `many`, `other` and so on); `%arg` in a
  form stands for the count.
- Some labels show the count next to them rather than in the text, such as
  `%lld leftovers: the program is gone`. Their English forms leave the count
  out, and yours should too.

## Checks

- `python3 -I scripts/check-translations.py` lists phrases that are missing,
  unfinished or use the wrong arguments. CI runs it on every change.
- `python3 -I scripts/check-translations.py --missing <language>` lists every
  phrase your language still needs, one per line: the work left after the
  English text changes.
- `scripts/sync-strings.sh --check` confirms the catalog matches the code.
  It needs Xcode.
- Check the result in the app on macOS 26: a text that fits in English can
  run longer in another language.
