#!/usr/bin/env bash
#
# Rebase the fork's patch branch onto a new upstream go-ethereum release tag.
#
#   ./rebase_new_tag.sh v1.18.0
#   ./rebase_new_tag.sh v1.18.0 --push
#   ./rebase_new_tag.sh v1.18.0 --from v1.17.5 --no-verify
#
# The current base tag is derived from the repository, not stored anywhere:
# the patch branch forks off upstream history at exactly its base commit, so
# `git merge-base <patch branch> upstream/master` recovers it. --from overrides
# that when the derivation cannot work (e.g. a tag off a maintenance branch).
#
# Nothing is pushed unless --push is given. A backup ref is always written
# first, so the whole run can be undone with a single git update-ref.

set -euo pipefail

PATCH_BRANCH=ralim
MIRROR_BRANCH=master
UPSTREAM=upstream
ORIGIN=origin

usage() {
	sed -n '3,15p' "$0" | sed 's/^# \{0,1\}//'
	exit "${1:-0}"
}

die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }

NEW_TAG=""
FROM_TAG=""
DO_PUSH=0
DO_MIRROR=1
DO_VERIFY=1

while [ $# -gt 0 ]; do
	case "$1" in
		-h|--help)   usage 0 ;;
		--from)      FROM_TAG="${2:-}"; [ -n "$FROM_TAG" ] || die "--from needs a tag"; shift 2 ;;
		--push)      DO_PUSH=1; shift ;;
		--no-mirror) DO_MIRROR=0; shift ;;
		--no-verify) DO_VERIFY=0; shift ;;
		-*)          die "unknown option: $1" ;;
		*)           [ -z "$NEW_TAG" ] || die "unexpected argument: $1"; NEW_TAG="$1"; shift ;;
	esac
done

[ -n "$NEW_TAG" ] || usage 1

# ---------------------------------------------------------------- preconditions

cd "$(git rev-parse --show-toplevel)" || die "not inside a git repository"

git remote get-url "$UPSTREAM" >/dev/null 2>&1 \
	|| die "no '$UPSTREAM' remote. Run: git remote add $UPSTREAM https://github.com/ethereum/go-ethereum.git"

if [ -d "$(git rev-parse --git-path rebase-merge)" ] || [ -d "$(git rev-parse --git-path rebase-apply)" ]; then
	die "a rebase is already in progress. Finish it with 'git rebase --continue' or 'git rebase --abort' first."
fi

if ! git diff-index --quiet HEAD -- || [ -n "$(git ls-files --others --exclude-standard)" ]; then
	git status --short >&2
	die "working tree is not clean. Commit or stash first - a rebase needs a clean tree."
fi

git rev-parse --verify --quiet "refs/heads/$PATCH_BRANCH" >/dev/null \
	|| die "no local '$PATCH_BRANCH' branch"

START_BRANCH="$(git symbolic-ref --short -q HEAD || echo '')"

# ------------------------------------------------------------------------ fetch

step "Fetching $UPSTREAM (tags included)"
git fetch --quiet "$UPSTREAM" --tags --prune
info "done"

NEW_SHA="$(git rev-parse --verify --quiet "${NEW_TAG}^{commit}" || true)"
[ -n "$NEW_SHA" ] || die "tag '$NEW_TAG' does not exist upstream. Available:
$(git tag -l 'v*' --sort=-v:refname | head -8 | sed 's/^/      /')"

# ------------------------------------------------------- resolve the old base

if [ -n "$FROM_TAG" ]; then
	OLD_SHA="$(git rev-parse --verify --quiet "${FROM_TAG}^{commit}" || true)"
	[ -n "$OLD_SHA" ] || die "--from tag '$FROM_TAG' does not exist"
else
	OLD_SHA="$(git merge-base "$PATCH_BRANCH" "$UPSTREAM/master")" \
		|| die "cannot derive the current base; pass it explicitly with --from <tag>"
	FROM_TAG="$(git describe --tags --exact-match "$OLD_SHA" 2>/dev/null || echo "$(git rev-parse --short "$OLD_SHA") (untagged)")"
fi

[ "$OLD_SHA" != "$NEW_SHA" ] || die "$PATCH_BRANCH is already based on $NEW_TAG - nothing to do"

if ! git merge-base --is-ancestor "$OLD_SHA" "$NEW_SHA"; then
	warn "$NEW_TAG is not a descendant of the current base $FROM_TAG."
	warn "This moves the patch stack sideways or backwards, not forward."
	printf '    Continue anyway? [y/N] '
	read -r reply </dev/tty || reply=n
	case "$reply" in [yY]*) ;; *) die "aborted" ;; esac
fi

PATCH_COUNT="$(git rev-list --count "$OLD_SHA..$PATCH_BRANCH")"

step "Plan"
info "patch branch : $PATCH_BRANCH ($PATCH_COUNT commit(s) to replay)"
info "current base : $FROM_TAG  ($(git rev-parse --short "$OLD_SHA"))"
info "new base     : $NEW_TAG  ($(git rev-parse --short "$NEW_SHA"))"
git log --oneline "$OLD_SHA..$PATCH_BRANCH" | sed 's/^/      /'

# ----------------------------------------------------------------- backup ref

BACKUP="refs/fork-backup/${PATCH_BRANCH}-$(date +%Y%m%d-%H%M%S)"
git update-ref "$BACKUP" "$(git rev-parse "$PATCH_BRANCH")"
ROLLBACK="git update-ref refs/heads/$PATCH_BRANCH $BACKUP && git checkout -f $PATCH_BRANCH"

step "Backup"
info "$BACKUP -> $(git rev-parse --short "$PATCH_BRANCH")"
info "roll back with: $ROLLBACK"

# ------------------------------------------------------------- mirror the tip

if [ "$DO_MIRROR" -eq 1 ]; then
	step "Fast-forwarding the $MIRROR_BRANCH mirror"
	git checkout --quiet "$PATCH_BRANCH"   # fetching into the current branch is refused
	if git rev-parse --verify --quiet "refs/heads/$MIRROR_BRANCH" >/dev/null; then
		if git fetch --quiet . "$UPSTREAM/master:$MIRROR_BRANCH" 2>/dev/null; then
			info "$MIRROR_BRANCH -> $(git rev-parse --short "$MIRROR_BRANCH")"
		else
			warn "could not fast-forward $MIRROR_BRANCH (it has diverged from $UPSTREAM/master); skipping"
		fi
	else
		warn "no local '$MIRROR_BRANCH' branch; skipping"
	fi
fi

# ---------------------------------------------------------------------- rebase

step "Rebasing $PATCH_BRANCH onto $NEW_TAG"

rebase_in_progress() {
	[ -d "$(git rev-parse --git-path rebase-merge)" ] || [ -d "$(git rev-parse --git-path rebase-apply)" ]
}

# p2p/config_toml.go is generated by gencodec. Resolving it by hand produces
# a file that no longer matches `go generate`, so regenerate it instead.
GENERATED=p2p/config_toml.go

resolve_generated() {
	local unmerged
	unmerged="$(git diff --name-only --diff-filter=U)"
	[ "$unmerged" = "$GENERATED" ] || return 1

	info "only $GENERATED conflicts - regenerating instead of merging by hand"
	git checkout --ours -- "$GENERATED"
	go generate ./p2p/ >/dev/null || { warn "go generate failed"; return 1; }
	git add "$GENERATED"
	return 0
}

set +e
git rebase --onto "$NEW_SHA" "$OLD_SHA" "$PATCH_BRANCH"
rebase_status=$?
set -e

while [ "$rebase_status" -ne 0 ] && rebase_in_progress; do
	resolve_generated || break
	set +e
	GIT_EDITOR=true git rebase --continue
	rebase_status=$?
	set -e
done

if [ "$rebase_status" -ne 0 ]; then
	printf '\n'
	warn "the rebase stopped with conflicts. It is left in progress on purpose."
	printf '    Conflicting files:\n'
	git diff --name-only --diff-filter=U | sed 's/^/      /'
	cat <<-MSG

	    Resolve them, then:   git add <files> && git rebase --continue
	    Give up entirely:     git rebase --abort
	    Undo everything:      $ROLLBACK

	    Reminder: never hand-merge $GENERATED. Take either side and run
	    'go generate ./p2p/' to rebuild it from p2p/config.go.
	MSG
	exit 1
fi

info "replayed $PATCH_COUNT commit(s) cleanly"

# ---------------------------------------------------------------------- verify

if [ "$DO_VERIFY" -eq 1 ]; then
	step "Verifying"

	fmt_out="$(gofmt -l p2p cmd)"
	[ -z "$fmt_out" ] || { warn "gofmt reports unformatted files:"; printf '%s\n' "$fmt_out" | sed 's/^/      /'; die "fix formatting, then re-run with --no-verify"; }
	info "gofmt        ok"

	go generate ./p2p/ >/dev/null
	if ! git diff --quiet -- "$GENERATED"; then
		git checkout -- "$GENERATED"
		die "$GENERATED is stale after the rebase. Run 'go generate ./p2p/' and amend the patch commit."
	fi
	info "go generate  ok ($GENERATED in sync)"

	go build ./p2p/... ./cmd/... || die "build failed on $NEW_TAG. Fix the patch, then re-run verification."
	info "go build     ok"

	go test ./p2p/ || die "p2p tests failed on $NEW_TAG."
	info "go test      ok"
fi

# ------------------------------------------------------------------------ push

step "Result"
info "$PATCH_BRANCH is now $NEW_TAG + $PATCH_COUNT commit(s)  ($(git rev-parse --short "$PATCH_BRANCH"))"

if [ "$DO_PUSH" -eq 1 ]; then
	step "Pushing"
	if [ "$DO_MIRROR" -eq 1 ] && git rev-parse --verify --quiet "refs/heads/$MIRROR_BRANCH" >/dev/null; then
		git push "$ORIGIN" "$MIRROR_BRANCH"
	fi
	git push --force-with-lease "$ORIGIN" "$PATCH_BRANCH"
	info "pushed"
else
	cat <<-MSG

	    Not pushed. When you are happy with the result:

	        git push $ORIGIN $MIRROR_BRANCH
	        git push --force-with-lease $ORIGIN $PATCH_BRANCH

	    Teammates must then run: git fetch $ORIGIN && git rebase $ORIGIN/$PATCH_BRANCH
	MSG
fi

cat <<-MSG

	    Update the base tag recorded in FORK.md: $FROM_TAG -> $NEW_TAG
	    Undo this run:  $ROLLBACK
MSG

[ -z "$START_BRANCH" ] || [ "$START_BRANCH" = "$PATCH_BRANCH" ] || git checkout --quiet "$START_BRANCH"
