#!/bin/sh
# Apply the fork guards for Lambda256/go-ethereum-ralim.
#
# Everything here lives in .git/config, which is NOT versioned, so every clone
# has to run this once:
#
#     ./.githooks/install.sh
#
# Branch model:
#   master  - untouched mirror of ethereum/go-ethereum, advanced only by
#             `git merge --ff-only upstream/<release tag>`. Never commit here.
#   ralim   - the bandwidth-limit patch stack, rebased onto each upstream tag.
#             This is the branch to work from and to open pull requests against.
set -e

cd "$(git rev-parse --show-toplevel)"

# 1. Install the hooks. They are COPIED into .git/hooks rather than reached via
#    core.hooksPath: hooksPath resolves against the working tree, so it would
#    silently stop working the moment you check out master, where .githooks
#    does not exist. Re-run this script after editing anything in .githooks/.
#    pre-push rejects pushes aimed at upstream; pre-commit rejects commits on
#    master.
hooks_dir="$(git rev-parse --git-common-dir)/hooks"
mkdir -p "$hooks_dir"
for hook in pre-push pre-commit; do
	cp ".githooks/$hook" "$hooks_dir/$hook"
	chmod +x "$hooks_dir/$hook"
done
git config --local --unset core.hooksPath 2>/dev/null || true

# 2. Make pushing to the upstream remote impossible, even by explicit request,
#    while leaving it fetchable.
if git remote get-url upstream >/dev/null 2>&1; then
	git remote set-url --push upstream "no-push://blocked/ethereum-go-ethereum-is-read-only"
fi

# 3. Tell the GitHub CLI that this fork - not ethereum/go-ethereum - is the base
#    repo, so `gh pr create` opens PRs against Lambda256/go-ethereum-ralim.
git config --local remote.origin.gh-resolved base

# 4. Default every push to the fork.
git config --local remote.pushDefault origin
git config --local checkout.defaultRemote origin
git config --local init.defaultBranch ralim

#    Point origin/HEAD at whatever GitHub reports as the default branch, so
#    `git checkout origin/HEAD` and bare `git log origin` follow ralim.
git remote set-head origin -a >/dev/null 2>&1 || true

# 5. Feature branches cut from ralim should rebase, not merge, on pull - the
#    patch branch is force-pushed after every upstream rebase.
git config --local pull.rebase true

echo "Fork guards installed."
echo "  upstream : fetch-only"
echo "  master   : read-only upstream mirror (commits blocked)"
echo "  ralim    : patch branch - work here, PRs target Lambda256/go-ethereum-ralim"
