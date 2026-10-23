# Exploratory testing

Scripted tests check what we already thought of. This is for the rest: an
agent drives the real app in a real browser, follows a charter, and writes down
what it finds.

```sh
tool/explore.sh start          # disposable server + app + headless Chrome
tool/explore.mjs open /
tool/explore.mjs text          # what is on screen, with coordinates
tool/explore.mjs click "New page"
tool/explore.sh stop           # deletes the database; next session starts empty
```

`tool/explore.mjs` with no arguments lists every command. The ones worth
knowing: `text` (the accessibility tree, which is how a canvas app can be read
at all), `fill "#0" "..."` (fields by index, because Flutter does not always
give them a name), `shot` (a screenshot to look at), `console`, `sql` (the
server's database), `api`, and `passkey "<button>"` which attaches a virtual
authenticator and completes a real WebAuthn ceremony.

## The loop

1. Pick a charter from `charters/`. One session, one charter, 30-60 minutes.
2. Explore it. Vary things: interrupt, go offline, go back, do it twice, do it
   in the wrong order, leave fields empty.
3. When something looks wrong, **reproduce it from a fresh session**. A finding
   nobody can reproduce is a rumour.
4. Write it up in `findings/` using `findings/TEMPLATE.md`.
5. A confirmed bug gets a failing test first, then a fix. The finding links to
   both.

## What counts as a finding

Anything that would annoy, mislead or lose data for the person using giki.
Crashes obviously, but also: a button that reports success after failing, state
that survives when it should not, a message that explains nothing, an action
with no way back. "The UI claims X while the database says Y" is the most
valuable shape, because it is exactly what unit tests cannot see.

Findings about the *harness* count too. The first session's best find was that
`tool/explore.sh` served the integration-test bundle instead of the app.
