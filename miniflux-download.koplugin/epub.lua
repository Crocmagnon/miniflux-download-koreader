--[[--
Builds an EPUB file from an article's HTML content, downloading and embedding
its images for offline reading.

This is a self-contained adaptation of the EPUB generation logic found in
KOReader's built-in `newsdownloader.koplugin/epubdownloadbackend.lua`.
--]]

local Version = require("version")
local ffiutil = require("ffi/util")
local http = require("socket.http")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local ltn12 = require("ltn12")
local socket = require("socket")
local socket_url = require("socket.url")
local socketutil = require("socketutil")
local time = require("ui/time")
local util = require("util")
local _ = require("gettext")
local T = ffiutil.template

local MinifluxEpub = {}

local ext_to_mimetype = {
    png = "image/png",
    jpg = "image/jpeg",
    jpeg = "image/jpeg",
    gif = "image/gif",
    svg = "image/svg+xml",
    webp = "image/webp",
    avif = "image/avif",
    bmp = "image/bmp",
    ico = "image/x-icon",
    tif = "image/tiff",
    tiff = "image/tiff",
}

-- Download the raw bytes of a remote URL (used for article images).
-- Images on a Miniflux feed are public URLs, so no auth header is needed.
local IMAGE_BLOCK_TIMEOUT = 10
local IMAGE_TOTAL_TIMEOUT = 60
local function getUrlContent(url)
    local parsed_url = socket_url.parse(url)
    if not parsed_url then
        logger.warn("MinifluxEpub: invalid image URL:", url)
        return false, "Invalid URL"
    end
    local path = parsed_url.path
    if path then
        -- Percent-encode invalid path characters (e.g. spaces) while preserving
        -- "/" separators and "%" (so existing "%XX" escapes are not double-
        -- encoded). Mirrors KOReader's newsdownloader plugin.
        parsed_url.path = util.urlEncode(path, "/%%")
        url = socket_url.build(parsed_url)
    end

    local sink = {}
    socketutil:set_timeout(IMAGE_BLOCK_TIMEOUT, IMAGE_TOTAL_TIMEOUT)
    local request = {
        url    = url,
        method = "GET",
        sink   = ltn12.sink.table(sink),
    }
    local code, headers, status = socket.skip(1, http.request(request))
    socketutil:reset_timeout()
    local content = table.concat(sink)

    -- Diagnostic trace: what was actually requested and what came back.
    logger.dbg("MinifluxEpub: GET", url,
        "-> code:", code,
        "status:", status,
        "content-type:", headers and headers["content-type"],
        "content-length:", headers and headers["content-length"],
        "content-encoding:", headers and headers["content-encoding"],
        "location:", headers and headers["location"],
        "received:", #content, "bytes")

    if code == socketutil.TIMEOUT_CODE or
       code == socketutil.SSL_HANDSHAKE_CODE or
       code == socketutil.SINK_TIMEOUT_CODE
    then
        logger.warn("MinifluxEpub: image request interrupted:", status or code)
        return false, code
    end
    if headers == nil then
        logger.warn("MinifluxEpub: no HTTP headers:", status or code or "network unreachable")
        return false, "Network or remote server unavailable"
    end
    if headers and headers["content-length"] then
        local content_length = tonumber(headers["content-length"])
        if #content ~= content_length then
            logger.warn("MinifluxEpub: incomplete content for", url,
                "expected", content_length, "got", #content)
            return false, "Incomplete content received"
        end
    end
    if type(code) ~= "number" or code < 200 or code >= 300 then
        logger.warn("MinifluxEpub: HTTP error fetching image:", status or code)
        return false, status or code
    end

    return true, content
end

local function isRelative(url_string)
    local parsed = socket_url.parse(url_string)
    -- If there is no scheme component, it is a relative URL.
    return parsed and parsed.scheme == nil
end

--[[--
Create an EPUB file from an HTML document.

@param epub_path  absolute path of the EPUB file to create
@param html       the full HTML document (must contain a <title> element)
@param url        the article's original URL, used to resolve relative image links
@param include_images  whether to download and embed images
@param message    progress message prefix (shown above per-image progress)
@treturn boolean  true on success, false if cancelled/failed
--]]
function MinifluxEpub:createEpub(epub_path, html, url, include_images, message)
    logger.dbg("MinifluxEpub:createEpub(", epub_path, ")")
    -- Trapper is used to display progress and ask questions through the UI.
    -- We must have been Trapper:wrap()'ed for the UI to be used; otherwise
    -- Trapper:info() / Trapper:confirm() fall back to the logger.
    local UI = require("ui/trapper")
    -- We may need to build absolute URLs for non-absolute image links.
    local base_url = socket_url.parse(url)

    local cancelled = false
    local page_htmltitle = html:match([[<title[^>]*>(.-)</title>]]) or _("Untitled")

    -- Rejigger HTML into XHTML to avoid unclosed elements.
    local cre = require("libs/libkoreader-cre")
    html = cre.getBalancedHTML(html, 0x0)

    local bookid = "miniflux_placeholder"
    local images = {}
    local seen_images = {}
    local imagenum = 1
    local cover_imgid = nil
    local matched_tags = 0

    local processImg = function(img_tag)
        matched_tags = matched_tags + 1
        local src = img_tag:match([[src="([^"]*)"]])
        if src == nil or src == "" then
            logger.dbg("MinifluxEpub: no src found in", img_tag)
            return nil
        end
        if src:sub(1, 5) == "data:" then
            logger.dbg("MinifluxEpub: skipping data URI")
            return nil
        end
        if src:sub(1, 2) == "//" then
            src = "https:" .. src
        elseif isRelative(src) then
            src = socket_url.absolute(base_url, src)
        end
        local cur_image
        if seen_images[src] then
            cur_image = seen_images[src]
        else
            local src_ext = src
            if src_ext:find("?") then
                src_ext = src_ext:match("(.-)%?") -- remove ?query
            end
            local ext = src_ext:match(".*%.(%S%S%S?%S?%S?)$") -- 2 to 5 chars
            if ext == nil then
                ext = ""
            end
            ext = ext:lower()
            local imgid = string.format("img%05d", imagenum)
            local imgpath = ext ~= "" and string.format("images/%s.%s", imgid, ext)
                                       or string.format("images/%s", imgid)
            local mimetype = ext_to_mimetype[ext] or ""
            local width = tonumber(img_tag:match([[width="([^"]*)"]]))
            local height = tonumber(img_tag:match([[height="([^"]*)"]]))
            -- Higher resolution (2x) image url, if any.
            local src2x = nil
            local srcset = img_tag:match([[srcset="([^"]*)"]])
            if srcset then
                srcset = " " .. srcset .. ", "
                src2x = srcset:match([[ (%S+) 2x, ]])
                if src2x then
                    if src2x:sub(1, 2) == "//" then
                        src2x = "https:" .. src2x
                    elseif isRelative(src2x) then
                        src2x = socket_url.absolute(base_url, src2x)
                    end
                end
            end
            cur_image = {
                imgid = imgid,
                imgpath = imgpath,
                src = src,
                src2x = src2x,
                mimetype = mimetype,
                width = width,
                height = height,
            }
            table.insert(images, cur_image)
            seen_images[src] = cur_image
            -- Use the first reasonably-sized portrait image as the cover.
            if not cover_imgid and width and width > 50 and height and height > 50 and height > width then
                cover_imgid = imgid
            end
            imagenum = imagenum + 1
        end
        local style_props = {}
        if cur_image.width then
            table.insert(style_props, string.format("width: %spx", cur_image.width))
        end
        if cur_image.height then
            table.insert(style_props, string.format("height: %spx", cur_image.height))
        end
        local style = table.concat(style_props, "; ")
        return string.format([[<img src="%s" style="%s" alt=""/>]], cur_image.imgpath, style)
    end

    if include_images then
        -- Count raw <img occurrences (case-insensitive) to compare against the
        -- number actually matched by our pattern: a gap means tags we failed to
        -- extract (e.g. lazy-loaded data-src, single-quoted src, uppercase IMG).
        local raw_img_tags = select(2, html:gsub("<%s*[Ii][Mm][Gg][%s/>]", ""))
        html = html:gsub("(<%s*img [^>]*>)", processImg)
        logger.dbg("MinifluxEpub: <img> tags raw:", raw_img_tags,
            "matched by pattern:", matched_tags,
            "unique images queued:", #images)
    else
        -- Remove img tags to avoid little blank squares of missing images.
        html = html:gsub("<%s*img [^>]*>", "")
    end

    UI:info(T(_("%1\n\nBuilding EPUB…"), message))

    -- Open the zip as .tmp first, so we don't clobber a good existing EPUB on failure.
    local Archiver = require("ffi/archiver")
    local epub = Archiver.Writer:new{}
    local epub_path_tmp = epub_path .. ".tmp"
    if not epub:open(epub_path_tmp, "epub") then
        logger.warn("MinifluxEpub: failed to open", epub_path_tmp)
        return false
    end

    local mtime = os.time()

    -- /mimetype : always "application/epub+zip", stored uncompressed.
    epub:setZipCompression("store")
    epub:addFileFromMemory("mimetype", "application/epub+zip", mtime)
    epub:setZipCompression("deflate")

    -- /META-INF/container.xml
    epub:addFileFromMemory("META-INF/container.xml", [[
<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>]], mtime)

    -- OEBPS/content.opf : metadata + manifest + spine
    local content_opf_parts = {}
    local meta_cover = "<!-- no cover image -->"
    if include_images and cover_imgid then
        meta_cover = string.format([[<meta name="cover" content="%s"/>]], cover_imgid)
    end
    table.insert(content_opf_parts, string.format([[
<?xml version='1.0' encoding='utf-8'?>
<package xmlns="http://www.idpf.org/2007/opf"
        xmlns:dc="http://purl.org/dc/elements/1.1/"
        unique-identifier="bookid" version="2.0">
  <metadata>
    <dc:title>%s</dc:title>
    <dc:publisher>KOReader %s</dc:publisher>
    %s
  </metadata>
  <manifest>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="content" href="content.html" media-type="application/xhtml+xml"/>
    <item id="css" href="stylesheet.css" media-type="text/css"/>
]], page_htmltitle, Version:getCurrentRevision(), meta_cover))
    if include_images then
        for _, img in ipairs(images) do
            table.insert(content_opf_parts, string.format(
                [[    <item id="%s" href="%s" media-type="%s"/>%s]],
                img.imgid, img.imgpath, img.mimetype, "\n"))
        end
    end
    table.insert(content_opf_parts, [[
  </manifest>
  <spine toc="ncx">
    <itemref idref="content"/>
  </spine>
</package>
]])
    epub:addFileFromMemory("OEBPS/content.opf", table.concat(content_opf_parts), mtime)

    -- OEBPS/stylesheet.css (empty, but referenced by the manifest)
    epub:addFileFromMemory("OEBPS/stylesheet.css", [[
/* Empty */
]], mtime)

    -- OEBPS/toc.ncx
    local toc_ncx_parts = {}
    table.insert(toc_ncx_parts, string.format(
        [[<navPoint id="navpoint-1" playOrder="1"><navLabel><text>%s</text></navLabel><content src="content.html"/></navPoint>]],
        page_htmltitle))
    table.insert(toc_ncx_parts, 1, string.format([[
<?xml version='1.0' encoding='utf-8'?>
<!DOCTYPE ncx PUBLIC "-//NISO//DTD ncx 2005-1//EN" "http://www.daisy.org/z3986/2005/ncx-2005-1.dtd">
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head>
    <meta name="dtb:uid" content="%s"/>
    <meta name="dtb:depth" content="0"/>
    <meta name="dtb:totalPageCount" content="0"/>
    <meta name="dtb:maxPageNumber" content="0"/>
  </head>
  <docTitle>
    <text>%s</text>
  </docTitle>
  <navMap>
]], bookid, page_htmltitle))
    table.insert(toc_ncx_parts, [[
  </navMap>
</ncx>
]])
    epub:addFileFromMemory("OEBPS/toc.ncx", table.concat(toc_ncx_parts), mtime)

    -- OEBPS/content.html
    epub:addFileFromMemory("OEBPS/content.html", html, mtime)

    collectgarbage()
    collectgarbage()

    -- OEBPS/images/*
    if include_images then
        local nb_images = #images
        local before_images_time = time.now()
        local time_prev = before_images_time
        for inum, img in ipairs(images) do
            -- The download can be interrupted between images by tapping the
            -- InfoMessage. We use fast_refresh from image #2 for a quicker UI.
            local go_on
            if time.to_ms(time.since(time_prev)) > 1000 then
                time_prev = time.now()
                go_on = UI:info((message and message ~= "" and message .. "\n\n" or "")
                    .. T(_("Retrieving image %1 / %2 …"), inum, nb_images), inum >= 2)
                if not go_on then
                    cancelled = true
                    break
                end
            else
                UI:info((message and message ~= "" and message .. "\n\n" or "")
                    .. T(_("Retrieving image %1 / %2 …"), inum, nb_images), inum >= 2, true)
            end
            local src = img.src
            local success, content = getUrlContent(src)
            if success then
                -- Store binary images uncompressed (they are already
                -- compressed); SVG is XML text, so deflate is worthwhile.
                -- Compression is selected via setZipCompression, not an
                -- argument to addFileFromMemory (which is path, content, mtime).
                epub:setZipCompression(img.mimetype == "image/svg+xml"
                    and "deflate" or "store")
                epub:addFileFromMemory("OEBPS/" .. img.imgpath, content, mtime)
            else
                logger.warn("MinifluxEpub: failed fetching image:", src, "reason:", content)
                go_on = UI:confirm(T(_("Downloading image %1 failed. Continue anyway?"), inum),
                    _("Stop"), _("Continue"))
                if not go_on then
                    cancelled = true
                    break
                end
            end
        end
        logger.dbg("MinifluxEpub: image download time:",
            time.to_ms(time.since(before_images_time)), "ms")
    end

    if cancelled then
        if UI:confirm(_("Download did not complete.\nDo you want to create an EPUB with the already downloaded images?"),
                _("Don't create"), _("Create")) then
            cancelled = false
        end
    end
    if cancelled then
        UI:info(_("Canceled. Cleaning up…"))
    else
        UI:info(T(_("%1\n\nPacking EPUB…"), message))
    end
    epub:close()

    if cancelled then
        if lfs.attributes(epub_path_tmp, "mode") == "file" then
            os.remove(epub_path_tmp)
        end
        -- Signal a user cancellation distinctly from a failure, so the caller
        -- can stop the whole batch instead of moving on to the next article.
        return false, "cancelled"
    end

    if not os.rename(epub_path_tmp, epub_path) then
        logger.warn("MinifluxEpub: failed to rename", epub_path_tmp, "to", epub_path)
        if lfs.attributes(epub_path_tmp, "mode") == "file" then
            os.remove(epub_path_tmp)
        end
        return false
    end
    logger.dbg("MinifluxEpub: successfully created", epub_path)

    collectgarbage()
    collectgarbage()
    return true
end

return MinifluxEpub
