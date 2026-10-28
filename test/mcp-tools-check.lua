-- Unit tests for install/mcp-tools.lua: run with `luajit test/mcp-tools-check.lua` from the repo
-- root. Each case is a POST body, a mode and list, and whether it must be allowed.
local T = dofile("install/mcp-tools.lua")

local function call(name, id) return '{"jsonrpc":"2.0","id":' .. (id or "1") .. ',"method":"tools/call","params":{"name":"' .. name .. '","arguments":{}}}' end
local deny, allow = { "deny", "write_thing other.tool" }, { "allow", "read_a read-b" }
local cases = {
  -- passes: other methods, notifications, responses, calls the list lets through
  { true,  deny,  '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"c","version":"1"}}}' },
  { true,  deny,  '{"jsonrpc":"2.0","method":"notifications/initialized"}' },
  { true,  deny,  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' },
  { true,  deny,  '{"jsonrpc":"2.0","id":"s-1","result":{}}' },
  { true,  deny,  call("read_a") },
  { true,  deny,  call("write_thing2") },
  { true,  allow, call("read_a") },
  { true,  allow, call("read-b", '"x"') },
  { true,  allow, '{"jsonrpc":"2.0","id":3,"method":"resources/read","params":{"uri":"file:///x"}}' },
  { true,  deny,  '[' .. call("read_a", 1) .. ',' .. call("read_b", 2) .. ']' },
  { true,  deny,  ' \r\n' .. call("read_a") .. '\n ' },
  { true,  deny,  '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"arguments":{"name":"write_thing"},"name":"read_a"}}' },
  { true,  deny,  '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"read_a","arguments":{"s":"\\"name\\":\\"write_thing\\" \\u00e9 \\ud83d\\ude00","n":-1.5e+3,"z":0,"a":[true,false,null,{}]}}}' },
  { true,  deny,  '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"read_a","arguments":{"x":"' .. string.rep("a", 900000) .. '"}}}' },
  -- refused: the listed (or not allowed) tool, however it is spelled
  { false, deny,  call("write_thing") },
  { false, deny,  call("WRITE_THING") },
  { false, deny,  call("other.tool") },
  { false, deny,  '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"write_\\u0074hing"}}' },
  { false, deny,  '{"jsonrpc":"2.0","id":1,"m\\u0065thod":"tools/call","params":{"name":"write_thing"}}' },
  { false, deny,  '{"jsonrpc":"2.0","id":1,"method":"TOOLS/CALL","params":{"name":"write_thing"}}' },
  { false, deny,  '{"jsonrpc":"2.0","id":1,"method":"tools\\/call","params":{"name":"write_thing"}}' },
  { false, deny,  '{"jsonrpc":"2.0","method":"tools/call","params":{"name":"write_thing"}}' },
  { false, allow, call("write_thing") },
  { false, allow, call("READ_A") },
  { false, allow, call("read_a ") },
  -- a batch with one refused message is refused whole
  { false, deny,  '[' .. call("read_a", 1) .. ',' .. call("write_thing", 2) .. ']' },
  { false, allow, '[' .. call("read_a", 1) .. ',{"jsonrpc":"2.0","method":"notifications/x"},' .. call("nope", 3) .. ']' },
  -- refused: a call this can't read for certain
  { false, deny,  '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"read_a","name":"write_thing"}}' },
  { false, deny,  '{"jsonrpc":"2.0","id":1,"method":"tools/call","method":"tools/list","params":{"name":"write_thing"}}' },
  { false, deny,  '{"jsonrpc":"2.0","id":1,"method":"tools/list","method":"tools/call","params":{"name":"write_thing"}}' },
  { false, deny,  '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"x"},"params":{"name":"write_thing"}}' },
  { false, deny,  '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"r\\u00e9ad"}}' },
  { false, deny,  '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"a b"}}' },
  { false, deny,  '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"' .. string.rep("a", 129) .. '"}}' },
  { false, deny,  '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":""}}' },
  { false, deny,  '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":1}}' },
  { false, deny,  '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{}}' },
  { false, deny,  '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":["write_thing"]}' },
  { false, deny,  '{"jsonrpc":"2.0","id":1,"method":"tools/call"}' },
  { false, deny,  '{"jsonrpc":"2.0","id":1,"method":7}' },
  { false, deny,  '{"jsonrpc":"2.0","id":{"a":1},"method":"tools/list"}' },
  { false, deny,  '' },
  { false, deny,  '   ' },
  { false, deny,  'null' },
  { false, deny,  '"tools/call"' },
  { false, deny,  '[]' },
  { false, deny,  '[1]' },
  { false, deny,  '{"jsonrpc":"2.0","id":1,"method":"tools/list"} {}' },
  { false, deny,  '{"jsonrpc":"2.0","id":1,"method":"tools/list",}' },
  { false, deny,  "{'jsonrpc':'2.0'}" },
  { false, deny,  '{"jsonrpc":"2.0","id":01,"method":"tools/list"}' },
  { false, deny,  '{"jsonrpc":"2.0","id":1.,"method":"tools/list"}' },
  { false, deny,  '{"jsonrpc":"2.0","id":NaN,"method":"tools/list"}' },
  { false, deny,  '{"jsonrpc":"2.0","id":1,"method":"tools/list","x":"a\nb"}' },
  { false, deny,  '{"jsonrpc":"2.0","id":1,"method":"tools/list","x":"\\x"}' },
  { false, deny,  '{"jsonrpc":"2.0","id":1,"method":"tools/list","x":"\\u12"}' },
  { false, deny,  '\239\187\191{"jsonrpc":"2.0","id":1,"method":"tools/list"}' },
  { false, deny,  '{"jsonrpc":"2.0","id":1,"method":"tools/list"' },
  { false, deny,  '{"jsonrpc":"2.0","id":1,"method":"tools/list","x":' .. string.rep("[", 100000) .. string.rep("]", 100000) .. '}' },
  { false, deny,  '[' .. string.rep('{"jsonrpc":"2.0","method":"n"},', 100) .. '{"jsonrpc":"2.0","method":"n"}]' },
  { false, deny,  '{"x":"' .. string.rep("a", 1048576) .. '"}' },
  -- from the cold review: keys a Go server would match in any case or by folding
  { false, deny,  '{"jsonrpc":"2.0","id":1,"Method":"tools/call","Params":{"Name":"write_thing"}}' },
  { false, deny,  '{"jsonrpc":"2.0","id":1,"method":"ping","Method":"tools/call","params":{"name":"write_thing"}}' },
  { false, deny,  '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"echo","Name":"write_thing"}}' },
  { false, allow, '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"read_a","NAME":"write_thing"}}' },
  { false, deny,  '{"jsonrpc":"2.0","id":1,"method":"tools/call","paramſ":{"name":"write_thing"},"params":{"name":"read_a"}}' },
  { false, deny,  '{"jsonrpc":"2.0","id":1,"method":"tools/call","param\\u017f":{"name":"write_thing"},"params":{"name":"read_a"}}' },
  { false, deny,  '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"read_a","\\u212aey":1}}' },
  { false, deny,  '{"jsonrpc":"2.0","ID":1,"method":"tools/list"}' },
  { false, deny,  '{"jsonrpc":"2.0","id":1,"method":"tools/list","id":2}' },
  { true,  deny,  '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"read_a","arguments":{"Name":"x","name":"y","ſ":1}}}' },
  { true,  deny,  '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"read_a","_meta":{"progressToken":1}}}' },
  -- from the re-review: a JS server copying the message would take what __proto__ holds
  { false, deny,  '{"jsonrpc":"2.0","id":1,"__proto__":{"method":"tools/call","params":{"name":"write_thing"}}}' },
  { false, deny,  '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"read_a","__proto__":{"name":"write_thing"}}}' },
  { false, deny,  '{"jsonrpc":"2.0","id":1,"constructor":{},"method":"tools/list"}' },
  { true,  deny,  '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"read_a","arguments":{"__proto__":{"x":1}}}}' },
  -- method names a server might trim or cut at a NUL
  { false, deny,  '{"jsonrpc":"2.0","id":1,"method":"tools/call ","params":{"name":"write_thing"}}' },
  { false, deny,  '{"jsonrpc":"2.0","id":1,"method":"tools/call\\u0000","params":{"name":"write_thing"}}' },
  { false, deny,  '{"jsonrpc":"2.0","id":1,"method":" tools/call","params":{"name":"write_thing"}}' },
  { false, deny,  '{"jsonrpc":"2.0","id":1,"method":"tools/c\\u00e1ll","params":{"name":"write_thing"}}' },
  { false, deny,  '{"jsonrpc":"2.0","id":1,"method":"","params":{}}' },
  { false, { "", "" }, call("read_a") },
  { false, { nil, nil }, call("read_a") },
}

local fails = 0
for i, c in ipairs(cases) do
  local ok, r = pcall(T.check_body, c[3], c[2][1], c[2][2])
  local allowed = ok and r == nil
  if allowed ~= c[1] then
    fails = fails + 1
    print(string.format("FAIL case %d: wanted %s, got %s: %s", i, c[1] and "allowed" or "refused",
      allowed and "allowed" or (ok and ("refused (" .. r.reason .. ")") or ("error: " .. tostring(r))),
      c[3]:sub(1, 160)))
  end
end
print(string.format("%s %d check cases", fails == 0 and "ok  " or "FAIL", #cases))

-- The replies: the request's id, an error for each request of a batch, a null id without one.
local function reply(body, mode, list) return T.reply(T.check_body(body, mode, list), "/a/mcp") end
local expect = {
  { reply(call("write_thing", '"r-7"'), "deny", "write_thing"),
    '{"jsonrpc":"2.0","id":"r-7","error":{"code":-32001,"message":"airlock-envoy: refused on /a/mcp: tool write_thing is refused on this endpoint (deny-tools)"}}' },
  { reply('[' .. call("x", 4) .. ',{"jsonrpc":"2.0","method":"n"},' .. call("write_thing", 5) .. ']', "deny", "write_thing"),
    '[{"jsonrpc":"2.0","id":4,"error":{"code":-32001,"message":"airlock-envoy: refused on /a/mcp: a batch holding a refused message: tool write_thing is refused on this endpoint (deny-tools)"}},'
    .. '{"jsonrpc":"2.0","id":5,"error":{"code":-32001,"message":"airlock-envoy: refused on /a/mcp: a batch holding a refused message: tool write_thing is refused on this endpoint (deny-tools)"}}]' },
  { reply('{"jsonrpc":', "deny", "x"),
    '{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"airlock-envoy: refused on /a/mcp: bad JSON"}}' },
  { reply('{"jsonrpc":"2.0","method":"tools/call","params":{"name":"zz"}}', "allow", "x"),
    '{"jsonrpc":"2.0","id":null,"error":{"code":-32001,"message":"airlock-envoy: refused on /a/mcp: tool zz is not allowed on this endpoint (tools)"}}' },
  { T.quote('a"b\\c\n\1\128'), '"a\\"b\\\\c\\u000a\\u0001\\u0080"' },
}
local rfails = 0
for i, e in ipairs(expect) do
  if e[1] ~= e[2] then rfails = rfails + 1; print("FAIL reply " .. i .. ": " .. e[1]) end
end
print(string.format("%s %d replies", rfails == 0 and "ok  " or "FAIL", #expect))

-- The request's headers (the route checks them too): JSON alone or with charset=utf-8; another
-- charset would let the server read other JSON (utf-7: +ACI- is a quote).
local function handle(hdrs, body)
  local h = { get = function(_, k) return hdrs[k] end }
  local meta = { get = function(_, k) return ({ mode = "deny", tools = "write_thing" })[k] end }
  local b = { length = function() return #body end, getBytes = function(_, i, n) return body:sub(i + 1, i + n) end }
  return { headers = function() return h end, metadata = function() return meta end, body = function() return b end }
end
local utf7 = '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"echo","zz":"+ACI-,+ACI-name+ACI-:+ACI-write_thing"}}'
local hcases = {
  { true,  { [":method"] = "POST", ["content-type"] = "application/json" } },
  { true,  { [":method"] = "POST", ["content-type"] = "application/json; charset=utf-8" } },
  { true,  { [":method"] = "POST", ["content-type"] = "Application/JSON;charset=UTF-8" } },
  { true,  { [":method"] = "POST", ["content-type"] = 'application/json; charset="utf-8"' } },
  { false, { [":method"] = "POST", ["content-type"] = "application/json; charset=utf-7" } },
  { false, { [":method"] = "POST", ["content-type"] = "application/json;charset=UTF-7" } },
  { false, { [":method"] = "POST", ["content-type"] = "application/json; charset=cp037" } },
  { false, { [":method"] = "POST", ["content-type"] = "application/json; charset=utf-8; charset=utf-7" } },
  { false, { [":method"] = "POST", ["content-type"] = "application/json; x=1" } },
  { false, { [":method"] = "POST", ["content-type"] = "application/json-seq" } },
  { false, { [":method"] = "POST", ["content-type"] = "text/plain" } },
  { false, { [":method"] = "POST" } },
  { false, { [":method"] = "POST", ["content-type"] = "application/json", ["content-encoding"] = "gzip" } },
  { false, { [":method"] = "GET", ["content-type"] = "application/json" } },
}
local hfails = 0
for i, c in ipairs(hcases) do
  local r = T.check_request(handle(c[2], utf7))
  if (r == nil) ~= c[1] then hfails = hfails + 1; print("FAIL header case " .. i .. ": " .. tostring(c[2]["content-type"]) .. " " .. (r and r.reason or "allowed")) end
end
print(string.format("%s %d header cases", hfails == 0 and "ok  " or "FAIL", #hcases))
rfails = rfails + hfails

-- The worst-case body costs bounded time (the check runs on Envoy's shared worker threads).
local worst = {
  { "a 1 MiB string argument", '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"a","arguments":{"x":"' .. string.rep("a", 1048000) .. '"}}}' },
  { "1 MiB of escapes", '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"a","arguments":{"x":"' .. string.rep("\\n", 524000) .. '"}}}' },
  { "1 MiB of small numbers", '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"a","arguments":{"x":[' .. string.rep("1,", 524000) .. '1]}}}' },
  { "1 MiB of empty objects", '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"a","arguments":{"x":[' .. string.rep("{},", 349000) .. '{}]}}}' },
  { "1 MiB of short strings", '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"a","arguments":{"x":[' .. string.rep('"",', 349000) .. '""]}}}' },
}
local slow = 0
for _, w in ipairs(worst) do
  local t0 = os.clock()
  local r = T.check_body(w[2], "deny", "zz")
  local ms = (os.clock() - t0) * 1000
  if r ~= nil then slow = slow + 1; print("FAIL worst case refused: " .. w[1] .. ": " .. r.reason)
  elseif ms > 1000 then slow = slow + 1; print(string.format("FAIL %s: %.0f ms", w[1], ms))
  else print(string.format("ok   %s (%d bytes): %.0f ms", w[1], #w[2], ms)) end
end
os.exit((fails + rfails + slow == 0) and 0 or 1)
