# Presets in detail

A preset is the `rules` of an `http` line. Every preset is default deny: its routes, in order,
then 403. The routes themselves are in `preset_rules` in `install/airlock-envoy-apply`;
`airlock-envoy-apply --render` shows the rendered result.

## The presets

### `victoria-metrics`

The query paths only: `/api/v1/query*` (GET, POST), `/api/v1/series`, `/api/v1/labels`
(GET, POST), `/api/v1/label/<name>/values` and `/api/v1/metadata` (GET).

### `victoria-logs`

The LogsQL query paths only: `/select/logsql/` (GET, POST).

### `git-read`

git fetch only (smart HTTP `info/refs` and `git-upload-pack`).

### `git`

git fetch **and push, to any branch the token can write**: force-push, branch deletion and a
push to `main` included. That is a merge, without any GraphQL check. Protect branches on the
server (rulesets or branch protection), list them in `protect` (below), or use `git-read`.

### `forgejo`

Forgejo or Gitea for a bot account. One credential covers git and the API: a token, set with
`--format basic:<bot user>`.

- **Allowed**: git fetch and push; API reads; PR create and edit, including base and state;
  comments; labels; reviewers.
- **Refused**: merge; reviews and approval; files written through the API; the branch and tag
  API; releases; settings; hooks; keys; tokens; deletes; admin; the web UI; wiki git; the
  `token`, `access_token` and `sudo` query parameters; form bodies. (Forgejo reads a token from
  the query string or a form body before the Authorization header.)
- **Limits**:
  - Which branches and tags a push may touch is the server's branch and tag protection, and
    `protect` (below). A push can create, force-push or delete any branch or tag that neither
    protects.
  - Edits reach other people's issues, PRs and comments, not only the bot's (Forgejo keeps the
    edit history).
  - Set `DISABLE_QUERY_AUTH_TOKEN` on the server too.

### `kubernetes-read`

A Kubernetes API server, read only.

- **Allowed**: GET and HEAD on `/api`, `/apis`, `/openapi` and `/version`. POST only to the self
  access reviews (`selfsubjectaccessreviews`, `selfsubjectrulesreviews`) and
  `selfsubjectreviews`, so `kubectl auth can-i` and `kubectl auth whoami` work.
- **Refused**:
  - every write;
  - any protocol upgrade (WebSocket, SPDY);
  - any escaped character in the path. Names never hold `%`, and kubectl escapes only the query
    and names with a space or non-ASCII (so those names are refused here). The API server would
    decode `%70roxy` to `proxy`;
  - exec, attach, port-forward, and the pod, service and node `proxy` subresources, whatever
    the method.
- **Limits**:
  - What the token reads is its RBAC: Secrets too, if it may.
  - Reads have no request timeout or stream cap, so watches and `logs -f` run on until 5 minutes
    pass with nothing sent.

### `github-issues`

- **Allowed**: reads; issue create, edit, close, reopen; comments; labels; assignees; reactions.
- **Refused**: PR writes, and everything `github-api` refuses.
- REST numbers PRs as issues, and GraphQL comment, label and assignee writes take any node ID. So
  `github-issues` also reaches a PR's comments, labels, assignees, title, body and state (not
  its base, reviewers or code).

### `github-api`

- **Allowed**: everything `github-issues` allows, plus PR create, edit (including the base
  branch), close, reopen, draft state, and reviewers.
- **Refused** (in both GitHub presets): merge, approve, auto-merge, settings, hooks, keys,
  deletes, Projects (unless `projects` is set, below), anything else.

### `mcp`

MCP servers over the Streamable HTTP transport (one endpoint per server, JSON-RPC over POST),
such as a gateway that checks a bearer token in front of several servers at their own paths.
The line's `endpoints` name them, each an exact path.

- **Allowed**, on each endpoint and nothing else:
  - POST: JSON-RPC requests, notifications and responses. `Content-Type: application/json`
    (with `charset=utf-8` at most: no other parameter), a `Content-Length` up to 1 MiB, no
    `Content-Encoding`. The answer, JSON or an event stream,
    streams back unbuffered and uncapped in size.
  - GET: the server's event stream. A server without one answers 405, which passes through.
  - DELETE: the end of a session.
  - GET and DELETE carry no body (a `Content-Length` of 0 at most, nothing chunked): one would
    reach the server past the tool check.
- **Refused** (403, with the reason, nothing upstream):
  - every other path: a prefix or suffix of an endpoint, another case, a trailing slash the
    line doesn't list, `/.well-known/*` (OAuth discovery: the credential comes from Envoy),
    health paths;
  - every other method on an endpoint;
  - any query string;
  - a POST with another content type or charset, a compressed or chunked body, or no
    `Content-Length`; over 1 MiB, 413. A charset other than UTF-8 would let the server read
    other JSON than the tool check: in UTF-7, `+ACI-` is a quote.
- **Headers**: `Mcp-Session-Id` passes both ways, and so do `MCP-Protocol-Version`, `Accept`,
  `Content-Type` and `Last-Event-ID`. The credential replaces the box's `Authorization`, and the
  steering headers are stripped as on every preset ([Request handling](#request-handling-all-presets)).
- **Endpoints** are plain paths (letters, digits, `.`, `_`, `~`, `-`, and `/` between parts; no
  `.` or `..` part), up to 32 a line. `/` alone is one, and so is a path with a trailing slash
  (matched with it, exactly).
- **Out of scope**: the older HTTP+SSE transport (GET `/sse` plus POST `/messages`). List its two
  paths as endpoints and it may work, but its POST answers arrive on the GET stream, which the
  tool check does not read.

### `any`

Every method but TRACE (which echoes headers). Use it only for upstreams you trust not to
reflect request headers: one that does hands the injected credential back to the box.

## The GitHub GraphQL check

GitHub writes go through `POST /graphql`, so method and path alone can't tell a PR from a merge.
Both GitHub presets run a check on that route (`install/github-graphql.lua`):

- Queries pass.
- A mutation passes only if every top-level field is on the preset's allowlist, as gh 2.102 sends
  them (`replaceActorsForAssignable` for assignees, `requestReviewsByLogin` for reviewers).
- Its `input` must be readable and name no project except as null. `projectIds` and
  `projectV2Ids` would skip the `projects` pin; gh sends `projectIds: null` on every issue
  create with labels or assignees.
- Refused: `mergePullRequest`, review approval, ref and branch-protection changes.
- Also refused: any body it can't read for certain, a query string, a Content-Type other than
  JSON, a compressed body, and any error while checking.
- Every other `/graphql` form (any method, case or suffix) is refused.

LuaJIT's compiler is off: the unit's `MemoryDenyWriteExecute` would make it panic Envoy.

## Projects (v2)

On the GitHub presets, `projects <id>[,<id>...]` (project node IDs, `PVT_...`) lets four item
writes through:

- `updateProjectV2ItemFieldValue`
- `clearProjectV2ItemFieldValue`
- `addProjectV2ItemById`
- `archiveProjectV2Item`

Only when the mutation's `input.projectId` is one of the listed IDs: a plain string in the query,
or a variable in the body's `variables` (an operation's default value is not read). Anything the
check can't resolve for certain is refused. `deleteProjectV2Item` (removing an item) is refused
too, even on a listed project: it can't be undone, while an archived item can be restored. So
are project, field and view settings. Without `projects`, all Projects writes are
refused.

Limits:

- That an item, field or value ID belongs to the named project is GitHub's check, not this one.
  Verify it live before relying on the pin.
- `addProjectV2ItemById` takes any content ID, so a box can put any issue it can read (another
  repo's, a private one's) on the pinned board.
- GitHub adds items to boards by itself: org auto-add workflows, and an issue template with
  `projects:` (createIssue with an `issueTemplate`) can add items to boards the box never names.

## The MCP tool check (`tools`, `deny-tools`)

On an `mcp` line, an endpoint may take a list of tools: `tools <endpoint>:<tool>,...` lets only
those be called there, `deny-tools <endpoint>:<tool>,...` refuses those. One list per endpoint;
an endpoint without one passes any call. The check (`install/mcp-tools.lua`) reads each POST
body to that endpoint:

- One JSON-RPC message or a batch. For each `tools/call` (in any case), `params.name` must be
  on the `tools` list (exactly, in its case) or off the `deny-tools` list (in any case, so a
  server that matched names loosely can't be reached around it).
- Every other method, notifications and responses pass. Which method decides: only
  `tools/call` is checked.
- A batch with one refused message is refused whole.
- Also refused: a body that isn't strict JSON, a key twice in one object, a call without a
  string `params.name`, a tool name outside the MCP character set (1 to 128 of
  `A-Z a-z 0-9 _ - .`), a method name with anything but printable ASCII (no space: a server
  that trimmed `tools/call ` would run it), a batch of over 100 messages, nesting over 64
  deep, and any error while checking.
- In a message and its `params`, keys are read as a Go server reads them: in any case. So a
  key twice in another case (`method` and `Method`), a protocol key in another case (`Method`,
  `Params`, `Name`, `ID`) and a key outside printable ASCII (Go folds `ſ` to `s`, so `paramſ`
  is `params` to it) are refused. Keys inside `arguments` are the tool's, and pass.
- A refusal is a JSON-RPC error, HTTP 200, so the client shows the reason: one error with the
  request's `id` (code -32001), or for a batch an array with an error for each request in it.
  A body it can't read gets one error with a null `id` (code -32700).

Why the name is checked in its exact case for `tools` but in any case for `deny-tools`: an
allowlist that ignored case would let `READ_A` through for a server that holds both `read_a`
and a different `READ_A`; a denylist that kept case would let `WRITE_THING` reach a server that
dispatches names without regard to case.

**Limits:**

- Only the tool's name is checked, not its arguments: an allowed tool may still do anything
  its arguments ask, with the credential's rights.
- A deny list fails open: a tool the server adds later passes until it is listed. Prefer
  `tools` where the set of tools is known.
- `resources/read`, `prompts/get`, `completion/complete` and other methods are not checked.
- Answers are not read: a server that starts a tool on its own (say from a sampling response)
  is not bounded by this.
- The check reads JSON strictly (UTF-8, a key once). Where a server's reader differs, the
  rules above close the known gaps (another charset, keys in any case, a trimmed method); a
  reader that differs in some other way could still see another call than the check did.

## Repo scoping (`repos`)

On the `git`, `git-read`, `forgejo`, `github-api` and `github-issues` presets,
`repos <owner>/<repo>[,...]` narrows every route that names a repo to those repos.
`<owner>/*` stands for every repo of that owner. Names match in any case, and the site file
may write them in any case (apply keeps them lowercase).

| Preset | With `repos` |
|---|---|
| `git`, `git-read` | fetch (and, with `git`, push) only the listed repos; `.git` optional |
| `forgejo` | git and the API routes only in the listed repos; API reads only under `/api/v1/repos/<listed>/`, plus `/api/v1/user` and `/api/v1/version`. Wiki git and token parameters stay refused |
| `github-api`, `github-issues` | REST reads only under `/repos/<listed>/`, plus `/user` and `/rate_limit`; REST writes only in the listed repos; **GraphQL refused** |

Refused outright, besides other repos: search, `/repositories/<id>`, users, orgs and gists
(and on Forgejo, repo search and user or org repo lists). Also refused:

- A path with an escaped unreserved character (a letter, digit, `-`, `.`, `_` or `~`, which no
  client needs to escape), unless Envoy's path normalization has already decoded it (then
  the routes see the decoded path): after a listed repo, `%2e%2e/%2e%2e/` would be a dot segment the
  upstream could decode into another repo's path, and `c%6fmpare` would slip past the next
  rule. Other escapes (`%20`, `%2B`, non-ASCII) pass. The listener already rejects escaped
  slashes and resolves plain dot segments before matching.
- A compare across repos (`compare/main...owner:branch`, a `:` after `compare/`, in any
  case), which reads another repo of the fork network by branch name. A compare within the
  repo (`main...feature`) passes.

Each scoped route becomes one route per listed repo, and the rendered config raises RE2's
program size limit (Envoy refuses a regex over it, and a long name is over the default).

**Why GraphQL is refused.** One GraphQL query walks from a repo to any other (`parent`,
`forks`, an owner's `repositories`, a node looked up by ID), and so do mutation results. A
check on the path or the top-level field can't bound that. So with `repos`, a box uses the REST
API: `gh api repos/<owner>/<repo>/pulls -f title=... -f head=... -f base=...` and the like.
What that loses:

- `gh pr list`, `gh pr view`, `gh pr checks`, `gh pr create` and the other porcelain that
  speaks GraphQL. `gh api` works. For `gh pr checkout`, use
  `git fetch origin pull/<n>/head`.
- What only GraphQL can do: turning a PR from draft to ready (or back) after it is open,
  resolving review threads (and reading whether they are), Discussions, and Projects (v2)
  item writes. `repos` and `projects` can't be on one line.

**Limits:**

- **A listed repo's fork network.** GitHub shares objects across a whole fork network (the
  parent, its forks and theirs, public or private): a fetch by SHA through a listed repo or a
  commit by SHA reads the rest of the network that the token can. On GitHub and Forgejo, a PR
  whose head is another fork's branch (`head: owner:branch` in a JSON body, which a path
  can't see) does the same. Cross-repo compare is refused, these are not. So list a fork only
  if its network may be read. Scoping also bounds which repos a box names, not what text it reads: issue bodies and
  timelines mention other repos too.
- **Links from a listed repo return other repos' issues.** Relation endpoints under a listed
  repo (GitHub sub-issues and issue dependencies, Forgejo issue dependencies) return the
  linked issues whole, body included, from whatever repo they are in. The box can't create
  such links (no route allows it), but reads the ones others made.
- **Writes in a listed repo can reach other repos by reference.** A comment or issue body
  naming `other/repo#1` adds a cross-reference (with the box's title) to that issue, and a
  commit pushed to a listed repo's default branch with `closes other/repo#1` closes it if the
  token may write there. Writes that name a comment by ID (`issues/comments/<id>`) rely on
  the server to check that the comment belongs to the repo in the path.
- **Renamed repos.** GitHub redirects an old name to `/repositories/<id>`, which is refused.
  List the new name.
- **`<owner>/*` includes the owner's wikis** (`<repo>.wiki.git`) under the git rules, on GitHub
  and Forgejo alike. Under the forgejo rules the wiki route stays refused.
- **Writes are still bounded by the token.** `repos` narrows where a box may write, but what
  the token or App installation may write is still the site's to set: keep it to the same
  repos.

### Read-only repos (`repos-read`)

`repos-read <owner>/<repo>[,...]` lists repos a box may only read, on the same line as `repos`
or alone, on the `git`, `forgejo`, `github-api` and `github-issues` presets (`git-read` is read
only already: give it `repos`). It is the same scoping as `repos`, with GraphQL refused just the
same, but for these repos only the preset's read routes pass:

| Preset | In a `repos-read` repo |
|---|---|
| `git` | fetch (`info/refs`, `git-upload-pack`); a push is refused at `git-receive-pack` |
| `forgejo` | fetch, and API reads under `/api/v1/repos/<repo>/` |
| `github-api`, `github-issues` | REST reads (GET, HEAD) under `/repos/<repo>/` |

A push (`git-receive-pack`), or any other method on its API path, gets 403 "this repo is read
only on <host> (repos-read)", so a box can tell the cause from a repo not listed at all. Other
writes (LFS, `/repositories/<id>`) are refused too, with the generic message.

- A repo is in `repos` or `repos-read`, not both; `<owner>/*` in one list takes every repo of
  that owner, so a named repo of it in the other list is refused. Together, at most 64.
- The point is the token. A token, or an App installation, has one set of permissions for
  every repo it covers, so a box that may write some repos and only read others can't get the
  difference from the token. `repos-read` puts it in Envoy, and also keeps a repo read only if
  the token is later widened to write it.
- The limits of `repos` hold here too, the fork network above all: a fetch by SHA through a
  read-only repo reads the rest of its network that the token can.
- **References from a writable repo still act on it.** If the token can write the read-only
  repo, a commit pushed to a writable repo's default branch (or a PR merged there) with
  `closes owner/ro#1` closes that issue, and a mention adds a cross-reference to its timeline.
  Envoy sees only the writable repo's request. Keep the token from writing it where that
  matters.

### Protected branches (`protect`)

`protect <branch>[,...]` on a `git` or `forgejo` line refuses a push that would create, update,
force-update or delete one of those branches: `<name>` exactly, or `<prefix>/*` for every
branch under `<prefix>/`, in any case (`MAIN` is refused with `main`). The whole push is
refused, its other ref updates too. It works with or without `repos` and `repos-read`. Nothing
is protected by default: list the branches per line. For one repo with and one without, use two
definitions of the host (variants, each with its `repos`; the same credential may serve both):

```
http github.com@deploy rules git credential gh-git repos example-org/config protect main
http github.com@work   rules git credential gh-git repos example-org/app
```

**Why the push is the whole surface.** No preset lets a box change a ref through the API: the
REST routes write issues, PRs, comments, labels and reviewers only (no ref, contents or merge
writes, no PUT or DELETE), and the GraphQL allowlist has no ref, commit or merge mutation (and
GraphQL is refused under `repos`). A ref changes only through `POST <repo>/git-receive-pack`.

**How it's checked.** On a protected line, `git-receive-pack` gets a route of its own whose
`ext_authz` filter holds the request: no header or body byte goes upstream until a check
decides. The check (Lua, `install/git-protect.lua`, on an internal listener of the same Envoy)
reads at most the first 64 KiB of the body: the ref updates (`<old> <new> <ref>` pkt-lines,
optional `shallow` lines before them) up to their flush. It never reads the pack. A longer push
that passes then streams on, unbuffered. Refused, by default deny:

- a ref update naming a protected branch;
- a body it can't read for certain: no flush within the first 64 KiB, a malformed pkt-line or
  ref update, an encoded body (`Content-Encoding` other than identity; git never compresses a
  push), a signed push (`push-cert`);
- any failure of the check itself (`ext_authz` fails closed: 503).

**What the box sees.** git shows a push's reply only from a 200, so a refused protected branch
is answered as git's own protocol would: `remote: airlock-envoy: refused by the git rules
(listener ...): push to protected branch refs/heads/main on <host> (protect): push another
branch and open a PR`, then `! [remote rejected] HEAD -> main (protected branch ...)`. The
answer is Envoy's (nothing reached the upstream), and the HTTP status is 200; the access log
shows the route `...-push-guard`, flag `UAEX` and details `ext_authz_denied`. A body it can't
read gets 400 with the reason as text. On a push larger than what Envoy had read when it
refused, git (curl) resends the rest on a new connection; that is refused as unreadable, and
git adds `RPC failed; HTTP 400` after the reason.

**Limits:**

- It guards pushes through Envoy only: a merge in the server's web UI or by a person's own
  token, and a server's own default-branch change, don't pass here.
- Tags are not protected (they are not branches). A symbolic ref pointing at a protected branch
  would be updated through its own name; GitHub and Forgejo don't let a push create one.
- git's empty probe before a large pack (`0000`, no ref update) passes: it changes nothing.
- A ref name git would refuse is refused here too, by git's own rules (`git check-ref-format`):
  control characters, space, `~^:?*[\`, an empty component (`//`, a leading or trailing `/`),
  a component starting with `.` or ending in `.lock` (any case here), `..`, a trailing `.`,
  `@{`, a lone `@`. So `refs/heads//main` or `refs/heads/x/../main` is refused, never compared
  with `main`. test/protect-e2e.sh checks the rules against git itself.
- A repo's other names reach it as well: GitHub serves a renamed repo under its old name. Don't
  list a protected repo's old name in another, unprotected definition.

### Several credentials on one host

A listener may list several definitions of one host (variants, `http <host>@<variant>`) when
each has `repos` or `repos-read`, no repo is in two of them (`<owner>/*` takes every repo of that owner), and
they share their rules (`github-api` and `github-issues` may mix), port, `ca`, and having a
credential or none (the credential itself may differ). Apply refuses anything else.

- They make one virtual host. Each listed repo's routes carry the credential of the definition
  that lists it, and go to that definition's upstream. A read-only repo is read only whichever
  definition lists it.
- The first definition the listener lists (in the order of its lines, an include's where the
  include stands) stands for all
  in what no repo decides: its refusals, and its routes outside a repo (`/user`,
  `/rate_limit`, `/api/v1/user`, `/api/v1/version`), so `gh api user` names that identity.
- The client manifest has one line for the host: the first definition's rules.
- Use it where one box works for two owners with different credentials: an organisation's
  GitHub App for its repos and a personal fine-grained token for your own, on `api.github.com`
  and on `github.com` for git.

## Request handling (all presets)

- **Paths are normalized** before the rules see them (dot segments, merged slashes). An escaped
  slash is refused. Rules match the path without the query string.
- **Headers a box sends that steer Envoy, or claim a client or method, are removed** before
  anything else:
  - `x-envoy-*`, `x-forwarded-*`, `forwarded`, `x-real-ip`, `x-client-ip`, `x-original-url`,
    `x-rewrite-url`, `x-request-id`, `sudo`;
  - the method overrides: `x-http-method`, `x-http-method-override`, `x-method-override`;
  - other ways to authenticate than the injected credential: `cookie`, `cookie2`, `signature`,
    `signature-input`, `proxy-authorization`;
  - the identity headers of reverse-proxy and forward auth: `x-webauth*`, `remote-user`,
    `x-remote-user`, `x-auth-request-*`, `x-authentik-*`;
  - Kubernetes impersonation: `impersonate-*`.
- **A header name with an underscore is refused outright** (400): Rack and CGI servers read
  `x_http_method_override` as the dashed name.
- Envoy adds no headers of its own.
- The credential replaces any `Authorization` the box sent.

## Limits

### What one box can cost the others

The GraphQL check runs on Envoy's worker threads, which every listener shares, so it is bounded
per listener:

| Limit | Value | Over it |
|---|---|---|
| GraphQL requests, over all the listener's GitHub hosts | 10 a second, bursts of 20 | 429 |
| Body size | 64 KiB | 413 |
| GraphQL tokens | 8192 | 403 |
| Mutation fields | 50 | 403 |

A worst-case body costs about 20 ms of CPU in Envoy, so one listener can keep about a fifth of
one worker busy.

The MCP tool check runs there too, with its own bounds per listener:

| Limit | Value | Over it |
|---|---|---|
| POSTs to endpoints with `tools` or `deny-tools`, over all the listener's MCP hosts | 10 a second, bursts of 20 | 429 |
| Body size (every MCP POST) | 1 MiB | 413 |
| Messages in a batch | 100 | JSON-RPC error |
| Nesting | 64 | JSON-RPC error |

A worst-case 1 MiB body (small numbers in an array) costs about 80 ms on a workstation, so one
listener can keep most of one worker busy for as long as it keeps sending. An endpoint without
a list has no check and no rate limit: its body is never read.

### Stream timeouts

| Routes | Request timeout | Whole-stream cap | Idle |
|---|---|---|---|
| Most plain-HTTP routes | 120 s | 5 minutes | 5 minutes |
| `git` and `git-read`; `forgejo`'s git routes; `kubernetes-read`'s API reads | none | none | 5 minutes |
| `mcp` POST | none | 30 minutes | 10 minutes |
| `mcp` GET (the event stream) | none | none | 15 minutes |
| `mcp` DELETE | 120 s | 5 minutes | 5 minutes |

The cap means a body sent slowly can't hold a connection. Clones, pushes, watches and `logs -f`
are exempt because they can legitimately take long; they still close after 5 minutes with nothing
sent.

MCP tool calls can run for minutes, and a call that answers in plain JSON sends nothing until it
is done: its POST waits up to 10 minutes idle, and gets 30 in all. A call that answers as an
event stream keeps its POST open while events flow. The GET stream may stay open as long as the
server sends something every 15 minutes; a client reconnects with `Last-Event-ID` after it
closes.

### What the presets don't bound

This is the site's job:

- **Repo scoping is opt-in.** Without `repos`, a box can read any repo the token can (a
  GitHub token also reads every public repo), and write issues and comments in any it may
  write, e.g. copy a private repo into another repo's issue. Only the token's (or App
  installation's) repo list bounds it. With `repos`, see [Repo scoping](#repo-scoping-repos).
- **Label and comment writes also land on PRs**, where org automation (an auto-merge label, a
  comment-triggered workflow) can turn them into merges or deploys.
- **Assignment can start an agent.** Where an org has the Copilot coding agent on, assigning an
  issue to Copilot (`replaceActorsForAssignable`, REST assignees) has GitHub write code and open
  a PR, from an issues-only box. The presets do not refuse it: turn the agent off where the
  token reaches.
