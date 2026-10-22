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
server (rulesets or branch protection), or use `git-read`.

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
  - Which branches and tags a push may touch is the server's branch and tag protection. A push
    can create, force-push or delete any branch or tag that is not protected.
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
too, and so are project, field and view settings. Without `projects`, all Projects writes are
refused.

Limits:

- That an item, field or value ID belongs to the named project is GitHub's check, not this one.
  Verify it live before relying on the pin.
- `addProjectV2ItemById` takes any content ID, so a box can put any issue it can read (another
  repo's, a private one's) on the pinned board.
- GitHub adds items to boards by itself: org auto-add workflows, and an issue template with
  `projects:` (createIssue with an `issueTemplate`) can add items to boards the box never names.

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

### Stream timeouts

| Routes | Request timeout | Whole-stream cap | Idle |
|---|---|---|---|
| Most plain-HTTP routes | 120 s | 5 minutes | 5 minutes |
| `git` and `git-read`; `forgejo`'s git routes; `kubernetes-read`'s API reads | none | none | 5 minutes |

The cap means a body sent slowly can't hold a connection. Clones, pushes, watches and `logs -f`
are exempt because they can legitimately take long; they still close after 5 minutes with nothing
sent.

### What the presets don't bound

This is the site's job:

- **No repo scoping.** A box can read any repo the token can, and write issues and comments in
  any of them, e.g. copy a private repo into another repo's issue. Only the token's (or App
  installation's) repo list bounds it.
- **Label and comment writes also land on PRs**, where org automation (an auto-merge label, a
  comment-triggered workflow) can turn them into merges or deploys.
- **Assignment can start an agent.** Where an org has the Copilot coding agent on, assigning an
  issue to Copilot (`replaceActorsForAssignable`, REST assignees) has GitHub write code and open
  a PR, from an issues-only box. The presets do not refuse it: turn the agent off where the
  token reaches.
