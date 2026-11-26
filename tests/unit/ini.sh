# shellcheck shell=bash
# qbt-ini.awk against the qBittorrent.conf the previous image shipped.

legacy="$FIXTURES/qbittorrent/legacy-image-template.conf"

ini_apply() {
  printf '%s\n' "$@" >"$QBTVPN_RUN/ops"
  awk -v OPS="$QBTVPN_RUN/ops" -f "$QBTVPN_LIB/qbt-ini.awk" <"$legacy"
}

test_replaces_a_key_in_place() {
  local out
  out=$(ini_apply $'set\tPreferences\tWebUI\\Port\t9090')
  assert_contains 'WebUI\Port=9090' "$out"
  assert_not_contains 'WebUI\Port=8080' "$out"
  assert_eq "$(wc -l <"$legacy")" "$(wc -l <<<"$out")" "line count is unchanged"
  assert_line_order "$out" 'WebUI\LocalHostAuth=true' 'WebUI\Port=9090'
  assert_line_order "$out" 'WebUI\Port=9090' 'WebUI\ServerDomains=*'
}

test_deletes_every_occurrence() {
  local out
  out=$(ini_apply $'del\tPreferences\tWebUI\\Port' $'del\tPreferences\tConnection\\UPnP')
  assert_not_contains 'WebUI\Port=' "$out"
  assert_not_contains 'Connection\UPnP=' "$out"
  assert_eq $(($(wc -l <"$legacy") - 2)) "$(wc -l <<<"$out")"
}

test_adds_a_missing_section_at_the_end() {
  local out
  out=$(ini_apply $'set\tWebUI\tPort\t9090' $'set\tWebUI\tUseUPnP\tfalse' $'set\tLegalNotice\tAccepted\ttrue')
  assert_eq '[LegalNotice]' "$(tail -n 2 <<<"$out" | head -n 1)"
  assert_line_order "$out" '[WebUI]' 'Port=9090'
  assert_line_order "$out" 'Port=9090' 'UseUPnP=false'
  assert_line_order "$out" 'WebUI\Username=admin' '[WebUI]'
}

test_adds_a_missing_key_inside_its_section() {
  local out
  out=$(ini_apply $'set\tAutoRun\tenabled_extra\tyes')
  assert_line_order "$out" '[AutoRun]' 'enabled_extra=yes'
  assert_line_order "$out" 'enabled_extra=yes' '[Preferences]'
}

test_first_operation_for_a_key_wins() {
  local out
  out=$(ini_apply $'set\tPreferences\tWebUI\\Port\t1111' $'set\tPreferences\tWebUI\\Port\t2222' $'set\tNew\tk\ta' $'set\tNew\tk\tb')
  assert_contains 'WebUI\Port=1111' "$out"
  assert_not_contains '2222' "$out"
  assert_eq 1 "$(grep -c '^k=' <<<"$out")"
  assert_contains 'k=a' "$out"
}

test_untouched_lines_are_copied_exactly() {
  local out
  out=$(ini_apply $'set\tPreferences\tWebUI\\Port\t9090')
  assert_eq "$(grep -v '^WebUI\\Port=' "$legacy")" "$(grep -v '^WebUI\\Port=' <<<"$out")"
}

test_crlf_input_comes_out_lf() {
  local out
  awk '{ printf "%s\r\n", $0 }' "$legacy" >"$QBTVPN_RUN/crlf.conf"
  printf 'set\tPreferences\tWebUI\\Port\t9090\n' >"$QBTVPN_RUN/ops"
  out=$(awk -v OPS="$QBTVPN_RUN/ops" -f "$QBTVPN_LIB/qbt-ini.awk" <"$QBTVPN_RUN/crlf.conf")
  assert_not_contains $'\r' "$out"
  assert_contains 'WebUI\Port=9090' "$out"
}

test_values_with_quotes_and_parentheses_survive() {
  local out value='"@ByteArray(c2FsdA==:aGFzaA==)"'
  out=$(ini_apply "set	WebUI	Password_PBKDF2	${value}")
  assert_contains "Password_PBKDF2=${value}" "$out"
}
