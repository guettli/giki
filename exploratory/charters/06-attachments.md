# Charter: files that travel

**Explore** attaching, removing and opening files on one device while a second
device (`tool/explore.mjs api ...`) changes the same page, **to discover** a
file that is lost, shown on the wrong page, or stuck "waiting" forever.

Ideas to try: attach to a page deleted elsewhere; delete the page, then restore
it; attach the same file twice; attach while the server is down, then reload
before it comes back; remove a file on one side while the other still shows it;
a file over the 10 MiB limit; an SVG or a file with no extension. Compare the
screen with `tool/explore.mjs sql "SELECT filename, node_id, is_deleted FROM
attachments"` and `sql "SELECT sha256, length(data) FROM blobs"`.
