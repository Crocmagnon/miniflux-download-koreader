--[[--
Self-updater: keeps the plugin up to date by pulling releases published on
GitHub by the CI (see .github/workflows/release.yml).

This module is deliberately isolated from the rest of the plugin: nothing in the
download / status-sync flow requires it. `main.lua` only `require`s it lazily,
inside the "Check for updates" menu callback, under a pcall — so any failure here
can never affect the core download functionality.

It is also built for testability via dependency injection. All side effects
(HTTP, hashing, zip extraction, filesystem) go through seams passed to `:new`,
each defaulting to the real KOReader host implementation (lazily required so the
module loads under plain luajit + busted without those host modules). The pure
logic — release selection and version comparison — is plain functions exposed on
the module table and covered by spec/updater_spec.lua.

The CI publishes, per release, a single zip asset whose entries are prefixed with
the plugin folder name, plus a `<zip>.sha256` checksum asset. Official releases
come from git tags `v*` (`prerelease = false`); every push to `main` publishes a
`snapshot-<sha>` prerelease. The updater only considers prereleases when the user
opts in.
--]]

local json = require("json")

local MinifluxUpdater = {}
MinifluxUpdater.__index = MinifluxUpdater

-- Repository / release layout. Overridable through :new (handy for tests).
local API_BASE = "https://api.github.com"
local OWNER = "Crocmagnon"
local REPO = "miniflux-download-koreader"
local PLUGIN_NAME = "miniflux-download.koplugin"
local ZIP_NAME = PLUGIN_NAME .. ".zip"

-------------------------------------------------------------------------------
-- Default host seams (lazily required so the module loads outside KOReader)
-------------------------------------------------------------------------------

-- GET a URL, following redirects (GitHub asset URLs redirect to storage).
-- Returns ok, body, code. Mirrors the request pattern used in api.lua.
local function default_http_get(url)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socket = require("socket")
    local socketutil = require("socketutil")

    local sink = {}
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    -- On a socket-level failure http.request returns (nil, err): headers is nil
    -- and `code` holds the error string, so guard on headers like api.lua does.
    local code, headers = socket.skip(1, http.request{
        url = url,
        method = "GET",
        sink = ltn12.sink.table(sink),
    })
    socketutil:reset_timeout()
    if headers == nil then
        return false, nil
    end
    local body = table.concat(sink)
    if code == 200 then
        return true, body, code
    end
    return false, nil, code
end

-- Hex SHA-256 of an in-memory string (KOReader bundles ffi/sha2).
local function default_hash(content)
    return require("ffi/sha2").sha256(content)
end

-- Extract every entry of a zip into dest_dir, recreating the directory tree.
-- Uses KOReader's libarchive binding (ffi/archiver Reader).
local function default_extract_zip(zip_path, dest_dir)
    local Archiver = require("ffi/archiver")
    local ffiutil = require("ffi/util")
    local util = require("util")

    local reader = Archiver.Reader:new()
    if not reader:open(zip_path) then
        return false, "open"
    end
    util.makePath(dest_dir)
    for entry in reader:iterate() do
        local dest = ffiutil.joinPath(dest_dir, entry.path)
        if entry.mode == "directory" then
            util.makePath(dest)
        elseif entry.mode == "file" then
            util.makePath(ffiutil.dirname(dest))
            if not reader:extractToPath(entry.path, dest) then
                reader:close()
                return false, "extract:" .. tostring(entry.path)
            end
        end
    end
    reader:close()
    return true
end

local default_fs = {
    dirname = function(p) return require("ffi/util").dirname(p) end,
    joinPath = function(a, b) return require("ffi/util").joinPath(a, b) end,
    exists = function(p)
        return require("libs/libkoreader-lfs").attributes(p, "mode") ~= nil
    end,
    writeFile = function(p, content)
        local f = io.open(p, "wb")
        if not f then return false end
        f:write(content)
        f:close()
        return true
    end,
    rename = function(a, b) return os.rename(a, b) end,
    -- Remove a file or a whole directory tree; a no-op if absent.
    removePath = function(p)
        local lfs = require("libs/libkoreader-lfs")
        local mode = lfs.attributes(p, "mode")
        if mode == nil then return true end
        if mode == "directory" then
            require("ffi/util").purgeDir(p)
        else
            os.remove(p)
        end
        return true
    end,
}

-- The plugin's own directory, derived from this file's location.
local function default_plugin_dir()
    local source = debug.getinfo(1, "S").source -- "@/…/miniflux-download.koplugin/updater.lua"
    local path = source:gsub("^@", "")
    return require("ffi/util").dirname(path)
end

-------------------------------------------------------------------------------
-- Pure logic (no host dependencies) — exposed for unit tests
-------------------------------------------------------------------------------

-- Is `remote_created_at` (ISO 8601) newer than the locally built `built_at`?
-- ISO 8601 timestamps sort lexicographically, so a string compare is enough.
-- A nil/empty local build (e.g. installed from source) is older than anything.
function MinifluxUpdater.isNewer(remote_created_at, local_built_at)
    if type(remote_created_at) ~= "string" or remote_created_at == "" then
        return false
    end
    if type(local_built_at) ~= "string" or local_built_at == "" then
        return true
    end
    return remote_created_at > local_built_at
end

-- Pick the most recent eligible release from the API list. Drafts are always
-- skipped; prereleases (snapshots) are skipped unless the user opted in.
function MinifluxUpdater.selectRelease(releases, include_prereleases)
    local best
    for _, r in ipairs(releases or {}) do
        if not r.draft and (include_prereleases or not r.prerelease) then
            if not best or (type(r.created_at) == "string"
                            and r.created_at > (best.created_at or "")) then
                best = r
            end
        end
    end
    return best
end

-- URL of a named asset on a release, or nil.
local function findAssetUrl(release, name)
    for _, a in ipairs(release.assets or {}) do
        if a.name == name then
            return a.browser_download_url
        end
    end
    return nil
end

-------------------------------------------------------------------------------
-- Updater object
-------------------------------------------------------------------------------

function MinifluxUpdater:new(opts)
    opts = opts or {}
    local o = {
        http_get = opts.http_get or default_http_get,
        hash = opts.hash or default_hash,
        extract_zip = opts.extract_zip or default_extract_zip,
        fs = opts.fs or default_fs,
        -- Resolved lazily in :applyRelease so construction needs no host modules.
        plugin_dir = opts.plugin_dir,
        api_base = opts.api_base or API_BASE,
        owner = opts.owner or OWNER,
        repo = opts.repo or REPO,
        local_version = opts.local_version,
        local_built_at = opts.local_built_at,
    }
    return setmetatable(o, self)
end

--[[--
Look for an update.

@param include_prereleases  whether snapshot prereleases are eligible
@treturn table|nil  an update descriptor when a newer release is available:
  { version, created_at, prerelease, body, zip_url, sha256_url }
@treturn string  a reason keyword when no update is returned:
  "network" | "parse" | "none" | "uptodate" | "noasset"
@treturn number|nil  HTTP status code (on "network")
--]]
function MinifluxUpdater:checkForUpdate(include_prereleases)
    local url = string.format("%s/repos/%s/%s/releases?per_page=20",
        self.api_base, self.owner, self.repo)
    local ok, body, code = self.http_get(url)
    if not ok or not body then
        return nil, "network", code
    end

    local pok, releases = pcall(json.decode, body)
    if not pok or type(releases) ~= "table" then
        return nil, "parse"
    end

    local release = MinifluxUpdater.selectRelease(releases, include_prereleases)
    if not release then
        return nil, "none"
    end
    -- Same tag we already run, or not actually newer → nothing to do. The tag
    -- check handles the "already on this release" case exactly; the timestamp
    -- check guards against offering a strictly older release.
    if release.tag_name == self.local_version
        or not MinifluxUpdater.isNewer(release.created_at, self.local_built_at) then
        return nil, "uptodate"
    end

    local zip_url = findAssetUrl(release, ZIP_NAME)
    if not zip_url then
        return nil, "noasset"
    end

    return {
        version = release.tag_name,
        created_at = release.created_at,
        prerelease = release.prerelease,
        body = release.body,
        zip_url = zip_url,
        sha256_url = findAssetUrl(release, ZIP_NAME .. ".sha256"),
    }
end

--[[--
Download and install an update descriptor returned by :checkForUpdate.

The replacement is done at the directory level and only swapped into place once
the new copy is fully extracted and validated, so an interruption (lost network,
bad checksum, failed extraction) never touches the running plugin folder.

@treturn boolean ok
@treturn string|nil  reason keyword on failure:
  "download" | "checksum" | "write" | "extract" | "incomplete" | "swap"
--]]
function MinifluxUpdater:applyRelease(update)
    local fs = self.fs
    local plugin_dir = self.plugin_dir or default_plugin_dir()
    local parent = fs.dirname(plugin_dir)
    local stage = fs.joinPath(parent, ".miniflux_update")
    local zip_path = fs.joinPath(parent, ".miniflux_update.zip")
    local new_dir = fs.joinPath(stage, PLUGIN_NAME)
    local old_dir = plugin_dir .. ".old"

    local function cleanup_staging()
        fs.removePath(stage)
        fs.removePath(zip_path)
    end

    -- 1. Download the zip.
    local ok, body = self.http_get(update.zip_url)
    if not ok or not body or body == "" then
        return false, "download"
    end

    -- 2. Verify the checksum when the release ships one (HTTPS otherwise covers
    --    transport integrity, so a missing .sha256 asset is not fatal). When the
    --    release *does* ship one, fail closed: an unreachable or unparsable
    --    checksum must not silently install an unverified download.
    if update.sha256_url then
        local sok, sbody = self.http_get(update.sha256_url)
        local expected = sok and sbody and sbody:match("%x+") or nil
        if not expected or self.hash(body) ~= expected then
            return false, "checksum"
        end
    end

    -- Clear any leftovers from a previous interrupted attempt.
    cleanup_staging()
    fs.removePath(old_dir)

    -- 3. Stage the download and extract it.
    if not fs.writeFile(zip_path, body) then
        return false, "write"
    end
    local xok = self.extract_zip(zip_path, stage)
    if not xok then
        cleanup_staging()
        return false, "extract"
    end

    -- 4. Sanity-check the staged copy before touching the live folder.
    if not fs.exists(fs.joinPath(new_dir, "_meta.lua")) then
        cleanup_staging()
        return false, "incomplete"
    end

    -- 5. Swap: move the live folder aside, move the new one in. Restore on
    --    failure so we never end up with no plugin at all.
    if not fs.rename(plugin_dir, old_dir) then
        cleanup_staging()
        return false, "swap"
    end
    if not fs.rename(new_dir, plugin_dir) then
        fs.rename(old_dir, plugin_dir)
        cleanup_staging()
        return false, "swap"
    end

    -- 6. Clean up.
    fs.removePath(old_dir)
    cleanup_staging()
    return true
end

return MinifluxUpdater
