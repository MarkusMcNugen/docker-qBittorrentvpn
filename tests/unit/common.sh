# shellcheck shell=bash
# shellcheck disable=SC2034  # variables read by the library functions under test
# common.sh helpers, with Python's ipaddress module as the oracle for the
# IPv4 arithmetic.

test_cidr_contains_matches_python() {
  local cases expected got cidr ip
  cases=$'10.0.0.0/8 10.255.255.255\n10.0.0.0/8 11.0.0.0\n172.16.0.0/12 172.31.1.1\n172.16.0.0/12 172.32.0.1\n192.168.1.0/24 192.168.1.255\n192.168.1.0/24 192.168.2.1\n0.0.0.0/0 8.8.8.8\n203.0.113.5/32 203.0.113.5\n203.0.113.5/32 203.0.113.6\n100.64.0.0/10 100.127.255.255'
  while read -r cidr ip; do
    expected=$(python3 -c 'import ipaddress,sys; print("yes" if ipaddress.ip_address(sys.argv[2]) in ipaddress.ip_network(sys.argv[1]) else "no")' "$cidr" "$ip")
    if cidr_contains "$cidr" "$ip"; then got=yes; else got=no; fi
    assert_eq "$expected" "$got" "${ip} in ${cidr}"
  done <<<"$cases"
}

test_cidr_normalize_matches_python() {
  local c expected
  for c in 192.168.1.77/24 10.1.2.3/8 172.20.5.9/12 203.0.113.9/32 1.2.3.4/0 192.168.255.255/17; do
    expected=$(python3 -c 'import ipaddress,sys; print(ipaddress.ip_network(sys.argv[1], strict=False))' "$c")
    assert_eq "$expected" "$(cidr_normalize "$c")" "$c"
  done
}

test_is_ipv4_edges() {
  local ip
  for ip in 0.0.0.0 255.255.255.255 10.0.0.1 192.168.1.1 203.0.113.250; do
    assert_succeeds is_ipv4 "$ip"
    assert_eq "$ip" "$(python3 -c 'import ipaddress,sys; print(ipaddress.IPv4Address(sys.argv[1]))' "$ip")" "python agrees on ${ip}"
  done
  for ip in 256.1.1.1 1.2.3 1.2.3.4.5 a.b.c.d '' 1.2.3.-4 192.168.001.1 01.2.3.4; do
    assert_fails is_ipv4 "$ip"
    assert_fails python3 -c 'import ipaddress,sys; ipaddress.IPv4Address(sys.argv[1])' "$ip"
  done
}

test_is_private_ipv4() {
  local ip
  for ip in 10.1.1.1 172.31.255.1 192.168.0.1 100.100.0.1 169.254.1.1 127.0.0.1; do
    assert_succeeds is_private_ipv4 "$ip"
  done
  for ip in 8.8.8.8 172.32.0.1 192.169.0.1 100.128.0.1; do
    assert_fails is_private_ipv4 "$ip"
  done
}

test_split_list_trims_and_skips_empty_items() {
  assert_eq $'a\nb c\nd' "$(split_list ' a ,b c,, d ,')"
  assert_eq "" "$(split_list '')"
}

test_bool_value_spellings() {
  local v
  for v in yes Yes TRUE 1 on enabled; do assert_eq yes "$(bool_value "$v")" "$v"; done
  for v in no NO false 0 off disabled; do assert_eq no "$(bool_value "$v")" "$v"; done
  assert_fails bool_value maybe
}

test_env_secret_reads_the_file_without_trailing_newline() {
  printf 's3cr3t with spaces\n\n' >"$QBTVPN_RUN/secret"
  unset MYSECRET
  MYSECRET_FILE="$QBTVPN_RUN/secret"
  assert_eq 's3cr3t with spaces' "$(env_secret MYSECRET)"
  MYSECRET=direct
  assert_fails env_secret MYSECRET
}
