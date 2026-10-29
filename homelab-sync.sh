#!/usr/bin/env bash
# homelab-config-sync.sh
#
# Builds and maintains a git repo of the homelab's configuration, so changes
# can be reviewed as a diff instead of a full audit.
#
# First run initialises the repo (git init, .gitignore, secret-scanning hook).
# Every run after that refreshes the copies and shows you what changed.
#
# Usage:
#   sudo ./homelab-config-sync.sh                 # sync, show diff, don't commit
#   sudo ./homelab-config-sync.sh -c "msg"        # sync and commit
#   sudo INGEST_DIR=/opt/ingest ./homelab-config-sync.sh
#
# Env:
#   REPO         repo location            (default /srv/nubmedia/homelab-config)
#   COMPOSE_DIRS space-separated          (default "/srv/jellyfin")
#   INGEST_DIR   Python ingest scripts    (default /srv/ingest — skipped if absent)
#
# Nothing here is a backup until you push it somewhere off this box.

set -uo pipefail

REPO="${REPO:-/srv/nubmedia/homelab-config}"
COMPOSE_DIRS="${COMPOSE_DIRS:-/srv/jellyfin}"
INGEST_DIR="${INGEST_DIR:-/srv/ingest}"
COMMIT_MSG=""
DO_COMMIT=0

while getopts "c:" opt; do
  case "$opt" in
    c) DO_COMMIT=1; COMMIT_MSG="$OPTARG" ;;
    *) echo "usage: $0 [-c \"commit message\"]" >&2; exit 1 ;;
  esac
done

[[ $EUID -ne 0 ]] && { echo "Run with sudo — these files are root-owned." >&2; exit 1; }
command -v git >/dev/null || { echo "git not installed: dnf install git" >&2; exit 1; }

# ---------------------------------------------------------------- scaffolding

init_repo() {
  echo "Initialising repo at $REPO"
  mkdir -p "$REPO"
  chmod 700 "$REPO"
  git -C "$REPO" init -q -b main
  git -C "$REPO" config user.name  "homelab-config-sync"
  git -C "$REPO" config user.email "root@$(hostname -s)"

  cat >"$REPO/.gitignore" <<'EOF'
# Never track resolved secrets
.env
*.env
!*.env.keys
*.key
*.pem
*.p12
*.pfx
id_rsa*
id_ed25519*
secrets/
# Runtime data that isn't configuration
*.db
*.db-shm
*.db-wal
cache/
log/
logs/
*.log
EOF

  cat >"$REPO/.git/hooks/pre-commit" <<'EOF'
#!/usr/bin/env bash
# Blocks commits containing things that look like secrets.
# Bypass with: git commit --no-verify   (think first)
pattern='(password|passwd|secret|token|api[_-]?key|apikey|access[_-]?key|client[_-]?secret)[[:space:]]*[=:][[:space:]]*[^[:space:]<"'"'"']{6,}'
hits=$(git diff --cached -U0 | grep -E '^\+' | grep -vE '^\+\+\+' | grep -inE "$pattern")
pem=$(git diff --cached -U0 | grep -E '^\+' | grep -c 'BEGIN [A-Z ]*PRIVATE KEY')
if [[ -n "$hits" || "$pem" -gt 0 ]]; then
  echo "pre-commit: possible secret in staged changes:" >&2
  echo "$hits" | head -10 >&2
  [[ "$pem" -gt 0 ]] && echo "  + a PRIVATE KEY block" >&2
  echo >&2
  echo "Remove it, or re-run with --no-verify if it's a false positive." >&2
  exit 1
fi
EOF
  chmod +x "$REPO/.git/hooks/pre-commit"

  cat >"$REPO/README.md" <<EOF
# homelab-config

Copies of this host's configuration, refreshed by \`homelab-config-sync.sh\`.

**This is a mirror, not the live config.** Editing files here changes nothing.
Edit the real file, re-run the sync, commit.

Restoring from here is not a straight copy — git does not preserve ownership,
modes, or SELinux contexts. \`meta/manifest.tsv\` records all three. After
restoring any file: \`restorecon -v <path>\`.

Secrets (\`.env\` and friends) are deliberately not tracked. \`meta/env-keys.txt\`
records variable *names* only, so a new secret appearing shows up in a diff
without its value ever being committed. Back those values up separately.
EOF

  mkdir -p "$REPO"/{compose,etc,scripts,meta}
  echo "Done. Repo has no remote yet — see notes at the end."
}

[[ -d "$REPO/.git" ]] || init_repo

# ---------------------------------------------------------------- collection

copied=()

# copy_in <source> <repo-relative dest dir> [find args...]
copy_in() {
  local src="$1" destdir="$2"; shift 2
  [[ -e "$src" ]] || { echo "  skip (absent): $src"; return; }
  mkdir -p "$REPO/$destdir"
  if [[ -d "$src" ]]; then
    while IFS= read -r -d '' f; do
      local rel="${f#"$src"/}"
      mkdir -p "$REPO/$destdir/$(dirname "$rel")"
      cp -p "$f" "$REPO/$destdir/$rel"
      copied+=("$f")
    done < <(find "$src" -type f "$@" -print0 2>/dev/null)
  else
    cp -p "$src" "$REPO/$destdir/"
    copied+=("$src")
  fi
  echo "  ok: $src"
}

echo "Collecting config..."

# Compose projects — yaml only, never the .env
for d in $COMPOSE_DIRS; do
  name="$(basename "$d")"
  copy_in "$d" "compose/$name" -maxdepth 1 \( -name '*.yml' -o -name '*.yaml' \)
done

# nginx
copy_in /etc/nginx/nginx.conf        etc/nginx
copy_in /etc/nginx/conf.d            etc/nginx/conf.d       -name '*.conf'
copy_in /etc/nginx/default.d         etc/nginx/default.d    -name '*.conf'

# firewalld — the XML under /etc is the permanent source of truth
copy_in /etc/firewalld/zones         etc/firewalld/zones    -name '*.xml'
copy_in /etc/firewalld/services      etc/firewalld/services -name '*.xml'
copy_in /etc/firewalld/firewalld.conf etc/firewalld

# samba, fail2ban, ssh
copy_in /etc/samba/smb.conf          etc/samba
copy_in /etc/fail2ban/jail.local     etc/fail2ban
copy_in /etc/fail2ban/jail.d         etc/fail2ban/jail.d    -name '*.conf'
copy_in /etc/fail2ban/filter.d       etc/fail2ban/filter.d  -name '*.local'
copy_in /etc/ssh/sshd_config         etc/ssh
copy_in /etc/ssh/sshd_config.d       etc/ssh/sshd_config.d  -name '*.conf'

# misc
copy_in /etc/docker/daemon.json      etc/docker
copy_in /etc/fstab                   etc
copy_in /etc/dnf/automatic.conf      etc/dnf

# Python ingest pipeline
copy_in "$INGEST_DIR" scripts/ingest \
  \( -name '*.py' -o -name '*.sh' -o -name '*.toml' -o -name '*.cfg' -o -name '*.json' \) \
  ! -path '*/.venv/*' ! -path '*/__pycache__/*'

# systemd units you wrote yourself (not vendor ones)
copy_in /etc/systemd/system etc/systemd/system -maxdepth 1 \( -name '*.service' -o -name '*.timer' \)

# ---------------------------------------------------------------- metadata

echo "Writing metadata..."

{
  printf 'source_path\tmode\towner\tgroup\tselinux_context\n'
  for f in "${copied[@]}"; do
    stat -c $'%n\t%a\t%U\t%G' "$f" 2>/dev/null | tr -d '\n'
    printf '\t%s\n' "$(stat -c '%C' "$f" 2>/dev/null || echo '-')"
  done | sort
} >"$REPO/meta/manifest.tsv"

# Secret variable NAMES only — values never leave the host
{
  echo "# Variable names present in untracked env files. Values intentionally omitted."
  for d in $COMPOSE_DIRS; do
    for e in "$d"/.env "$d"/*.env; do
      [[ -f "$e" ]] || continue
      echo "--- $e"
      grep -oE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=' "$e" \
        | tr -d ' =' | sort
    done
  done
} >"$REPO/meta/env-keys.txt"

# Versions — so upgrades and image drift show up as diff lines
{
  echo "# Refreshed $(date -u '+%Y-%m-%d %H:%MZ')"
  echo "## os"
  grep -E '^(NAME|VERSION_ID)=' /etc/os-release
  echo "kernel=$(uname -r)"
  echo
  echo "## packages"
  rpm -q nginx fail2ban samba openssh-server docker-ce containerd.io git 2>/dev/null | sort
  echo
  echo "## container images (digest-pinned view)"
  docker ps --format '{{.Names}}' 2>/dev/null | while read -r c; do
    img=$(docker inspect "$c" --format '{{.Config.Image}}' 2>/dev/null)
    dig=$(docker inspect "$c" --format '{{index .Image}}' 2>/dev/null)
    echo "$c  image=$img  id=$dig"
  done | sort
  echo
  echo "## selinux"
  echo "mode=$(getenforce 2>/dev/null)"
  semanage boolean -l -C 2>/dev/null | sed 's/^/boolean: /'
  semanage fcontext -l -C 2>/dev/null | sed 's/^/fcontext: /'
} >"$REPO/meta/versions.txt"

# Keep a copy of this script with the repo
cp -p "$0" "$REPO/homelab-config-sync.sh" 2>/dev/null || true

# ---------------------------------------------------------------- report

cd "$REPO" || exit 1
git add -A

if git diff --cached --quiet; then
  echo
  echo "No changes since last sync."
  exit 0
fi

echo
echo "===== changed since last commit ====="
git diff --cached --stat
echo

if [[ $DO_COMMIT -eq 1 ]]; then
  if git commit -q -m "$COMMIT_MSG"; then
    echo "Committed: $(git log -1 --oneline)"
  else
    echo "Commit blocked (see above). Nothing committed; changes remain staged."
    exit 1
  fi
else
  echo "Staged but not committed. To commit:"
  echo "  sudo git -C $REPO commit -m \"what changed and why\""
  echo
  echo "To see the full diff:"
  echo "  sudo git -C $REPO diff --cached"
fi
