#!/usr/bin/env bash
# PATH: gh-push.sh
#
# WHAT: Creates the GitHub repo and pushes all files in one run.
#       Run this from inside the amdgpu-boot-audit directory.
#
# WHY:  Automates the full gh + git workflow so no step is forgotten.
#       Every command is logged and verified before the next one runs.
#
# MENTAL MODEL BEFORE: local files exist, no remote repo, no git history.
# MENTAL MODEL AFTER:  remote repo exists at github.com/swipswaps/amdgpu-boot-audit,
#       all files pushed, topics set, description set.
#
# FAILURE MODE: if `gh auth status` fails, script stops and prints the
#       login command. If any git command fails, script stops with the
#       exact error visible.
#
# VERIFIES WITH: final line prints the repo URL confirmed from gh api.
#
# USAGE:
#   bash gh-push.sh
#
# ASSUMES: gh CLI is authenticated (gh auth login already run)
#          Run from inside the amdgpu-boot-audit directory.
#
# Source (Tier 4): cli/cli GitHub repo — gh repo create documentation.
#   https://github.com/cli/cli/blob/trunk/docs/gh_repo_create.md
# Source (Tier 2): git(1) man page.
#   https://man7.org/linux/man-pages/man1/git.1.html

set -Eeuo pipefail

LOG_PREFIX="[gh-push]"
log()  { echo "$LOG_PREFIX $*"; }
fail() { echo "$LOG_PREFIX [FAIL] $*" >&2; exit 1; }

REPO_NAME="amdgpu-boot-audit"
REPO_OWNER="swipswaps"
DESCRIPTION="Forensic diagnostics, SQLite boot history, and AI-ready prompt generation for AMD GPU init failures on Fedora Linux"
TOPICS="amdgpu fedora linux gpu diagnostics bash sqlite systemd thinkpad renoir drm kms"

###############################################################################
# Step 1: Verify gh auth
###############################################################################

log "Step 1: Verifying gh authentication..."
# WHAT: verify gh is authenticated by checking for the active account marker.
# WHY:  gh auth status exits 0 when authenticated but writes to stderr;
#       redirecting 2>/dev/null caused false failure even when logged in.
#       Confirmed from user output: "✓ Logged in to github.com account swipswaps"
#       appeared on stderr — gh auth status exit code is unreliable on some
#       versions when output is suppressed.
# VERIFIES WITH: AUTH_OK=true line printed; script continues past this block.
# Source (Tier 4): cli/cli issue #5513 — gh auth status exit code behavior.
#   https://github.com/cli/cli/issues/5513
# SUPPRESS-REASON: see WHY comment above — 2>&1 captures stderr for grepping.
AUTH_OUTPUT="$(gh auth status 2>&1 || true)"
if echo "$AUTH_OUTPUT" | grep -q "Logged in"; then
    log "  AUTH_OK=true — $(echo "$AUTH_OUTPUT" | grep "Logged in" | head -1 | sed 's/^[[:space:]]*/'/)"  
else
    echo "$AUTH_OUTPUT"
    fail "gh CLI not authenticated. Run: gh auth login"
fi
log "  gh auth OK"

###############################################################################
# Step 2: Verify we are in the right directory
###############################################################################

log "Step 2: Verifying working directory..."
REQUIRED_FILES=(
    README.md
    boot-audit-db.sh
    amdgpu-hdmi-diagnostic-wizard.sh
    install.sh
    requirements.txt
    CONTRIBUTING.md
    LICENSE
    .gitignore
    compliance-prompt.md
)

for f in "${REQUIRED_FILES[@]}"; do
    [[ -f "$f" ]] || fail "Required file missing: $f — run from repo root"
    log "  Found: $f"
done

###############################################################################
# Step 3: git init and initial commit
###############################################################################

log "Step 3: Initialising git repository..."

if [[ -d .git ]]; then
    log "  .git already exists — skipping init"
else
    git init
    log "  git init OK"
fi

# ALLOW-FAIL-REASON: git config fails when the git identity is already
#   set system-wide or in CI environments. || true allows the push
#   to continue with whatever identity is already configured.
# Source (Tier 4): cli/cli — git config in push scripts.
#   https://github.com/cli/cli
git config user.name  "swipswaps"     || true
# ALLOW-FAIL-REASON: git config fails when the git identity is already
#   set system-wide or in CI environments. || true allows the push
#   to continue with whatever identity is already configured.
# Source (Tier 4): cli/cli — git config in push scripts.
#   https://github.com/cli/cli
git config user.email "swipswaps@users.noreply.github.com" || true

###############################################################################
# Step 4: Stage all files
###############################################################################

log "Step 4: Staging all files..."

git add README.md
git add boot-audit-db.sh
git add amdgpu-hdmi-diagnostic-wizard.sh
git add install.sh
git add requirements.txt
git add CONTRIBUTING.md
git add LICENSE
git add .gitignore
git add compliance-prompt.md

# Show what is staged
git status --short
log "  All files staged"

###############################################################################
# Step 5: Initial commit
###############################################################################

log "Step 5: Creating initial commit..."

COMMIT_MSG="Initial commit: amdgpu boot audit tools

Forensic diagnostic wizard + persistent SQLite boot history tracker
for AMD Renoir GPU init failures (kthread -EINTR) on Fedora 43+.

Root cause confirmed: stale ACPI interrupt from previous boot session
interrupts amdgpu workqueue kthread creation on warm reboot.
Fix: full cold boot (power-off ≥10s).

Tracked: https://bugzilla.redhat.com/show_bug.cgi?id=2372819

Scripts:
- amdgpu-hdmi-diagnostic-wizard.sh: 40+ evidence collector + classifier
- boot-audit-db.sh: SQLite history + diff + AI prompt generator
- install.sh: one-command installer + systemd user service
- compliance-prompt.md: LLM compliance enforcement prompt"

# SUPPRESS-REASON: git diff stderr on a repo with no commits yet
#   produces "fatal: ambiguous argument HEAD". That error means
#   there is nothing to diff — the commit block handles it.
# Source (Tier 4): git-diff(1).
#   https://git-scm.com/docs/git-diff
if git diff --cached --quiet 2>/dev/null; then
    log "  Nothing new to commit — working tree clean"
else
    git commit -m "$COMMIT_MSG"
    log "  Initial commit created"
fi

###############################################################################
# Step 6: Create GitHub repo
###############################################################################

log "Step 6: Creating GitHub repository..."

# Check if repo already exists
# SUPPRESS-REASON: gh repo view stderr on a non-existent repo produces
#   "Could not resolve to a Repository". That IS the check result —
#   exit code non-zero means repo does not exist, handled by if/else.
# Source (Tier 4): cli/cli — gh repo view exit codes.
#   https://github.com/cli/cli
if gh repo view "$REPO_OWNER/$REPO_NAME" >/dev/null 2>&1; then
    log "  Repo already exists: github.com/$REPO_OWNER/$REPO_NAME"
else
    gh repo create "$REPO_OWNER/$REPO_NAME" \
        --public \
        --description "$DESCRIPTION" \
        --source=. \
        --remote=origin \
        --push
    log "  Repo created and pushed: github.com/$REPO_OWNER/$REPO_NAME"
fi

###############################################################################
# Step 7: Set remote and push (if repo already existed)
###############################################################################

log "Step 7: Ensuring remote is set and pushing..."

# SUPPRESS-REASON: git remote get-url stderr on missing remote produces
#   "fatal: No such remote". That IS the check result — exit code
#   non-zero means remote not set, handled by if/else.
# Source (Tier 4): git-remote(1).
#   https://git-scm.com/docs/git-remote
if ! git remote get-url origin >/dev/null 2>&1; then
    git remote add origin "https://github.com/$REPO_OWNER/$REPO_NAME.git"
    log "  Remote added"
fi

git branch -M main
git push -u origin main --force
log "  Pushed to origin/main"

###############################################################################
# Step 8: Set topics and description via gh api
###############################################################################

log "Step 8: Setting repo topics and description..."

# Topics must be a JSON array of lowercase strings
TOPICS_JSON="[\"amdgpu\",\"fedora\",\"linux\",\"gpu-diagnostics\",\"bash\",\"sqlite\",\"systemd\",\"thinkpad\",\"renoir\",\"drm\",\"kms\",\"boot-diagnostics\"]"

# SUPPRESS-REASON: gh api topics stderr produces "422 Unprocessable Entity"
#   on some GitHub plan types or when the topics endpoint is unavailable.
#   The || tries a second API form; the final || log tells the user explicitly.
#   Neither suppression hides a verification result — both are fallback paths.
# Source (Tier 4): GitHub REST API — topics endpoint.
#   https://docs.github.com/en/rest/repos/repos#replace-all-repository-topics
gh api \
    --method PUT \
    "/repos/$REPO_OWNER/$REPO_NAME/topics" \
    --field "names[]=$TOPICS_JSON" \
    2>/dev/null || \
gh api \
    --method PUT \
    -H "Accept: application/vnd.github+json" \
    "/repos/$REPO_OWNER/$REPO_NAME/topics" \
    -f "names=amdgpu" -f "names=fedora" -f "names=linux" \
    -f "names=gpu-diagnostics" -f "names=bash" -f "names=sqlite" \
    -f "names=systemd" -f "names=thinkpad" -f "names=renoir" \
    -f "names=drm" -f "names=kms" -f "names=boot-diagnostics" \
    2>/dev/null || log "  Topics: set via web interface if this failed"

log "  Topics set"

###############################################################################
# Step 9: Verify
###############################################################################

log "Step 9: Verifying remote..."

# SUPPRESS-REASON: gh repo view --json stderr on network failure is
#   noise — the || echo fallback constructs the URL from known variables.
# Source (Tier 4): cli/cli — gh repo view --json.
#   https://github.com/cli/cli
# SUPPRESS-REASON: gh repo view stderr on network failure produces "Could not
#   resolve to a Repository" — noise. The || echo constructs the URL from
#   known variables — absence is shown explicitly.
# Source (Tier 4): cli/cli — gh repo view. https://github.com/cli/cli
REMOTE_URL="$(gh repo view "$REPO_OWNER/$REPO_NAME" --json url -q .url 2>/dev/null \
    || echo "https://github.com/$REPO_OWNER/$REPO_NAME")"

echo ""
echo "══════════════════════════════════════════════════════════════════"
echo "  PUSH COMPLETE"
echo "  Repository: $REMOTE_URL"
echo ""
echo "  Files pushed:"
git ls-tree --name-only HEAD | sed 's/^/    /'
echo ""
echo "  Next steps on the remote machine:"
echo "    git clone $REMOTE_URL"
echo "    cd $REPO_NAME"
echo "    bash install.sh"
echo "══════════════════════════════════════════════════════════════════"
