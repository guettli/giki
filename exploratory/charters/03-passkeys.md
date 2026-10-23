# Charter: signing in

**Explore** registering and signing in with a passkey
(`tool/explore.mjs passkey "<button>"`), **to discover** states a user can get
into and not out of.

Authentication is where a wrong state is most expensive: it locks someone out
of their own writing, and the recovery path is somebody with database access.

Ideas to try: abandon a ceremony half way (do not run `passkey`, just click);
register the same account twice; register with the wrong token, then the right
one; sign out while offline; remove the passkey you are signed in with; remove
the last one; sign in after clearing the browser's storage. After each, ask
whether the app and `sql "SELECT * FROM passkeys"` agree.
