-- Unit tests for install/git-protect.lua: run with `luajit test/git-protect-check.lua` from the
-- repo root. Each case is a git-receive-pack body and whether it must be allowed.
local P = dofile("install/git-protect.lua")

local Z, A, B = string.rep("0", 40), string.rep("a", 40), string.rep("b", 40)
local Z2, A2 = string.rep("0", 64), string.rep("c", 64)
local function pkt(s) return string.format("%04x", #s + 4) .. s end
local function cmd(old, new, ref, caps) return pkt(old .. " " .. new .. " " .. ref .. (caps and ("\0" .. caps) or "") .. "\n") end
local CAPS = "report-status side-band-64k quiet object-format=sha1 agent=git/2.47.0"
local PACK = "PACK\0\0\0\2\0\0\0\0" .. string.rep("x", 100)
local set = P.protected_set("main Staging release/*")

local cases = {
  -- allowed: feature branches, tags, the probe a big push sends first, a pack the check never reads
  { true,  "feature branch",                cmd(Z, A, "refs/heads/feature", CAPS) .. "0000" .. PACK },
  { true,  "several, none protected",       cmd(Z, A, "refs/heads/a", CAPS) .. cmd(A, B, "refs/heads/b") .. "0000" .. PACK },
  { true,  "a tag",                         cmd(Z, A, "refs/tags/main", CAPS) .. "0000" .. PACK },
  { true,  "a name only starting with main", cmd(Z, A, "refs/heads/maintenance", CAPS) .. "0000" .. PACK },
  { true,  "main as a path below a branch", cmd(Z, A, "refs/heads/x/main", CAPS) .. "0000" .. PACK },
  { true,  "release itself is not release/*", cmd(Z, A, "refs/heads/release", CAPS) .. "0000" .. PACK },
  { true,  "the probe of a large push",     "0000" },
  { true,  "shallow line first",            pkt("shallow " .. B .. "\n") .. cmd(Z, A, "refs/heads/f", CAPS) .. "0000" .. PACK },
  { true,  "sha256 ids",                    cmd(Z2, A2, "refs/heads/f", CAPS) .. "0000" .. PACK },
  { true,  "a delete of a feature branch",  cmd(A, Z, "refs/heads/f", CAPS) .. "0000" },
  { true,  "push options after the flush",  cmd(Z, A, "refs/heads/f", CAPS .. " push-options") .. "0000" .. pkt("refs/heads/main") .. "0000" .. PACK },
  { true,  "the pack may hold anything",    cmd(Z, A, "refs/heads/f", CAPS) .. "0000" .. "PACK" .. cmd(Z, A, "refs/heads/main") },
  { true,  "dots, @, + and UTF-8 inside names", cmd(Z, A, "refs/heads/a.b/c-d_e@f+g/caf\195\169", CAPS) .. "0000" .. PACK },
  { true,  "lock not at a component's end", cmd(Z, A, "refs/heads/main.lockx/y.lock2", CAPS) .. "0000" .. PACK },
  { true,  "no newline on the command",     pkt(Z .. " " .. A .. " refs/heads/f\0" .. CAPS) .. "0000" },
  -- refused: a protected branch, whatever the update does
  { false, "update main",                   cmd(A, B, "refs/heads/main", CAPS) .. "0000" .. PACK },
  { false, "create main",                   cmd(Z, A, "refs/heads/main", CAPS) .. "0000" .. PACK },
  { false, "delete main",                   cmd(A, Z, "refs/heads/main", CAPS) .. "0000" },
  { false, "main in another case",          cmd(A, B, "refs/heads/MAIN", CAPS) .. "0000" .. PACK },
  { false, "Main",                          cmd(A, B, "refs/heads/Main", CAPS) .. "0000" .. PACK },
  { false, "staging (listed in another case)", cmd(A, B, "refs/heads/staging", CAPS) .. "0000" .. PACK },
  { false, "under release/*",               cmd(A, B, "refs/heads/release/1.2", CAPS) .. "0000" .. PACK },
  { false, "deep under release/*",          cmd(A, B, "refs/heads/release/a/b", CAPS) .. "0000" .. PACK },
  { false, "main second in a mixed push",   cmd(Z, A, "refs/heads/f", CAPS) .. cmd(A, B, "refs/heads/main") .. "0000" .. PACK },
  { false, "main with caps on a later line", cmd(Z, A, "refs/heads/f", CAPS) .. cmd(A, B, "refs/heads/main", "x") .. "0000" },
  { false, "main in sha256",                cmd(Z2, A2, "refs/heads/main", CAPS) .. "0000" .. PACK },
  { false, "after a shallow line",          pkt("shallow " .. B .. "\n") .. cmd(A, B, "refs/heads/main", CAPS) .. "0000" },
  -- refused: what the check can't read for certain
  { false, "no flush, body ends",           cmd(Z, A, "refs/heads/f", CAPS) },
  { false, "empty body",                    "" },
  { false, "a cut length",                  "00" },
  { false, "a cut command",                 cmd(Z, A, "refs/heads/f", CAPS):sub(1, 30) },
  { false, "a length that isn't hex",       "zz10" .. string.rep("x", 12) .. "0000" },
  { false, "a length under 4 (delim)",      "0001" .. "0000" },
  { false, "a length of 3",                 "0003" .. "0000" },
  { false, "a length over 65520",           "fff1" .. string.rep("x", 65520) .. "0000" },
  { false, "a signed push",                 pkt("push-cert\0" .. CAPS .. "\n") .. pkt("certificate version 0.1\n") .. "0000" },
  { false, "short old id",                  cmd("abc", A, "refs/heads/f", CAPS) .. "0000" },
  { false, "ids of mixed length",           cmd(Z, A2, "refs/heads/f", CAPS) .. "0000" },
  { false, "no refname",                    pkt(Z .. " " .. A .. "\n") .. "0000" },
  { false, "a non-hex id",                  cmd(string.rep("g", 40), A, "refs/heads/f", CAPS) .. "0000" },
  { false, "a bad shallow line",            pkt("shallow xyz\n") .. "0000" },
  { false, "shallow after a command",       cmd(Z, A, "refs/heads/f", CAPS) .. pkt("shallow " .. B .. "\n") .. "0000" },
  { false, "a blank command",               pkt("\n") .. "0000" },
}

local fails = 0
for _, c in ipairs(cases) do
  local why = P.check_body(c[3], set, false)
  if (why == nil) ~= c[1] then
    fails = fails + 1
    print(string.format("FAIL %s: %s (%s)", c[1] and "allow" or "refuse", c[2], tostring(why)))
  end
end

-- Each refusal for its own reason, not a fallback's (a guard removed must fail here).
for _, c in ipairs({
  { "a signed push (push-cert)",         pkt("push-cert\0" .. CAPS .. "\n") .. "0000" },
  { "a malformed pkt-line length",       "fff1" .. string.rep("x", 65520) .. "0000" },
  { "a malformed pkt-line length",       "0003" .. "0000" },
  { "a malformed ref update",            cmd("abc", A, "refs/heads/f", CAPS) .. "0000" },
  { "a malformed ref update",            cmd(Z, string.rep("a", 41), "refs/heads/f", CAPS) .. "0000" },
  { "a malformed ref update",            cmd(Z, A2, "refs/heads/f", CAPS) .. "0000" },
  { "a malformed ref update",            cmd(string.rep("0", 41), string.rep("a", 41), "refs/heads/f", CAPS) .. "0000" },
  { "a malformed ref update",            cmd(string.rep("0", 39), string.rep("a", 39), "refs/heads/main", CAPS) .. "0000" },
  { "the push ends before its flush",    cmd(Z, A, "refs/heads/f", CAPS):sub(1, 30) },
  { "the push ends before its flush",    "00ff" .. Z },
  { "a malformed shallow line",          pkt("shallow xyz\n") .. "0000" },
  { "a ref name git would refuse",       cmd(Z, A, "refs/heads/release/x\n[1][critical] forged\27[31m", CAPS) .. "0000" },
  { "a ref name git would refuse",       cmd(Z, A, "refs/heads/a b", CAPS) .. "0000" },
  { "a ref name git would refuse",       cmd(Z, A, "refs/heads/a\r", CAPS) .. "0000" },
  { "a ref name git would refuse",       cmd(Z, A, "refs/heads/a~1", CAPS) .. "0000" },
  { "a ref name git would refuse",       cmd(Z, A, "refs/heads/a^", CAPS) .. "0000" },
  { "a ref name git would refuse",       cmd(Z, A, "refs/heads/a:b", CAPS) .. "0000" },
  { "a ref name git would refuse",       cmd(Z, A, "refs/heads/a?", CAPS) .. "0000" },
  { "a ref name git would refuse",       cmd(Z, A, "refs/heads/a*", CAPS) .. "0000" },
  { "a ref name git would refuse",       cmd(Z, A, "refs/heads/a[b", CAPS) .. "0000" },
  { "a ref name git would refuse",       cmd(Z, A, "refs/heads/a\\b", CAPS) .. "0000" },
  { "a ref name git would refuse",       cmd(Z, A, "refs/heads/a\127", CAPS) .. "0000" },
  -- git check-ref-format's rules beyond characters: names near "main" a server might read as it
  { "a ref name git would refuse",       cmd(Z, A, "refs/heads//main", CAPS) .. "0000" },
  { "a ref name git would refuse",       cmd(Z, A, "refs/heads/./main", CAPS) .. "0000" },
  { "a ref name git would refuse",       cmd(Z, A, "refs/heads/x/../main", CAPS) .. "0000" },
  { "a ref name git would refuse",       cmd(Z, A, "refs/heads/main/", CAPS) .. "0000" },
  { "a ref name git would refuse",       cmd(Z, A, "refs/heads/main.", CAPS) .. "0000" },
  { "a ref name git would refuse",       cmd(Z, A, "refs/heads/main.lock", CAPS) .. "0000" },
  { "a ref name git would refuse",       cmd(Z, A, "refs/heads/main.LOCK", CAPS) .. "0000" },
  { "a ref name git would refuse",       cmd(Z, A, "refs/heads/.main", CAPS) .. "0000" },
  { "a ref name git would refuse",       cmd(Z, A, "refs/heads/main@{0}", CAPS) .. "0000" },
  { "a ref name git would refuse",       cmd(Z, A, "/refs/heads/main", CAPS) .. "0000" },
  { "a ref name git would refuse",       cmd(Z, A, "refs/heads/a..b", CAPS) .. "0000" },
  { "a ref name git would refuse",       cmd(Z, A, "@", CAPS) .. "0000" },
}) do
  local why = P.check_body(c[2], set, false)
  if why ~= c[1] then fails = fails + 1; print(string.format("FAIL reason: want %q, got %q", c[1], tostring(why))) end
end
if P.check_body(cmd(Z, A, "refs/heads/release/1.0-rc_2/x.y", CAPS) .. "0000", set, false) ~= "push to protected branch refs/heads/release/1.0-rc_2/x.y" then
  fails = fails + 1; print("FAIL a plain name under release/ not matched")
end

-- The 64 KiB cut: commands complete within it pass, a flush beyond it is refused as cut.
local many = cmd(Z, A, "refs/heads/f0", CAPS)
for k = 1, 700 do many = many .. cmd(Z, A, "refs/heads/f" .. k) end
local cut = many:sub(1, 65536)
local why = P.check_body(cut, set, true)
if not (why and why:find("64 KiB", 1, true)) then fails = fails + 1; print("FAIL ref updates past 64 KiB: " .. tostring(why)) end
why = P.check_body(cmd(Z, A, "refs/heads/f", CAPS) .. "0000" .. string.rep("P", 70000), set, true)
if why then fails = fails + 1; print("FAIL commands within 64 KiB, the rest cut: " .. why) end

-- The refusal names the ref as sent.
why = P.check_body(cmd(A, B, "refs/heads/Main", CAPS) .. "0000", set, false)
if why ~= "push to protected branch refs/heads/Main" then fails = fails + 1; print("FAIL message: " .. tostring(why)) end

-- Matching on its own.
for _, m in ipairs({ { "refs/heads/main", true }, { "refs/heads/release/", true }, { "refs/heads/releases/x", false },
                     { "refs/heads/main/x", false }, { "refs/remotes/origin/main", false }, { "refs/heads/STAGING", true } }) do
  if P.is_protected(m[1], set) ~= m[2] then fails = fails + 1; print("FAIL is_protected " .. m[1]) end
end
if #P.protected_set("") ~= 0 or #P.protected_set(nil) ~= 0 then fails = fails + 1; print("FAIL empty set") end

-- envoy_on_request with a stub handle: 200 or 403, and the headers it reads. As in Envoy, a
-- headers object taken before body() can't be used after it (body() yields).
local function run(hdrs, body)
  local out, gen = {}, 0
  local h = {}
  function h:headers()
    local mine = gen
    return { get = function(_, k)
      if mine ~= gen then error("object used outside of proper scope") end
      return hdrs[k]
    end }
  end
  function h:body()
    gen = gen + 1
    return { length = function() return #body end, getBytes = function(_, a, n) return body:sub(a + 1, a + n) end }
  end
  function h:logWarn() end
  function h:respond(head, b) out.status, out.body = head[":status"], b end
  envoy_on_request(h)
  return out
end
local H = { ["x-airlock-protect"] = "main", ["x-airlock-rules"] = "git", ["x-airlock-listener"] = "agent", ["x-airlock-host"] = "git.example.com" }
local function with(k, v) local t = {}; for a, b in pairs(H) do t[a] = b end; t[k] = v; return t end
local MSG = "airlock-envoy: refused by the git rules (listener agent): push to protected branch refs/heads/main on git.example.com (protect): push another branch and open a PR\n"
-- A protected branch: 403 (the listener maps it to 200) with the git reply: the message on
-- band 2, then on band 1 the report, ng for each ref update.
local r = run(H, cmd(A, B, "refs/heads/main", CAPS) .. "0000")
local want = pkt("\2" .. MSG) .. pkt("\1" .. pkt("unpack ok\n") .. pkt("ng refs/heads/main protected branch (airlock-envoy protect)\n") .. "0000") .. "0000"
if r.status ~= "403" or r.body ~= want then fails = fails + 1; print("FAIL handle refusal: " .. tostring(r.status) .. " " .. string.format("%q", tostring(r.body))) end
-- A mixed push: every ref update gets its ng line, the others say why.
r = run(H, cmd(Z, A, "refs/heads/f", CAPS) .. cmd(A, B, "refs/heads/main") .. "0000")
if r.status ~= "403" or not r.body:find("ng refs/heads/f refused with a protected branch in the same push\n", 1, true)
   or not r.body:find("ng refs/heads/main protected branch", 1, true) then fails = fails + 1; print("FAIL mixed push reply") end
-- Only the forms asked for: report-status alone, side-band alone, neither (400, plain text).
r = run(H, cmd(A, B, "refs/heads/main", "report-status") .. "0000")
if r.body ~= pkt("unpack ok\n") .. pkt("ng refs/heads/main protected branch (airlock-envoy protect)\n") .. "0000" then fails = fails + 1; print("FAIL report-status only") end
r = run(H, cmd(A, B, "refs/heads/main", "side-band-64k") .. "0000")
if r.body ~= pkt("\2" .. MSG) .. "0000" then fails = fails + 1; print("FAIL side-band only") end
r = run(H, cmd(A, B, "refs/heads/main", "report-status-v2 side-band") .. "0000")
if r.status ~= "403" or not r.body:find("ng refs/heads/main", 1, true) then fails = fails + 1; print("FAIL report-status-v2 with side-band") end
r = run(H, cmd(A, B, "refs/heads/main", "agent=x") .. "0000")
if r.status ~= "400" or r.body ~= MSG then fails = fails + 1; print("FAIL no reply form: " .. tostring(r.status)) end
-- A protected ref, then a body that stops making sense: still that refusal, in git's form.
r = run(H, cmd(A, B, "refs/heads/main", CAPS) .. "zz")
if r.status ~= "403" or not r.body:find("ng refs/heads/main", 1, true) then fails = fails + 1; print("FAIL protected then malformed") end
-- Side-band (not 64k) packets stay within 1000 bytes.
local refs = {}
for k = 1, 40 do refs[k] = "refs/heads/main" .. string.rep("x", 20) .. k end
local rep = P.git_reply(MSG, refs, "report-status side-band", set)
local k2, okb = 1, true
while k2 <= #rep do
  local l = tonumber(rep:sub(k2, k2 + 3), 16); if l == 0 then l = 4 end
  if l > 1000 then okb = false end
  k2 = k2 + l
end
if not okb then fails = fails + 1; print("FAIL side-band packet over 1000 bytes") end
-- Allowed: 200, empty.
r = run(H, cmd(A, B, "refs/heads/f", CAPS) .. "0000")
if r.status ~= "200" then fails = fails + 1; print("FAIL handle allow: " .. tostring(r.status)) end
-- What the check can't read: 400, plain text.
r = run(with("content-encoding", "gzip"), cmd(A, B, "refs/heads/f", CAPS) .. "0000")
if r.status ~= "400" or not r.body:find("encoded", 1, true) then fails = fails + 1; print("FAIL gzip not refused") end
r = run(with("content-encoding", "Identity"), cmd(A, B, "refs/heads/f", CAPS) .. "0000")
if r.status ~= "200" then fails = fails + 1; print("FAIL identity encoding refused") end
r = run(with("x-airlock-protect", nil), cmd(A, B, "refs/heads/f", CAPS) .. "0000")
if r.status ~= "400" then fails = fails + 1; print("FAIL no protect list allowed") end
r = run(with("x-envoy-auth-partial-body", "true"), cmd(A, B, "refs/heads/f", CAPS))
if r.status ~= "400" or not r.body:find("64 KiB", 1, true) then fails = fails + 1; print("FAIL partial without flush: " .. tostring(r.body)) end
r = run(H, "garbage")
if r.status ~= "400" then fails = fails + 1; print("FAIL garbage") end
-- What it logs has no control characters (a box-chosen name can't forge a log line).
local logged
local function runlog(body)
  local h = {}
  function h:headers() return { get = function(_, k) return H[k] end } end
  function h:body() return { length = function() return #body end, getBytes = function(_, a, n) return body:sub(a + 1, a + n) end } end
  function h:logWarn(m) logged = m end
  function h:respond() end
  envoy_on_request(h)
end
runlog(cmd(Z, A, "refs/heads/release/x\n[1][critical] forged", CAPS) .. "0000")
if not logged or logged:find("%c") then fails = fails + 1; print("FAIL a control character in the log: " .. string.format("%q", tostring(logged))) end

if fails == 0 then print(string.format("ok   push check: %d bodies, the replies, the handle", #cases)) end
print(string.format("%d cases, failures: %d", #cases, fails))
os.exit(fails == 0 and 0 or 1)
