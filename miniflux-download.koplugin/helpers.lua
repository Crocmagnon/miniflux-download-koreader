--[[--
Pure helper functions, with no dependency on the KOReader host application
beyond gettext and ffi/util's `template` (interpolation). Kept in a separate
module so they can be unit-tested with busted outside of KOReader (see spec/).

The Miniflux entry id is encoded in the downloaded file name, e.g.
"[mf-id_1234] Some article title.epub". This lets the plugin detect
already-downloaded entries and reconcile read statuses on later syncs. Both
ends of that scheme (building and parsing the name) live here, so they cannot
drift apart.
--]]

local ffiutil = require("ffi/util")
local _ = require("gettext")
local N_ = _.ngettext
local T = ffiutil.template

local Helpers = {}

-- Read a boolean setting that defaults to true when it has never been set.
-- Takes the raw value returned by LuaSettings:readSetting so it stays pure.
function Helpers.defaultTrue(value)
    return value == nil or value
end

-- Build the lines of a download/sync result summary from the counters.
-- `downloaded` is included whenever present (even at 0); the other counts are
-- omitted when nil or <= 0. Returns an array of strings (possibly empty), which
-- the caller joins with "\n" and may extend with a context-specific fallback.
function Helpers.buildResultLines(c)
    local lines = {}
    if c.downloaded ~= nil then
        table.insert(lines, T(N_("Downloaded %1 article.",
                                 "Downloaded %1 articles.", c.downloaded), c.downloaded))
    end
    if c.cancelled then
        table.insert(lines, _("Download interrupted."))
    end
    if c.skipped and c.skipped > 0 then
        table.insert(lines, T(_("Skipped %1 already downloaded."), c.skipped))
    end
    if c.failed and c.failed > 0 then
        table.insert(lines, T(_("Failed: %1."), c.failed))
    end
    if c.marked and c.marked > 0 then
        table.insert(lines, T(N_("Marked %1 article as read on the server.",
                                 "Marked %1 articles as read on the server.", c.marked), c.marked))
    end
    if c.removed and c.removed > 0 then
        table.insert(lines, T(N_("Removed %1 article read on another device.",
                                 "Removed %1 articles read on another device.", c.removed), c.removed))
    end
    return lines
end

-- How many articles the image-failure summary lists individually before it
-- collapses the rest into a "…and N more." line.
local IMAGE_FAILURE_LIST_MAX = 5

-- Build the summary lines listing the articles whose images could not all be
-- downloaded. `failures` is an array of { title = , failed = , total = }.
-- Returns an empty array when nothing failed.
function Helpers.buildImageFailureLines(failures)
    if not failures or #failures == 0 then
        return {}
    end
    local lines = {
        T(N_("Missing images in %1 article:",
             "Missing images in %1 articles:", #failures), #failures),
    }
    for index = 1, math.min(#failures, IMAGE_FAILURE_LIST_MAX) do
        local failure = failures[index]
        table.insert(lines, T(_("• %1 (%2/%3)"),
            failure.title, failure.failed, failure.total))
    end
    if #failures > IMAGE_FAILURE_LIST_MAX then
        table.insert(lines, T(_("…and %1 more."), #failures - IMAGE_FAILURE_LIST_MAX))
    end
    return lines
end

-- Escape the Lua pattern magic characters of a literal string.
local function patternEscape(s)
    return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%1"))
end

-- Replace every <img> tag pointing at `imgpath` (an EPUB-internal image path,
-- e.g. "images/img00001.jpg") with an inline note, for images that could not
-- be downloaded: without this they render as an empty square.
function Helpers.replaceMissingImage(html, imgpath)
    local note = string.format([[<em class="miniflux-missing-image">%s</em>]],
        _("[Image unavailable]"))
    local pattern = [[<img src="]] .. patternEscape(imgpath) .. [["[^>]*>]]
    return (html:gsub(pattern, function() return note end))
end

-- Prefix/postfix framing the entry id in a downloaded file name.
Helpers.id_prefix = "[mf-id_"
Helpers.id_postfix = "] "

-- Translated message for a known API error keyword, or nil for anything else
-- (so callers can supply their own context-specific fallback wording).
function Helpers.apiErrorMessage(result)
    if result == "unauthorized" then
        return _("Authentication failed. Please check your API token.")
    elseif result == "network_error" then
        return _("Could not connect to the Miniflux server.\nCheck the server URL and your network.")
    end
    return nil
end

-- Extract the Miniflux entry id encoded in a file name, or nil.
function Helpers.entryIdFromFilename(filename)
    local id = filename:match("^%[mf%-id_(%d+)%]")
    return id and tonumber(id) or nil
end

-- Build the downloaded file name for an entry from its id and a (host-sanitised)
-- title. Inverse of entryIdFromFilename for the id part.
function Helpers.entryFilename(id, safe_title)
    return Helpers.id_prefix .. id .. Helpers.id_postfix .. safe_title .. ".epub"
end

-- Escape a plain-text string for safe inclusion in XML/XHTML.
function Helpers.xmlEscape(s)
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
function Helpers.buildArticleHtml(entry)
    local xmlEscape = Helpers.xmlEscape
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

return Helpers
