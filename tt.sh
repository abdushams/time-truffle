#!/usr/bin/env bash
set -Eeuo pipefail

# ---------- helpers ----------
usage() {
  echo "Usage: $0 [account_name]"
  echo "If account_name is omitted, you'll be prompted."
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1"; exit 1; }
}

restore_repo() {
  # Restore deleted/unreachable files into .restored/ inside a given repo
  local repo_dir="$1"
  pushd "$repo_dir" >/dev/null

  local out=".restored"
  mkdir -p "$out"
  echo "[*] Restoring into: $repo_dir/$out"

  # Map of object IDs to paths (helps naming blobs later)
  git rev-list --all --objects > "$out/all-objects.map"

  # (1) Recover files deleted in commits (parent→child diffs)
  mkdir -p "$out/commit_diffs"
  while IFS= read -r commit; do
    git diff-tree --name-only --diff-filter=D -r -z "$commit" \
    | xargs -0 -I{} bash -c '
        c="$0"; p="$1"
        dest="'"$out"'"/commit_diffs/"$c"/"$p"
        mkdir -p "$(dirname "$dest")"
        git show "$c^1:$p" > "$dest" 2>/dev/null || true
      ' "$commit" {}
  done < <(git rev-list --all)

  # (2) Unpack packfiles to surface loose objects
  shopt -s nullglob
  for p in .git/objects/pack/pack-*.pack; do
    git unpack-objects < "$p" || true
  done
  shopt -u nullglob

  # Build lost-found for unreachable things
  git fsck --full --no-reflogs --lost-found --dangling || true

  # Copy blobs from lost-found with best-effort original names
  mkdir -p "$out/from_packs" "$out/fsck_blobs" "$out/fsck_commits"
  local map="$out/all-objects.map"

  if compgen -G ".git/lost-found/other/*" >/dev/null; then
    for f in .git/lost-found/other/*; do
      [ -f "$f" ] || continue
      sha=$(basename "$f")
      path=$(awk -v s="$sha" '$1==s{ $1=""; sub(/^ +/,""); print; exit }' "$map" || true)
      if [[ -n "${path:-}" ]]; then
        dest="$out/from_packs/$path"
      else
        dest="$out/from_packs/$sha"
      fi
      mkdir -p "$(dirname "$dest")"
      git cat-file -p "$sha" > "$dest" 2>/dev/null || cp -f "$f" "$dest"
    done
  fi

  # (3a) Dangling blobs
  git fsck --full --no-reflogs --unreachable --dangling \
  | awk '/dangling blob/ {print $3}' \
  | while read -r sha; do
      path=$(awk -v s="$sha" '$1==s{ $1=""; sub(/^ +/,""); print; exit }' "$map" || true)
      dest="$out/fsck_blobs/${path:-$sha}"
      mkdir -p "$(dirname "$dest")"
      git show "$sha" > "$dest" 2>/dev/null || true
    done

  # (3b) Dangling commits → extract full trees
  git fsck --full --no-reflogs --unreachable --dangling \
  | awk '/dangling commit/ {print $3}' \
  | while read -r c; do
      git ls-tree -r --name-only "$c" \
      | while read -r p; do
          dest="$out/fsck_commits/$c/$p"
          mkdir -p "$(dirname "$dest")"
          git show "$c:$p" > "$dest" 2>/dev/null || true
        done
    done

  popd >/dev/null
}

# ---------- main ----------
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then usage; exit 0; fi

need_cmd gh
need_cmd git
need_cmd trufflehog

ACCOUNT_NAME="${1:-}"
if [[ -z "$ACCOUNT_NAME" ]]; then
  read -rp "GitHub account/organization name: " ACCOUNT_NAME
  [[ -n "$ACCOUNT_NAME" ]] || { echo "No account provided."; exit 1; }
fi

ROOT_DIR="$(pwd)"
GIT_DIR="$ROOT_DIR/git"
SECRETS_FILE="$ROOT_DIR/secrets.txt"

mkdir -p "$GIT_DIR"
cd "$GIT_DIR"

echo "[*] Cloning repositories for $ACCOUNT_NAME into $GIT_DIR ..."
# Robust read to handle names safely (repo names typically have no spaces, but just in case)
gh repo list "$ACCOUNT_NAME" -L 1000 --json name --jq '.[].name' \
| while IFS= read -r REPO_NAME; do
    [[ -z "$REPO_NAME" ]] && continue
    if [[ -d "$REPO_NAME/.git" ]]; then
      echo "[-] Already cloned: $REPO_NAME"
    else
      FULL_REPO_URL="https://github.com/$ACCOUNT_NAME/$REPO_NAME.git"
      echo "[+] Cloning $FULL_REPO_URL"
      git clone --quiet "$FULL_REPO_URL" "$REPO_NAME" || echo "[!] Clone failed: $REPO_NAME"
    fi
  done

cd "$ROOT_DIR"

echo "[*] Restoring deleted/unreachable files into .restored/ inside each repo..."
parent="$GIT_DIR"
for d in "$parent"/*/.git; do
  repo_dir="${d%/.git}"
  echo "=== $repo_dir ==="
  restore_repo "$repo_dir"
done

echo "[*] Scanning with TruffleHog (git history + restored folders)..."

LOG="$ROOT_DIR/trufflehog.log"
JSON_OUT="$ROOT_DIR/secrets.ndjson"
TXT_OUT="$ROOT_DIR/secrets.txt"
: > "$LOG"; : > "$JSON_OUT"; : > "$TXT_OUT"

# choose the "verified only" flag depending on your version
if trufflehog git --help 2>/dev/null | grep -q -- '--results'; then
  VERIFIED_FLAG=(--results=verified)   # modern CLI
else
  VERIFIED_FLAG=(--only-verified)      # legacy CLI
fi

for d in "$parent"/*/.git; do
  repo_dir="${d%/.git}"
  name=$(basename "$repo_dir")

  # --- scan git history (JSON to stdout; logs to stderr) ---
  trufflehog git "file://$repo_dir" "${VERIFIED_FLAG[@]}" --json 2>>"$LOG" \
  | jq -rc --arg repo "$name" '
      select(.Verified==true) |
      {
        repo: $repo,
        detector: .DetectorName,
        file: (.SourceMetadata.Data.Git.file // .SourceMetadata.Data.file // "unknown"),
        line: (.SourceMetadata.Data.Git.line // .SourceMetadata.Data.line // 0),
        commit: (.SourceMetadata.Data.Git.commit // null),
        redacted: .Redacted
      }' >> "$JSON_OUT" || true

  # --- scan restored files (filesystem) ---
  if [[ -d "$repo_dir/.restored" ]]; then
    trufflehog filesystem "$repo_dir/.restored" "${VERIFIED_FLAG[@]}" --json 2>>"$LOG" \
    | jq -rc --arg repo "$name" '
        select(.Verified==true) |
        {
          repo: $repo,
          detector: .DetectorName,
          file: (.SourceMetadata.Data.Filesystem.file // .SourceMetadata.Data.file // "unknown"),
          line: (.SourceMetadata.Data.line // 0),
          commit: null,
          redacted: .Redacted
        }' >> "$JSON_OUT" || true
  fi
done

# Make a readable text summary (deduped)
jq -r '"\(.repo)\t\(.detector)\t\(.file):\(.line)\t\(.redacted)"' "$JSON_OUT" \
| sort -u > "$TXT_OUT"

echo
echo "[✔] Done."
echo "    JSON results: $JSON_OUT"
echo "    Pretty text : $TXT_OUT"
echo "    Logs        : $LOG"

