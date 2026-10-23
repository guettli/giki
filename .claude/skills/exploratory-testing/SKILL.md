---
name: exploratory-testing
description: Run an agent-driven exploratory testing session against giki in a real browser. Use when asked to explore, poke at, stress or "try to break" the app, or to investigate a bug report that needs the real UI rather than a unit test.
---

# Exploratory testing

You drive the real app in a real browser and write down what you find. The
value is in the states nobody thought to write a test for, so follow the
app rather than a script.

## Start

```sh
tool/explore.sh start      # ~1 min the first time (it builds the web bundle)
tool/explore.mjs open /
```

If Chrome is not on the PATH, set `CHROME_EXECUTABLE`. Stop with
`tool/explore.sh stop`, which deletes the database so the next session starts
empty.

## Drive

| Command | What it does |
| --- | --- |
| `text` | What is on screen: accessibility tree plus every editable field as `#0`, `#1`, … |
| `click "<label>"` | Click by label |
| `fill "#0" "<text>"` | Type into a field by index (Flutter often leaves them unlabelled) |
| `shot <path>` | Screenshot — read it when `text` is not enough |
| `console` | Console messages and page errors from the next 1.5s |
| `eval "<js>"` | JavaScript in the page |
| `passkey "<button>"` | Attach a virtual authenticator and complete a real WebAuthn ceremony |
| `api <METHOD> <path> [body]` | Call the API directly — this is your "second device" |
| `sql "<query>"` | Query the **server's** database |

The browser keeps its state between commands, so explore one step at a time.

## The loop

1. Pick a charter from `exploratory/charters/`. Work one charter per session.
2. Do the ordinary thing first, so you know what normal looks like.
3. Then vary it: interrupt it, repeat it, do it offline, do it out of order,
   leave it half finished, go back, reload.
4. **After every step, compare what the screen says with what the data says**
   (`sql`, `api`, the server log at `.explore/server.log`). The richest
   findings live in that gap.
5. Reproduce anything suspicious from a fresh `start` before writing it up.

## Write it up

Copy `exploratory/findings/TEMPLATE.md` into `exploratory/findings/` and fill
it in. One file per finding, named for the symptom.

Then, for a confirmed bug: write a failing test first, fix it, and link both
from the finding. A finding without a test is a story; with one it is a
regression that cannot come back.

## Honesty rules

- Report what you observed, not what you expect the code does. Quote the UI,
  the log line or the query output.
- If you cannot reproduce it, say so in the finding and keep it as "not
  reproduced" rather than deleting it.
- A finding about this harness counts. If the tool lied to you, that is worth
  more than most app bugs, because it would have lied to the next person too.
