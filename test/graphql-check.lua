-- Unit tests for install/github-graphql.lua: run with `luajit test/graphql-check.lua` from the
-- repo root. Each case is a POST /graphql body and whether it must be allowed.
package.path = "install/?.lua;" .. package.path
envoy_on_request = nil
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
}

local fails = 0
for n, c in ipairs(cases) do
  local why = G.check_body(c[2])
  local allowed = (why == nil)
  if allowed ~= c[1] then
    fails = fails + 1
    print(string.format("FAIL %2d want %s got %s (%s): %s", n, c[1] and "allow" or "refuse", allowed and "allow" or "refuse", tostring(why), c[2]:sub(1, 90)))
  else
    print(string.format("ok   %2d %-7s %s", n, allowed and "allow" or "refuse", why or ""))
  end
end
print("failures: " .. fails)
os.exit(fails == 0 and 0 or 1)
