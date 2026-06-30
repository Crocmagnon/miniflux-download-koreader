# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

A [KOReader](https://koreader.rocks/) plugin (`miniflux-download.koplugin/`) that connects to a
self-hosted [Miniflux](https://miniflux.app/) server and downloads unread articles — with their images
embedded — as EPUB files for offline reading. It registers under the name `miniflux_download` so it can
coexist with any other Miniflux plugin without conflict.

This is pure Lua running inside the KOReader host application. There is no build step.

## Commands

- **Lint:** `luacheck miniflux-download.koplugin/` — `.luacheckrc` mirrors KOReader's own conventions
  (`std = "luajit"`, implicit `self = false`, long lines ignored).
- **Install / test:** copy the `miniflux-download.koplugin/` directory into KOReader's `plugins/`
  directory (e.g. `.adds/koreader/plugins/` on Kobo, `koreader/plugins/` elsewhere) and restart KOReader.
  There is no test framework in this repo — verification is manual inside KOReader.

## Architecture

Three modules under `miniflux-download.koplugin/`, deliberately separated by concern:

- `main.lua` — `Miniflux` extends `WidgetContainer`. Owns settings (`LuaSettings` →
  `miniflux_download.lua` in KOReader's settings dir), the Tools menu, and the download/sync
  orchestration. Modelled on KOReader's built-in `wallabag` plugin.
- `api.lua` — `MinifluxApi`, a minimal REST client: `GET /v1/me`, `GET /v1/entries`, `PUT /v1/entries`,
  `GET /v1/entries/:id`. Authenticates with the `X-Auth-Token` header.
- `epub.lua` — `MinifluxEpub:createEpub()`, builds an EPUB from an article's HTML and downloads/embeds
  its `<img>` resources. Adapted from KOReader's `newsdownloader.koplugin/epubdownloadbackend.lua`.
- `_meta.lua` — plugin metadata (display name, description).

## Cross-cutting concepts

These span multiple files and are the things to understand before changing behaviour:

- **Entry id is encoded in the filename:** `[mf-id_1234] Title.epub` (`id_prefix` / `id_postfix` in
  `main.lua`, parsed by `entryIdFromFilename`). This is how the plugin detects already-downloaded
  articles and reconciles read statuses — don't change the naming scheme without updating both ends.
- **Bidirectional status sync:**
  - `uploadReadStatuses` pushes articles *finished in KOReader* up to the server as read. "Finished" is
    read from the `.sdr` sidecar via `DocSettings` (`summary.status == "complete"` or
    `percent_finished == 1`), then optionally deletes the local copy.
  - `deleteRemotelyReadArticles` removes local copies of articles read *elsewhere*. Each candidate is
    confirmed individually with `getEntry` (treating a 404 as removed) so articles merely beyond the
    download limit are never deleted by mistake.
- **Host APIs:** every `require` except `api` and `epub` resolves to a KOReader module
  (`ui/trapper`, `socket.http`, `ui/network/manager`, `datastorage`, `docsettings`, …) that is **not**
  present in this repo. Any flow that shows cancellable progress must run inside `Trapper:wrap()`, and
  network work must go through `NetworkMgr:runWhenOnline(...)`.
- **Localization:** all user-facing strings go through `gettext` — `_()`, `N_` (plurals), and
  `T = ffiutil.template` for interpolation.

## Conventions

The guiding philosophy (see `README.md`) is to adapt patterns from existing KOReader plugins
(`wallabag`, `newsdownloader`) rather than invent new ones. Keep code lint-clean against `.luacheckrc`.
