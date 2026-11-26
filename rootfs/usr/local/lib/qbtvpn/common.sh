# shellcheck shell=bash
# Shared helpers: logging, booleans, lists, secrets, IPv4 arithmetic and the
# runtime state directory. Sourced by the entrypoint and its tools.

QBTVPN_RUN="${QBTVPN_RUN:-/run/qbtvpn}"
QBTVPN_LIB="${QBTVPN_LIB:-/usr/local/lib/qbtvpn}"
QBTVPN_SHARE="${QBTVPN_SHARE:-/usr/local/share/qbtvpn}"
QBTVPN_DEBUG="${QBTVPN_DEBUG:-0}"

log() {
  local level="$1"
  shift
  printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" >&2
}
log_debug() { if [ "$QBTVPN_DEBUG" = 1 ]; then log debug "$@"; fi; }
log_info() { log info "$@"; }
log_warn() { log warn "$@"; }
log_error() { log error "$@"; }

# Logs an error and exits the shell it runs in. Inside $( ) that is the
# subshell, whose failure set -e then turns into an exit of the caller.
die() {
  log error "$@"
  exit 1
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# Prints yes or no for the boolean spelled in $1; returns 2 for anything else.
bool_value() {
  case "${1,,}" in
    1 | y | yes | true | on | enable | enabled) printf 'yes' ;;
    0 | n | no | false | off | disable | disabled) printf 'no' ;;
    *) return 2 ;;
  esac
}

# env_bool NAME DEFAULT: prints yes or no for the variable NAME.
env_bool() {
  local name="$1" def="$2" raw
  raw=$(trim "${!name-}")
  [ -n "$raw" ] || raw="$def"
  bool_value "$raw" || die "${name} must be yes or no, not '${raw}'"
}

# env_uint NAME DEFAULT [MIN]: prints the non-negative integer in NAME.
env_uint() {
  local name="$1" def="$2" min="${3:-0}" raw
  raw=$(trim "${!name-}")
  [ -n "$raw" ] || raw="$def"
  [[ "$raw" =~ ^[0-9]+$ ]] || die "${name} must be a whole number, not '${raw}'"
  raw=$((10#$raw))
  [ "$raw" -ge "$min" ] || die "${name} must be at least ${min}, not ${raw}"
  printf '%s' "$raw"
}

# env_choice NAME DEFAULT CHOICE...: prints NAME, lowercased, if it is one of CHOICE.
env_choice() {
  local name="$1" def="$2" raw c
  shift 2
  raw=$(trim "${!name-}")
  [ -n "$raw" ] || raw="$def"
  raw="${raw,,}"
  for c in "$@"; do
    if [ "$raw" = "$c" ]; then
      printf '%s' "$raw"
      return 0
    fi
  done
  die "${name} must be one of: $*; not '${raw}'"
}

# env_secret NAME: prints NAME, or the contents of the file named by NAME_FILE
# with trailing newlines removed. Setting both is an error.
env_secret() {
  local name="$1" file_var="${1}_FILE" val file
  val="${!name-}"
  file="${!file_var-}"
  if [ -n "$file" ]; then
    [ -z "$val" ] || die "set ${name} or ${file_var}, not both"
    [ -r "$file" ] || die "${file_var}: cannot read ${file}"
    val=$(<"$file")
  fi
  printf '%s' "$val"
}

# first_set NAME...: prints the value of the first variable that is set and not empty.
first_set() {
  local name
  for name in "$@"; do
    if [ -n "${!name-}" ]; then
      trim "${!name}"
      return 0
    fi
  done
  return 0
}

# split_list STRING: prints each comma-separated item, trimmed, one per line.
split_list() {
  local -a parts=()
  local item
  IFS=, read -r -a parts <<<"$1"
  for item in "${parts[@]}"; do
    item=$(trim "$item")
    if [ -n "$item" ]; then
      printf '%s\n' "$item"
    fi
  done
  return 0
}

is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }

is_port() { is_uint "$1" && [ "$((10#$1))" -ge 1 ] && [ "$((10#$1))" -le 65535 ]; }

# Dotted-quad IPv4 with no leading zeros, which some parsers read as octal.
is_ipv4() {
  local octet='(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])'
  [[ "$1" =~ ^${octet}\.${octet}\.${octet}\.${octet}$ ]]
}

is_ipv6() { [[ "$1" == *:* ]] && [[ "$1" =~ ^[0-9A-Fa-f:.]+$ ]]; }

is_ipv4_cidr() {
  local ip="${1%/*}" len="${1##*/}"
  [[ "$1" == */* ]] && is_ipv4 "$ip" && [[ "$len" =~ ^[0-9]{1,2}$ ]] && [ "$((10#$len))" -le 32 ]
}

ipv4_to_int() {
  local a b c d
  IFS=. read -r a b c d <<<"$1"
  printf '%d' $(((10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d))
}

int_to_ipv4() {
  local n="$1"
  printf '%d.%d.%d.%d' $(((n >> 24) & 255)) $(((n >> 16) & 255)) $(((n >> 8) & 255)) $((n & 255))
}

cidr_mask() {
  local len="$1"
  if [ "$len" -eq 0 ]; then
    printf '0'
  else
    printf '%d' $(((0xFFFFFFFF << (32 - len)) & 0xFFFFFFFF))
  fi
}

# cidr_normalize A.B.C.D/N: prints the network address with host bits cleared.
cidr_normalize() {
  local ip="${1%/*}" len="${1##*/}" mask
  len=$((10#$len))
  mask=$(cidr_mask "$len")
  printf '%s/%d' "$(int_to_ipv4 $(($(ipv4_to_int "$ip") & mask)))" "$len"
}

# cidr_contains CIDR IP: true when IP is inside CIDR.
cidr_contains() {
  local net="${1%/*}" len="${1##*/}" mask
  len=$((10#$len))
  mask=$(cidr_mask "$len")
  [ $(($(ipv4_to_int "$net") & mask)) -eq $(($(ipv4_to_int "$2") & mask)) ]
}

# True for addresses that do not route on the public internet: RFC 1918,
# shared address space, link-local and loopback.
is_private_ipv4() {
  local ip="$1" net
  for net in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 169.254.0.0/16 127.0.0.0/8; do
    if cidr_contains "$net" "$ip"; then
      return 0
    fi
  done
  return 1
}

now() { printf '%s' "$EPOCHSECONDS"; }

# state_write NAME VALUE / state_read NAME: small files under QBTVPN_RUN/state.
state_write() {
  local dir="$QBTVPN_RUN/state"
  mkdir -p "$dir"
  printf '%s\n' "$2" >"$dir/$1.tmp"
  mv -f "$dir/$1.tmp" "$dir/$1"
}

state_read() {
  local f="$QBTVPN_RUN/state/$1"
  if [ -r "$f" ]; then
    cat "$f"
  fi
  return 0
}
