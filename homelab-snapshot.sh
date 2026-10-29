#!/usr/bin/env bash
# homelab-snapshot.sh
#
# Collects a redacted, paste-friendly security/config snapshot of an
# AlmaLinux 9 host running Jellyfin in Docker behind host-level nginx.
#
# Usage:
#   sudo ./homelab-snapshot.sh
#   sudo DOMAIN=media.example.com ./homelab-snapshot.sh
#   sudo COMPOSE_DIR=/srv/jellyfin MAXLINES=300 ./homelab-snapshot.sh
#
# Output: /tmp/homelab-snapshot-YYYYmmdd-HHMM.md
#
# REVIEW THE OUTPUT BEFORE PASTING IT ANYWHERE. Redaction is best-effort.

set -uo pipefail

COMPOSE_DIR="${COMPOSE_DIR:-/srv/jellyfin}"
JELLYFIN_URL="${JELLYFIN_URL:-http://127.0.0.1:8096}"
MEDIA_PATH="${MEDIA_PATH:-/media}"
MAXLINES="${MAXLINES:-200}"
DOMAIN="${DOMAIN:-}"
STAMP="$(date +%Y%m%d-%H%M)"
RAW="$(mktemp)"
OUT="/tmp/homelab-snapshot-${STAMP}.md"

if [[ $EUID -ne 0 ]]; then
  echo "Run with sudo — most of these commands need root." >&2
  exit 1
fi

trap 'rm -f "$RAW"' EXIT

# ---------- helpers ----------

section() { printf '\n\n## %s\n' "$1" >>"$RAW"; }

# run <label> <command...>
run() {
  local label="$1"; shift
  printf '\n### %s\n\n```\n' "$label" >>"$RAW"
  if ! command -v "${1}" >/dev/null 2>&1 && [[ "${1}" != "bash" ]]; then
    printf '(%s not installed)\n' "${1}" >>"$RAW"
  else
    { "$@" 2>&1 || true; } | head -n "$MAXLINES" >>"$RAW"
    local total
    total=$({ "$@" 2>&1 || true; } | wc -l)
    (( total > MAXLINES )) && printf '... [truncated: %s of %s lines]\n' "$MAXLINES" "$total" >>"$RAW"
  fi
  printf '```\n' >>"$RAW"
}

# runsh <label> <shell string>  — for pipelines
runsh() {
  local label="$1"; shift
  printf '\n### %s\n\n```\n' "$label" >>"$RAW"
  { bash -c "$*" 2>&1 || true; } | head -n "$MAXLINES" >>"$RAW"
  printf '```\n' >>"$RAW"
}

note() { printf '\n%s\n' "$1" >>"$RAW"; }

# ---------- header ----------

{
  echo "# Homelab snapshot — ${STAMP}"
  echo
  echo "Redaction: secrets by key name, SSH key bodies, public IPv4 addresses."
  [[ -n "$DOMAIN" ]] && echo "Domain \`$DOMAIN\` replaced with \`example.invalid\`."
} >"$RAW"

# ---------- 1. host & patch state ----------

section "Host and patch state"
runsh "identity" "hostnamectl; echo; uname -r; echo; uptime"
run  "os-release" cat /etc/os-release
runsh "pending updates" "dnf -q check-update; echo \"exit=\$?  (100 = updates available, 0 = none)\""
runsh "security updates" "dnf -q updateinfo list security 2>/dev/null || echo '(dnf updateinfo unavailable)'"
runsh "reboot required" "needs-restarting -r 2>/dev/null || echo '(needs-restarting not installed: dnf install dnf-utils)'"
runsh "services needing restart" "needs-restarting -s 2>/dev/null | head -20"
runsh "last 15 dnf transactions" "dnf history list 2>/dev/null | head -20"
runsh "installed kernels" "rpm -q kernel"
runsh "enabled repos" "dnf repolist --enabled"
runsh "automatic updates" "systemctl is-enabled dnf-automatic.timer 2>/dev/null; systemctl is-active dnf-automatic.timer 2>/dev/null; echo '---'; grep -E '^(upgrade_type|apply_updates)' /etc/dnf/automatic.conf 2>/dev/null || echo '(no automatic.conf)'"

# ---------- 2. exposure: what is actually listening ----------

section "Network exposure"
runsh "listening sockets" "ss -tulpnH | sort -k5"
run  "firewalld active zones" firewall-cmd --get-active-zones
run  "firewalld all zones" firewall-cmd --list-all-zones
run  "firewalld direct rules" firewall-cmd --direct --get-all-rules
runsh "nftables ruleset (first ${MAXLINES} lines)" "nft list ruleset 2>/dev/null | head -${MAXLINES} || echo '(nft unavailable)'"
runsh "ip forwarding / sysctl net" "sysctl net.ipv4.ip_forward net.ipv4.conf.all.accept_redirects net.ipv4.conf.all.send_redirects net.ipv6.conf.all.disable_ipv6 2>/dev/null"

# ---------- 3. docker & jellyfin ----------

section "Docker and Jellyfin"
run  "docker version" docker version --format '{{.Server.Version}} (API {{.Server.APIVersion}})'
runsh "compose version" "docker compose version 2>/dev/null || docker-compose version 2>/dev/null"
runsh "running containers" "docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'"
runsh "all containers incl. stopped" "docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'"
runsh "image digests" "docker images --digests --format 'table {{.Repository}}:{{.Tag}}\t{{.Digest}}\t{{.CreatedSince}}'"
runsh "compose config" "cd '${COMPOSE_DIR}' 2>/dev/null && docker compose config 2>&1 || echo '(no compose project at ${COMPOSE_DIR})'"

note "**Container hardening posture** — check for \`privileged: true\`, host networking, root user, and writable binds:"
runsh "container security fields" "for c in \$(docker ps -q); do
  docker inspect \"\$c\" --format '{{.Name}}
  image:      {{.Config.Image}}
  user:       {{if .Config.User}}{{.Config.User}}{{else}}(root){{end}}
  privileged: {{.HostConfig.Privileged}}
  netmode:    {{.HostConfig.NetworkMode}}
  capadd:     {{.HostConfig.CapAdd}}
  capdrop:    {{.HostConfig.CapDrop}}
  restart:    {{.HostConfig.RestartPolicy.Name}}
  readonly:   {{.HostConfig.ReadonlyRootfs}}
  ports:      {{.HostConfig.PortBindings}}
  mounts:     {{range .Mounts}}{{.Source}}->{{.Destination}}({{if .RW}}rw{{else}}ro{{end}}) {{end}}
'; done"

runsh "jellyfin version (public endpoint)" "curl -s --max-time 5 '${JELLYFIN_URL}/System/Info/Public' || echo '(no response from ${JELLYFIN_URL})'"
runsh "docker daemon config" "cat /etc/docker/daemon.json 2>/dev/null || echo '(no daemon.json)'"
runsh "docker socket perms" "ls -l /var/run/docker.sock; getent group docker"

# ---------- 4. nginx ----------

section "nginx / TLS"
runsh "nginx version and build" "nginx -v 2>&1; nginx -V 2>&1 | tr ' ' '\n' | grep -E 'with-|openssl' | head -20"
run  "config test" nginx -t
runsh "full config (nginx -T)" "nginx -T 2>/dev/null"
runsh "TLS certificate expiry" "find /etc/letsencrypt/live /etc/pki/tls/certs /etc/nginx -name '*.pem' -o -name '*.crt' 2>/dev/null | while read -r f; do
  exp=\$(openssl x509 -enddate -noout -in \"\$f\" 2>/dev/null | cut -d= -f2)
  subj=\$(openssl x509 -subject -noout -in \"\$f\" 2>/dev/null)
  [[ -n \"\$exp\" ]] && echo \"\$f | \$exp | \$subj\"
done | head -20"
runsh "certbot renewal timer" "systemctl list-timers --all 2>/dev/null | grep -iE 'certbot|renew' || echo '(no certbot timer)'"

# ---------- 5. SELinux ----------

section "SELinux"
run  "sestatus" sestatus
runsh "recent AVC denials (7 days)" "ausearch -m AVC,USER_AVC -ts week 2>/dev/null | tail -60 || echo '(no denials or auditd unavailable)'"
runsh "AVC summary" "aureport -a --summary 2>/dev/null | head -20 || echo '(aureport unavailable)'"
runsh "non-default booleans" "semanage boolean -l -C 2>/dev/null || echo '(no local boolean changes)'"
runsh "contexts on key paths" "ls -dZ ${MEDIA_PATH} ${MEDIA_PATH}/* ${COMPOSE_DIR} /etc/nginx 2>/dev/null | head -30"
runsh "local file context rules" "semanage fcontext -l -C 2>/dev/null || echo '(none)'"

# ---------- 6. fail2ban ----------

section "fail2ban"
runsh "version and status" "fail2ban-client version; echo; fail2ban-client status"
runsh "per-jail detail" "for j in \$(fail2ban-client status 2>/dev/null | sed -n 's/.*Jail list:\t*//p' | tr ',' ' '); do
  echo \"--- \$j ---\"; fail2ban-client status \"\$j\"; done"
runsh "jail.local" "cat /etc/fail2ban/jail.local 2>/dev/null || echo '(no jail.local)'"
runsh "jail.d fragments" "ls -1 /etc/fail2ban/jail.d/ 2>/dev/null && cat /etc/fail2ban/jail.d/*.conf 2>/dev/null"

# ---------- 7. samba ----------

section "Samba"
runsh "effective config" "testparm -s 2>/dev/null"
runsh "connections and shares" "smbstatus --shares 2>/dev/null; echo; smbstatus --brief 2>/dev/null"
runsh "samba accounts (names only)" "pdbedit -L 2>/dev/null | cut -d: -f1,2"
runsh "share path perms" "ls -ldZ ${MEDIA_PATH}/Shows 2>/dev/null"

# ---------- 8. ssh & accounts ----------

section "SSH and accounts"
runsh "effective sshd config (key settings)" "sshd -T 2>/dev/null | grep -iE '^(port|permitrootlogin|passwordauthentication|pubkeyauthentication|permitemptypasswords|challengeresponse|kbdinteractive|allowusers|allowgroups|denyusers|maxauthtries|logingracetime|x11forwarding|allowtcpforwarding|clientalive)' | sort"
runsh "authorized_keys inventory" "for h in /root /home/*; do
  f=\"\$h/.ssh/authorized_keys\"
  [[ -f \"\$f\" ]] && echo \"\$f: \$(grep -cvE '^\\s*(#|\$)' \"\$f\") key(s), perms \$(stat -c '%a %U:%G' \"\$f\")\"
done"
runsh "login accounts (uid>=1000)" "awk -F: '\$3>=1000 && \$3<65534 {print \$1, \$3, \$6, \$7}' /etc/passwd"
runsh "accounts with shells but no password set" "awk -F: '(\$2==\"\" ){print \$1\" HAS EMPTY PASSWORD\"}' /etc/shadow"
runsh "sudo/wheel members" "getent group wheel; grep -rhE '^[^#].*ALL' /etc/sudoers /etc/sudoers.d/ 2>/dev/null"
runsh "recent failed logins" "journalctl -u sshd --since '7 days ago' 2>/dev/null | grep -ciE 'failed password|invalid user' | xargs -I{} echo 'failed ssh attempts (7d): {}'; lastb -n 10 2>/dev/null | head -12"
runsh "current logins / last 10" "who; echo; last -n 10"

# ---------- 9. services & scheduled jobs ----------

section "Services and scheduled jobs"
runsh "enabled services" "systemctl list-unit-files --state=enabled --type=service --no-pager | head -60"
runsh "failed units" "systemctl --failed --no-pager"
runsh "timers" "systemctl list-timers --all --no-pager | head -30"
runsh "root crontab" "crontab -l 2>/dev/null || echo '(none)'"
runsh "user crontabs" "for u in \$(awk -F: '\$3>=1000 && \$3<65534 {print \$1}' /etc/passwd); do
  echo \"--- \$u ---\"; crontab -u \"\$u\" -l 2>/dev/null || echo '(none)'; done"
runsh "system cron dirs" "ls -1 /etc/cron.d/ /etc/cron.daily/ 2>/dev/null"

# ---------- 10. storage & data health ----------

section "Storage"
run  "block devices" lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,UUID
runsh "filesystem usage" "df -hT -x tmpfs -x devtmpfs"
runsh "mount options" "findmnt -no SOURCE,TARGET,FSTYPE,OPTIONS ${MEDIA_PATH} / 2>/dev/null"
runsh "fstab" "grep -vE '^\\s*(#|\$)' /etc/fstab"
runsh "LVM" "pvs 2>/dev/null; vgs 2>/dev/null; lvs 2>/dev/null"
runsh "SMART health" "for d in /dev/sd? /dev/nvme?n1; do
  [[ -b \"\$d\" ]] || continue
  echo \"--- \$d ---\"
  smartctl -H -A \"\$d\" 2>/dev/null | grep -iE 'overall-health|Reallocated|Current_Pending|Offline_Uncorrect|UDMA_CRC|Power_On_Hours|Temperature|Percentage Used|Media and Data' || echo '(smartctl unavailable)'
done"
runsh "smartd status" "systemctl is-enabled smartd 2>/dev/null; systemctl is-active smartd 2>/dev/null"

# ---------- 11. integrity & log spot-checks ----------

section "Spot checks"
runsh "world-writable files outside /tmp and /proc" "find / -xdev -type f -perm -0002 -not -path '/tmp/*' -not -path '/var/tmp/*' 2>/dev/null | head -20 || true"
runsh "unowned files" "find / -xdev \\( -nouser -o -nogroup \\) 2>/dev/null | head -20 || true"
runsh "setuid binaries" "find / -xdev -perm -4000 -type f 2>/dev/null | head -40"
runsh "rpm verify of key packages" "rpm -V nginx docker-ce fail2ban samba openssh-server 2>/dev/null | head -30 || echo '(clean or packages absent)'"
runsh "nginx 4xx/5xx counts (last 1000 lines)" "tail -1000 /var/log/nginx/access.log 2>/dev/null | awk '{print \$9}' | sort | uniq -c | sort -rn | head -10 || echo '(no access.log)'"

# ---------- redaction ----------

gawk_bin="$(command -v gawk || command -v awk)"

"$gawk_bin" -v domain="$DOMAIN" '
BEGIN { IGNORECASE = 1 }

function is_private(ip,   a) {
  split(ip, a, ".")
  if (a[1] == 10) return 1
  if (a[1] == 127) return 1
  if (a[1] == 0) return 1
  if (a[1] == 192 && a[2] == 168) return 1
  if (a[1] == 172 && a[2] >= 16 && a[2] <= 31) return 1
  if (a[1] == 169 && a[2] == 254) return 1
  if (a[1] >= 224) return 1
  return 0
}

{
  line = $0

  # secrets by key name
  gsub(/(password|passwd|secret|token|api[_-]?key|apikey|access[_-]?key|private[_-]?key|credential|client[_-]?secret|auth[_-]?key|smb[_-]?pass)[A-Za-z0-9_-]*[[:space:]]*[=:][[:space:]]*[^[:space:],;}"]+/, "&", line)
  if (match(line, /(password|passwd|secret|token|api[_-]?key|apikey|access[_-]?key|private[_-]?key|credential|client[_-]?secret|auth[_-]?key)[A-Za-z0-9_-]*[[:space:]]*[=:]/)) {
    pre = substr(line, 1, RSTART + RLENGTH - 1)
    line = pre " <REDACTED>"
  }

  # ssh public key bodies
  gsub(/(ssh-(rsa|ed25519|dss)|ecdsa-sha2-nistp[0-9]+)[[:space:]]+[A-Za-z0-9+\/=]{20,}/, "SSH-KEY <REDACTED>", line)

  # PEM bodies
  if (line ~ /-----BEGIN [A-Z ]*PRIVATE KEY-----/) { print "<REDACTED PRIVATE KEY BLOCK>"; skip = 1; next }
  if (skip) { if (line ~ /-----END/) skip = 0; next }

  # public IPv4
  tmp = line; out = ""
  while (match(tmp, /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/)) {
    ip = substr(tmp, RSTART, RLENGTH)
    out = out substr(tmp, 1, RSTART - 1) (is_private(ip) ? ip : "<PUBLIC-IP>")
    tmp = substr(tmp, RSTART + RLENGTH)
  }
  line = out tmp

  if (domain != "") gsub(domain, "example.invalid", line)

  print line
}
' "$RAW" >"$OUT"

chmod 600 "$OUT"

echo "Wrote $OUT ($(wc -l <"$OUT") lines, $(du -h "$OUT" | cut -f1))"
echo
echo "Next: skim it for anything the redactor missed, then paste it."
echo "  less $OUT"
echo "  grep -niE 'password|secret|token|key' $OUT"