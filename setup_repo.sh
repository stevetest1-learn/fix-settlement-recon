#!/usr/bin/env bash
# One-time repo setup.
#
#   ./setup_repo.sh YOUR-GITHUB-USERNAME
#
# Substitutes your username into the README badges and demo link, then
# initialises git and stages the first commit. Does not push — review first,
# then push yourself.

set -euo pipefail
cd "$(dirname "$0")"

USER_NAME="${1:-}"
if [ -z "$USER_NAME" ]; then
  echo "Usage: ./setup_repo.sh YOUR-GITHUB-USERNAME" >&2
  echo >&2
  echo "This is your GitHub username, not your LinkedIn handle — they are" >&2
  echo "often different. Check github.com/settings/profile if unsure." >&2
  exit 1
fi

# --- substitute the placeholder --------------------------------------
for f in README.md pyproject.toml; do
  if grep -q "USERNAME" "$f" 2>/dev/null; then
    if sed --version >/dev/null 2>&1; then
      sed -i "s|USERNAME|$USER_NAME|g" "$f"          # GNU
    else
      sed -i '' "s|USERNAME|$USER_NAME|g" "$f"       # BSD / macOS
    fi
    echo "  updated $f"
  fi
done

# --- sanity check before committing ----------------------------------
echo
echo "Running tests before the first commit..."
if command -v pytest >/dev/null 2>&1; then
  pytest -q || { echo "Tests failed. Fix before committing." >&2; exit 1; }
else
  python3 -m pytest -q 2>/dev/null || echo "  (pytest not installed; skipping)"
fi

# --- git ---------------------------------------------------------------
if [ ! -d .git ]; then
  git init -q -b main
  echo "  initialised git repository"
fi

git add -A
echo
echo "Staged for commit:"
git status --short | head -30
echo
cat <<NEXT
Next steps:

  git commit -m "FIX to on-chain settlement reconciliation"

  # create the repo on github.com first, then:
  git remote add origin https://github.com/$USER_NAME/fix-settlement-recon.git
  git push -u origin main

Then turn on GitHub Pages:

  Settings -> Pages -> Source: "GitHub Actions"

The deploy workflow runs on push and publishes web/ to:

  https://$USER_NAME.github.io/fix-settlement-recon/

That URL is what goes in your LinkedIn post. Confirm it loads and that a
scenario runs before you post — the wheel has to build in CI for the page
to work.
NEXT
