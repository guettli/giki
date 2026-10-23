# Charter: links that point nowhere yet

**Explore** `[[WikiLinks]]` between pages that do and do not exist,
**to discover** links that resolve to the wrong page, backlinks that go stale,
or titles that collide.

Links resolve by normalized title rather than by id, which is what makes a link
to a page nobody has written yet work. It also means two pages can claim the
same name.

Ideas to try: link to a page, then create it; create two pages with the same
title (and with different capitalisation and spacing); rename a page that
others link to; delete a page that others link to; put a link in a page and
then empty the body. Check `sql "SELECT * FROM links"` against what the editor
shows under "Links out" and "Backlinks".
