# shellcheck shell=bash
# shellcheck disable=SC2034  # variables read by the library functions under test
# qbittorrent.sh: the PBKDF2 hash against Python's hashlib, the API key
# format, and qBittorrent.conf as written for a first run and for the
# previous image's configuration.

# shellcheck source=/dev/null
. "$QBTVPN_LIB/qbittorrent.sh"

python_pbkdf2() {
  python3 - "$1" "$2" <<'EOF'
import base64, hashlib, sys
password, salt_hex = sys.argv[1], sys.argv[2]
salt = bytes.fromhex(salt_hex)
key = hashlib.pbkdf2_hmac("sha512", password.encode("utf-8"), salt, 100000, 64)
print(base64.b64encode(salt).decode() + ":" + base64.b64encode(key).decode())
EOF
}

conf_setup() {
  QBT_DIR="$QBTVPN_RUN/config/qBittorrent"
  QBT_CONF="$QBT_DIR/config/qBittorrent.conf"
  QBT_WEBUI_SECTION_NEW=yes
  CFG_VPN_ENABLED=yes
  CFG_WEBUI_PORT=8080
  CFG_INCOMING_PORT=""
  CFG_WEBUI_USERNAME=""
  CFG_WEBUI_PASSWORD=""
  CFG_WEBUI_CSRF=""
  CFG_PF_MODE=off
  CFG_PUID=99
  CFG_PGID=100
  FW_TUN=wg0
}

section_of() {
  SECTION="$2" awk '/^\[.*\]$/ { cur = substr($0, 2, length($0) - 2); next } cur == ENVIRON["SECTION"]' "$1"
}

test_pbkdf2_matches_python_hashlib() {
  local pw salt
  for pw in 'adminadmin' 'pässwörd with spaces & symbols:;"' "$(printf 'x%.0s' {1..200})"; do
    salt=$(openssl rand -hex 16)
    assert_eq "$(python_pbkdf2 "$pw" "$salt")" "$(qbt_pbkdf2 "$pw" "$salt")" "password '${pw:0:20}'"
  done
}

test_password_matches_its_own_stored_form() {
  local stored
  stored="\"@ByteArray($(qbt_pbkdf2 'correct horse' "$(openssl rand -hex 16)"))\""
  assert_succeeds qbt_password_matches "$stored" 'correct horse'
  assert_fails qbt_password_matches "$stored" 'wrong horse'
  assert_fails qbt_password_matches 'garbage' 'correct horse'
}

test_api_key_has_qbittorrents_format() {
  local key
  key=$(qbt_generate_api_key)
  # Alphabet and length from qBittorrent's src/base/utils/password.cpp and apikey.cpp.
  [[ "$key" =~ ^qbt_[23456789ABCDEFGHIJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz]{28}$ ]] || { echo "bad key ${key}"; return 1; }
  assert_fails test "$key" = "$(qbt_generate_api_key)"
}

test_first_run_writes_the_5_3_layout() {
  conf_setup
  qbt_write_config 51413 2>/dev/null
  assert_eq 'Accepted=true' "$(section_of "$QBT_CONF" LegalNotice)"
  local webui bt
  webui=$(section_of "$QBT_CONF" WebUI)
  bt=$(section_of "$QBT_CONF" BitTorrent)
  assert_contains 'Port=8080' "$webui"
  assert_contains 'UseUPnP=false' "$webui"
  assert_contains 'CSRFProtection=true' "$webui"
  assert_contains 'Session\Interface=wg0' "$bt"
  assert_contains 'Session\InterfaceName=wg0' "$bt"
  assert_contains 'Session\InterfaceAddress=' "$bt"
  assert_contains 'Session\Port=51413' "$bt"
  assert_contains 'Session\DefaultSavePath=/downloads/' "$bt"
  assert_contains 'Session\TempPath=/downloads/temp/' "$bt"
  assert_eq 'PortForwardingEnabled=false' "$(section_of "$QBT_CONF" Network)"
  assert_eq 51413 "$QBT_LISTEN_PORT"
}

test_previous_image_config_is_migrated_and_kept() {
  conf_setup
  mkdir -p "$(dirname "$QBT_CONF")"
  cp "$FIXTURES/qbittorrent/legacy-image-template.conf" "$QBT_CONF"
  CFG_WEBUI_PORT=9090
  qbt_write_config "" 2>/dev/null
  local prefs
  prefs=$(section_of "$QBT_CONF" Preferences)
  assert_not_contains 'WebUI\Port=' "$prefs"
  assert_not_contains 'WebUI\UseUPnP=' "$prefs"
  assert_not_contains 'Connection\UPnP=' "$prefs"
  assert_contains 'Downloads\SavePath=/downloads/' "$prefs"
  assert_contains 'WebUI\CSRFProtection=false' "$prefs"
  assert_contains 'Port=9090' "$(section_of "$QBT_CONF" WebUI)"
  assert_contains 'Session\Interface=wg0' "$(section_of "$QBT_CONF" BitTorrent)"
}

test_legacy_layout_for_qbittorrent_before_5_3() {
  conf_setup
  QBT_WEBUI_SECTION_NEW=no
  qbt_write_config "" 2>/dev/null
  assert_contains 'WebUI\Port=8080' "$(section_of "$QBT_CONF" Preferences)"
  assert_eq "" "$(section_of "$QBT_CONF" WebUI)"
}

test_passthrough_is_applied_but_cannot_override_enforced_keys() {
  conf_setup
  export QBT_CONF_BitTorrent__Session__MaxConnections=500
  export QBT_CONF_BitTorrent__Session__Interface=eth0
  export QBT_CONF_Preferences__General__Locale=de
  qbt_write_config "" 2>"$QBTVPN_RUN/log"
  local bt
  bt=$(section_of "$QBT_CONF" BitTorrent)
  assert_contains 'Session\MaxConnections=500' "$bt"
  assert_contains 'Session\Interface=wg0' "$bt"
  assert_not_contains 'Session\Interface=eth0' "$bt"
  assert_contains 'General\Locale=de' "$(section_of "$QBT_CONF" Preferences)"
  assert_contains 'which the container manages; ignored' "$(cat "$QBTVPN_RUN/log")"
}

test_webui_credentials_and_csrf_come_from_env() {
  conf_setup
  CFG_WEBUI_USERNAME=operator
  CFG_WEBUI_PASSWORD='s3cret!'
  CFG_WEBUI_CSRF=no
  qbt_write_config "" 2>/dev/null
  local webui stored first
  webui=$(section_of "$QBT_CONF" WebUI)
  assert_contains 'Username=operator' "$webui"
  assert_contains 'CSRFProtection=false' "$webui"
  stored=$(qbt_webui_get Password_PBKDF2)
  assert_succeeds qbt_password_matches "$stored" 's3cret!'
  first="$stored"
  qbt_write_config "" 2>/dev/null
  assert_eq "$first" "$(qbt_webui_get Password_PBKDF2)" "an unchanged password is not rehashed"
}

test_vpn_disabled_clears_a_tunnel_binding() {
  conf_setup
  qbt_write_config "" 2>/dev/null
  CFG_VPN_ENABLED=no
  qbt_write_config "" 2>/dev/null
  assert_contains 'Session\Interface=' "$(section_of "$QBT_CONF" BitTorrent)"
  assert_not_contains 'Session\Interface=wg0' "$(section_of "$QBT_CONF" BitTorrent)"
}

test_api_key_generated_only_with_port_forwarding() {
  conf_setup
  qbt_write_config "" 2>/dev/null
  assert_eq "" "$(qbt_webui_get APIKey)"
  CFG_PF_MODE=auto
  qbt_write_config "" 2>/dev/null
  [[ "$(qbt_webui_get APIKey)" =~ ^qbt_ ]] || { echo "no API key written"; return 1; }
  assert_eq "$(qbt_webui_get APIKey)" "$QBT_API_KEY"
}
