-- airlock-envoy: MCP tool check (the mcp rules, on an endpoint with tools or deny-tools). Inlined
-- into the rendered config by airlock-envoy-apply. A POST body is one JSON-RPC message or a batch
-- of them; each "tools/call" names a tool in params.name. With tools (an allowlist), a call
-- passes only if its tool is listed; with deny-tools, only if it is not. Every other method,
-- notifications and responses pass. A batch with one refused call is refused whole.
-- Default deny: a body this can't read for certain (not strict JSON, a duplicate key in a
-- message or its params, a tool name outside the MCP character set) is refused too. A refusal
-- is a JSON-RPC error (HTTP 200, the request's id) so the client shows the reason. Plain Lua 5.1
-- (LuaJIT, as in Envoy), no modules. Any error while checking refuses the request too
-- (envoy_on_request runs the check under pcall).

-- Envoy's unit sets MemoryDenyWriteExecute: see github-graphql.lua.
if jit then jit.off() end

-- Bounds on the work one request can cause (the check runs on Envoy's worker threads, which
-- every listener shares): the body (the route and Envoy's buffer filter also stop it at this
-- size), the nesting and the messages in a batch.
local MAX_BODY = 1048576
local MAX_DEPTH = 64
local MAX_BATCH = 100
-- A tool name as the MCP specification allows it: 1 to 128 of A-Z a-z 0-9 _ - .
local TOOL_NAME = "^[A-Za-z0-9_.-]+$"
local MAX_TOOL_NAME = 128

local M = {}

-- ---- strict JSON ----------------------------------------------------------------------------

local function ws(s, i)
  local _, e = s:find("^[ \t\r\n]*", i)
  return e + 1
end

local SIMPLE = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }

-- A JSON string at s[i] == '"': its value and the index after it, or nil. An escaped character
-- outside ASCII decodes to \255, which no tool name or key this reads can hold.
local function str(s, i)
  local j, out = i + 1, nil
  while true do
    local k = s:find('["\\%z\1-\31]', j)
    if not k then return nil end
    local c = s:byte(k)
    if c == 34 then
      if not out then return s:sub(i + 1, k - 1), k + 1 end
      out[#out + 1] = s:sub(j, k - 1)
      return table.concat(out), k + 1
    elseif c ~= 92 then return nil end   -- a raw control character
    out = out or {}
    out[#out + 1] = s:sub(j, k - 1)
    local e = s:sub(k + 1, k + 1)
    if SIMPLE[e] then out[#out + 1] = SIMPLE[e]; j = k + 2
    elseif e == "u" then
      local hex = s:sub(k + 2, k + 5)
      if not hex:match("^%x%x%x%x$") then return nil end
      local cp = tonumber(hex, 16)
      out[#out + 1] = (cp < 128) and string.char(cp) or "\255"
      j = k + 6
    else return nil end
  end
end

-- Skip a JSON string at s[i] == '"' without decoding it; the index after it, or nil.
local function strskip(s, i)
  local j = i + 1
  while true do
    local k = s:find('["\\%z\1-\31]', j)
    if not k then return nil end
    local c = s:byte(k)
    if c == 34 then return k + 1 end
    if c ~= 92 then return nil end
    local e = s:byte(k + 1)
    if e == 117 then   -- u
      if not s:find("^%x%x%x%x", k + 2) then return nil end
      j = k + 6
    elseif e == 34 or e == 92 or e == 47 or e == 98 or e == 102 or e == 110 or e == 114 or e == 116 then j = k + 2
    else return nil end
  end
end

-- A number at s[i] (strict JSON: no leading zero, no bare dot or exponent); the index after it.
local function num(s, i)
  local _, e = s:find("^-?%d+", i)
  if not e then return nil end
  local b = s:byte(i)
  if b == 45 then b = s:byte(i + 1) end
  if b == 48 and e > i + ((s:byte(i) == 45) and 1 or 0) then return nil end   -- a leading zero
  local c = s:byte(e + 1)
  if c == 46 then   -- .
    _, e = s:find("^%d+", e + 2); if not e then return nil end
    c = s:byte(e + 1)
  end
  if c == 101 or c == 69 then   -- e E
    _, e = s:find("^[+-]?%d+", e + 2); if not e then return nil end
  end
  return e + 1
end

local LIT = { [116] = "true", [102] = "false", [110] = "null" }
local WS = { [32] = true, [9] = true, [10] = true, [13] = true }

-- Skip any JSON value at s[i] (no leading whitespace); the index after it, or nil. Iterative,
-- with the open containers on a stack (nesting capped at MAX_DEPTH from depth).
local function skip(s, i, depth)
  local stack, n = {}, 0
  while true do
    -- a value at i
    local c = s:byte(i)
    if c == 34 then
      local j = strskip(s, i); if not j then return nil end
      i = j
    elseif c == 123 or c == 91 then   -- { [
      if depth + n >= MAX_DEPTH then return nil end
      local close = (c == 123) and 125 or 93
      i = i + 1
      c = s:byte(i); if WS[c] then i = ws(s, i); c = s:byte(i) end
      if c == close then i = i + 1
      else
        n = n + 1; stack[n] = close
        if close == 125 then
          if c ~= 34 then return nil end
          local j = strskip(s, i); if not j then return nil end
          i = j; c = s:byte(i); if WS[c] then i = ws(s, i); c = s:byte(i) end
          if c ~= 58 then return nil end
          i = i + 1; c = s:byte(i); if WS[c] then i = ws(s, i) end
        end
        goto continue
      end
    elseif c == 45 or (c and c >= 48 and c <= 57) then
      i = num(s, i); if not i then return nil end
    else
      local lit = LIT[c]
      if not lit or s:sub(i, i + #lit - 1) ~= lit then return nil end
      i = i + #lit
    end
    -- after a value: close containers, or the next member
    while true do
      if n == 0 then return i end
      c = s:byte(i); if WS[c] then i = ws(s, i); c = s:byte(i) end
      if c == stack[n] then n = n - 1; i = i + 1
      elseif c == 44 then   -- ,
        i = i + 1; c = s:byte(i); if WS[c] then i = ws(s, i); c = s:byte(i) end
        if stack[n] == 125 then
          if c ~= 34 then return nil end
          local j = strskip(s, i); if not j then return nil end
          i = j; c = s:byte(i); if WS[c] then i = ws(s, i); c = s:byte(i) end
          if c ~= 58 then return nil end
          i = i + 1; c = s:byte(i); if WS[c] then i = ws(s, i) end
        end
        break
      else return nil end
    end
    ::continue::
  end
end

-- An object at s[i] == "{": calls on(key, i) for each member, which reads the value at i and
-- returns the index after it (or nil). A key twice is refused: two readers could take
-- different ones. Returns the index after the object, or nil and the reason.
local function members(s, i, on)
  local seen = {}
  i = ws(s, i + 1)
  if s:sub(i, i) == "}" then return i + 1 end
  while true do
    if s:sub(i, i) ~= '"' then return nil, "bad JSON" end
    local key, j = str(s, i); if not key then return nil, "bad JSON" end
    if seen[key] then return nil, "the key " .. key .. " twice in one object" end
    seen[key] = true
    i = ws(s, j); if s:sub(i, i) ~= ":" then return nil, "bad JSON" end
    local why
    i, why = on(key, ws(s, i + 1)); if not i then return nil, why or "bad JSON" end
    i = ws(s, i)
    local d = s:sub(i, i)
    if d == "}" then return i + 1 end
    if d ~= "," then return nil, "bad JSON" end
    i = ws(s, i + 1)
  end
end

-- One JSON-RPC message at s[i]: { method = <string or nil>, id = <its JSON text or nil>,
-- name = <params.name if a string>, params = <JSON type of params> } and the index after it.
local function message(s, i)
  if s:sub(i, i) ~= "{" then return nil, nil, "a batch entry that is not an object" end
  local m = {}
  local j, why = members(s, i, function(key, k)
    if key == "method" then
      if s:sub(k, k) ~= '"' then m.method = false; return skip(s, k, 2) end
      local v, e = str(s, k); m.method = v; return e
    elseif key == "id" then
      local e = skip(s, k, 2); if not e then return nil end
      local c = s:sub(k, k)
      if c == "{" or c == "[" or c == "t" or c == "f" then return nil, "an id that is not a string, number or null" end
      m.id = s:sub(k, e - 1); return e
    elseif key == "params" then
      if s:sub(k, k) ~= "{" then m.params = s:sub(k, k); return skip(s, k, 2) end
      m.params = "{"
      return members(s, k, function(pkey, p)
        if pkey == "name" and s:sub(p, p) == '"' then local v, e = str(s, p); m.name = v; return e end
        if pkey == "name" then m.name = false end
        return skip(s, p, 3)
      end)
    end
    return skip(s, k, 2)
  end)
  if not j then return nil, nil, why end
  return m, j
end

-- The messages of a body: a list, whether it was a batch, or nil and the reason.
function M.messages(body)
  local i = ws(body, 1)
  local c, list, batch = body:sub(i, i), {}, false
  if c == "{" then
    local m, j, why = message(body, i); if not m then return nil, why end
    list[1] = m; i = j
  elseif c == "[" then
    batch = true
    i = ws(body, i + 1)
    if body:sub(i, i) == "]" then return nil, "an empty batch" end
    while true do
      if #list >= MAX_BATCH then return nil, "over " .. MAX_BATCH .. " messages in a batch" end
      local m, j, why = message(body, i); if not m then return nil, why end
      list[#list + 1] = m
      i = ws(body, j)
      local d = body:sub(i, i)
      if d == "]" then i = i + 1; break end
      if d ~= "," then return nil, "bad JSON" end
      i = ws(body, i + 1)
    end
  else
    return nil, "not a JSON-RPC message or batch"
  end
  if ws(body, i) <= #body then return nil, "trailing data after the JSON" end
  return list, batch
end

-- ---- the check ------------------------------------------------------------------------------

-- A set from a space-separated list of tool names (lowercased for a deny list).
function M.tool_set(list, lower)
  local set = {}
  for n in (list or ""):gmatch("%S+") do set[lower and n:lower() or n] = true end
  return set
end

-- nil if message m may go on under mode ("allow" or "deny") and set, else the reason.
local function check_message(m, mode, set)
  if m.method == false then return "a method that is not a string" end
  if not m.method then return nil end   -- a response
  -- A server that dispatched methods in any case would take TOOLS/CALL as a call.
  if m.method:lower() ~= "tools/call" then return nil end
  if m.params ~= "{" then return "tools/call without params" end
  local n = m.name
  if type(n) ~= "string" then return "tools/call without a tool name" end
  if #n > MAX_TOOL_NAME or not n:match(TOOL_NAME) then return "a tool name outside the MCP character set" end
  if mode == "allow" then
    if not set[n] then return "tool " .. n .. " is not allowed on this endpoint (tools)" end
  elseif mode == "deny" then
    -- Refused in any case, so a server that matched names loosely can't be reached around it.
    if set[n:lower()] then return "tool " .. n .. " is refused on this endpoint (deny-tools)" end
  else
    return "no tool list for this endpoint"
  end
  return nil
end

-- nil if the body may go on, else a refusal: { reason, code, ids (JSON texts), batch }.
function M.check_body(body, mode, list)
  if not body or body == "" then return { reason = "an empty body", code = -32700, ids = {} } end
  if #body > MAX_BODY then return { reason = "a body over " .. MAX_BODY .. " bytes", code = -32600, ids = {} } end
  local msgs, batch = M.messages(body)
  if not msgs then return { reason = batch, code = -32700, ids = {} } end
  local set = M.tool_set(list, mode == "deny")
  local ids = {}
  for _, m in ipairs(msgs) do
    if m.id and m.id ~= "null" and m.method then ids[#ids + 1] = m.id end
  end
  for _, m in ipairs(msgs) do
    local why = check_message(m, mode, set)
    if why then
      if batch then why = "a batch holding a refused message: " .. why end
      return { reason = why, code = -32001, ids = ids, batch = batch }
    end
  end
  return nil
end

local function quote(s)
  return '"' .. s:gsub('[%z\1-\31"\\\127-\255]', function(c)
    if c == '"' then return '\\"' elseif c == "\\" then return "\\\\" end
    return string.format("\\u%04x", c:byte())
  end) .. '"'
end
M.quote = quote

-- The JSON-RPC reply to a refusal: an error for each request in it (one with a null id if
-- there is none), an array for a batch.
function M.reply(r, endpoint)
  local msg = quote("airlock-envoy: refused on " .. (endpoint or "?") .. ": " .. r.reason)
  local function err(id)
    return '{"jsonrpc":"2.0","id":' .. id .. ',"error":{"code":' .. r.code .. ',"message":' .. msg .. '}}'
  end
  if #r.ids == 0 then return err("null") end
  if not r.batch then return err(r.ids[1]) end
  local out = {}
  for i, id in ipairs(r.ids) do out[i] = err(id) end
  return "[" .. table.concat(out, ",") .. "]"
end

-- nil if the request may go on, else the refusal.
local function check_request(handle)
  local h = handle:headers()
  -- The route sends only POST here; anything else is a misconfiguration: refuse.
  if h:get(":method") ~= "POST" then return { reason = "not a POST", code = -32600, ids = {} } end
  local ct = (h:get("content-type") or ""):lower()
  if not (ct == "application/json" or ct:match("^application/json%s*;")) then
    return { reason = "Content-Type must be application/json", code = -32600, ids = {} }
  end
  if h:get("content-encoding") then return { reason = "an encoded (compressed) body", code = -32600, ids = {} } end
  -- The endpoint's list, from the route's metadata (airlock-envoy-apply sets it). Read before
  -- body(), which yields: a handle object taken before a yield is invalid after it.
  local meta = handle:metadata()
  local mode, tools = meta:get("mode"), meta:get("tools")
  local b = handle:body()
  local body = b and b:getBytes(0, b:length()) or ""
  return M.check_body(body, mode, tools)
end

function envoy_on_request(handle)
  local ok, r = pcall(check_request, handle)
  if not ok then r = { reason = "the MCP tool check failed: " .. tostring(r), code = -32603, ids = {} } end
  if r then
    local endpoint = (handle:metadata():get("endpoint")) or "?"
    handle:logWarn("airlock-envoy mcp refused on " .. endpoint .. ": " .. r.reason)
    handle:respond({ [":status"] = "200", ["content-type"] = "application/json" }, M.reply(r, endpoint))
  end
end

return M
