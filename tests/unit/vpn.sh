# shellcheck shell=bash
# shellcheck disable=SC2034  # variables read by the library functions under test
# vpn.sh: vpn_prepare_tun against a stand-in device, with chgrp failing as it
# does when the device belongs to a user outside the container's namespace.

# shellcheck source=/dev/null
. "$QBTVPN_LIB/vpn.sh"

# tun_stand_in MODE: points TUN_DEV at a root-owned character device with MODE.
# QBTVPN_RUN is opened up so the vpn user can reach the device inside it.
tun_stand_in() {
  chmod 0755 "$QBTVPN_RUN"
  TUN_DEV="$QBTVPN_RUN/tun-$1"
  mknod -m "$1" "$TUN_DEV" c 1 3
}

# chgrp as it fails under rootless Docker or Podman.
foreign_owner() {
  # shellcheck disable=SC2329  # called by vpn_prepare_tun
  chgrp() {
    echo "chgrp: $2: Operation not permitted" >&2
    return 1
  }
}

test_tun_device_goes_to_the_vpn_group() {
  tun_stand_in 0666
  vpn_prepare_tun
  assert_eq vpn:660 "$(stat -c %G:%a "$TUN_DEV")"
}

test_tun_device_owned_outside_the_namespace_is_used_as_it_is() {
  tun_stand_in 0666
  foreign_owner
  vpn_prepare_tun 2>"$QBTVPN_RUN/log"
  assert_eq root:666 "$(stat -c %G:%a "$TUN_DEV")" "left as it is"
  assert_contains "outside this container's user namespace" "$(cat "$QBTVPN_RUN/log")"
  assert_contains "using it as it is, mode 666" "$(cat "$QBTVPN_RUN/log")"
}

test_tun_device_the_vpn_user_cannot_open_stops_start_up() {
  tun_stand_in 0600
  foreign_owner
  assert_fails vpn_prepare_tun
  if (vpn_prepare_tun) 2>"$QBTVPN_RUN/log"; then
    echo "vpn_prepare_tun succeeded with a device the vpn user cannot open"
    return 1
  fi
  assert_contains "the vpn user cannot open ${TUN_DEV}" "$(cat "$QBTVPN_RUN/log")"
  assert_contains "Operation not permitted" "$(cat "$QBTVPN_RUN/log")"
  assert_contains "chmod 0666 /dev/net/tun" "$(cat "$QBTVPN_RUN/log")"
}
