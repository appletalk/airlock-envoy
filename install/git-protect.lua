-- airlock-envoy: protected branches (an http line's protect). Inlined into the rendered config
-- by airlock-envoy-apply as the Lua of the internal protect-check listener, which ext_authz on
-- a protected definition's git-receive-pack route asks before anything goes upstream. It gets
-- the first 64 KiB of the push body at most (x-envoy-auth-partial-body says whether there was
-- more), the protected branches (x-airlock-protect, set by the route's ext_authz filter, never
-- by the box), and answers 200 to let the push through or 403 naming the reason.
--
-- A push body (protocol v0/v1; push has no v2) is pkt-lines: optional "shallow <oid>" lines,
-- the ref-update commands "<old-oid> SP <new-oid> SP <refname>" (capabilities after a NUL;
-- git reads them on any line), a flush (0000), then push options and the pack, which this
-- never reads. A command whose refname is a protected branch is refused, whatever it does
-- (create, update, force, delete), and the whole push with it. Default deny: anything this
-- can't read for certain is refused: no flush within the bytes seen, a malformed pkt-line or
-- command, a signed push (push-cert), an encoded body. Plain Lua 5.1 (LuaJIT, as in Envoy).

if jit then jit.off() end   -- see github-graphql.lua: MemoryDenyWriteExecute

local M = {}

-- "main staging release/*" (as apply writes it) -> list of lowercased names.
function M.protected_set(s)
  local t = {}
  for p in (s or ""):gmatch("%S+") do t[#t + 1] = p:lower() end
  return t
end

-- Whether refname is one of the protected branches: refs/heads/<name> exactly, or under
-- refs/heads/<prefix>/ for a "<prefix>/*" entry. Case-insensitive: refs are case-sensitive on
-- the server, but a case variant of a protected name is never legitimate, and some hosts fold
-- case.
function M.is_protected(refname, set)
  local r = refname:lower()
  for _, p in ipairs(set) do
    if p:sub(-2) == "/*" then
      local prefix = "refs/heads/" .. p:sub(1, -2)
      if r:sub(1, #prefix) == prefix then return true end
    elseif r == "refs/heads/" .. p then
      return true
    end
  end
  return false
end

local function oid(s) return (#s == 40 or #s == 64) and s:match("^%x+$") ~= nil end

-- A refname git itself would take (git check-ref-format, which receive-pack applies): no
-- control character, space or ~^:?*[\; no empty component ("//", a leading or trailing "/"),
-- no component starting with "." or ending in ".lock" (in any case, stricter than git), no "..",
-- no trailing ".", no "@{", not "@" alone. Refused here too (default deny), so a name the
-- server might read differently is never matched, logged or echoed: refs/heads//main and
-- refs/heads/x/../main are refused, not compared with "main".
local function plain_ref(r)
  if r == "" or r == "@" or r:find("[%c ~^:?*%[\\]") then return false end
  if r:find("..", 1, true) or r:find("@{", 1, true) or r:find("//", 1, true) then return false end
  if r:sub(1, 1) == "/" or r:sub(-1) == "/" or r:sub(-1) == "." then return false end
  for part in r:gmatch("[^/]+") do
    if part:sub(1, 1) == "." or part:lower():sub(-5) == ".lock" then return false end
  end
  return true
end

-- nil to allow; or the reason, and for a protected branch also that ref, every ref update
-- read (up to the flush, or up to where the body stops making sense) and the push's
-- capabilities (what git asked to be answered in).
function M.check_body(body, set, partial)
  local i, n, refs, caps, hit = 1, #body, {}, nil, nil
  local cut = partial and "the ref updates go past the first 64 KiB of the push" or "the push ends before its flush"
  local function refuse(why)
    if hit then return "push to protected branch " .. hit, hit, refs, caps end
    return why
  end
  while true do
    if i + 3 > n then return refuse(cut) end
    local hex = body:sub(i, i + 3)
    if not hex:match("^%x%x%x%x$") then return refuse("a malformed pkt-line length") end
    local len = tonumber(hex, 16)
    if len == 0 then break end   -- flush: the commands end here
    if len < 4 or len > 65520 then return refuse("a malformed pkt-line length") end
    if i + len - 1 > n then return refuse(cut) end
    local line = body:sub(i + 4, i + len - 1)
    i = i + len
    if line:sub(-1) == "\n" then line = line:sub(1, -2) end
    local nul = line:find("\0", 1, true)
    if nul then
      caps = caps or line:sub(nul + 1)
      line = line:sub(1, nul - 1)
    end
    if #refs == 0 and line:match("^push%-cert") then return refuse("a signed push (push-cert)") end
    if #refs == 0 and line:match("^shallow ") then
      if not oid(line:sub(9)) then return refuse("a malformed shallow line") end
    else
      local old, new, ref = line:match("^(%x+) (%x+) (.+)$")
      if not old or not oid(old) or not oid(new) or #old ~= #new then return refuse("a malformed ref update") end
      if not plain_ref(ref) then return refuse("a ref name git would refuse") end
      refs[#refs + 1] = ref
      if not hit and M.is_protected(ref, set) then hit = ref end
    end
  end
  if hit then return refuse() end
  return nil
end

local function pkt(s) return string.format("%04x", #s + 4) .. s end

-- A refused push answered in git's own protocol, so git shows it: the message on sideband 2
-- (git prints it as "remote: ..."), then on sideband 1 a report with each ref update refused
-- (git prints "! [remote rejected] ... (<reason>)"). Only in the forms the push asked for
-- (its capabilities); nil if it asked for neither.
function M.git_reply(msg, refs, caps, set)
  local c = " " .. (caps or "") .. " "
  local sb = c:find(" side-band-64k ", 1, true) or c:find(" side-band ", 1, true)
  local rs = c:find(" report-status ", 1, true) or c:find(" report-status-v2 ", 1, true)
  if not sb and not rs then return nil end
  local report = ""
  if rs then
    report = pkt("unpack ok\n")
    for _, r in ipairs(refs) do
      report = report .. pkt("ng " .. r .. " " .. (M.is_protected(r, set) and "protected branch (airlock-envoy protect)"
        or "refused with a protected branch in the same push") .. "\n")
    end
    report = report .. "0000"
  end
  if not sb then return report end
  -- side-band packets carry at most 999 bytes (side-band) or 65519 (side-band-64k) after
  -- the band byte; the report is cut to fit.
  local max = c:find(" side-band-64k ", 1, true) and 65514 or 994
  local out = pkt("\2" .. msg:sub(1, max))
  for k = 1, #report, max do out = out .. pkt("\1" .. report:sub(k, k + max - 1)) end
  return out .. "0000"
end

local function check_request(handle)
  local h = handle:headers()
  local enc = (h:get("content-encoding") or "identity"):lower()
  if enc ~= "identity" then return "an encoded (compressed) push body" end
  local set = M.protected_set(h:get("x-airlock-protect"))
  if #set == 0 then return "no protected branches given (a config error)" end
  -- Every header is read before body(): it yields, and Envoy's headers object is no longer
  -- usable afterwards ("object used outside of proper scope").
  local partial = h:get("x-envoy-auth-partial-body") == "true"
  local b = handle:body()
  local body = b and b:getBytes(0, b:length()) or ""
  local why, ref, refs, caps = M.check_body(body, set, partial)
  return why, ref, refs, caps, set
end

-- 200 lets the push through. A protected branch: 403 with the git-protocol reply, which the
-- box listener's local reply mapping turns into the 200 git needs to read it (the push is
-- refused all the same: nothing went upstream). Anything else refused (and a push asking for
-- no reply form): 400, plain text.
function envoy_on_request(handle)
  local h = handle:headers()
  local rules, listener, host = h:get("x-airlock-rules") or "?", h:get("x-airlock-listener") or "?", h:get("x-airlock-host") or "?"
  local ok, why, ref, refs, caps, set = pcall(check_request, handle)
  if not ok then why, ref = "the push check failed: " .. tostring(why), nil end
  if not why then
    handle:respond({ [":status"] = "200" }, "")
    return
  end
  -- No control character reaches the log (a second layer: check_body refuses such ref names).
  handle:logWarn("airlock-envoy protect refused: " .. (why:gsub("%c", "?")))
  local msg = "airlock-envoy: refused by the " .. rules .. " rules (listener " .. listener .. "): " .. why
    .. " on " .. host .. " (protect)" .. (ref and ": push another branch and open a PR" or "") .. "\n"
  local reply = ref and M.git_reply(msg, refs, caps, set)
  if reply then
    handle:respond({ [":status"] = "403", ["content-type"] = "application/x-git-receive-pack-result" }, reply)
  else
    handle:respond({ [":status"] = "400", ["content-type"] = "text/plain" }, msg)
  end
end

return M
