# Text fields expose no accessible name

- **Found**: 2026-10-23 · **Charter**: 03-passkeys.md (noticed while driving the UI) · **Status**: fixed (`Semantics(textField:)` around each field, asserted in `integration_test/sync_flow_test.dart`)

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

## The fix

Every labelled field is wrapped in `Semantics(textField: true, label: ...)`.
Flutter renders `InputDecoration`'s label as a *sibling* node, so the editable
element itself reached the browser unnamed; the wrapper puts the name on the
control that takes focus, which is what gets announced.

Verified in a browser:

```js
[...document.querySelectorAll('flt-semantics input, flt-semantics textarea')]
  .map(i => i.getAttribute('aria-label'))
// ["Title", "Title", "Body", "Body"]   (was [null, null])
```

The wrapper nodes themselves stay unlabelled, so nothing is announced twice.

`tool/explore.mjs` now also addresses fields by name, which is what made the
indices brittle; `#0`-style targeting stays for fields that still have none.
