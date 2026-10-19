-- airlock-envoy: GitHub GraphQL write check (the github-api and github-issues rules). Inlined
-- into the rendered config by airlock-envoy-apply. A POST /graphql body is allowed only if
-- every mutation in it asks for top-level fields on the route's allowlist below (the route's
-- metadata names it; none, or an unknown one, refuses); queries pass. Default deny: a body this
-- can't read for certain (not one JSON object, no single string "query", a GraphQL document
-- that doesn't tokenize, a subscription, a fragment on Mutation or a spread at a mutation's
-- top level, schema definitions) is refused. Plain Lua 5.1 (LuaJIT, as in Envoy), no modules. Any error while
-- checking refuses the request too (envoy_on_request runs the check under pcall).

-- Envoy's unit sets MemoryDenyWriteExecute, so LuaJIT can't compile hot code: a hot loop would
-- panic the whole Envoy. The interpreter is plenty for request bodies this size.
if jit then jit.off() end

-- Issues: create, edit, close, reopen, comments, labels, assignees (gh 2.102 sends
-- replaceActorsForAssignable for --assignee), reactions. Comments, labels, assignees and
-- reactions take any node ID, so they reach PRs too.
local ISSUES = {
  createIssue = true, updateIssue = true, closeIssue = true, reopenIssue = true,
  addComment = true, updateIssueComment = true,
  addLabelsToLabelable = true, removeLabelsFromLabelable = true,
  replaceActorsForAssignable = true, addAssigneesToAssignable = true,
  removeAssigneesFromAssignable = true,
  addReaction = true, removeReaction = true,
}
-- The above, and PRs: create, edit (base branch included), close, reopen, draft state,
-- reviewers (gh 2.102 sends requestReviewsByLogin). No merge, approval or auto-merge.
local PULLS = {
  createPullRequest = true, updatePullRequest = true, closePullRequest = true,
  reopenPullRequest = true, markPullRequestReadyForReview = true,
  convertPullRequestToDraft = true, requestReviews = true, requestReviewsByLogin = true,
}
local function union(a, b)
  local t = {}
  for k in pairs(a) do t[k] = true end
  for k in pairs(b) do t[k] = true end
  return t
end
local ALLOWLISTS = { ["github-issues"] = ISSUES, ["github-api"] = union(ISSUES, PULLS) }
-- Projects (v2) item writes, under either preset, only when the route names projects and
-- each such mutation's input.projectId is one of them (read from the query or its variables;
-- anything it can't resolve for certain is refused).
local PROJECT_MUTATIONS = {
  updateProjectV2ItemFieldValue = true, clearProjectV2ItemFieldValue = true,
  addProjectV2ItemById = true, archiveProjectV2Item = true,
}

-- Bounds on the work one request can cause (the check runs on Envoy's worker threads, which
-- every listener shares): the body (Envoy's buffer filter also stops it at this size) and
-- the tokens in the query.
local MAX_BODY = 65536
local MAX_TOKENS = 8192
-- ...and the top-level fields of all its mutations together (each is checked on its own).
local MAX_MUTATION_FIELDS = 50
-- A null value (JSON null in the variables, the null literal in the query).
local NULL = { null = true }

local M = {}

-- ---- JSON: the top-level "query" string, exactly once -------------------------------------

local function skip_ws(s, i)
  local _, e = s:find("^[ \t\r\n]*", i)
  return e + 1
end

-- A JSON string at s[i] == '"': its decoded value and the index after it.
local function json_string(s, i)
  local out, n = {}, #s
  i = i + 1
  while i <= n do
    local c = s:sub(i, i)
    if c == '"' then return table.concat(out), i + 1 end
    if c == "\\" then
      local e = s:sub(i + 1, i + 1)
      local simple = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
      if simple[e] then out[#out + 1] = simple[e]; i = i + 2
      elseif e == "u" then
        local hex = s:sub(i + 2, i + 5)
        if not hex:match("^%x%x%x%x$") then return nil end
        local cp = tonumber(hex, 16)
        out[#out + 1] = (cp < 128) and string.char(cp) or "\1"   -- non-ASCII: never GraphQL syntax
        i = i + 6
      else return nil end
    elseif c:byte() < 32 then return nil
    else out[#out + 1] = c; i = i + 1 end
  end
  return nil
end

-- Skip any JSON value at s[i]; returns the index after it, or nil. Nesting is capped (as
-- Ruby's JSON parser does at 100), so a deep document is refused, never a stack overflow.
local MAX_DEPTH = 100
local function json_skip(s, i, depth)
  depth = (depth or 0) + 1
  if depth > MAX_DEPTH then return nil end
  i = skip_ws(s, i)
  local c = s:sub(i, i)
  if c == '"' then local _, j = json_string(s, i); return j end
  if c == "{" or c == "[" then
    local close = (c == "{") and "}" or "]"
    i = skip_ws(s, i + 1)
    if s:sub(i, i) == close then return i + 1 end
    while true do
      if c == "{" then
        if s:sub(i, i) ~= '"' then return nil end
        local _, j = json_string(s, i); if not j then return nil end
        i = skip_ws(s, j); if s:sub(i, i) ~= ":" then return nil end
        i = i + 1
      end
      i = json_skip(s, i, depth); if not i then return nil end
      i = skip_ws(s, i)
      local d = s:sub(i, i)
      if d == close then return i + 1 end
      if d ~= "," then return nil end
      i = skip_ws(s, i + 1)
    end
  end
  local _, e = s:find("^-?%d+%.?%d*[eE]?[+-]?%d*", i)
  if e and e >= i then return e + 1 end
  for _, lit in ipairs({ "true", "false", "null" }) do
    if s:sub(i, i + #lit - 1) == lit then return i + #lit end
  end
  return nil
end

-- Decode the JSON value at s[i] (for the variables): a string as a Lua string, an object as
-- { obj = { key = value } }, null as NULL, anything else as { other = true }. Duplicate keys in an object
-- are refused (which one a server takes is not ours to guess). Returns value, next index.
local function json_value(s, i, depth)
  depth = (depth or 0) + 1
  if depth > MAX_DEPTH then return nil end
  i = skip_ws(s, i)
  local c = s:sub(i, i)
  if c == '"' then return json_string(s, i) end
  if c == "{" then
    local o = {}
    i = skip_ws(s, i + 1)
    if s:sub(i, i) == "}" then return { obj = o }, i + 1 end
    while true do
      if s:sub(i, i) ~= '"' then return nil end
      local k, j = json_string(s, i); if not k then return nil end
      if o[k] ~= nil then return nil end
      i = skip_ws(s, j); if s:sub(i, i) ~= ":" then return nil end
      local v; v, i = json_value(s, i + 1, depth); if v == nil then return nil end
      o[k] = v
      i = skip_ws(s, i)
      local d = s:sub(i, i)
      if d == "}" then return { obj = o }, i + 1 end
      if d ~= "," then return nil end
      i = skip_ws(s, i + 1)
    end
  end
  if s:sub(i, i + 3) == "null" then return NULL, i + 4 end
  local j = json_skip(s, i, depth - 1)
  if not j then return nil end
  return { other = true }, j
end

-- The query string and the variables (an object, or nil if absent or null) of the body.
function M.query_of(body)
  local i = skip_ws(body, 1)
  if body:sub(i, i) ~= "{" then return nil, "not a JSON object" end
  i = skip_ws(body, i + 1)
  local query, seen, vars, vseen = nil, 0, nil, 0
  if body:sub(i, i) == "}" then return nil, "no query" end
  while true do
    if body:sub(i, i) ~= '"' then return nil, "bad JSON" end
    local key, j = json_string(body, i); if not key then return nil, "bad JSON" end
    i = skip_ws(body, j); if body:sub(i, i) ~= ":" then return nil, "bad JSON" end
    i = skip_ws(body, i + 1)
    if key == "query" then
      seen = seen + 1
      if body:sub(i, i) ~= '"' then return nil, "query is not a string" end
      local v, k = json_string(body, i); if not v then return nil, "bad JSON" end
      query, i = v, k
    elseif key == "variables" then
      vseen = vseen + 1
      local v, k = json_value(body, i); if v == nil then return nil, "bad JSON in the variables" end
      if v.obj then vars = v.obj
      elseif v ~= NULL then return nil, "variables is not an object" end
      i = k
    else
      i = json_skip(body, i); if not i then return nil, "bad JSON" end
    end
    i = skip_ws(body, i)
    local d = body:sub(i, i)
    if d == "}" then
      if skip_ws(body, i + 1) <= #body then return nil, "trailing data after the JSON object" end
      break
    end
    if d ~= "," then return nil, "bad JSON" end
    i = skip_ws(body, i + 1)
  end
  if seen ~= 1 then return nil, (seen == 0) and "no query" or "more than one query" end
  if vseen > 1 then return nil, "more than one variables" end
  return query, nil, vars
end

-- ---- GraphQL: tokens, then the operations --------------------------------------------------

local function tokenize(s)
  local t, i, n = {}, 1, #s
  while i <= n do
    if #t >= MAX_TOKENS then return nil end
    local c = s:sub(i, i)
    if c:match("[ \t\r\n,\239\187\191]") then i = i + 1   -- whitespace, commas, BOM bytes
    elseif c == "#" then
      local e = s:find("[\r\n]", i); i = e and e + 1 or n + 1
    elseif s:sub(i, i + 2) == '"""' then
      local j = i + 3
      while true do
        local e = s:find('"""', j, true); if not e then return nil end
        if s:sub(e - 1, e - 1) == "\\" then j = e + 3 else i = e + 3; break end
      end
      t[#t + 1] = { k = "str" }
    elseif c == '"' then
      local j = i + 1
      while true do
        local d = s:sub(j, j)
        if d == "" or d == "\n" or d == "\r" then return nil end
        if d == "\\" then j = j + 2
        elseif d == '"' then break
        else j = j + 1 end
      end
      -- The value, only when plain (no escapes): a project ID is compared to it.
      local raw = s:sub(i + 1, j - 1)
      t[#t + 1] = { k = "str", v = (not raw:find("\\", 1, true)) and raw or nil }; i = j + 1
    elseif c:match("[_A-Za-z]") then
      local _, e = s:find("^[_0-9A-Za-z]*", i + 1)
      t[#t + 1] = { k = "name", v = s:sub(i, e) }; i = e + 1
    elseif c:match("[-0-9]") then
      local _, e = s:find("^-?[0-9]+%.?[0-9]*[eE]?[+-]?[0-9]*", i)
      if not e or e < i then return nil end
      t[#t + 1] = { k = "num" }; i = e + 1
    elseif s:sub(i, i + 2) == "..." then t[#t + 1] = { k = "p", v = "..." }; i = i + 3
    elseif c:match("[!$&()%[%]{}|:=@]") then t[#t + 1] = { k = "p", v = c }; i = i + 1
    else return nil end
  end
  return t
end

-- Index after the balanced group opening at t[i] ("(", "[" or "{").
local function skip_group(t, i)
  local open = t[i].v
  local close = ({ ["("] = ")", ["["] = "]", ["{"] = "}" })[open]
  local depth = 0
  while i <= #t do
    local x = t[i]
    if x.k == "p" and (x.v == "(" or x.v == "[" or x.v == "{") then depth = depth + 1
    elseif x.k == "p" and (x.v == ")" or x.v == "]" or x.v == "}") then
      depth = depth - 1
      if depth == 0 then return (x.v == close) and i + 1 or nil end
      if depth < 0 then return nil end
    end
    i = i + 1
  end
  return nil
end

local function is_p(x, v) return x and x.k == "p" and x.v == v end

-- Directives at t[i] (@name, optional arguments); returns the index after them.
local function skip_directives(t, i)
  while is_p(t[i], "@") do
    if not (t[i + 1] and t[i + 1].k == "name") then return nil end
    i = i + 2
    if is_p(t[i], "(") then i = skip_group(t, i); if not i then return nil end end
  end
  return i
end

-- The top-level fields of the selection set opening at t[i]; nil + reason if not plain fields.
local function top_fields(t, i)
  local fields = {}
  if not is_p(t[i], "{") then return nil, "no selection set" end
  i = i + 1
  while true do
    local x = t[i]
    if not x then return nil, "unterminated selection set" end
    if is_p(x, "}") then return fields, i + 1 end
    if is_p(x, "...") then return nil, "a fragment at a mutation's top level" end
    if x.k ~= "name" then return nil, "unexpected token in a selection set" end
    local field = x.v
    i = i + 1
    if is_p(t[i], ":") then
      if not (t[i + 1] and t[i + 1].k == "name") then return nil, "bad alias" end
      field = t[i + 1].v; i = i + 2
    end
    local f = { name = field }
    fields[#fields + 1] = f
    if is_p(t[i], "(") then
      f.a = i
      i = skip_group(t, i); if not i then return nil, "unbalanced arguments" end
      f.b = i - 1                                          -- the closing ")"
    end
    i = skip_directives(t, i); if not i then return nil, "bad directive" end
    if is_p(t[i], "{") then i = skip_group(t, i); if not i then return nil, "unbalanced selection" end end
  end
end

-- A mutation field's input: its arguments must be exactly (input: <value>), the value an
-- object literal or a $variable holding an object. Returns its top-level fields, each
-- resolved to a string (a plain string literal, or a $variable holding a string), NULL (the
-- null literal, or a variable holding null), a table (a variable holding an object) or false
-- (anything else), and, for a $variable input, the variable's name; a duplicate field refuses. Variables
-- come only from the body (an operation's default value is not read).
local function read_input(t, f, vars)
  if not f.a then return nil, "no input" end
  local i = f.a + 1
  if not (t[i] and t[i].k == "name" and t[i].v == "input" and is_p(t[i + 1], ":")) then return nil, "arguments other than input" end
  i = i + 2
  local function var(n)
    if not (n and n.k == "name") then return nil end
    return vars and vars[n.v]
  end
  local fields, after, vname = {}, nil, nil
  if is_p(t[i], "$") then
    local v = var(t[i + 1])
    if not (type(v) == "table" and v.obj) then return nil, "input variable missing or not an object" end
    fields = v.obj; after = i + 2; vname = t[i + 1].v
  elseif is_p(t[i], "{") then
    local j = i + 1
    while not is_p(t[j], "}") do
      local key = t[j]
      if not (key and key.k == "name" and is_p(t[j + 1], ":")) then return nil, "an input field that can't be read" end
      if fields[key.v] ~= nil then return nil, "input field " .. key.v .. " given twice" end
      j = j + 2
      local val = t[j]
      if not val then return nil, "unterminated input" end
      local got = false
      if is_p(val, "$") then got = var(t[j + 1]); if got == nil then got = false end; j = j + 2
      elseif is_p(val, "{") or is_p(val, "[") then j = skip_group(t, j); if not j then return nil, "unbalanced input" end
      elseif val.k == "p" then return nil, "an input field that can't be read"
      elseif val.k == "name" and val.v == "null" then got = NULL; j = j + 1
      else got = (val.k == "str" and val.v) or false; j = j + 1 end
      fields[key.v] = got
    end
    after = j + 1
  else
    return nil, "input that can't be read"
  end
  if after ~= f.b then return nil, "arguments other than input" end
  return fields, nil, vname
end

-- The project a Projects mutation writes to (input.projectId, a string), or nil + reason.
local function project_of(t, f, vars)
  local fields, why = read_input(t, f, vars)
  if not fields then return nil, why end
  if type(fields.projectId) ~= "string" then return nil, "a projectId that can't be read" end
  return fields.projectId
end

-- An allowlisted mutation may not name a project (createIssue, updateIssue and
-- updatePullRequest take projectIds/projectV2Ids): that would skip the projects pin. With
-- arguments, its input must be readable (as above) and a field that mentions a project must
-- be null (gh 2.102 sends "projectIds": null on every issue create with metadata). A $variable
-- input is walked once per document (seen), however many fields use it.
local function no_project_fields(t, f, vars, seen)
  if not f.a then return nil end
  local fields, why, vname = read_input(t, f, vars)
  if not fields then return why end
  if vname and seen[vname] then return nil end
  for k, v in pairs(fields) do
    if type(k) ~= "string" or (k:lower():find("project", 1, true) and v ~= NULL) then
      return "input field " .. tostring(k) .. " names a project"
    end
  end
  if vname then seen[vname] = true end
  return nil
end

-- nil if allowed under the preset's allowlist (and, for Projects mutations, the projects
-- set), else the reason.
function M.check_document(doc, rules, vars, projects)
  local ALLOWED = ALLOWLISTS[rules or ""]
  if not ALLOWED then return "no GraphQL allowlist for rules '" .. tostring(rules) .. "'" end
  local t = tokenize(doc)
  if not t then return "the GraphQL document does not tokenize (or has over " .. MAX_TOKENS .. " tokens)" end
  if #t == 0 then return "empty GraphQL document" end
  local i, nfields, seen = 1, 0, {}
  while i <= #t do
    local x = t[i]
    if is_p(x, "{") then                                   -- anonymous query
      i = skip_group(t, i); if not i then return "unbalanced query" end
    elseif x.k == "name" and (x.v == "query" or x.v == "mutation" or x.v == "subscription") then
      local op = x.v
      if op == "subscription" then return "subscriptions are not allowed" end
      i = i + 1
      if t[i] and t[i].k == "name" then i = i + 1 end      -- operation name
      if is_p(t[i], "(") then i = skip_group(t, i); if not i then return "unbalanced variables" end end
      i = skip_directives(t, i); if not i then return "bad directive" end
      if op == "query" then
        if not is_p(t[i], "{") then return "a query without a selection set" end
        i = skip_group(t, i); if not i then return "unbalanced query" end
      else
        local fields, j = top_fields(t, i)
        if not fields then return j end
        if #fields == 0 then return "an empty mutation" end
        nfields = nfields + #fields
        if nfields > MAX_MUTATION_FIELDS then return "over " .. MAX_MUTATION_FIELDS .. " mutation fields" end
        for _, f in ipairs(fields) do
          if PROJECT_MUTATIONS[f.name] and projects and next(projects) then
            local pid, why = project_of(t, f, vars)
            if not pid then return "mutation " .. f.name .. ": " .. why end
            if not projects[pid] then return "mutation " .. f.name .. " on a project not allowed here" end
          elseif not ALLOWED[f.name] then return "mutation " .. f.name .. " is not allowed"
          else
            local why = no_project_fields(t, f, vars, seen)
            if why then return "mutation " .. f.name .. ": " .. why end
          end
        end
        i = j
      end
    elseif x.k == "name" and x.v == "fragment" then
      if not (t[i + 1] and t[i + 1].k == "name" and t[i + 2] and t[i + 2].k == "name" and t[i + 2].v == "on"
              and t[i + 3] and t[i + 3].k == "name") then return "bad fragment" end
      if t[i + 3].v == "Mutation" or t[i + 3].v == "Subscription" then return "a fragment on " .. t[i + 3].v end
      i = skip_directives(t, i + 4); if not i then return "bad directive" end
      if not is_p(t[i], "{") then return "a fragment without a selection set" end
      i = skip_group(t, i); if not i then return "unbalanced fragment" end
    else
      return "not an executable GraphQL definition"
    end
  end
  return nil
end

-- A set from a space-separated list of project IDs ("" or nil: none).
function M.project_set(list)
  local set = {}
  for id in (list or ""):gmatch("%S+") do set[id] = true end
  return set
end

-- nil if the body is allowed under rules (a preset name) and projects (a set), else the reason.
function M.check_body(body, rules, projects)
  if not body or body == "" then return "empty body" end
  if #body > MAX_BODY then return "GraphQL body over " .. MAX_BODY .. " bytes" end
  local q, why, vars = M.query_of(body)
  if not q then return why end
  return M.check_document(q, rules, vars, projects)
end

-- nil if the request (headers and body) may go on, else the reason.
local function check_request(handle)
  local h = handle:headers()
  -- The route sends only POST /graphql here; anything else is a misconfiguration: refuse.
  if h:get(":method") ~= "POST" then return "not a POST" end
  if h:get(":path") ~= "/graphql" then return "a query string or another path on /graphql" end
  local ct = (h:get("content-type") or ""):lower()
  if not (ct == "application/json" or ct:match("^application/json%s*;")) then
    return "Content-Type must be application/json"
  end
  if h:get("content-encoding") then return "an encoded (compressed) body" end
  local len = tonumber(h:get("content-length") or "")
  if len and len > MAX_BODY then return "GraphQL body over " .. MAX_BODY .. " bytes" end
  -- The route's preset, from its metadata (airlock-envoy-apply sets it).
  local meta = handle:metadata()
  local rules, projects = meta:get("rules"), M.project_set(meta:get("projects"))
  local b = handle:body()
  local body = b and b:getBytes(0, b:length()) or ""
  return M.check_body(body, rules, projects)
end

function envoy_on_request(handle)
  local ok, why = pcall(check_request, handle)
  if not ok then why = "the GraphQL check failed: " .. tostring(why) end
  if why then
    handle:logWarn("airlock-envoy graphql refused: " .. why)
    handle:respond({ [":status"] = "403", ["content-type"] = "text/plain" }, "airlock-envoy: " .. why .. "\n")
  end
end

return M
