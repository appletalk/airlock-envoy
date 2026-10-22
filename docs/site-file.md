# The site file in detail

`/etc/airlock-envoy/site.conf` defines this host's listeners. The README has the overview and
the keyword table; this page has every rule. `configs/site.conf.example` is a worked example,
and `airlock-envoy-apply --help` is the built-in summary.

## Destinations

- **`host:port`**: CONNECT to exactly this host and port. Only TLS whose server name (SNI) is
  that host passes, so another site on the same address is out of reach (as for `anthropic`).
- **`IPv4:port`**: CONNECT to exactly this address and port. Only TLS that sends *no* server name
  passes. Clients send none for an address (checked for curl, Python and Go, which kubectl
  uses). A kubeconfig with `tls-server-name` set does send one, and is refused.
  - Meant for hosts you run, such as a Kubernetes API server addressed by IP. On a shared edge,
    the HTTP `Host` inside TLS could still pick another site.
  - Loopback, `0.0.0.0/8`, link-local and multicast addresses are refused.
  - A host name is not checked for what it resolves to, so a name that resolves to the host
    itself or its LAN reaches it.
- **`@name`**: everything listener `name` allows. It must be defined above, so there are no
  cycles, and a listener cannot be extended once something includes it. Repeat a name to
  continue it on another line.
- **`web`**: the public internet, any host name on port 443 (see
  [design.md](design.md#how-web-decides)). A listener's exact entries still win. So
  `infra metrics.example.net:443 web` with `internal-name example.net` reaches metrics and the
  public web, but no other `example.net` name.
- **`http://<host>`** or **`http://<host>@<variant>`**: a plain-HTTP destination defined by an
  `http` line above (see the README).

## `client <listener> <user>`

A line of its own, anywhere in the file. It names the one user whose boxes may connect. A
listener with a socket has exactly one; a listener only included by others has none (see below).

**Where the socket goes.** `/run/airlock-envoy/<user>/<listener>.sock`, in a directory only that
uid may enter (root's, 0700 with an ACL), with an ACL on the socket for that uid alone.

- An ACL by uid, not a group: rootless containers drop supplementary groups, so a group would
  not work, and no group membership matters.
- The directory is root's, so nothing running as the user can swap the socket.
- Names are not secret. Other users see user and listener names (in `/run/airlock-envoy/`, the
  units' drop-ins, systemd), but cannot enter, list or connect.

**Who may be a client.** Checked at `--check` and at apply:

- The user must exist and be a login account: uid from `UID_MIN` to `UID_MAX` in
  `/etc/login.defs` (else 1000 to 60000), and not root or nobody.
- The uid must be outside every other user's subordinate uids in `/etc/subuid`, whose rootless
  containers could take that uid on, and with it the sockets. Ranges served by NSS instead of
  the file are not seen. `/etc/subuid` is read as shadow reads it (decimal, hex, octal); a line
  it can't read refuses the apply.
- **Make clients local accounts** (`/etc/passwd`). The ACLs name the user by uid, and a socket
  starts (at boot too) only while the name still has that uid. Box sockets start early at boot,
  before a directory service (SSSD, LDAP) answers, so a socket whose user can't be looked up then
  stays down until the next apply.

**Removing or renumbering a client.** Take its `client` lines out and apply first. An apply that
finds the applied client gone, renumbered or inside someone's subordinate uids refuses, and
stops that listener's socket.

**Listeners without a client.** A listener that another one includes may go without one. It is
then a definition only, with no socket, Envoy listener or upstreams of its own (the built-in
`anthropic` is one). A listener that nothing includes must have a client, so a forgotten line is
an error, not a socket no one can use. The built-in `anthropic` cannot be given a client: define
your own (say `alice-anthropic @anthropic`) and name its client.

**Naming.** Name listeners after their user (`alice-infra`, `agent-infra`) so the name in a box's
config says whose it is.

**A credential belongs to one user.** If listeners of two users would reach the same credential
(directly or through an include), apply refuses. Give the second user a variant
(`http <host>@<variant> ... credential <its own>`).

The audit log names the user (`user`) on every request line.

## `internal-name` and `internal-net`

Site-wide lines, not listeners. They say what `web` treats as internal, beyond the built-ins.

- **Built-in names**: `localhost`, `local`, `localdomain`, `internal`, `lan`, `home.arpa`, and
  their subdomains.
- **Built-in addresses**: everything not public (private, loopback, link-local, CGNAT,
  documentation, multicast, IPv6 ULA and the address-mapping prefixes; the list is in
  `airlock-envoy-web.service`).
- Use `internal-net` for internal ranges that are publicly routable (a company's own blocks) and
  for **your own public addresses**, which lead back in to your services. It takes IPv4 or IPv6
  CIDRs.
- CIDRs are checked strictly: systemd skips an entry it can't parse, and a skipped deny would
  fail open.

## Syntax

- Lowercase names, explicit ports, no wildcards, URLs, IPv6 destinations or Windows line endings.
- `#` starts a comment.
- Listener names: `a-z`, `0-9` and `-`, starting with a letter, up to 32 characters.
- Reserved: `admin` (Envoy's admin socket), `client`, `http`, `internal-name`, `internal-net`,
  and the built-in `anthropic`. `web` is a destination, not a listener name.
- A bad line stops the apply with its line number.

## What an apply does

`sudo airlock-envoy-apply`:

1. Renders the config and checks it with `envoy --mode validate`, run as the service account.
2. Prints the change in allowed destinations against the last apply.
3. Swaps the config in atomically and restarts Envoy, only if the config changed or Envoy is
   down. With the kill switch on, nothing is started.
4. Writes each socket's drop-in and starts a socket for each new listener.
5. Moves the socket of a listener whose user changed. It is stopped before any Envoy runs the new
   config, so the old user's box never reaches the listener as it now is, and started in the new
   user's directory once Envoy runs it. Boxes set to the old path need a relaunch.
6. Removes the socket of each listener that is gone (and a user's directory once it has none),
   so a box set to it no longer launches.

If Envoy does not start with the new config, the previous one goes back.

- `--check` does all the checking and shows the change without applying.
- `--list`, `--render` and `--clients` work as any user.
- `--status` is described in the README.
- **A file from elsewhere**: any site file named on the command line other than the literal
  `/etc/airlock-envoy/site.conf` counts as from elsewhere, symlinks into `/etc` included. When it
  would change the allowed destinations, apply shows the change and asks (`--yes` skips) before
  installing it.

## Upgrading from one global client

Earlier versions took one client user for every socket (`install-service.sh <user>`), with
sockets in `/run/airlock-envoy/` itself. To upgrade:

1. Write the site file with a `client` line for every listener. The built-in `anthropic` has no
   socket now, so give it a listener of your own if you used it directly.
2. Install with it: `sudo install/install-service.sh --site FILE`.

What that does:

- This version checks FILE, shows what it changes and asks (`--yes` skips). It installs it as the
  site file in the same step, since the earlier version's tools can't read the new format and
  this version refuses the old file.
- A client user given on the command line is ignored, with a warning.
- A site file it rejects changes nothing.
- The file it replaces is kept as `site.conf.prev` (an earlier version reads only that).
- If the apply itself fails after that (say Envoy won't start), egress stays shut and `--status`
  says "Applied: NO". Fix the cause and rerun `install-service.sh` (no `--site`).
- The old sockets, their manifests and the global ACL drop-in go. Boxes need their new socket
  path and a relaunch.
