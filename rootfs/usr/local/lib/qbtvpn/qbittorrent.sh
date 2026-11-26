# shellcheck shell=bash
# qBittorrent: writes qBittorrent.conf before each start (first-run defaults,
# the settings the container enforces, credentials and QBT_CONF_* values),
# starts qbittorrent-nox as PUID:PGID with no capabilities, and changes its
# listen port at run time through the WebUI API.
#
# qBittorrent 5.3 moved the WebUI keys from [Preferences] WebUI\<key> to
# [WebUI] <key>, and on first start it copies every legacy key over its new
# one. Each enforced key is therefore written in the layout the installed
# binary reads, and its legacy copy is deleted.

QBT_PROFILE=/config
QBT_DIR=/config/qBittorrent
QBT_CONF=/config/qBittorrent/config/qBittorrent.conf
QBT_PID=""
QBT_VERSION=""
QBT_WEBUI_SECTION_NEW=yes
QBT_API_KEY=""
QBT_OPS=""
QBT_LISTEN_PORT=""
declare -A QBT_ENFORCED=()

version_ge() {
  local -a a b
  local i
  IFS=. read -r -a a <<<"$1"
  IFS=. read -r -a b <<<"$2"
  for i in 0 1 2; do
    if [ "$((10#${a[i]:-0}))" -gt "$((10#${b[i]:-0}))" ]; then return 0; fi
    if [ "$((10#${a[i]:-0}))" -lt "$((10#${b[i]:-0}))" ]; then return 1; fi
  done
  return 0
}

qbt_detect_version() {
  QBT_VERSION=$(qbittorrent-nox --version 2>&1 | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^v[0-9]+\.[0-9]+\.[0-9]+/) { sub(/^v/, "", $i); print $i; exit } }')
  [ -n "$QBT_VERSION" ] || die "qbittorrent: cannot read the version of qbittorrent-nox"
  if version_ge "$QBT_VERSION" 5.3.0; then QBT_WEBUI_SECTION_NEW=yes; else QBT_WEBUI_SECTION_NEW=no; fi
  log_info "qbittorrent: qbittorrent-nox ${QBT_VERSION}"
}

# qbt_op OP SECTION KEY [VALUE]: queues one operation for qbt-ini.awk. The
# first operation for a key wins, so enforced settings are queued first.
qbt_op() {
  if [ "$1" = set ]; then
    printf 'set\t%s\t%s\t%s\n' "$2" "$3" "$4" >>"$QBT_OPS"
  else
    printf 'del\t%s\t%s\n' "$2" "$3" >>"$QBT_OPS"
  fi
}

qbt_enforce() {
  QBT_ENFORCED["$2"$'\t'"$3"]=1
  qbt_op "$@"
}

# WebUI key in the layout the installed qBittorrent reads.
qbt_webui() {
  local op="$1" key="$2" value="${3-}"
  if [ "$QBT_WEBUI_SECTION_NEW" = yes ]; then
    qbt_enforce "$op" WebUI "$key" "$value"
    qbt_enforce del Preferences "WebUI\\${key}"
  else
    qbt_enforce "$op" Preferences "WebUI\\${key}" "$value"
  fi
}

# Session key under [BitTorrent], with the legacy [Preferences] key it replaced.
qbt_session() {
  qbt_enforce set BitTorrent "Session\\$1" "$2"
  if [ -n "${3-}" ]; then qbt_enforce del Preferences "$3"; fi
}

# qbt_ini_get SECTION KEY: prints the value of KEY in SECTION, or nothing.
qbt_ini_get() {
  [ -r "$QBT_CONF" ] || return 0
  SECTION="$1" KEY="$2" awk '
    { sub(/\r$/, "") }
    /^\[.*\][ \t]*$/ { s = $0; sub(/[ \t]+$/, "", s); cur = substr(s, 2, length(s) - 2); next }
    cur == ENVIRON["SECTION"] && index($0, ENVIRON["KEY"] "=") == 1 { print substr($0, length(ENVIRON["KEY"]) + 2); exit }' "$QBT_CONF"
}

qbt_webui_get() {
  local v
  v=$(qbt_ini_get WebUI "$1")
  if [ -z "$v" ]; then v=$(qbt_ini_get Preferences "WebUI\\$1"); fi
  printf '%s' "$v"
}

hex_of() { od -An -tx1 -v | tr -d ' \n'; }

# qbt_pbkdf2 PASSWORD SALT_HEX: prints base64(salt):base64(key), the format
# qBittorrent stores: PBKDF2-HMAC-SHA512, 100000 iterations, 64-byte key.
qbt_pbkdf2() {
  local pass_hex salt_b64 key_b64
  pass_hex=$(printf '%s' "$1" | hex_of)
  key_b64=$(openssl kdf -keylen 64 -kdfopt digest:SHA512 -kdfopt "hexpass:${pass_hex}" \
    -kdfopt "hexsalt:$2" -kdfopt iter:100000 -binary PBKDF2 | base64 | tr -d '\n')
  salt_b64=$(qbt_hex_to_base64 "$2")
  printf '%s:%s' "$salt_b64" "$key_b64"
}

qbt_hex_to_base64() {
  local hex="$1" esc="" i
  for ((i = 0; i < ${#hex}; i += 2)); do esc+="\\x${hex:i:2}"; done
  printf '%b' "$esc" | base64 | tr -d '\n'
}

# True when the stored PBKDF2 value matches PASSWORD.
qbt_password_matches() {
  local stored="$1" pass="$2" inner salt_b64 salt_hex
  inner="${stored#\"@ByteArray(}"
  inner="${inner%)\"}"
  [ "$inner" != "$stored" ] || return 1
  salt_b64="${inner%%:*}"
  salt_hex=$(printf '%s' "$salt_b64" | base64 -d | hex_of) || return 1
  [ "$(qbt_pbkdf2 "$pass" "$salt_hex")" = "$inner" ]
}

qbt_generate_api_key() {
  local alphabet=23456789ABCDEFGHIJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz key="qbt_" i
  for ((i = 0; i < 28; i++)); do key+="${alphabet:SRANDOM % ${#alphabet}:1}"; done
  printf '%s' "$key"
}

# Builds and applies every qBittorrent.conf operation for this start.
# $1 is the listen port to set, or empty to keep the configured one.
qbt_write_config() {
  local listen_port="$1" first_run=no name rest section key value stored salt_hex current
  mkdir -p "$QBT_DIR/config" "$QBT_DIR/data"
  if [ ! -e "$QBT_CONF" ]; then
    first_run=yes
    : >"$QBT_CONF"
    log_info "qbittorrent: creating ${QBT_CONF}"
  fi
  QBT_OPS="$QBTVPN_RUN/qbittorrent.ops"
  : >"$QBT_OPS"
  QBT_ENFORCED=()

  qbt_enforce set LegalNotice Accepted true
  qbt_webui set Port "$CFG_WEBUI_PORT"
  if [ "$CFG_VPN_ENABLED" = yes ]; then
    qbt_session Interface "$FW_TUN" "Connection\\Interface"
    qbt_session InterfaceName "$FW_TUN" "Connection\\InterfaceName"
    qbt_session InterfaceAddress "" "Connection\\InterfaceAddress"
    qbt_enforce set Network PortForwardingEnabled false
    qbt_enforce del Preferences "Connection\\UPnP"
    qbt_webui set UseUPnP false
  else
    current=$(qbt_ini_get BitTorrent 'Session\Interface')
    case "$current" in
      tun[0-9]* | tap[0-9]* | wg[0-9]*)
        qbt_session Interface "" "Connection\\Interface"
        qbt_session InterfaceName "" "Connection\\InterfaceName"
        qbt_session InterfaceAddress "" "Connection\\InterfaceAddress"
        log_info "qbittorrent: VPN disabled; cleared the binding to ${current}"
        ;;
    esac
  fi
  if [ -n "$listen_port" ]; then
    qbt_session Port "$listen_port" "Connection\\PortRangeMin"
    qbt_session UseRandomPort false "General\\UseRandomPort"
  fi
  if [ -n "$CFG_WEBUI_USERNAME" ]; then
    qbt_webui set Username "$CFG_WEBUI_USERNAME"
  fi
  if [ -n "$CFG_WEBUI_PASSWORD" ]; then
    stored=$(qbt_webui_get Password_PBKDF2)
    if [ -n "$stored" ] && qbt_password_matches "$stored" "$CFG_WEBUI_PASSWORD"; then
      log_debug "qbittorrent: WebUI password already matches WEBUI_PASSWORD"
    else
      salt_hex=$(openssl rand -hex 16)
      qbt_webui set Password_PBKDF2 "\"@ByteArray($(qbt_pbkdf2 "$CFG_WEBUI_PASSWORD" "$salt_hex"))\""
      log_info "qbittorrent: WebUI password set from WEBUI_PASSWORD"
    fi
  fi
  if [ -n "$CFG_WEBUI_CSRF" ]; then
    if [ "$CFG_WEBUI_CSRF" = yes ]; then qbt_webui set CSRFProtection true; else qbt_webui set CSRFProtection false; fi
  fi
  QBT_API_KEY=""
  if [ "$QBT_WEBUI_SECTION_NEW" = yes ]; then
    QBT_API_KEY=$(qbt_webui_get APIKey)
    if [ -z "$QBT_API_KEY" ] && [ "$CFG_VPN_ENABLED" = yes ] && [ "$CFG_PF_MODE" != off ]; then
      QBT_API_KEY=$(qbt_generate_api_key)
      qbt_webui set APIKey "$QBT_API_KEY"
      log_info "qbittorrent: generated a WebUI API key so forwarded-port changes apply without a restart (WebUI > Options > WebUI shows it)"
    fi
  fi

  while IFS= read -r name; do
    rest="${name#QBT_CONF_}"
    [[ "$rest" == *__* ]] || { log_warn "qbittorrent: ${name} needs the form QBT_CONF_<Section>__<Key>; ignored"; continue; }
    section="${rest%%__*}"
    key="${rest#*__}"
    key="${key//__/\\}"
    value="${!name}"
    if [ -n "${QBT_ENFORCED["$section"$'\t'"$key"]-}" ]; then
      log_warn "qbittorrent: ${name} sets [${section}] ${key}, which the container manages; ignored"
      continue
    fi
    qbt_op set "$section" "$key" "$value"
    log_info "qbittorrent: [${section}] ${key} set from ${name}"
  done < <(compgen -e | awk '/^QBT_CONF_/' | sort)

  if [ "$first_run" = yes ]; then
    qbt_session DefaultSavePath /downloads/ "Downloads\\SavePath"
    qbt_session TempPath /downloads/temp/ "Downloads\\TempPath"
    qbt_session TempPathEnabled true "Downloads\\TempPathEnabled"
    qbt_session Port "${listen_port:-8999}" "Connection\\PortRangeMin"
    qbt_webui set CSRFProtection true
    qbt_webui set HostHeaderValidation true
    qbt_webui set ClickjackingProtection true
  fi

  awk -v OPS="$QBT_OPS" -f "$QBTVPN_LIB/qbt-ini.awk" <"$QBT_CONF" >"$QBT_CONF.qbtvpn"
  chown "$CFG_PUID:$CFG_PGID" "$QBT_CONF.qbtvpn"
  chmod 0600 "$QBT_CONF.qbtvpn"
  mv -f "$QBT_CONF.qbtvpn" "$QBT_CONF"
  QBT_LISTEN_PORT=$(qbt_ini_get BitTorrent 'Session\Port')
  [ -n "$QBT_LISTEN_PORT" ] || QBT_LISTEN_PORT=8999
  log_info "qbittorrent: listen port ${QBT_LISTEN_PORT}, WebUI port ${CFG_WEBUI_PORT}"
}

# Gives PUID:PGID ownership of the profile and checks /downloads is writable.
qbt_prepare_ownership() {
  local changed
  mkdir -p "$QBT_DIR/config" "$QBT_DIR/data"
  changed=$(find "$QBT_DIR" \( ! -user "$CFG_PUID" -o ! -group "$CFG_PGID" \) -print -exec chown -h "$CFG_PUID:$CFG_PGID" {} + | wc -l)
  if [ "$changed" -gt 0 ]; then
    log_info "qbittorrent: gave ${changed} file(s) under ${QBT_DIR} to ${CFG_PUID}:${CFG_PGID}"
  fi
  if [ -d /downloads ] && ! setpriv --reuid="$CFG_PUID" --regid="$CFG_PGID" --clear-groups -- test -w /downloads; then
    log_warn "qbittorrent: /downloads is not writable by ${CFG_PUID}:${CFG_PGID}; set PUID/PGID to its owner or change its ownership"
  fi
  if [ -w /etc/passwd ] && ! awk -F: -v u="$CFG_PUID" '$3 == u { found = 1 } END { exit !found }' /etc/passwd; then
    printf 'qbittorrent:x:%s:%s:qBittorrent:%s:/sbin/nologin\n' "$CFG_PUID" "$CFG_PGID" "$QBT_DIR" >>/etc/passwd
  fi
  if [ -w /etc/group ] && ! awk -F: -v g="$CFG_PGID" '$3 == g { found = 1 } END { exit !found }' /etc/group; then
    printf 'qbittorrent:x:%s:\n' "$CFG_PGID" >>/etc/group
  fi
}

qbt_start() {
  (
    umask "$CFG_UMASK"
    exec env -i HOME="$QBT_DIR" PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 TZ="${TZ-}" \
      setpriv --reuid="$CFG_PUID" --regid="$CFG_PGID" --clear-groups \
      --inh-caps=-all --ambient-caps=-all --bounding-set=-all --no-new-privs -- \
      qbittorrent-nox --profile="$QBT_PROFILE" --confirm-legal-notice
  ) &
  QBT_PID=$!
  log_info "qbittorrent: started as ${CFG_PUID}:${CFG_PGID} with no capabilities (pid ${QBT_PID})"
}

qbt_alive() { [ -n "$QBT_PID" ] && kill -0 "$QBT_PID" 2>/dev/null; }

# qbt_set_listen_port PORT: applies a new listen port to the running
# qBittorrent through its WebAPI. Returns 1 when the API cannot be used.
qbt_set_listen_port() {
  local port="$1" scheme=http out
  [ -n "$QBT_API_KEY" ] || return 1
  if [ "$(qbt_webui_get 'HTTPS\Enabled')" = true ]; then scheme=https; fi
  if ! out=$(curl -fsS --max-time 15 -k -H "Authorization: Bearer ${QBT_API_KEY}" \
    --data-urlencode "json={\"listen_port\":${port}}" \
    "${scheme}://127.0.0.1:${CFG_WEBUI_PORT}/api/v2/app/setPreferences" 2>&1); then
    log_warn "qbittorrent: WebAPI port change failed: ${out}"
    return 1
  fi
  log_info "qbittorrent: listen port set to ${port} through the WebAPI"
}

qbt_stop() {
  local i
  if qbt_alive; then
    log_info "qbittorrent: stopping (up to ${CFG_QBT_STOP_TIMEOUT} s to save resume data)"
    kill -TERM "$QBT_PID"
    for ((i = 0; i < CFG_QBT_STOP_TIMEOUT; i++)); do
      qbt_alive || break
      sleep 1
    done
    if qbt_alive; then
      log_warn "qbittorrent: still running after ${CFG_QBT_STOP_TIMEOUT} s; sending SIGKILL"
      kill -KILL "$QBT_PID"
    fi
    wait "$QBT_PID" 2>/dev/null
    log_info "qbittorrent: stopped"
  fi
  return 0
}
