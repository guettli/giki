# Every id minted in a browser is dated January 1970

- **Found**: 2026-10-24 · **Charter**: 02-sync-and-conflicts.md (noticed in a server log line) · **Status**: fixed (`encodeTimestamp48`, tests in `client/test/ids_test.dart`, unit suite now also runs on Chrome in CI)

## What happens

UUIDv7 puts a 48-bit millisecond timestamp at the front of the id, which is
why giki uses it: ids sort by creation time. In the browser the top 16 bits of
that timestamp were always zero. Device A's id began `00006c89-230b-…`, which
decodes to 1970-01-22; a 2026 id should begin around `019…`.

## Reproduce

From a fresh `tool/explore.sh start`, configure a server and let one sync run,
then look at the device id in the server log:

```sh
grep 'msg=sync' .explore/server.log | head -1    # device_id=00006c89-230b-...
python3 -c "print(hex(int(__import__('time').time()*1000)))"   # 0x1a16c8a5dba
```

Observed: the id's prefix `0x6c89230b` equals the **low 32 bits** of the
current time; the top two bytes are gone.
Expected: the full 48-bit timestamp, `0x01a16c8a…`.

## Why it matters

Not data loss: the 74 random bits still make collisions negligible, and
existing ids stay valid as opaque keys, so nothing needs migrating. But the
property giki chose UUIDv7 *for* was false on the only platform giki runs on.
Ids sorted by creation time only until the low 32 bits wrapped -- every 49.7
days -- and the comment in `ids.dart` said otherwise.

The sharper lesson is about the tests:

- They ran on the Dart VM, where ints are 64-bit and `millis >> 40` is fine.
  On the web bitwise operators work on the value truncated to 32 bits.
- The ordering test compared two ids minted 5ms apart. The low 32 bits still
  increase over 5ms, so **it passed on Chrome too**. It could only have failed
  across a wrap, weeks apart.

## The fix

`encodeTimestamp48` splits the timestamp with integer division and remainder,
which are exact below 2^53 on both platforms, so no shift ever exceeds 32 bits.

Two tests that can see the bug, verified red on Chrome before the fix and
green after: one decodes the prefix of a fresh id and compares it with the
clock, one encodes a fixed 2026 timestamp and checks the bytes. And CI now
runs the whole unit suite on Chrome as well as the VM, since the platform the
tests run on was the actual gap.
