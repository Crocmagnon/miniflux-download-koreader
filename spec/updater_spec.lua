require("spec_helper")
local MinifluxUpdater = require("updater")
local json = require("json")

local PLUGIN_NAME = "miniflux-download.koplugin"
local ZIP_NAME = PLUGIN_NAME .. ".zip"

-- A controllable http_get: returns the mapped body for a URL (ok, body), or a
-- 404 failure for anything unmapped. A single string maps every URL.
local function fakeHttp(map)
    if type(map) == "string" then
        local body = map
        return function() return true, body end
    end
    return function(url)
        local body = map[url]
        if body == nil then return false, nil, 404 end
        return true, body
    end
end

-- An in-memory filesystem double that records the side-effecting calls so tests
-- can assert ordering and that the live folder is never touched on failure.
local function fakeFs(existing)
    local fs = { calls = {}, files = {} }
    for _, p in ipairs(existing or {}) do fs.files[p] = true end
    function fs.dirname(p) return p:match("^(.*)/[^/]+$") or p end
    function fs.joinPath(a, b) return a .. "/" .. b end
    function fs.exists(p) return fs.files[p] == true end
    function fs.writeFile(p)
        table.insert(fs.calls, { "write", p }); fs.files[p] = true; return true
    end
    function fs.rename(a, b)
        table.insert(fs.calls, { "rename", a, b })
        if not fs.files[a] then return false end
        fs.files[a] = nil; fs.files[b] = true; return true
    end
    function fs.removePath(p)
        table.insert(fs.calls, { "remove", p }); fs.files[p] = nil; return true
    end
    return fs
end

local function names(calls)
    local out = {}
    for i, c in ipairs(calls) do out[i] = c[1] end
    return out
end

describe("MinifluxUpdater.isNewer", function()
    it("is true when the remote timestamp is later", function()
        assert.is_true(MinifluxUpdater.isNewer("2026-06-30T10:00:00Z", "2026-06-01T10:00:00Z"))
    end)
    it("is false when the remote timestamp is earlier or equal", function()
        assert.is_false(MinifluxUpdater.isNewer("2026-06-01T10:00:00Z", "2026-06-30T10:00:00Z"))
        assert.is_false(MinifluxUpdater.isNewer("2026-06-01T10:00:00Z", "2026-06-01T10:00:00Z"))
    end)
    it("treats a missing local build as older than anything", function()
        assert.is_true(MinifluxUpdater.isNewer("2026-06-30T10:00:00Z", nil))
        assert.is_true(MinifluxUpdater.isNewer("2026-06-30T10:00:00Z", ""))
    end)
    it("is false when the remote timestamp is missing", function()
        assert.is_false(MinifluxUpdater.isNewer(nil, "2026-06-01T10:00:00Z"))
    end)
end)

describe("MinifluxUpdater.selectRelease", function()
    local official = { tag_name = "v1.0.0", prerelease = false, created_at = "2026-06-01T00:00:00Z" }
    local snapshot = { tag_name = "snapshot-abc", prerelease = true, created_at = "2026-06-20T00:00:00Z" }
    local newer_official = { tag_name = "v1.1.0", prerelease = false, created_at = "2026-06-10T00:00:00Z" }

    it("ignores prereleases by default", function()
        local r = MinifluxUpdater.selectRelease({ snapshot, official }, false)
        assert.equals("v1.0.0", r.tag_name)
    end)
    it("considers prereleases when opted in", function()
        local r = MinifluxUpdater.selectRelease({ official, snapshot }, true)
        assert.equals("snapshot-abc", r.tag_name) -- newest by created_at
    end)
    it("picks the newest eligible release by created_at", function()
        local r = MinifluxUpdater.selectRelease({ official, newer_official }, false)
        assert.equals("v1.1.0", r.tag_name)
    end)
    it("skips drafts", function()
        local draft = { tag_name = "v2.0.0", prerelease = false, draft = true,
                        created_at = "2026-07-01T00:00:00Z" }
        local r = MinifluxUpdater.selectRelease({ official, draft }, false)
        assert.equals("v1.0.0", r.tag_name)
    end)
    it("returns nil when nothing is eligible", function()
        assert.is_nil(MinifluxUpdater.selectRelease({ snapshot }, false))
        assert.is_nil(MinifluxUpdater.selectRelease({}, true))
    end)
end)

describe("MinifluxUpdater:checkForUpdate", function()
    local function releaseJson(releases)
        return json.encode(releases)
    end
    local function withZip(tag, created_at, prerelease)
        return {
            tag_name = tag,
            prerelease = prerelease or false,
            created_at = created_at,
            assets = {
                { name = ZIP_NAME, browser_download_url = "https://dl/" .. tag .. ".zip" },
                { name = ZIP_NAME .. ".sha256", browser_download_url = "https://dl/" .. tag .. ".sha256" },
            },
        }
    end

    it("returns an update descriptor for a newer release with a zip asset", function()
        local up = MinifluxUpdater:new{
            http_get = fakeHttp(releaseJson({ withZip("v1.2.0", "2026-06-30T00:00:00Z") })),
            local_version = "v1.0.0",
            local_built_at = "2026-06-01T00:00:00Z",
        }
        local update, reason = up:checkForUpdate(false)
        assert.is_nil(reason)
        assert.equals("v1.2.0", update.version)
        assert.equals("https://dl/v1.2.0.zip", update.zip_url)
        assert.equals("https://dl/v1.2.0.sha256", update.sha256_url)
    end)

    it("reports uptodate when the latest tag is already installed", function()
        local up = MinifluxUpdater:new{
            http_get = fakeHttp(releaseJson({ withZip("v1.2.0", "2026-06-30T00:00:00Z") })),
            local_version = "v1.2.0",
            local_built_at = "2026-06-30T00:00:00Z",
        }
        local update, reason = up:checkForUpdate(false)
        assert.is_nil(update)
        assert.equals("uptodate", reason)
    end)

    it("reports uptodate when the latest release is older than the local build", function()
        local up = MinifluxUpdater:new{
            http_get = fakeHttp(releaseJson({ withZip("v0.9.0", "2026-05-01T00:00:00Z") })),
            local_version = "snapshot-xyz",
            local_built_at = "2026-06-15T00:00:00Z",
        }
        local update, reason = up:checkForUpdate(false)
        assert.is_nil(update)
        assert.equals("uptodate", reason)
    end)

    it("offers snapshots only when prereleases are enabled", function()
        local body = releaseJson({ withZip("snapshot-abc", "2026-06-30T00:00:00Z", true) })
        local off = MinifluxUpdater:new{ http_get = fakeHttp(body), local_built_at = "2026-06-01T00:00:00Z" }
        local _, reason = off:checkForUpdate(false)
        assert.equals("none", reason)

        local on = MinifluxUpdater:new{ http_get = fakeHttp(body), local_built_at = "2026-06-01T00:00:00Z" }
        local update = on:checkForUpdate(true)
        assert.equals("snapshot-abc", update.version)
    end)

    it("reports none when there is no eligible release", function()
        local up = MinifluxUpdater:new{ http_get = fakeHttp(releaseJson({})) }
        local _, reason = up:checkForUpdate(false)
        assert.equals("none", reason)
    end)

    it("reports noasset when a newer release ships no zip", function()
        local release = { tag_name = "v1.2.0", prerelease = false,
                          created_at = "2026-06-30T00:00:00Z", assets = {} }
        local up = MinifluxUpdater:new{
            http_get = fakeHttp(releaseJson({ release })),
            local_built_at = "2026-06-01T00:00:00Z",
        }
        local _, reason = up:checkForUpdate(false)
        assert.equals("noasset", reason)
    end)

    it("queries the GitHub releases API", function()
        local requested
        local up = MinifluxUpdater:new{ http_get = function(url) requested = url; return false, nil, 500 end }
        up:checkForUpdate(false)
        assert.equals("https://api.github.com/repos/Crocmagnon/miniflux-download-koreader/releases?per_page=20", requested)
    end)

    it("reports network when the request fails", function()
        local up = MinifluxUpdater:new{ http_get = function() return false, nil, 500 end }
        local _, reason, code = up:checkForUpdate(false)
        assert.equals("network", reason)
        assert.equals(500, code)
    end)

    it("reports parse on a non-JSON body", function()
        local up = MinifluxUpdater:new{ http_get = fakeHttp("not json {{{") }
        local _, reason = up:checkForUpdate(false)
        assert.equals("parse", reason)
    end)
end)

describe("MinifluxUpdater:applyRelease", function()
    local plugin_dir = "/plugins/" .. PLUGIN_NAME
    local stage = "/plugins/.miniflux_update"
    local new_dir = stage .. "/" .. PLUGIN_NAME
    local zip_path = "/plugins/.miniflux_update.zip"
    local update = {
        version = "v1.2.0",
        zip_url = "https://dl/v1.2.0.zip",
        sha256_url = "https://dl/v1.2.0.sha256",
    }

    -- extract double that materialises the staged plugin folder in the fake fs.
    local function extractInto(fs, ok)
        return function()
            if ok then
                fs.files[new_dir] = true
                fs.files[new_dir .. "/_meta.lua"] = true
            end
            return ok
        end
    end

    it("downloads, verifies, extracts and swaps on the happy path", function()
        local fs = fakeFs{ plugin_dir }
        local up = MinifluxUpdater:new{
            plugin_dir = plugin_dir,
            http_get = fakeHttp{ [update.zip_url] = "ZIPDATA", [update.sha256_url] = "deadbeef" },
            hash = function() return "deadbeef" end,
            extract_zip = extractInto(fs, true),
            fs = fs,
        }
        local ok = up:applyRelease(update)
        assert.is_true(ok)
        -- New folder is now in place, staging cleaned up.
        assert.is_true(fs.exists(plugin_dir))
        assert.is_false(fs.exists(new_dir))
        assert.is_false(fs.exists(zip_path))
        -- The zip is written before the swap, and the live folder is moved aside
        -- before the new one is moved in.
        local order = names(fs.calls)
        local function indexOf(action, a, b)
            for i, c in ipairs(fs.calls) do
                if c[1] == action and (not a or c[2] == a) and (not b or c[3] == b) then return i end
            end
        end
        assert.is_truthy(order[1]) -- sanity
        assert.is_true(indexOf("write", zip_path) < indexOf("rename", plugin_dir, plugin_dir .. ".old"))
        assert.is_true(indexOf("rename", plugin_dir, plugin_dir .. ".old")
            < indexOf("rename", new_dir, plugin_dir))
    end)

    it("aborts on a checksum mismatch without touching anything", function()
        local fs = fakeFs{ plugin_dir }
        local up = MinifluxUpdater:new{
            plugin_dir = plugin_dir,
            http_get = fakeHttp{ [update.zip_url] = "ZIPDATA", [update.sha256_url] = "00000000" },
            hash = function() return "deadbeef" end,
            extract_zip = extractInto(fs, true),
            fs = fs,
        }
        local ok, reason = up:applyRelease(update)
        assert.is_false(ok)
        assert.equals("checksum", reason)
        -- Nothing was written or renamed; the live folder is intact.
        assert.same({}, names(fs.calls))
        assert.is_true(fs.exists(plugin_dir))
    end)

    it("fails cleanly when the download fails", function()
        local fs = fakeFs{ plugin_dir }
        local up = MinifluxUpdater:new{
            plugin_dir = plugin_dir,
            http_get = function() return false, nil, 404 end,
            fs = fs,
        }
        local ok, reason = up:applyRelease(update)
        assert.is_false(ok)
        assert.equals("download", reason)
        assert.is_true(fs.exists(plugin_dir))
    end)

    it("fails cleanly and keeps the folder when extraction fails", function()
        local fs = fakeFs{ plugin_dir }
        local up = MinifluxUpdater:new{
            plugin_dir = plugin_dir,
            http_get = fakeHttp{ [update.zip_url] = "ZIPDATA", [update.sha256_url] = "deadbeef" },
            hash = function() return "deadbeef" end,
            extract_zip = extractInto(fs, false),
            fs = fs,
        }
        local ok, reason = up:applyRelease(update)
        assert.is_false(ok)
        assert.equals("extract", reason)
        assert.is_true(fs.exists(plugin_dir)) -- never renamed
    end)

    it("fails when the staged copy is incomplete", function()
        local fs = fakeFs{ plugin_dir }
        local up = MinifluxUpdater:new{
            plugin_dir = plugin_dir,
            http_get = fakeHttp{ [update.zip_url] = "ZIPDATA", [update.sha256_url] = "deadbeef" },
            hash = function() return "deadbeef" end,
            extract_zip = function() return true end, -- extracts nothing
            fs = fs,
        }
        local ok, reason = up:applyRelease(update)
        assert.is_false(ok)
        assert.equals("incomplete", reason)
        assert.is_true(fs.exists(plugin_dir))
    end)

    it("fails closed when a shipped checksum cannot be fetched", function()
        local fs = fakeFs{ plugin_dir }
        local up = MinifluxUpdater:new{
            plugin_dir = plugin_dir,
            -- zip downloads, but the .sha256 URL is unmapped (404).
            http_get = fakeHttp{ [update.zip_url] = "ZIPDATA" },
            hash = function() return "deadbeef" end,
            extract_zip = extractInto(fs, true),
            fs = fs,
        }
        local ok, reason = up:applyRelease(update) -- update has a sha256_url
        assert.is_false(ok)
        assert.equals("checksum", reason)
        assert.is_true(fs.exists(plugin_dir)) -- live folder untouched
    end)

    it("installs without a checksum asset (HTTPS-only integrity)", function()
        local fs = fakeFs{ plugin_dir }
        local up = MinifluxUpdater:new{
            plugin_dir = plugin_dir,
            http_get = fakeHttp{ [update.zip_url] = "ZIPDATA" }, -- no sha256 mapped
            hash = function() error("hash should not be called") end,
            extract_zip = extractInto(fs, true),
            fs = fs,
        }
        local no_sha = { version = "v1.2.0", zip_url = update.zip_url } -- no sha256_url
        local ok = up:applyRelease(no_sha)
        assert.is_true(ok)
    end)
end)
