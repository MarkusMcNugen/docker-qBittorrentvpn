# Reads an OpenVPN client configuration on standard input.
#
# MODE=parse prints one fact per line:
#   remote <host> <port> <proto>   each remote, with the global port and proto filled in
#   dev <value>                    the dev option, when present
#   auth-user-pass <file or ->     when present; - means no file argument
#   connection-block               when a <connection> block is present
#   secret                         when static-key mode is configured
#   pia                            when the configuration names Private Internet Access
#
# MODE=sanitize prints the configuration with every remote line replaced by
# the lines of the file named by REMOTES (at the first remote's position),
# with options the container manages, or that OpenVPN 2.7 rejects or ignores,
# removed or translated, and with paths under SRCDIR rewritten to DSTDIR. DROP_AUTH=1
# also removes auth-user-pass. Each change is reported on standard error.
#
# Inline blocks (<ca> ... </ca> and the like) are copied unchanged.

function note(msg) {
  if (!(msg in noted)) {
    noted[msg] = 1
    print "openvpn config: " msg > "/dev/stderr"
  }
}

function drop(opt, why) {
  note("removed '" opt "' (" why ")")
}

BEGIN {
  inblock = ""
  first_remote_done = 0
  nremotes = 0
  gport = ""
  gproto = ""
  if (MODE == "sanitize" && REMOTES != "") {
    while ((getline line < REMOTES) > 0) pinned[++npinned] = line
    close(REMOTES)
  }
  split("up down route-up route-pre-down ipchange learn-address client-connect client-disconnect tls-verify auth-user-pass-verify client-crresponse dns-updown script-security", a, " ")
  for (i in a) managed[a[i]] = "the container sets its own script hooks"
  split("user group chroot daemon log log-append syslog writepid status status-version management management-client-user management-client-group management-hold management-query-passwords cd iproute dev-node ifconfig-noexec route-noexec route-nopull dev dev-type", a, " ")
  for (i in a) managed[a[i]] = "managed by the container"
  split("mlock nice", a, " ")
  for (i in a) managed[a[i]] = "needs privileges the unprivileged OpenVPN process does not hold"
  split("keysize ncp-disable prng no-iv key-method client-cert-not-required memstats", a, " ")
  for (i in a) managed[a[i]] = "removed from OpenVPN"
  split("block-outside-dns register-dns ip-win32 route-method dhcp-renew dhcp-release dhcp-pre-release tap-sleep show-net-up win-sys windows-driver service allow-nonadmin", a, " ")
  for (i in a) managed[a[i]] = "Windows only"
  managed["remote-random-hostname"] = "remotes are pinned to resolved addresses"
  managed["redirect-gateway"] = "the container routes all traffic through the tunnel itself"
  managed["redirect-private"] = "the container routes all traffic through the tunnel itself"
  managed["persist-key"] = "OpenVPN 2.7 always keeps keys across restarts"
}

{
  sub(/\r$/, "")
  raw = $0

  if (inblock != "") {
    if (MODE == "sanitize") print raw
    t = raw
    gsub(/[ \t]/, "", t)
    if (t == "</" inblock ">") inblock = ""
    next
  }

  t = raw
  gsub(/^[ \t]+|[ \t]+$/, "", t)
  if (t ~ /^<[A-Za-z0-9-]+>$/) {
    inblock = substr(t, 2, length(t) - 2)
    if (inblock == "connection") {
      if (MODE == "parse") print "connection-block"
    }
    if (MODE == "sanitize") print raw
    next
  }

  if (t == "" || t ~ /^[#;]/) {
    if (MODE == "sanitize") print raw
    next
  }

  n = split(t, f, /[ \t]+/)
  opt = f[1]
  sub(/^--/, "", opt)
  lower = tolower(t)
  if (lower ~ /privacy\.network|privateinternetaccess/) is_pia = 1

  if (MODE == "parse") {
    if (opt == "remote") {
      nremotes++
      rhost[nremotes] = f[2]
      rport[nremotes] = (n >= 3 ? f[3] : "")
      rproto[nremotes] = (n >= 4 ? f[4] : "")
    } else if (opt == "port" || opt == "rport") {
      gport = f[2]
    } else if (opt == "proto") {
      gproto = f[2]
    } else if (opt == "dev") {
      print "dev " f[2]
    } else if (opt == "auth-user-pass") {
      print "auth-user-pass " (n >= 2 ? f[2] : "-")
    } else if (opt == "secret") {
      print "secret"
    }
    next
  }

  # MODE == "sanitize"
  if (opt == "remote") {
    if (!first_remote_done) {
      for (i = 1; i <= npinned; i++) print pinned[i]
      first_remote_done = 1
      note("remote lines pinned to " npinned " resolved address(es)")
    }
    next
  }
  if (opt in managed) {
    drop(opt, managed[opt])
    next
  }
  if (opt == "auth-user-pass" && DROP_AUTH == "1") {
    note("auth-user-pass replaced by VPN_USERNAME and VPN_PASSWORD")
    next
  }
  if (opt == "ns-cert-type" && n >= 2) {
    note("'ns-cert-type " f[2] "' translated to 'remote-cert-tls " f[2] "'")
    print "remote-cert-tls " f[2]
    next
  }
  if (opt == "tls-remote" && n >= 2) {
    rest = substr(t, index(t, f[2]))
    if (rest ~ /=/) {
      note("'tls-remote' translated to 'verify-x509-name ... subject'")
      print "verify-x509-name \"" rest "\" subject"
    } else {
      note("'tls-remote' translated to 'verify-x509-name ... name'")
      print "verify-x509-name " f[2] " name"
    }
    next
  }
  if (SRCDIR != "" && index(raw, SRCDIR) > 0) {
    out = raw
    gsub(SRCDIR, DSTDIR, out)
    print out
    next
  }
  print raw
}

END {
  if (MODE == "parse") {
    for (i = 1; i <= nremotes; i++) {
      p = rport[i]
      if (p == "") p = (gport == "" ? "1194" : gport)
      pr = rproto[i]
      if (pr == "") pr = (gproto == "" ? "udp" : gproto)
      print "remote " rhost[i] " " p " " pr
    }
    if (is_pia) print "pia"
  } else if (!first_remote_done && npinned > 0) {
    for (i = 1; i <= npinned; i++) print pinned[i]
  }
}
