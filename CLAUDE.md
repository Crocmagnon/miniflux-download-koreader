# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

A [KOReader](https://koreader.rocks/) plugin (`miniflux-download.koplugin/`) that connects to a
self-hosted [Miniflux](https://miniflux.app/) server and downloads unread articles — with their images
embedded — as EPUB files for offline reading. It registers under the name `miniflux_download` so it can
coexist with any other Miniflux plugin without conflict.

This is pure Lua running inside the KOReader host application. There is no build step.

## Goals and non-goals

Use these to keep the scope from drifting (see `README.md` for the full phrasing).

- **Goals:** offline-first reading (unread articles → self-contained EPUBs with images); two-way
  read-status sync (finished in KOReader → read on server; read elsewhere → deleted locally); self-updating
  from GitHub releases; being a good KOReader citizen — reuse native mechanisms (EPUBs in a browsable folder, `.sdr`
  reading statuses, the Tools menu) and adapt existing plugin patterns (`wallabag`, `newsdownloader`).
- **Non-goals:** being a full Miniflux client (no categories, feeds, starred, history, search); managing
  subscriptions/feeds; replacing the Miniflux web UI; being a general RSS reader; live/online reading
  (it's a batch downloader).

## Commands

- **Lint:** `mise run lint` (runs `luacheck miniflux-download.koplugin/ spec/`) — `.luacheckrc` mirrors
  KOReader's own conventions (`std = "luajit"`, implicit `self = false`, long lines ignored).
- **Test:** `mise run test` (runs `busted spec/`). Tests cover the pure logic that can run outside
  KOReader — `api.lua` (via stubbed host modules in `spec/spec_helper.lua`) and `helpers.lua`.
  Everything coupled to the host (UI, Trapper, DocSettings, filesystem) is still verified manually.
- **Pre-commit:** `prek install` wires `.pre-commit-config.yaml`, which runs `mise run test` on commit.
- **Install / manual test:** `mise run sync` (or copy `miniflux-download.koplugin/` into KOReader's
  `plugins/` dir — `.adds/koreader/plugins/` on Kobo, `koreader/plugins/` elsewhere) and restart KOReader.

## Architecture

Modules under `miniflux-download.koplugin/`, deliberately separated by concern:

- `main.lua` — `Miniflux` extends `WidgetContainer`. Owns settings (`LuaSettings` →
  `miniflux_download.lua` in KOReader's settings dir), the Tools menu, and the download/sync
  orchestration. Modelled on KOReader's built-in `wallabag` plugin.
- `api.lua` — `MinifluxApi`, a minimal REST client: `GET /v1/me`, `GET /v1/entries`, `PUT /v1/entries`,
  `GET /v1/entries/:id`. Authenticates with the `X-Auth-Token` header.
- `epub.lua` — `MinifluxEpub:createEpub()`, builds an EPUB from an article's HTML and downloads/embeds
  its `<img>` resources. Adapted from KOReader's `newsdownloader.koplugin/epubdownloadbackend.lua`.
  Images are downloaded **before** `content.opf` and `content.html` are written, so those only ever
  reference images that actually made it into the zip; the ones that failed are replaced in the HTML
  by a note (`Helpers.replaceMissingImage`) and counted in the third return value,
  `{ failed = , total = }`. Never prompt per failed image — failures are reported once at the end of
  the sync (`Helpers.buildImageFailureLines`).
- `helpers.lua` — pure, host-independent helpers (filename id encoding/parsing, XML escaping, article
  HTML, API error messages). Isolated here so they can be unit-tested with busted; `gettext` is its
  only host dependency.
- `_meta.lua` — plugin metadata (display name, description).

## Cross-cutting concepts

These span multiple files and are the things to understand before changing behaviour:

- **Entry id is encoded in the filename:** `[mf-id_1234] Title.epub`. Both ends of the scheme live in
  `helpers.lua` — `entryFilename(id, safe_title)` builds it, `entryIdFromFilename` parses it back. This
  is how the plugin detects already-downloaded articles and reconciles read statuses — don't change the
  naming scheme without updating both ends (the `helpers_spec.lua` round-trip test guards this).
- **Bidirectional status sync:** both directions run as part of the single **Sync articles** flow
  (`onSynchronizeMinifluxDownload` → `downloadEntries`); there is no separate status-only menu entry.
  - `uploadReadStatuses` pushes articles *finished in KOReader* up to the server as read. "Finished" is
    read from the `.sdr` sidecar via `DocSettings` (`summary.status == "complete"` or
    `percent_finished == 1`), then optionally deletes the local copy.
  - `deleteRemotelyReadArticles` removes local copies of articles read *elsewhere*. Each candidate is
    confirmed individually with `getEntry` (treating a 404 as removed) so articles merely beyond the
    download limit are never deleted by mistake.
- **Host APIs:** every `require` except `api`, `epub` and `helpers` resolves to a KOReader module
  (`ui/trapper`, `socket.http`, `ui/network/manager`, `datastorage`, `docsettings`, …) that is **not**
  present in this repo. Any flow that shows cancellable progress must run inside `Trapper:wrap()`, and
  network work must go through `NetworkMgr:runWhenOnline(...)`.
- **Localization:** all user-facing strings go through `gettext` — `_()`, `N_` (plurals), and
  `T = ffiutil.template` for interpolation.

## Conventions

The guiding philosophy (see `README.md`) is to adapt patterns from existing KOReader plugins
(`wallabag`, `newsdownloader`) rather than invent new ones. Keep code lint-clean against `.luacheckrc`.

When adding pure, host-independent logic, prefer putting it in `helpers.lua` (or another testable
module) and covering it in `spec/`. Tests run under plain luajit + busted: host modules are stubbed in
`spec/spec_helper.lua` via `package.preload`, so a module is only testable to the extent its host
dependencies are stubbed there. Anything that genuinely needs the running UI stays manual.
