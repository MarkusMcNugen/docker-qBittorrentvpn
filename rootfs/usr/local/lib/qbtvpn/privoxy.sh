# shellcheck shell=bash
# Privoxy, the HTTP proxy started by PRIVOXY_ENABLED=yes. It runs as the
# privoxy user with no capabilities; the firewall accepts PRIVOXY_PORT from
# local networks only and lets Privoxy's own connections leave only through
# the tunnel, apart from DNS, which follows the container's DNS rules.

PRIVOXY_USER_DIR=/config/privoxy # the user's user.action and user.filter
PRIVOXY_DIR=""                   # private copy Privoxy reads
PRIVOXY_PID=""

# Prints Privoxy's main configuration: the package's default actions and
# filters, the user's own files when present, the listen address and
# PRIVOXY_CONF_ options last, so a single-valued option set there wins.
privoxy_render_config() {
  local line
  printf '%s\n' 'confdir /etc/privoxy' 'actionsfile match-all.action' 'actionsfile default.action'
  printf 'actionsfile %s\n' "$(privoxy_user_file user.action)"
  printf '%s\n' 'filterfile default.filter'
  printf 'filterfile %s\n' "$(privoxy_user_file user.filter)"
  printf 'listen-address 0.0.0.0:%s\n' "$CFG_PRIVOXY_PORT"
  printf '%s\n' 'toggle 1' 'enable-remote-toggle 0' 'enable-remote-http-toggle 0' 'enable-edit-actions 0' \
    'enforce-blocks 0' 'buffer-limit 4096' 'enable-proxy-authentication-forwarding 0' 'forwarded-connect-retries 0' \
    'accept-intercepted-requests 0' 'allow-cgi-request-crunching 0' 'split-large-forms 0' 'keep-alive-timeout 5' \
    'tolerate-pipelining 1' 'socket-timeout 300'
  for line in "${CFG_PRIVOXY_CONF[@]}"; do
    printf '%s\n' "$line"
  done
}

# privoxy_user_file NAME: the private copy of the user's NAME when there is
# one, else the package's own NAME in confdir.
privoxy_user_file() {
  if [ -f "$PRIVOXY_DIR/$1" ]; then printf '%s' "$PRIVOXY_DIR/$1"; else printf '%s' "$1"; fi
}

# Writes the private configuration and checks it with Privoxy itself. Sets
# FW_PRIVOXY_UID, which tells the firewall to add Privoxy's rules for
# PRIVOXY_PORT.
privoxy_prepare() {
  local f out
  PRIVOXY_DIR="$QBTVPN_RUN/privoxy"
  mkdir -p "$PRIVOXY_DIR"
  for f in user.action user.filter; do
    if [ -f "$PRIVOXY_USER_DIR/$f" ]; then
      cp "$PRIVOXY_USER_DIR/$f" "$PRIVOXY_DIR/$f"
      log_info "privoxy: using ${PRIVOXY_USER_DIR}/${f}"
    fi
  done
  privoxy_render_config >"$PRIVOXY_DIR/config"
  chown -R privoxy:privoxy "$PRIVOXY_DIR"
  chmod -R u=rwX,go= "$PRIVOXY_DIR"
  if ! out=$(privoxy_exec --config-test "$PRIVOXY_DIR/config" 2>&1); then
    die "privoxy: the configuration was refused: $(tr '\n' ' ' <<<"$out")"
  fi
  # shellcheck disable=SC2034  # read by firewall.sh
  FW_PRIVOXY_UID=$(id -u privoxy)
}

# privoxy_exec ARG...: runs privoxy as the privoxy user with no capabilities.
privoxy_exec() {
  env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin TZ="${TZ-}" \
    setpriv --reuid=privoxy --regid=privoxy --init-groups \
    --inh-caps=-all --ambient-caps=-all --bounding-set=-all --no-new-privs -- \
    privoxy --no-daemon "$@"
}

# Copies Privoxy's log lines into the container log at their level, without
# Privoxy's own timestamp and thread id.
privoxy_relay() {
  local line
  while IFS= read -r line; do
    if [[ "$line" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9:.]+\ [0-9a-fA-F]+\ (.*)$ ]]; then
      line="${BASH_REMATCH[1]}"
    fi
    case "$line" in
      "Fatal error: "* | "Error: "*) log_error "privoxy: ${line}" ;;
      *) log_info "privoxy: ${line}" ;;
    esac
  done
}

# Starts Privoxy, or logs and records why it cannot: without the VPN, or
# without the firewall's owner match, its traffic could not be kept in the
# tunnel.
privoxy_start() {
  local reason=""
  if [ "$CFG_VPN_ENABLED" != yes ]; then
    reason="VPN_ENABLED=no leaves no tunnel to keep its traffic in"
  elif [ "$FW_OWNER" != yes ]; then
    reason="the firewall's owner match is unavailable, so its traffic could not be kept in the tunnel"
  fi
  if [ -n "$reason" ]; then
    log_error "privoxy: not started: ${reason}"
    state_write privoxy "not started: ${reason}"
    return 0
  fi
  privoxy_exec "$PRIVOXY_DIR/config" > >(privoxy_relay) 2>&1 &
  PRIVOXY_PID=$!
  state_write privoxy "${CFG_PRIVOXY_PORT} ${PRIVOXY_PID}"
  log_info "privoxy: started as user privoxy with no capabilities on port ${CFG_PRIVOXY_PORT} (pid ${PRIVOXY_PID})"
}

privoxy_alive() { [ -n "$PRIVOXY_PID" ] && kill -0 "$PRIVOXY_PID" 2>/dev/null; }

# Restarts Privoxy when it has exited. Returns 1 while it should run and does not.
privoxy_supervise() {
  local status=0
  [ -n "$PRIVOXY_PID" ] || return 0
  privoxy_alive && return 0
  wait "$PRIVOXY_PID" 2>/dev/null || status=$?
  log_warn "privoxy: exited with status ${status}; restarting"
  privoxy_start
  sleep 1
  privoxy_alive
}

privoxy_stop() {
  if privoxy_alive; then
    kill -TERM "$PRIVOXY_PID"
    for _ in $(seq 1 10); do
      privoxy_alive || break
      sleep 1
    done
    if privoxy_alive; then
      log_warn "privoxy: still running after 10 s; sending SIGKILL"
      kill -KILL "$PRIVOXY_PID"
    fi
    wait "$PRIVOXY_PID" 2>/dev/null
    log_info "privoxy: stopped"
  fi
  PRIVOXY_PID=""
  return 0
}
