--[[--
Minimal client for the Miniflux REST API.

Only the few endpoints needed by this plugin are implemented:
  * GET  /v1/me               -- connection / token check
  * GET  /v1/entries          -- list entries (filtered by status)
  * PUT  /v1/entries          -- change the status of a set of entries

Authentication uses the `X-Auth-Token` header (a Miniflux API key created from
Settings > API Keys in the Miniflux web UI).

See <https://miniflux.app/docs/api.html>.
--]]

local JSON = require("json")
local http = require("socket.http")
local logger = require("logger")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")

local MinifluxApi = {}
MinifluxApi.__index = MinifluxApi

--- Create a new API client.
-- @param server_url base URL of the Miniflux server (no trailing slash, no /v1)
-- @param token the API token (X-Auth-Token)
function MinifluxApi:new(server_url, token)
    local o = {
        server_url = server_url,
        token = token,
    }
    return setmetatable(o, self)
end

--[[--
Perform an HTTP request against the Miniflux API.

@param method  "GET", "PUT", "POST", …
@param endpoint  path beginning with "/v1/…"
@param body  optional Lua table, JSON-encoded as the request body
@treturn boolean ok
@treturn table|string  decoded JSON response on success, or an error keyword
@treturn number|nil  HTTP status code (when relevant)
--]]
function MinifluxApi:request(method, endpoint, body)
    local sink = {}
    local headers = {
        ["X-Auth-Token"] = self.token,
        ["Accept"] = "application/json",
    }
    local source = nil
    if body ~= nil then
        local body_json = JSON.encode(body)
        source = ltn12.source.string(body_json)
        headers["Content-Type"] = "application/json"
        headers["Content-Length"] = tostring(#body_json)
    end

    local request = {
        url     = self.server_url .. endpoint,
        method  = method,
        headers = headers,
        source  = source,
        sink    = ltn12.sink.table(sink),
    }

    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    logger.dbg("MinifluxApi:request:", method, request.url)
    local code, resp_headers, status = socket.skip(1, http.request(request))
    socketutil:reset_timeout()

    if resp_headers == nil then
        logger.err("MinifluxApi:request: network error", status or code)
        return false, "network_error"
    end

    if code == 200 or code == 201 then
        local content = table.concat(sink)
        if content == "" then
            return true, {}
        end
        local ok, result = pcall(JSON.decode, content)
        if ok and result then
            return true, result
        end
        logger.err("MinifluxApi:request: invalid JSON response")
        return false, "json_error"
    elseif code == 204 then
        -- No Content -- e.g. successful status update.
        return true, {}
    elseif code == 401 then
        logger.err("MinifluxApi:request: unauthorized (bad token)")
        return false, "unauthorized", code
    else
        logger.err("MinifluxApi:request: HTTP error", status or code)
        return false, "http_error", code
    end
end

--- Check the connection and token by querying the current user.
-- @treturn boolean ok
-- @treturn table|string user object on success, error keyword otherwise
function MinifluxApi:getMe()
    return self:request("GET", "/v1/me")
end

--[[--
List entries.

@param opts table of options:
  status     -- "unread" | "read" | "removed" (default "unread")
  limit      -- max number of entries
  order      -- "id" | "published_at" | … (default "published_at")
  direction  -- "asc" | "desc" (default "desc")
@treturn boolean ok
@treturn table|string  { total = N, entries = {…} } on success, error keyword otherwise
--]]
function MinifluxApi:getEntries(opts)
    opts = opts or {}
    local params = {
        "status=" .. (opts.status or "unread"),
        "order=" .. (opts.order or "published_at"),
        "direction=" .. (opts.direction or "desc"),
    }
    if opts.limit then
        table.insert(params, "limit=" .. tostring(opts.limit))
    end
    if opts.offset then
        table.insert(params, "offset=" .. tostring(opts.offset))
    end
    local endpoint = "/v1/entries?" .. table.concat(params, "&")
    return self:request("GET", endpoint)
end

--[[--
Fetch a single entry by id.

@param entry_id  the entry id
@treturn boolean ok
@treturn table|string  the entry object on success, error keyword otherwise
@treturn number|nil    HTTP status code (e.g. 404 when the entry no longer exists)
--]]
function MinifluxApi:getEntry(entry_id)
    return self:request("GET", "/v1/entries/" .. tostring(entry_id))
end

--[[--
Change the status of a list of entries.

@param entry_ids  array of entry ids (numbers)
@param status     "read" | "unread" | "removed"
@treturn boolean ok
@treturn table|string
--]]
function MinifluxApi:updateEntriesStatus(entry_ids, status)
    return self:request("PUT", "/v1/entries", {
        entry_ids = entry_ids,
        status = status,
    })
end

return MinifluxApi
