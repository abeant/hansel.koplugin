# Architecture

A book is a Grimmory record. A local file is an attribute.

## Identity

Canonical id is the Grimmory book id (stringified integer), from REST or parsed from OPDS `href`s:

- `/api/v1/opds/{id}/download`
- `/api/v1/opds/{id}/cover`

Never match server records on filename or title. The native KOReader lane uses partial MD5 only as its wire document key; the local queue remains keyed by Grimmory id.

`local_path` is stored in `hansel_cache_map.lua` as `id -> { path, pinned, bytes, last_access, owned }`. If the file vanishes, state returns to `remote` and the id stays.

## Persistence

All under KOReader’s settings dir (`DataStorage:getSettingsDir()`), never `settings.reader.lua`:

| File | Contents |
| --- | --- |
| `hansel_settings.lua` | Server URL, obfuscated credentials, grid density, budgets |
| `hansel_catalog.lua` | Cached OPDS pages + `by_id` metadata (offline grid) |
| `hansel_cache_map.lua` | Account-scoped mappings for downloads this plugin owns |
| `hansel_sync_queue.lua` | Latest pending progress per account + Grimmory book id |
| `hansel/covers/{account-hash}-{id}.jpg` | Account-scoped cover bytes (extension is only a cache convention) |

One-release migration still reads `dork_*.lua` and the inner `dork` settings key, then writes the Hansel names.

Catalog and queue buckets are scoped by normalized server origin + account. Downloads default to KOReader Home and remain in place across sign-out.

## Tiers

- **Tier 1** - OPDS Basic auth (Devices / OPDS user). Browse, covers, download, open, pin, cache.
- **Tier 2** - Grimmory account login. REST catalog/navigation, truthful health status, and Auto sync provisioning. SSO-only users can remain on Tier 1.

Passwords, rotating refresh tokens, and native sync keys are XOR’d with a built-in key mixed with `device_id`, then base64 (`d1:…`). This is obfuscation, not encryption. Access JWTs remain memory-only.

## Session and known library

- Access JWTs refresh 60 seconds before expiry. A 401 invalidates, refreshes or password-falls-back once, then retries the original call once.
- Transport, authentication, permission, and 5xx failures retain distinct state; only authentication trouble asks the user to reconnect.
- `All` queries one known-library snapshot: account-scoped catalog metadata + the current server page + local downloads, deduplicated by Grimmory id. Device/status/format filters and sorting run before pagination.
- Legacy URL-keyed REST pages are reindexed as canonical `all` pages. Page-size changes can fall back to any saved logical page or the `by_id` manifest.

## Cache state machine

```
remote  --download-->  cached  --pin-->  pinned
   ^                     |                 |
   +--remove/evict-------+                 |
   +--file missing-------------------------+
pinned is never LRU-evicted. The file KOReader currently has open is never deleted.
```

## UI / e-ink

- Full refresh (`UIManager:setDirty(self, "full")`) on page/view change.
- Interactive catalog/account requests run inside `Trapper`; manifest refresh and native progress HTTP run on the next UI tick on Android (no `runInSubProcess` - it aborts).
- Home is a `covers_fullscreen` overlay on File Manager (same pattern as Bookshelf): the FM stays loaded underneath so the system menu still works.

## Auto sync

- One opt-in switch provisions/reuses Grimmory’s native KOReader profile through the shared JWT session without changing its web-reader bridge preference.
- ReaderReady pulls. Ten distinct page changes schedule a trailing ten-second snapshot. Close/suspend only persist the snapshot and return.
- The queue stores one newest snapshot per account/book. A single worker performs pull-before-push with short timeouts and existing Wi-Fi only.
- Reflowable documents carry percentage + XPointer; paged documents carry percentage only. No CFI is generated, parsed, or stored.
- Remote progress more than `0.005` ahead blocks the push pending an explicit conflict choice.
- `grimmory.koplugin` or configured same-origin KOReader Progress sync makes Hansel stand down without modifying either competitor or the saved Hansel preference. Existing `dork-<md5>` kosync usernames keep working; new profiles are `hansel-<md5>`.

## Licensing

AGPL-3.0. Start-with menu patching, Trapper usage, and e-ink dirty flags follow `bookshelf.koplugin` (AGPL). All of that code lives in this repo; do not factor it into a library consumed by non-AGPL clients.
