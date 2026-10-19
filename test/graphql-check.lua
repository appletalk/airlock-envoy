-- Unit tests for install/github-graphql.lua: run with `luajit test/graphql-check.lua` from the
-- repo root. Each case is a POST /graphql body and whether it must be allowed.
package.path = "install/?.lua;" .. package.path
local G = dofile("install/github-graphql.lua")

local function j(q) return '{"query":' .. string.format("%q", q):gsub("\\\n", "\\n") .. '}' end
local cases = {
  -- allowed: queries, and mutations on the allowlist (what gh pr/issue create and comment send)
  { true,  j("query { viewer { login } }") },
  { true,  j("{ viewer { login } }") },
  { true,  j("query PullRequests($o: String!) { repository(owner: $o, name: \"x\") { id } }") },
  { true,  '{"query":"mutation PullRequestCreate($input: CreatePullRequestInput!) { createPullRequest(input: $input) { pullRequest { url } } }","variables":{"input":{"title":"t","body":"has } and { in it","baseRefName":"main"}}}' },
  { true,  j("mutation { addComment(input: {subjectId: \"x\", body: \"merge it } mergePullRequest\"}) { clientMutationId } }") },
  { true,  j("mutation M { a: createIssue(input: {}) { clientMutationId } b: addLabelsToLabelable(input: {}) { clientMutationId } }") },
  { true,  j("query Q { viewer { ...F } } fragment F on User { login }") },
  { true,  j("# a comment with mutation { mergePullRequest }\nquery { viewer { login } }") },
  { true,  j("mutation { addComment(input: {body: \"\"\"block \\\"\"\" with } brace\"\"\"}) { clientMutationId } }") },
  -- refused: merges, approvals, ref and settings changes, however they are spelled
  { false, j("mutation { mergePullRequest(input: {pullRequestId: \"x\"}) { clientMutationId } }") },
  { false, j("mutation { a: createIssue(input: {}) { clientMutationId } b: mergePullRequest(input: {}) { clientMutationId } }") },
  { false, j("mutation { x: mergePullRequest(input: {}) { clientMutationId } }") },
  { false, j("mutation { createIssue: mergePullRequest(input: {}) { clientMutationId } }") },
  { false, j("mutation { addPullRequestReview(input: {event: APPROVE}) { clientMutationId } }") },
  { false, j("mutation { enablePullRequestAutoMerge(input: {}) { clientMutationId } }") },
  { false, j("mutation { deleteRef(input: {}) { clientMutationId } }") },
  { false, j("mutation { updateBranchProtectionRule(input: {}) { clientMutationId } }") },
  { false, j("query { viewer { login } } mutation { mergePullRequest(input: {}) { clientMutationId } }") },
  { false, j("mutation { ...M } fragment M on Mutation { mergePullRequest(input: {}) { clientMutationId } }") },
  { false, j("mutation { ... on Mutation { mergePullRequest(input: {}) { clientMutationId } } }") },
  { false, j("fragment M on Mutation { mergePullRequest(input: {}) { clientMutationId } } query { viewer { login } }") },
  { false, j("subscription { x }") },
  { false, j("mutation { __typename }") },
  { false, j("mutation { }") },
  { false, j("type Query { a: Int }") },
  { false, j("mutation @skip(if: false) { mergePullRequest(input: {}) { clientMutationId } }") },
  { false, '{"query":"mutation { createIssue(input: {}) { clientMutationId } }","query":"mutation { mergePullRequest(input: {}) { clientMutationId } }"}' },
  { false, '{"query":"mutation { addComment(input: {}) { id } } \\u006dutation { mergePullRequest(input: {}) { id } }"}' },
  { false, '{"query":"mutation \\u007b mergePullRequest(input: {}) { id } }"}' },
  -- from the mutation round: each of these failed to catch a broken guard
  { false, '{"query":"mutation { mergePullRequest(input: {}) { id } }","query":"mutation { createIssue(input: {}) { id } }"}' },
  { false, j("mutation { createIssue(input: {}) { id } ... on Mutation { mergePullRequest(input: {}) { id } } }") },
  { false, j("subscription { createIssue(input: {}) { id } }") },
  { true,  j("mutation { addComment(input: {body: \"say \\\"hi\\\" { ok } mergePullRequest\"}) { clientMutationId } }") },
  { false, '{"query":"query { viewer { login } }\\u0120"}' },
  -- from the cold review: deep nesting must refuse, not overflow the stack (which let it pass)
  { false, '{"v":' .. string.rep("[", 100000) .. string.rep("]", 100000) .. ',"query":"mutation { mergePullRequest(input: {}) { id } }"}' },
  { false, '{"v":' .. string.rep("[", 150) .. string.rep("]", 150) .. ',"query":"{ viewer { login } }"}' },
  { true,  '{"v":' .. string.rep("[", 50) .. string.rep("]", 50) .. ',"query":"{ viewer { login } }"}' },
  -- refused: anything this can't read for certain
  { false, "" },
  { false, "mutation { mergePullRequest }" },
  { false, '[{"query":"query { viewer { login } }"}]' },
  { false, '{"query":null}' },
  { false, '{"variables":{}}' },
  { false, '{"query":"query { viewer { login } }"} trailing' },
  { false, j("query { viewer { login }") },
  { false, j("mutation { addComment(input: {body: \"unterminated }) { id } }") },
  { false, j("mutation { addComment(input: {}) { id } } }") },
  { false, '{"query":"mutation { createIssue(input: {}) { id } }\\u00e9"}' },
  -- what gh 2.102 sends for assignees and reviewers
  { true,  j("mutation { replaceActorsForAssignable(input: {}) { clientMutationId } }") },
  { true,  j("mutation { requestReviewsByLogin(input: {}) { clientMutationId } }") },
  -- github-issues: issues, comments, labels, assignees; no PR writes
  { true,  j("mutation { createIssue(input: {}) { clientMutationId } }"), "github-issues" },
  { true,  j("mutation { a: addComment(input: {}) { clientMutationId } b: addLabelsToLabelable(input: {}) { clientMutationId } }"), "github-issues" },
  { true,  j("mutation { replaceActorsForAssignable(input: {}) { clientMutationId } }"), "github-issues" },
  { true,  j("mutation { closeIssue(input: {}) { clientMutationId } }"), "github-issues" },
  { true,  j("{ viewer { login } }"), "github-issues" },
  { false, j("mutation { createPullRequest(input: {}) { clientMutationId } }"), "github-issues" },
  { false, j("mutation { updatePullRequest(input: {baseRefName: \"main\"}) { clientMutationId } }"), "github-issues" },
  { false, j("mutation { requestReviews(input: {}) { clientMutationId } }"), "github-issues" },
  { false, j("mutation { requestReviewsByLogin(input: {}) { clientMutationId } }"), "github-issues" },
  { false, j("mutation { closePullRequest(input: {}) { clientMutationId } }"), "github-issues" },
  { false, j("mutation { mergePullRequest(input: {}) { clientMutationId } }"), "github-issues" },
  { false, j("mutation { updateProjectV2ItemFieldValue(input: {}) { clientMutationId } }"), "github-issues" },
  -- no allowlist for the route: refused, queries too
  { false, j("{ viewer { login } }"), "" },
  { false, j("{ viewer { login } }"), "any" },
  -- bounds: the body (64 KiB) and the tokens (8192)
  { true,  '{"query":"{ viewer { login } }","v":"' .. string.rep("x", 65000) .. '"}' },
  { false, '{"query":"{ viewer { login } }","v":"' .. string.rep("x", 65536) .. '"}' },
  { true,  j("{ " .. string.rep("a ", 8000) .. "}") },
  { false, j("{ " .. string.rep("a ", 8200) .. "}") },
}

local fails = 0
for n, c in ipairs(cases) do
  local why = G.check_body(c[2], c[3] or "github-api")
  local allowed = (why == nil)
  if allowed ~= c[1] then
    fails = fails + 1
    print(string.format("FAIL %2d want %s got %s (%s): %s", n, c[1] and "allow" or "refuse", allowed and "allow" or "refuse", tostring(why), c[2]:sub(1, 90)))
  else
    print(string.format("ok   %2d %-7s %s", n, allowed and "allow" or "refuse", why or ""))
  end
end
-- envoy_on_request against a stand-in for Envoy's handle: the header checks, and that an
-- error anywhere refuses (a script error in Envoy's Lua filter otherwise lets the request on).
local function handle(hdrs, body, body_errors, meta)
  local h = { responded = nil }
  meta = meta or { rules = "github-api" }
  function h:headers() return { get = function(_, k) return hdrs[k] end } end
  function h:metadata() return { get = function(_, k) return meta[k] end } end
  function h:body()
    if body_errors then error("simulated failure") end
    return { length = function() return #body end, getBytes = function(_, a, n) return body:sub(a + 1, a + n) end }
  end
  function h:respond(r, _) self.responded = r[":status"] end
  function h:logWarn() end
  return h
end
local ok_body = '{"query":"{ viewer { login } }"}'
local hcases = {
  { nil,   { [":method"] = "POST", [":path"] = "/graphql", ["content-type"] = "application/json" }, ok_body },
  { nil,   { [":method"] = "POST", [":path"] = "/graphql", ["content-type"] = "application/json; charset=utf-8" }, ok_body },
  { "403", { [":method"] = "POST", [":path"] = "/graphql?query=mutation%7BmergePullRequest%7D", ["content-type"] = "application/json" }, ok_body },
  { "403", { [":method"] = "POST", [":path"] = "/graphql", ["content-type"] = "application/x-www-form-urlencoded" }, ok_body },
  { "403", { [":method"] = "POST", [":path"] = "/graphql" }, ok_body },
  { "403", { [":method"] = "POST", [":path"] = "/graphql", ["content-type"] = "application/json", ["content-encoding"] = "gzip" }, ok_body },
  { "403", { [":method"] = "GET",  [":path"] = "/graphql", ["content-type"] = "application/json" }, ok_body },
  { "403", { [":method"] = "POST", [":path"] = "/graphql", ["content-type"] = "application/json" }, ok_body, true },
  { "403", { [":method"] = "POST", [":path"] = "/graphql", ["content-type"] = "application/json", ["content-length"] = "65537" }, ok_body },
  { "403", { [":method"] = "POST", [":path"] = "/graphql", ["content-type"] = "application/json" }, ok_body, false, {} },
  { nil,   { [":method"] = "POST", [":path"] = "/graphql", ["content-type"] = "application/json" }, ok_body, false, { rules = "github-issues" } },
  { "403", { [":method"] = "POST", [":path"] = "/graphql", ["content-type"] = "application/json" },
           '{"query":"mutation { createPullRequest(input: {}) { id } }"}', false, { rules = "github-issues" } },
}
for n, c in ipairs(hcases) do
  local h = handle(c[2], c[3], c[4], c[5])
  envoy_on_request(h)
  if h.responded ~= c[1] then
    fails = fails + 1
    print(string.format("FAIL handle %d: want %s got %s", n, tostring(c[1]), tostring(h.responded)))
  else print(string.format("ok   handle %d: %s", n, c[1] and "refused" or "passed")) end
end
print("failures: " .. fails)
os.exit(fails == 0 and 0 or 1)
