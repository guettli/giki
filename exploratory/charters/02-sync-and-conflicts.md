# Charter: two devices, one truth

**Explore** editing the same page from this browser and from a second device
(`tool/explore.mjs api POST /api/v1/sync ...`), **to discover** cases where
the two disagree afterwards, or where an edit disappears.

Last-Write-Wins is a deliberate simplification; the question is whether it ever
loses something a user would expect to keep, and whether the UI ever shows a
version the server does not have.

Ideas to try: edit here and push an older edit from the fake device; push a
newer one while an edit is open in the editor; delete on one side and edit on
the other; sync twice in a row; sync with the server stopped and then started.
Compare the page on screen with `tool/explore.mjs sql "SELECT title, body,
is_deleted, updated_at FROM nodes"`.
