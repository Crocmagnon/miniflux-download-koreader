# Miniflux Download plugin for KOReader

A [KOReader](https://koreader.rocks/) plugin that connects to a self-hosted
[Miniflux](https://miniflux.app/) server and downloads your unread articles —
**with their images** — as EPUB files for offline reading.

It registers as **Miniflux Download** with its own settings and download folder, so it
can be installed alongside any existing Miniflux plugin without conflict.

## Features

- Downloads unread articles from Miniflux as self-contained EPUB files.
- Embeds article images so everything reads offline.
- Configurable **server URL**, **API token** and **download directory**.
- Marks articles as **read on the server only once you have finished reading
  them in KOReader** (like the Wallabag plugin), and optionally deletes the
  local copy afterwards.
- **Removes local copies of articles you read on another device** (or in the
  Miniflux web UI) so your device stays in sync both ways.
- Optional: choose how many articles to fetch and whether to download images.
- Skips articles that were already downloaded in a previous run.
- Cancellable, with per-article and per-image progress.

## Installation

1. Locate your KOReader `plugins` directory:
   - Kobo: `.adds/koreader/plugins/`
   - Kindle: `koreader/plugins/`
   - Desktop / emulator: `koreader/plugins/`
2. Copy the `miniflux-download.koplugin` directory from this repository into that
   `plugins` directory.
3. Restart KOReader.

```
koreader/plugins/
└── miniflux-download.koplugin/
    ├── _meta.lua
    ├── api.lua
    ├── epub.lua
    └── main.lua
```

## Setup

1. In Miniflux, create an API token under **Settings → API Keys → Create a new
   API key**.
2. In KOReader, open the top menu and go to **Tools → Miniflux Download → Settings →
   Configure Miniflux server** (the menu lives under the wrench/Tools tab, both
   in the file manager and while reading).
3. Enter:
   - **Server URL** — e.g. `https://miniflux.example.org` (no trailing slash
     needed).
   - **API token** — the key you created above.
4. Optionally set the **download folder** and other options in the same Settings
   menu. The folder defaults to `<KOReader data dir>/miniflux_download/`.

## Usage

Open the top menu and choose **Tools → Miniflux Download → Sync articles**.

KOReader will connect (turning on Wi-Fi if needed), fetch your most recent
unread articles, build an EPUB for each one (downloading images along the way),
and save them to the download folder. Use **Tools → Miniflux Download → Go to download
folder** to start reading.

### Read-status sync

When **Mark as read on server once finished** is enabled (the default), the
plugin checks which downloaded articles you have finished — i.e. marked as
*finished* or read to 100% in KOReader — and marks them as read on the Miniflux
server. This happens at the start of every **Sync articles** run.

If **Delete local copy once marked as read** is enabled (also the default), the
local EPUB (and its reading-progress sidecar) is removed once the article has
been marked read on the server, keeping the download folder tidy. Disable it to
keep finished articles on the device.

### Articles read on another device

When **Delete articles read on another device** is enabled (the default), every
**Sync articles** run also checks your downloaded articles against the
server. Any article that is no longer unread there — because you read it in the
Miniflux web UI, on your phone, or anywhere else — has its local copy removed.
This keeps the two sides in sync in both directions.

Each candidate article's current status is confirmed individually against the
server before deletion, so articles that are simply beyond the download limit
are never removed by mistake. Articles you have merely opened but not finished
are left untouched, both locally and on the server.

## How it works

- `api.lua` — a minimal Miniflux REST API client (`GET /v1/entries`,
  `PUT /v1/entries`, `GET /v1/me`), authenticating with the `X-Auth-Token`
  header.
- `epub.lua` — builds an EPUB from an article's HTML content, downloading and
  embedding `<img>` resources. Adapted from KOReader's built-in
  `newsdownloader` plugin.
- `helpers.lua` — pure, host-independent helpers (filename id encoding, XML
  escaping, article HTML, API error messages), kept separate so they can be
  unit-tested outside KOReader.
- `main.lua` — settings, menus and the download orchestration, modelled on
  KOReader's built-in `wallabag` plugin.

## Development

Tooling is managed with [mise](https://mise.jdx.dev/):

- `mise run test` — run the unit tests ([busted](https://lunarmodules.github.io/busted/)).
  The tests cover the host-independent logic (`api.lua`, `helpers.lua`) by
  stubbing the KOReader modules; UI/network flows are still verified manually.
- `mise run lint` — lint with [luacheck](https://github.com/lunarmodules/luacheck).
- `mise run sync` — rsync the plugin to a mounted e-reader.

Install the pre-commit hook with [`prek`](https://github.com/j178/prek)
(`prek install`) to run the linter and tests automatically before each commit.

## License

See the repository for license information.
