# Charter: the local-first promise

**Explore** writing, editing and deleting pages with no server configured,
**to discover** anything that needs the network to work, or that silently
waits for it.

giki's central claim is that the local database is the source of truth. A read
or a write that blocks, fails or lies when there is no server contradicts the
whole design.

Ideas to try: use it with no server URL at all; set a URL that refuses
connections; set one that hangs; kill the server mid-session; reload the page
after each. Watch what the sync indicator says versus what the outbox holds
(`tool/explore.mjs text` and the badge). Does anything claim to have saved when
it has not, or claim to be waiting when it is not?
