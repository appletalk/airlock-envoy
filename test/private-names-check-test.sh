#!/usr/bin/env bash
# Tests for scripts/private-names-check, in throwaway repos with a stand-in pattern list (the
# real list is private). Each case: what goes in, the exit code the check must give.
#   test/private-names-check-test.sh
set -uo pipefail
C="$(cd "$(dirname "$0")/.." && pwd)/scripts/private-names-check"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 AIRLOCK_PRIVATE_NAMES="$T/list"
printf '# stand-ins\n(^|[^a-z0-9])sitename([^a-z0-9]|$)\n10\\.77\\.66\\.\n' > "$T/list"
fails=0
want() {  # want <rc> <what> <command...>
  local w=$1 what=$2 rc=0; shift 2
  "$@" >"$T/out" 2>&1 || rc=$?
  if [ "$rc" = "$w" ]; then echo "ok   $what"; else echo "FAIL $what (want $w, got $rc)"; sed 's/^/     /' "$T/out"; fails=1; fi
}
repo() {  # a fresh repo with one clean commit, as $R
  R="$T/r$RANDOM$RANDOM"; git init -q -b main "$R"; cd "$R" || exit 1
  git config user.name t; git config user.email t@t
  echo clean > a.txt; git add a.txt; git commit -q -m base
}
commit() { git add -A; git commit -q -m "${1:-change}"; }

repo
echo "host 10.77.66.5" > b.txt; git add b.txt
want 1 "staged: an address" "$C" --staged
git reset -q; rm b.txt
want 0 "staged: nothing" "$C" --staged
printf '* -diff\n' > .gitattributes; echo "owner Sitename" > c.txt; git add .gitattributes c.txt
want 1 "staged: hidden behind .gitattributes -diff" "$C" --staged
commit; want 1 "range: hidden behind .gitattributes -diff" "$C" --range HEAD~1..HEAD
want 1 "tree: hidden behind .gitattributes -diff" "$C" --tree HEAD

repo
printf 'x\0y sitename\n' > bin.dat; commit
want 1 "range: a binary file (NUL bytes)" "$C" --range HEAD~1..HEAD
want 1 "tree: a binary file" "$C" --tree
repo
printf 'sitename\n' | iconv -t UTF-16LE > u16.txt; commit
want 1 "range: UTF-16 text" "$C" --range HEAD~1..HEAD
repo
printf '++ sitename\n' > d.txt; commit
want 1 "range: a line starting with ++" "$C" --range HEAD~1..HEAD
repo
mkdir sub; echo x > sub/f; ln -s ../sitename-target sub/link; commit
want 1 "range: a symlink target" "$C" --range HEAD~1..HEAD
repo
printf 'ELF\0user\0sitename\0home\0' > packed.bin; commit
want 1 "range: strings packed between NULs (a binary's string table)" "$C" --range HEAD~1..HEAD
want 1 "tree: strings packed between NULs" "$C" --tree
repo
printf 'x\n' > "$(printf 'a\tsitename')"; git add -A
want 1 "staged: a path with a tab before the name" "$C" --staged
commit; want 1 "range: a path with a tab" "$C" --range HEAD~1..HEAD
want 1 "tree: a path with a tab" "$C" --tree
repo
tree="$(git rev-parse "HEAD^{tree}")" parent="$(git rev-parse HEAD)"
c="$(printf 'tree %s\nparent %s\nauthor t <t@t> 1700000000 +0000\ncommitter t <t@t> 1700000000 +0000\nmergetag object %s\n type commit\n tag v1\n \n release for sitename\n\nclean subject\n' "$tree" "$parent" "$parent" | git hash-object -t commit -w --stdin)"
git update-ref refs/heads/main "$c"
want 1 "range: an extra commit header (a mergetag's message)" "$C" --range HEAD~1..HEAD
repo
git mv a.txt sitename.txt; commit
want 1 "range: a rename to a name" "$C" --range HEAD~1..HEAD
repo
echo "sitename" > e.txt; commit "add"; git rm -q e.txt; commit "remove"
want 0 "range: a commit that removes a name passes" "$C" --range HEAD~1..HEAD
want 1 "range: the commit that added it does not" "$C" --range HEAD~2..HEAD

R="$T/root"; git init -q -b main "$R"; cd "$R" || exit 1; git config user.name t; git config user.email t@t
echo "sitename" > f.txt; commit root; echo clean > f.txt; commit fix
want 1 "range: a name only in the root commit (log.showRoot=false)" git -c log.showRoot=false -c core.hooksPath=/dev/null "$C" --range main

repo
git checkout -q -b side; echo "via sitename" > s.txt; commit side; git checkout -q main
git merge -q --no-ff -m merge side
want 1 "range: content a merge brings in" "$C" --range HEAD~1..HEAD
repo
git checkout -q -b side2; echo y > y.txt; commit side; git checkout -q main
git merge -q --no-ff --no-commit side2 2>/dev/null; echo "evil sitename" > z.txt; git add z.txt; git commit -q -m merge
want 1 "range: an evil merge" "$C" --range HEAD~1..HEAD

repo
git commit -q --allow-empty -m "fix for Sitename"
want 1 "range: a message" "$C" --range HEAD~1..HEAD
git commit -q --allow-empty --author "Sitename <x@y>" -m clean
want 1 "range: an author" "$C" --range HEAD~1..HEAD
printf 'subject\n# sitename\n' > "$T/msg"
want 1 "msg: a # line (git commit -m keeps it)" "$C" --msg "$T/msg"
printf 'subject\n# ------------------------ >8 ------------------------\n# Do not modify or remove the line above.\n+ sitename\n' > "$T/msg"
want 0 "msg: git commit -v's diff below its scissors line is left out" "$C" --msg "$T/msg"
printf 'subject\n# ------------------------ >8 ------------------------\nsitename\n' > "$T/msg"
want 1 "msg: a scissors line typed into -m hides nothing" "$C" --msg "$T/msg"

repo
echo "sitename" > top.txt; mkdir deep; echo ok > deep/f; commit; cd deep || exit 1
want 1 "tree: run from a subdirectory still checks the whole tree" "$C" --tree

repo
echo "sitename" > h.txt; commit; git clone -q --bare "$R" "$T/bare.git"; cd "$T/bare.git" || exit 1
want 1 "range: in a bare repo" "$C" --range main

repo
for n in ';touch PWNED;|e;#' 'a|b&c\d' "$(printf 'x\nsitename')"; do printf 'sitename\n' > "$n"; done; git add -A
want 1 "staged: paths with | & \\ newline and a sed e-flag payload: reported, nothing run" "$C" --staged
commit; want 1 "range: the same paths" "$C" --range HEAD~1..HEAD
want 1 "tree: the same paths" "$C" --tree
if [ -e "$R/PWNED" ]; then echo "FAIL a path ran a command"; fails=1; else echo "ok   no command ran from a path"; fi
repo
printf '\xffsitename\xff\n' > latin.txt; commit
want 1 "range: a name between non-UTF-8 bytes, under a UTF-8 locale" env LC_ALL=C.UTF-8 "$C" --range HEAD~1..HEAD
want 1 "tree: the same, under a UTF-8 locale" env LC_ALL=C.UTF-8 "$C" --tree
repo
echo "sitename" > n.txt; git add n.txt
cp "$T/list" "$T/list.keep"; sed 's/$/\r/' "$T/list.keep" > "$T/list"
want 1 "a list with CRLF line ends still matches" "$C" --staged
sed 's/^/   /' "$T/list.keep" > "$T/list"
want 1 "an indented list still matches" "$C" --staged
cp "$T/list.keep" "$T/list"; git reset -q
want 2 "range: a bad rev is an error, not clean" "$C" --range nosuch..HEAD
want 2 "range: a bad end rev too" "$C" --range HEAD~1..nosuch
want 2 "tree: a bad rev" "$C" --tree nosuch
mkdir -p "$T/norepo"; cd "$T/norepo" || exit 1
want 2 "outside a repository: an error" env GIT_CEILING_DIRECTORIES="$T" "$C" --tree
repo
git commit -q --allow-empty -m "$(printf 'subject\ngpgsig note\nhost sitename here')"
want 1 "range: a message line starting with gpgsig hides nothing" "$C" --range HEAD~1..HEAD
repo
tree="$(git rev-parse "HEAD^{tree}")" parent="$(git rev-parse HEAD)"
c="$(printf 'tree %s\nparent %s\nauthor t <t@t> 1700000000 +0000\ncommitter t <t@t> 1700000000 +0000\ngpgsig -----BEGIN PGP SIGNATURE-----\n note for sitename\n -----END PGP SIGNATURE-----\n\nclean subject\n' "$tree" "$parent" | git hash-object -t commit -w --stdin)"
git update-ref refs/heads/main "$c"
want 1 "range: text hidden in a signature header" "$C" --range HEAD~1..HEAD
R="$T/sha256"; git init -q -b main --object-format=sha256 "$R" 2>/dev/null && { cd "$R" || exit 1
  git config user.name t; git config user.email t@t; echo sitename > s.txt; git add s.txt
  want 1 "staged: a first commit in a SHA-256 repo" "$C" --staged; }

repo
cp "$T/list" "$T/list.ok"; printf 'bad(\n' >> "$T/list"
echo sitename > g.txt; git add g.txt
want 2 "an invalid pattern is refused, not read as no match" "$C" --staged
printf '# only comments\n' > "$T/list"
want 2 "a list with no patterns" "$C" --staged
AIRLOCK_PRIVATE_NAMES="$T/none" want 2 "no list" "$C" --staged
cp "$T/list.ok" "$T/list"
want 2 "no arguments" "$C"

exit "$fails"
