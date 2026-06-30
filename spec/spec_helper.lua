-- Stub the KOReader host modules that the plugin's testable modules pull in,
-- so api.lua / helpers.lua can run under plain luajit + busted. Required at the
-- top of every spec file. Registering via package.preload means the real
-- module name resolves to the stub without touching the filesystem.

-- gettext: identity translation; ngettext picks singular/plural by count.
package.preload["gettext"] = function()
    return setmetatable({
        ngettext = function(singular, plural, n)
            return n == 1 and singular or plural
        end,
    }, { __call = function(_, msgid) return msgid end })
end

-- logger: discard everything.
package.preload["logger"] = function()
    local noop = function() end
    return { dbg = noop, info = noop, warn = noop, err = noop }
end

-- socket: only socket.skip is used (drops the first d return values, like
-- LuaSocket's socket.skip).
package.preload["socket"] = function()
    return {
        skip = function(d, ...) return select(d + 1, ...) end,
    }
end

-- ltn12: string source + table sink, matching LuaSocket's contract closely
-- enough for the API client.
package.preload["ltn12"] = function()
    return {
        source = {
            string = function(s)
                local done = false
                return function()
                    if done then return nil end
                    done = true
                    return s
                end
            end,
        },
        sink = {
            table = function(t)
                return function(chunk)
                    if chunk then t[#t + 1] = chunk end
                    return 1
                end
            end,
        },
    }
end

-- socketutil: timeout management is a no-op in tests.
package.preload["socketutil"] = function()
    return {
        LARGE_BLOCK_TIMEOUT = 0,
        LARGE_TOTAL_TIMEOUT = 0,
        set_timeout = function() end,
        reset_timeout = function() end,
    }
end

-- socket.http: a controllable stub. Tests set `http.response` to shape the
-- reply and read `http.last_request` / `http.last_body` to assert what was
-- sent. http.request mimics LuaSocket's generic (request-table) form, which
-- returns `1, code, headers, status` on success and `nil, err` on failure.
package.preload["socket.http"] = function()
    local http = {}
    function http.reset()
        http.response = nil
        http.last_request = nil
        http.last_body = nil
    end
    function http.request(req)
        http.last_request = req
        http.last_body = nil
        if req.source then
            local chunks = {}
            for chunk in req.source do
                chunks[#chunks + 1] = chunk
            end
            http.last_body = table.concat(chunks)
        end
        local r = http.response or {}
        if r.network_error then
            return nil, r.err or "closed"
        end
        if req.sink and r.body then
            req.sink(r.body)
        end
        return 1, r.code or 200, r.headers or {}, r.status or "HTTP/1.1 200 OK"
    end
    http.reset()
    return http
end
