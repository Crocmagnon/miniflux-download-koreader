--[[--
Miniflux plugin for KOReader.

Connects to a self-hosted Miniflux server, downloads unread articles as EPUB
files (with their images embedded) into a configurable folder for offline
reading, and can optionally mark the downloaded articles as read on the server.

User-configurable settings:
  * Miniflux base URL
  * Miniflux API token (X-Auth-Token)
  * Download directory

@module koplugin.miniflux
--]]

local BD = require("ui/bidi")
local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local DocSettings = require("docsettings")
local Event = require("ui/event")
local FileManager = require("apps/filemanager/filemanager")
local InfoMessage = require("ui/widget/infomessage")
local LuaSettings = require("luasettings")
local MultiConfirmBox = require("ui/widget/multiconfirmbox")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local SpinWidget = require("ui/widget/spinwidget")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiUtil = require("ffi/util")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local N_ = _.ngettext
local T = ffiUtil.template

local MinifluxApi = require("api")
local MinifluxEpub = require("epub")

-- Prefix used in downloaded file names to store the Miniflux entry id, e.g.
-- "[mf-id_1234] Some article title.epub". Lets us detect already-downloaded
-- entries on subsequent syncs.
local id_prefix = "[mf-id_"
local id_postfix = "] "

-- Seconds before a result/summary popup auto-dismisses.
local RESULT_TIMEOUT = 5

-- Translated message for a known API error keyword, or nil for anything else
-- (so callers can supply their own context-specific fallback wording).
local function apiErrorMessage(result)
    if result == "unauthorized" then
        return _("Authentication failed. Please check your API token.")
    elseif result == "network_error" then
        return _("Could not connect to the Miniflux server.\nCheck the server URL and your network.")
    end
    return nil
end

local Miniflux = WidgetContainer:extend{
    name = "miniflux_download",
    settings_file = DataStorage:getSettingsDir() .. "/miniflux_download.lua",
}

function Miniflux:init()
    self:readSettings()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function Miniflux:onDispatcherRegisterActions()
    Dispatcher:registerAction("miniflux_download_articles", {
        category = "none",
        event = "SynchronizeMinifluxDownload",
        title = _("Miniflux Download: download unread articles"),
        general = true,
    })
    Dispatcher:registerAction("miniflux_download_upload_statuses", {
        category = "none",
        event = "UploadMinifluxDownloadStatuses",
        title = _("Miniflux Download: upload read statuses"),
        general = true,
    })
end

-------------------------------------------------------------------------------
-- Settings
-------------------------------------------------------------------------------

function Miniflux:readSettings()
    self.settings = LuaSettings:open(self.settings_file)
    self.server_url = self.settings:readSetting("server_url") or ""
    self.api_token = self.settings:readSetting("api_token") or ""
    self.download_dir = self.settings:readSetting("download_dir")
        or (DataStorage:getFullDataDir() .. "/miniflux_download/")
    self.limit = self.settings:readSetting("limit") or 25
    -- Default to true when never set.
    local inc = self.settings:readSetting("include_images")
    self.include_images = (inc == nil) or inc
    -- Mark an article as read on the server once it has been finished in
    -- KOReader (default on), and, by default, remove the local copy afterwards
    -- (mirrors the Wallabag plugin behaviour).
    local sync_read = self.settings:readSetting("sync_read_status")
    self.sync_read_status = (sync_read == nil) or sync_read
    local del_after = self.settings:readSetting("delete_after_sync")
    self.delete_after_sync = (del_after == nil) or del_after
    -- Delete local copies of articles that have been read or removed on the
    -- server from another device (default on).
    local del_remote = self.settings:readSetting("delete_remotely_read")
    self.delete_remotely_read = (del_remote == nil) or del_remote
    self.order = self.settings:readSetting("order") or "published_at"
    self.direction = self.settings:readSetting("direction") or "desc"
end

function Miniflux:saveSettings()
    self.settings:saveSetting("server_url", self.server_url)
    self.settings:saveSetting("api_token", self.api_token)
    self.settings:saveSetting("download_dir", self.download_dir)
    self.settings:saveSetting("limit", self.limit)
    self.settings:saveSetting("include_images", self.include_images)
    self.settings:saveSetting("sync_read_status", self.sync_read_status)
    self.settings:saveSetting("delete_after_sync", self.delete_after_sync)
    self.settings:saveSetting("delete_remotely_read", self.delete_remotely_read)
    self.settings:saveSetting("order", self.order)
    self.settings:saveSetting("direction", self.direction)
    self.settings:flush()
end

-------------------------------------------------------------------------------
-- Menu
-------------------------------------------------------------------------------

function Miniflux:addToMainMenu(menu_items)
    menu_items.miniflux_download = {
        text = _("Miniflux Download"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Download unread articles"),
                callback = function()
                    self.ui:handleEvent(Event:new("SynchronizeMinifluxDownload"))
                end,
            },
            {
                text = _("Sync read statuses"),
                help_text = _("Mark articles finished in KOReader as read on the server, and remove local copies of articles that were read on another device."),
                callback = function()
                    self.ui:handleEvent(Event:new("UploadMinifluxDownloadStatuses"))
                end,
            },
            {
                text = _("Go to download folder"),
                callback = function()
                    self:onGoToMinifluxDirectory()
                end,
                separator = true,
            },
            {
                text = _("Settings"),
                sub_item_table = {
                    {
                        text = _("Configure Miniflux server"),
                        keep_menu_open = true,
                        callback = function()
                            self:editServerSettings()
                        end,
                    },
                    {
                        text_func = function()
                            local path
                            if not self.download_dir or self.download_dir == "" then
                                path = _("not set")
                            else
                                path = filemanagerutil.abbreviate(self.download_dir)
                            end
                            return T(_("Download folder: %1"), BD.dirpath(path))
                        end,
                        keep_menu_open = true,
                        callback = function(touchmenu_instance)
                            self:setDownloadDirectory(touchmenu_instance)
                        end,
                        separator = true,
                    },
                    {
                        text_func = function()
                            return T(_("Number of articles to download: %1"), self.limit)
                        end,
                        keep_menu_open = true,
                        callback = function(touchmenu_instance)
                            self:setArticlesLimit(touchmenu_instance)
                        end,
                    },
                    {
                        text = _("Download images"),
                        keep_menu_open = true,
                        checked_func = function()
                            return self.include_images
                        end,
                        callback = function()
                            self.include_images = not self.include_images
                            self:saveSettings()
                        end,
                    },
                    {
                        text = _("Mark as read on server once finished"),
                        help_text = _("When an article has been finished (or read to 100%) in KOReader, mark it as read on the Miniflux server during the next download or status upload."),
                        keep_menu_open = true,
                        checked_func = function()
                            return self.sync_read_status
                        end,
                        callback = function()
                            self.sync_read_status = not self.sync_read_status
                            self:saveSettings()
                        end,
                    },
                    {
                        text = _("Delete local copy once marked as read"),
                        help_text = _("After an article you finished in KOReader is marked as read on the server, also delete its local EPUB file."),
                        keep_menu_open = true,
                        enabled_func = function()
                            return self.sync_read_status
                        end,
                        checked_func = function()
                            return self.delete_after_sync
                        end,
                        callback = function()
                            self.delete_after_sync = not self.delete_after_sync
                            self:saveSettings()
                        end,
                    },
                    {
                        text = _("Delete articles read on another device"),
                        help_text = _("During a download or status sync, check downloaded articles against the server and delete the local copy of any that have been read or removed elsewhere."),
                        keep_menu_open = true,
                        checked_func = function()
                            return self.delete_remotely_read
                        end,
                        callback = function()
                            self.delete_remotely_read = not self.delete_remotely_read
                            self:saveSettings()
                        end,
                    },
                },
                separator = true,
            },
            {
                text = _("About Miniflux Download plugin"),
                keep_menu_open = true,
                callback = function()
                    UIManager:show(InfoMessage:new{
                        text = T(_([[The Miniflux Download plugin downloads unread articles from a Miniflux server as EPUB files (with images) for offline reading.

Configure the server URL and API token in the settings, then use "Download unread articles".

Downloads to:
%1

More about Miniflux: https://miniflux.app]]),
                            BD.dirpath(filemanagerutil.abbreviate(self.download_dir))),
                    })
                end,
            },
        },
    }
end

-------------------------------------------------------------------------------
-- Settings dialogs
-------------------------------------------------------------------------------

function Miniflux:editServerSettings()
    local text_info = _([[Enter the base URL of your Miniflux server (for example https://miniflux.example.org) and an API token.

Create an API token in the Miniflux web interface under Settings > API Keys.]])

    self.settings_dialog = MultiInputDialog:new{
        title = _("Miniflux settings"),
        fields = {
            {
                text = self.server_url,
                hint = _("Server URL (https://miniflux.example.org)"),
            },
            {
                text = self.api_token,
                text_type = "password",
                hint = _("API token"),
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(self.settings_dialog)
                    end,
                },
                {
                    text = _("Info"),
                    callback = function()
                        UIManager:show(InfoMessage:new{ text = text_info })
                    end,
                },
                {
                    text = _("Test"),
                    callback = function()
                        self:testConnection()
                    end,
                },
                {
                    text = _("Apply"),
                    callback = function()
                        local fields = self.settings_dialog:getFields()
                        local url = fields[1]:gsub("/*$", "") -- strip trailing slashes
                        if url ~= "" and not url:match("^https?://") then
                            UIManager:show(MultiConfirmBox:new{
                                text = _("The server URL should start with http:// or https://."),
                                choice1_text = _("http://"),
                                choice1_callback = function()
                                    self.settings_dialog.input_fields[1]:setText("http://" .. url)
                                end,
                                choice2_text = _("https://"),
                                choice2_callback = function()
                                    self.settings_dialog.input_fields[1]:setText("https://" .. url)
                                end,
                            })
                            return
                        end
                        self.server_url = url
                        self.api_token = fields[2]
                        self:saveSettings()
                        UIManager:close(self.settings_dialog)
                    end,
                },
            },
        },
    }
    UIManager:show(self.settings_dialog)
    self.settings_dialog:onShowKeyboard()
end

-- Validate the URL/token currently typed in the settings dialog by calling
-- GET /v1/me on the server, and report the result.
function Miniflux:testConnection()
    local fields = self.settings_dialog:getFields()
    local url = fields[1]:gsub("/*$", "") -- strip trailing slashes
    local token = fields[2]
    if url == "" or token == "" then
        UIManager:show(InfoMessage:new{
            text = _("Please enter both the server URL and an API token first."),
        })
        return
    end
    NetworkMgr:runWhenOnline(function()
        Trapper:wrap(function()
            Trapper:info(_("Testing connection to Miniflux…"))
            local ok, result = MinifluxApi:new(url, token):getMe()
            Trapper:reset()
            local msg
            if ok and type(result) == "table" then
                local who = result.username or result.email
                if who and who ~= "" then
                    msg = T(_("Connection successful. Logged in as %1."), who)
                else
                    msg = _("Connection successful.")
                end
            else
                msg = apiErrorMessage(result)
                    or _("Connection failed. Please check the server URL and API token.")
            end
            UIManager:show(InfoMessage:new{ text = msg, timeout = RESULT_TIMEOUT })
        end)
    end)
end

function Miniflux:setDownloadDirectory(touchmenu_instance)
    require("ui/downloadmgr"):new{
        onConfirm = function(path)
            self.download_dir = path .. "/"
            self:saveSettings()
            if touchmenu_instance then
                touchmenu_instance:updateItems()
            end
        end,
    }:chooseDir()
end

function Miniflux:setArticlesLimit(touchmenu_instance)
    local widget = SpinWidget:new{
        title_text = _("Number of articles to download"),
        info_text = _("The most recent unread articles will be downloaded."),
        value = self.limit,
        value_min = 1,
        value_max = 500,
        value_step = 1,
        value_hold_step = 10,
        ok_text = _("Set"),
        callback = function(spin)
            self.limit = spin.value
            self:saveSettings()
            if touchmenu_instance then
                touchmenu_instance:updateItems()
            end
        end,
    }
    UIManager:show(widget)
end

-------------------------------------------------------------------------------
-- Download flow
-------------------------------------------------------------------------------

-- An API client configured from the saved settings.
function Miniflux:getApi()
    return MinifluxApi:new(self.server_url, self.api_token)
end

-- Make sure the server URL, token and a valid download folder are configured.
-- Returns true when everything is in order, false otherwise (and shows a dialog).
function Miniflux:validateSettings()
    if self.server_url == "" or self.api_token == "" then
        UIManager:show(MultiConfirmBox:new{
            text = _("Please configure the Miniflux server URL and API token first."),
            choice1_text = _("Configure"),
            choice1_callback = function()
                self:editServerSettings()
            end,
            choice2_text = _("Cancel"),
            choice2_callback = function() end,
        })
        return false
    end

    -- Create the download directory if it does not exist yet.
    if not lfs.attributes(self.download_dir, "mode") then
        util.makePath(self.download_dir)
    end
    if lfs.attributes(self.download_dir, "mode") ~= "directory" then
        UIManager:show(InfoMessage:new{
            text = T(_("The download folder is not valid:\n%1\n\nPlease set it in the settings."),
                BD.dirpath(self.download_dir)),
        })
        return false
    end
    return true
end

function Miniflux:onSynchronizeMinifluxDownload()
    if not self:validateSettings() then
        return true
    end
    NetworkMgr:runWhenOnline(function()
        Trapper:wrap(function()
            self:downloadEntries()
            self:refreshFileManager()
        end)
    end)
    return true
end

-- Manual trigger: reconcile read statuses in both directions, without
-- downloading anything new. Pushes finished articles up, and removes local
-- copies of articles read on another device.
function Miniflux:onUploadMinifluxDownloadStatuses()
    if not self:validateSettings() then
        return true
    end
    NetworkMgr:runWhenOnline(function()
        Trapper:wrap(function()
            local marked = self:uploadReadStatuses(true)
            local removed = self:deleteRemotelyReadArticles()
            Trapper:reset()
            local lines = {}
            if marked > 0 then
                table.insert(lines, T(N_("Marked %1 article as read on the server.",
                                         "Marked %1 articles as read on the server.", marked), marked))
            end
            if removed > 0 then
                table.insert(lines, T(N_("Removed %1 article read on another device.",
                                         "Removed %1 articles read on another device.", removed), removed))
            end
            if #lines == 0 then
                table.insert(lines, _("Read statuses are already in sync."))
            end
            UIManager:show(InfoMessage:new{
                text = table.concat(lines, "\n"),
                timeout = RESULT_TIMEOUT,
            })
            self:refreshFileManager()
        end)
    end)
    return true
end

-- Extract the Miniflux entry id encoded in a file name, or nil.
local function entryIdFromFilename(filename)
    local id = filename:match("^%[mf%-id_(%d+)%]")
    return id and tonumber(id) or nil
end

-- Build a map of entry id -> local EPUB path for everything already downloaded
-- (recursively, skipping .sdr sidecar folders).
function Miniflux:getLocalEntries(dir, map)
    dir = dir or self.download_dir
    map = map or {}
    if lfs.attributes(dir, "mode") ~= "directory" then
        return map
    end
    for entry in lfs.dir(dir) do
        if entry ~= "." and entry ~= ".." then
            local entry_path = ffiUtil.joinPath(dir, entry)
            local mode = lfs.attributes(entry_path, "mode")
            if mode == "file" then
                local id = entryIdFromFilename(entry)
                if id then
                    map[id] = entry_path
                end
            elseif mode == "directory" and not entry:match("%.sdr$") then
                self:getLocalEntries(entry_path, map)
            end
        end
    end
    return map
end

-- True if a downloaded article has been finished (or read to 100%) in KOReader.
function Miniflux:isEntryRead(path)
    if not DocSettings:hasSidecarFile(path) then
        return false
    end
    local doc_settings = DocSettings:open(path)
    local summary = doc_settings:readSetting("summary")
    if summary and summary.status == "complete" then
        return true
    end
    return doc_settings:readSetting("percent_finished") == 1
end

-- Mark finished articles as read on the Miniflux server, then optionally delete
-- their local copies. Must run while online and within a Trapper:wrap context.
-- Returns the number of articles marked as read.
function Miniflux:uploadReadStatuses(quiet)
    if not self.sync_read_status then
        return 0
    end

    local read_ids = {}
    local read_paths = {}
    for id, path in pairs(self:getLocalEntries()) do
        if self:isEntryRead(path) then
            table.insert(read_ids, id)
            table.insert(read_paths, path)
        end
    end

    if #read_ids == 0 then
        if not quiet then
            UIManager:show(InfoMessage:new{
                text = _("No finished articles to mark as read."),
                timeout = RESULT_TIMEOUT,
            })
        end
        return 0
    end

    Trapper:info(_("Marking finished articles as read on the server…"))
    local api = self:getApi()
    local ok = api:updateEntriesStatus(read_ids, "read")
    if not ok then
        logger.warn("Miniflux: failed to upload read statuses")
        return 0
    end

    if self.delete_after_sync then
        for _, path in ipairs(read_paths) do
            if lfs.attributes(path, "mode") == "file" then
                FileManager:deleteFile(path, true)
            end
        end
    end
    return #read_ids
end

-- Delete local copies of articles that are no longer unread on the server
-- (e.g. read or removed on another device). Articles finished in KOReader are
-- left to the "delete local copy once marked as read" policy above, so this
-- only acts on articles read elsewhere. Must run while online and within a
-- Trapper:wrap context. Returns the number of local files deleted.
--
-- @param known_unread_ids  optional set (id -> true) of ids known to still be
--   unread on the server (e.g. from the entry list just fetched), to skip
--   confirming those individually.
function Miniflux:deleteRemotelyReadArticles(known_unread_ids)
    if not self.delete_remotely_read then
        return 0
    end

    -- Candidates: downloaded, not finished locally, and not known-unread.
    local candidates = {}
    local total = 0
    for id, path in pairs(self:getLocalEntries()) do
        if not (known_unread_ids and known_unread_ids[id]) and not self:isEntryRead(path) then
            candidates[id] = path
            total = total + 1
        end
    end
    if total == 0 then
        return 0
    end

    local api = self:getApi()
    local deleted = 0
    local index = 0
    for id, path in pairs(candidates) do
        index = index + 1
        Trapper:info(T(_("Checking read status on the server (%1 / %2)…"), index, total))
        local ok, entry, code = api:getEntry(id)
        -- Delete when the server says it is no longer unread, or when it has
        -- been removed entirely (404). Stay conservative on any other error.
        local remotely_read = (ok and type(entry) == "table"
                                  and entry.status and entry.status ~= "unread")
            or (not ok and code == 404)
        if remotely_read and lfs.attributes(path, "mode") == "file" then
            FileManager:deleteFile(path, true)
            deleted = deleted + 1
        end
    end
    return deleted
end

-- Escape a plain-text string for safe inclusion in XML/XHTML.
local function xmlEscape(s)
    if not s then
        return ""
    end
    return (s:gsub("[&<>\"]", {
        ["&"] = "&amp;",
        ["<"] = "&lt;",
        [">"] = "&gt;",
        ['"'] = "&quot;",
    }))
end

-- Assemble a full HTML document for a single Miniflux entry.
local function buildArticleHtml(entry)
    local title = xmlEscape(entry.title or _("Untitled"))

    local byline_parts = {}
    if entry.author and entry.author ~= "" then
        table.insert(byline_parts, xmlEscape(entry.author))
    end
    if entry.feed and entry.feed.title and entry.feed.title ~= "" then
        table.insert(byline_parts, xmlEscape(entry.feed.title))
    end
    if type(entry.published_at) == "string" then
        table.insert(byline_parts, xmlEscape(entry.published_at:sub(1, 10)))
    end
    local byline = table.concat(byline_parts, " · ")

    local content = entry.content or ""
    local source_url = entry.url or ""
    local footer = ""
    if source_url ~= "" then
        footer = string.format([[<hr/><p><a href="%s">%s</a></p>]],
            xmlEscape(source_url), xmlEscape(source_url))
    end

    return string.format([[<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8"/>
<title>%s</title>
</head>
<body>
<h1>%s</h1>
<p><em>%s</em></p>
<article>%s</article>
%s
</body>
</html>]], title, title, byline, content, footer)
end

-- Compute the local EPUB path for an entry.
function Miniflux:getEntryPath(entry)
    local safe_title = util.getSafeFilename(entry.title or ("entry_" .. entry.id),
        self.download_dir, 200, 0)
    local filename = id_prefix .. entry.id .. id_postfix .. safe_title .. ".epub"
    return ffiUtil.joinPath(self.download_dir, filename)
end

function Miniflux:downloadEntries()
    -- First push up the read statuses of articles already finished in KOReader,
    -- so they get marked as read (and possibly removed) before we fetch more.
    local synced_count = self:uploadReadStatuses(true)

    Trapper:info(_("Connecting to Miniflux…"))

    local api = self:getApi()
    local ok, result, code = api:getEntries{
        status = "unread",
        limit = self.limit,
        order = self.order,
        direction = self.direction,
    }

    if not ok then
        Trapper:reset()
        local msg = apiErrorMessage(result)
            or T(_("Failed to fetch articles from Miniflux. (%1)"), tostring(code or result))
        UIManager:show(InfoMessage:new{ text = msg })
        return
    end

    local entries = result.entries or {}

    -- Reconcile articles read elsewhere: anything still unread on the server is
    -- in this list, so local articles outside it (and not finished locally) are
    -- confirmed individually and removed if read/removed on the server.
    local unread_ids = {}
    for _, entry in ipairs(entries) do
        unread_ids[entry.id] = true
    end
    local removed_count = self:deleteRemotelyReadArticles(unread_ids)

    local downloaded_ids = self:getLocalEntries()
    local total = #entries
    local new_count = 0
    local skipped_count = 0
    local failed_count = 0
    local cancelled = false

    for index, entry in ipairs(entries) do
        local message = T(_("Article %1 / %2:\n%3"), index, total,
            BD.auto(entry.title or ""))

        if downloaded_ids[entry.id] then
            skipped_count = skipped_count + 1
        else
            local epub_path = self:getEntryPath(entry)
            local html = buildArticleHtml(entry)
            local created, reason
            local create_ok, create_err = pcall(function()
                created, reason = MinifluxEpub:createEpub(epub_path, html,
                    entry.url or self.server_url, self.include_images, message)
            end)
            if create_ok and created then
                new_count = new_count + 1
            elseif create_ok and reason == "cancelled" then
                -- User interrupted: stop the whole batch rather than moving on
                -- to (and downloading) the next article.
                cancelled = true
                break
            else
                failed_count = failed_count + 1
                logger.warn("Miniflux: failed to create EPUB for entry", entry.id, create_err)
            end
        end
    end

    Trapper:reset()

    local lines = {}
    table.insert(lines, T(N_("Downloaded %1 article.", "Downloaded %1 articles.", new_count), new_count))
    if cancelled then
        table.insert(lines, _("Download interrupted."))
    end
    if skipped_count > 0 then
        table.insert(lines, T(_("Skipped %1 already downloaded."), skipped_count))
    end
    if failed_count > 0 then
        table.insert(lines, T(_("Failed: %1."), failed_count))
    end
    if synced_count > 0 then
        table.insert(lines, T(N_("Marked %1 finished article as read on the server.",
                                 "Marked %1 finished articles as read on the server.", synced_count),
                              synced_count))
    end
    if removed_count > 0 then
        table.insert(lines, T(N_("Removed %1 article read on another device.",
                                 "Removed %1 articles read on another device.", removed_count),
                              removed_count))
    end
    UIManager:show(InfoMessage:new{
        text = table.concat(lines, "\n"),
        timeout = RESULT_TIMEOUT,
    })
end

-------------------------------------------------------------------------------
-- File manager integration
-------------------------------------------------------------------------------

function Miniflux:refreshFileManager()
    if FileManager.instance then
        FileManager.instance:onRefresh()
    end
end

function Miniflux:onGoToMinifluxDirectory()
    if not lfs.attributes(self.download_dir, "mode") then
        util.makePath(self.download_dir)
    end
    if self.ui.document then
        self.ui:onClose()
    end
    if FileManager.instance then
        FileManager.instance:reinit(self.download_dir)
    else
        FileManager:showFiles(self.download_dir)
    end
    return true
end

return Miniflux
