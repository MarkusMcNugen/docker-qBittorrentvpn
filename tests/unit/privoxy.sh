# shellcheck shell=bash
# shellcheck disable=SC2034  # variables read by the library functions under test
# privoxy.sh: the rendered configuration, Privoxy's own check of it, and how
# its log lines reach the container log.

# shellcheck source=/dev/null
. "$QBTVPN_LIB/privoxy.sh"

# The entrypoint makes QBTVPN_RUN 0755, so the privoxy user can reach its
# directory inside; the runner's mktemp directory starts at 0700.
setup() {
  chmod 0755 "$QBTVPN_RUN"
  CFG_PRIVOXY_PORT=8118
  CFG_PRIVOXY_CONF=()
  PRIVOXY_USER_DIR="$QBTVPN_RUN/config-privoxy"
}

test_default_config_uses_the_package_files_and_listens_on_every_address() {
  setup
  PRIVOXY_DIR="$QBTVPN_RUN/privoxy"
  local cfg
  cfg=$(privoxy_render_config)
  assert_eq 'confdir /etc/privoxy' "$(head -n 1 <<<"$cfg")" "confdir comes first"
  assert_contains $'actionsfile match-all.action\nactionsfile default.action\nactionsfile user.action\nfilterfile default.filter\nfilterfile user.filter' "$cfg"
  assert_contains 'listen-address 0.0.0.0:8118' "$cfg"
  assert_eq 1 "$(grep -c '^listen-address' <<<"$cfg")" "one listen address"
  assert_contains 'enable-remote-toggle 0' "$cfg"
  assert_contains 'enable-edit-actions 0' "$cfg"
}

test_user_files_replace_the_package_samples() {
  setup
  mkdir -p "$PRIVOXY_USER_DIR"
  printf '{ +block{test} }\n.example.invalid\n' >"$PRIVOXY_USER_DIR/user.action"
  privoxy_prepare 2>"$QBTVPN_RUN/log"
  local cfg
  cfg=$(cat "$PRIVOXY_DIR/config")
  assert_contains "actionsfile ${PRIVOXY_DIR}/user.action" "$cfg"
  assert_contains 'filterfile user.filter' "$cfg" "no user.filter given: the package's"
  assert_eq "$(cat "$PRIVOXY_USER_DIR/user.action")" "$(cat "$PRIVOXY_DIR/user.action")" "private copy"
  assert_eq privoxy "$(stat -c %U "$PRIVOXY_DIR/user.action")"
  assert_contains "privoxy: using ${PRIVOXY_USER_DIR}/user.action" "$(cat "$QBTVPN_RUN/log")"
}

test_conf_options_come_after_the_defaults() {
  setup
  PRIVOXY_DIR="$QBTVPN_RUN/privoxy"
  CFG_PRIVOXY_CONF=("socket-timeout 600" "forward .example.invalid 10.0.0.1:3128")
  local cfg
  cfg=$(privoxy_render_config)
  assert_line_order "$cfg" 'socket-timeout 300' 'socket-timeout 600'
  assert_eq 'forward .example.invalid 10.0.0.1:3128' "$(tail -n 1 <<<"$cfg")"
}

test_prepare_passes_privoxys_own_check_and_names_the_firewall_user() {
  setup
  CFG_PRIVOXY_PORT=8119
  privoxy_prepare 2>"$QBTVPN_RUN/log"
  assert_eq 874 "$FW_PRIVOXY_UID"
  assert_contains 'listen-address 0.0.0.0:8119' "$(cat "$PRIVOXY_DIR/config")"
  assert_eq "privoxy 700" "$(stat -c '%U %a' "$PRIVOXY_DIR")"
}

test_prepare_refuses_a_configuration_privoxy_refuses() {
  setup
  CFG_PRIVOXY_CONF=("actionsfile /nonexistent/missing.action")
  assert_fails privoxy_prepare
}

test_relay_drops_privoxys_timestamp_and_keeps_its_level() {
  local out
  out=$(printf '%s\n' '2026-11-26 05:40:00.123 7f2b1c3d4e5f Info: Listening on port 8118 on IP address 0.0.0.0' \
    '2026-11-26 05:40:01.000 7f2b1c3d4e5f Error: connect to example.invalid failed' \
    '2026-11-26 05:40:02.000 7f2b1c3d4e5f Fatal error: cannot bind' \
    'a line without a timestamp' | privoxy_relay 2>&1)
  assert_contains '[info] privoxy: Info: Listening on port 8118 on IP address 0.0.0.0' "$out"
  assert_contains '[error] privoxy: Error: connect to example.invalid failed' "$out"
  assert_contains '[error] privoxy: Fatal error: cannot bind' "$out"
  assert_contains '[info] privoxy: a line without a timestamp' "$out"
  assert_not_contains '7f2b1c3d4e5f' "$out"
}
