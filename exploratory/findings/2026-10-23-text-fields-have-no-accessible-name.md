# Text fields expose no accessible name

- **Found**: 2026-10-23 · **Charter**: 03-passkeys.md (noticed while driving the UI) · **Status**: open

## What happens

Every text field in the app -- Title, Body, Server URL, User id, Registration
token -- appears in the accessibility tree as an `<input>` or `<textarea>`
with an empty `aria-label`. The visible label is a separate node next to it, so
a screen reader announces the field as unlabelled.

## Reproduce

From a fresh `tool/explore.sh start`:

```sh
tool/explore.mjs open /
tool/explore.mjs click "New page"
tool/explore.mjs eval "[...document.querySelectorAll('flt-semantics input, flt-semantics textarea')].map(i => ({tag: i.tagName, label: i.getAttribute('aria-label')}))"
```

Observed: `[{"tag":"INPUT","label":null},{"tag":"TEXTAREA","label":null}]`
Expected: the `labelText` of each field, so it can be announced and addressed
by name.

## Why it matters

Anyone using a screen reader meets a form of unnamed boxes. It is also why
`tool/explore.mjs fill` needs `#0`/`#1` indices instead of labels, which makes
every exploratory session more brittle than it should be: the indices shift
when the layout changes.

## Worth checking before fixing

Flutter usually derives the semantics label from `InputDecoration.labelText`,
so this may be a quirk of how these fields are built rather than something
inherent. Wrapping each field in `Semantics(label: ..., textField: true)` is
the blunt fix; finding out why the decoration's label is not reaching the tree
is the better one.
