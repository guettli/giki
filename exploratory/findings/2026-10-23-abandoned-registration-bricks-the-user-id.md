# An abandoned registration reserves the user id forever

- **Found**: 2026-10-23 · **Charter**: 03-passkeys.md · **Status**: fixed (`UserHasPasskey`, regression test `TestAbandonedRegistrationDoesNotReserveTheName`)

## What happens

Starting a registration and not finishing it -- dismissing the browser's
passkey prompt, closing the tab -- made that user id unusable forever.
Registering it again was refused with "that account already exists; sign in
with one of its passkeys and add another from there", and signing in was
impossible because no credential had ever been stored. Only someone with
access to the server's database could free the name.

## Reproduce

From a fresh `tool/explore.sh start`, on the code before the fix:

```sh
tool/explore.mjs open /
tool/explore.mjs click "Settings"
tool/explore.mjs fill "#0" "http://localhost:8110"
tool/explore.mjs click "Register a new account"
tool/explore.mjs fill "#1" "explorer"
tool/explore.mjs fill "#3" "explore-register-token"
tool/explore.mjs click "Register a passkey"   # click, do NOT run `passkey`:
                                              # nothing answers the prompt
tool/explore.mjs click "Register a passkey"   # try again, properly this time
```

Observed: the second attempt returns 409 and the app shows "that account
already exists". The database explains why:

```
sqlite> SELECT user_id FROM passkey_users;   -- explorer
sqlite> SELECT COUNT(*) FROM passkeys;       -- 0
```

Expected: a name with no credential behind it is not an account. The retry
should succeed.

## Why it matters

One dismissed prompt and the user can never have that name. It is the first
thing a new user does, the failure is silent until they try again, and the
only recovery is an administrator with `sqlite3`.

## Evidence

Server log from the abandoned attempt, with no matching "passkey registered":

```
level=INFO msg="passkey registration begun" user_id=explorer new_account=true
```

## The cause, and the fix

The registration gate asked whether a `passkey_users` row existed. Beginning a
ceremony creates that row -- it has to, the handle goes into the challenge --
so the check conflated "account exists" with "somebody once pressed the
button".

It now asks whether the account has at least one registered credential. The
security property that the gate exists for is unchanged: an account with no
credentials cannot be signed into by anyone, so registering it creates an
account rather than joining one.
