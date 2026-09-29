# Changelog

## 1.1.1 (2026-09-29)

- Marked compatible with patch 12.1.5. No behavior changes.

## 1.1.0 (2026-09-08)

- Click the names on any reward slot and a side panel opens with everyone's
  progress toward that slot, uncapped, you included at the bottom. The gold
  line opens the same panel with every unopened vault. Built from the
  vault's own art, closes with the window or with its own x.
- The "Vault waiting" line moved up under the header text. Season 2 keeps
  the bottom of the window busy, and the line used to collide with the
  Collect bar there. It now shows four names and folds the rest into
  "+N more"; the panel has the full list.
- `/smv test` previews the whole display with nine fake characters in mixed
  states. Nothing is saved; toggle it off or reload to clear.

## 1.0.0 (2026-08-25)

- Initial release. Your other characters' Great Vault progress is stacked on
  each reward slot above your own line, in class colours, with fractions
  counted against that slot's own threshold. Green means earned.
- A gold "Vault waiting" line names every character with an unopened vault,
  including ones you have not logged in since the reset. Earned progress turns
  into a vault-waiting entry when the week rolls over instead of vanishing.
- Options: hide individual characters, force realm names, clear the store.
  `/smv` to toggle, `/smv clear` to reset.
