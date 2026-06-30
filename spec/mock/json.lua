-- Minimal, self-contained JSON codec standing in for KOReader's `json` module
-- during tests. Supports the subset exercised by the Miniflux API client:
-- objects, arrays, strings, numbers, booleans and null. decode() raises on
-- malformed input, which is what the client's pcall(JSON.decode, ...) relies on.

local json = {}

local escapes = {
    ['"'] = '\\"', ['\\'] = '\\\\',
    ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
}

local function encode_value(v, out)
    local t = type(v)
    if v == nil then
        out[#out + 1] = "null"
    elseif t == "boolean" or t == "number" then
        out[#out + 1] = tostring(v)
    elseif t == "string" then
        out[#out + 1] = '"' .. v:gsub('[%z\1-\31\\"]', function(c)
            return escapes[c] or string.format("\\u%04x", c:byte())
        end) .. '"'
    elseif t == "table" then
        local n = 0
        for _ in pairs(v) do n = n + 1 end
        if #v == n then -- array (covers the empty table too)
            out[#out + 1] = "["
            for i = 1, #v do
                if i > 1 then out[#out + 1] = "," end
                encode_value(v[i], out)
            end
            out[#out + 1] = "]"
        else
            out[#out + 1] = "{"
            local first = true
            for k, val in pairs(v) do
                if not first then out[#out + 1] = "," end
                first = false
                encode_value(tostring(k), out)
                out[#out + 1] = ":"
                encode_value(val, out)
            end
            out[#out + 1] = "}"
        end
    else
        error("json: cannot encode " .. t)
    end
end

function json.encode(v)
    local out = {}
    encode_value(v, out)
    return table.concat(out)
end

function json.decode(str)
    local pos = 1
    local parse_value

    local function err(msg) error("json: " .. msg .. " at " .. pos) end

    local function skip_ws()
        local _, e = str:find("^[ \t\r\n]*", pos)
        pos = e + 1
    end

    local string_escapes = {
        ['"'] = '"', ['\\'] = '\\', ['/'] = '/',
        n = '\n', r = '\r', t = '\t', b = '\b', f = '\f',
    }

    local function parse_string()
        pos = pos + 1 -- opening quote
        local buf = {}
        while true do
            local c = str:sub(pos, pos)
            if c == "" then err("unterminated string") end
            if c == '"' then pos = pos + 1; break end
            if c == "\\" then
                local e = str:sub(pos + 1, pos + 1)
                if e == "u" then
                    buf[#buf + 1] = string.char(tonumber(str:sub(pos + 2, pos + 5), 16) % 256)
                    pos = pos + 6
                elseif string_escapes[e] then
                    buf[#buf + 1] = string_escapes[e]
                    pos = pos + 2
                else
                    err("bad escape")
                end
            else
                buf[#buf + 1] = c
                pos = pos + 1
            end
        end
        return table.concat(buf)
    end

    local function parse_number()
        local s, e = str:find("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", pos)
        if not s then err("bad number") end
        pos = e + 1
        return tonumber(str:sub(s, e))
    end

    local function parse_object()
        pos = pos + 1 -- {
        local obj = {}
        skip_ws()
        if str:sub(pos, pos) == "}" then pos = pos + 1; return obj end
        while true do
            skip_ws()
            if str:sub(pos, pos) ~= '"' then err("expected key") end
            local k = parse_string()
            skip_ws()
            if str:sub(pos, pos) ~= ":" then err("expected colon") end
            pos = pos + 1
            obj[k] = parse_value()
            skip_ws()
            local c = str:sub(pos, pos)
            if c == "," then pos = pos + 1
            elseif c == "}" then pos = pos + 1; break
            else err("expected , or }") end
        end
        return obj
    end

    local function parse_array()
        pos = pos + 1 -- [
        local arr = {}
        skip_ws()
        if str:sub(pos, pos) == "]" then pos = pos + 1; return arr end
        while true do
            arr[#arr + 1] = parse_value()
            skip_ws()
            local c = str:sub(pos, pos)
            if c == "," then pos = pos + 1
            elseif c == "]" then pos = pos + 1; break
            else err("expected , or ]") end
        end
        return arr
    end

    function parse_value()
        skip_ws()
        local c = str:sub(pos, pos)
        if c == "{" then return parse_object()
        elseif c == "[" then return parse_array()
        elseif c == '"' then return parse_string()
        elseif str:sub(pos, pos + 3) == "true" then pos = pos + 4; return true
        elseif str:sub(pos, pos + 4) == "false" then pos = pos + 5; return false
        elseif str:sub(pos, pos + 3) == "null" then pos = pos + 4; return nil
        elseif c:match("[%-%d]") then return parse_number()
        else err("unexpected character") end
    end

    skip_ws()
    return parse_value()
end

return json
