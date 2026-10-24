# A file attached to a page deleted elsewhere vanishes

- **Found**: 2026-10-24 · **Charter**: 06-attachments.md · **Status**: fixed (`AttachmentRepository.add`, `AttachmentsSection`, two phases in `integration_test/sync_flow_test.dart`)

## What happens

Device A has a page open. Device B deletes it; A's editor shows the "deleted
on another device" banner, but still offers "Attach files". The file attaches
and shows up in the editor. After Back, the page and the file are gone: the
attachment row and its blob were pushed to the server, live, pointing at the
tombstone. The page fix in `2026-10-24-edit-saved-into-a-page-deleted-elsewhere.md`
guarded Save only.

## Reproduce

From a fresh `tool/explore.sh start`, with device A pointed at the server:

```sh
tool/explore.mjs click "New page"; fill "#0" Visa; fill "#2" scans; click Save
# sync, then reopen Visa; device B deletes it:
tool/explore.mjs api POST /api/v1/sync '{"device_id":"devB","cursor":0,"mutations":[{... "table":"nodes", ... "is_deleted":1}]}'
# wait for A's background sync (the banner appears), then:
tool/explore.mjs upload "Attach files" orange.png
tool/explore.mjs click Back
tool/explore.mjs sql "SELECT filename, node_id, is_deleted FROM attachments"
```

Observed: the editor showed `orange.png`; the list said "No pages yet"; the
server had `orange.png | <Visa's id> | 0` and the 292-byte blob.
Expected: no attach on a deleted page, or a restore first, as Save does.

## Why it matters

The user believes the file is stored with the page. It is stored, synced and
invisible everywhere; the app has no trash to get it back from.

## Evidence

```
filename   | node_id                              | is_deleted
orange.png | 01a16ec2-0b34-7616-90f7-ee51080661a4 | 0
```

Fix: `add()` refuses a page that is missing or deleted, and the editor replaces
"Attach files" with "Restore the page by saving it to attach files." while the
page is deleted elsewhere. Saving restores the page with its old attachments,
which were never deleted with it.
