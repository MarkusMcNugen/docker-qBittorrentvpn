# Applies operations to a QSettings INI file read on standard input and
# prints the result.
#
# OPS names a file of tab-separated operations, one per line:
#   set <section> <key> <value>   replaces the key's first occurrence in the
#                                 section and drops later duplicates; a key
#                                 not present is added at the end of its
#                                 section, a section not present at the end
#                                 of the file
#   del <section> <key>           removes every occurrence of the key
#
# When several operations name the same section and key, the first one wins
# and the rest are ignored. Keys match exactly, as QSettings writes them.
# Every other line is copied unchanged; a CR at the end of a line is dropped.

function emit_pending(s,   i) {
  for (i = 1; i <= n; i++) {
    if (!shadowed[i] && op[i] == "set" && sec[i] == s && !done[i]) {
      print key[i] "=" val[i]
      done[i] = 1
    }
  }
}

function flush_blanks() {
  while (blanks > 0) {
    print ""
    blanks--
  }
}

BEGIN {
  n = 0
  while ((getline line < OPS) > 0) {
    if (line == "") continue
    c = split(line, f, "\t")
    n++
    op[n] = f[1]
    sec[n] = f[2]
    key[n] = f[3]
    val[n] = (c >= 4 ? f[4] : "")
    for (j = 5; j <= c; j++) val[n] = val[n] "\t" f[j]
    id = sec[n] SUBSEP key[n]
    if (id in first) shadowed[n] = 1
    else first[id] = n
  }
  close(OPS)
  cur = ""
  blanks = 0
}

{
  sub(/\r$/, "")
  line = $0
  if (line ~ /^\[.*\][ \t]*$/) {
    emit_pending(cur)
    flush_blanks()
    name = line
    sub(/[ \t]+$/, "", name)
    cur = substr(name, 2, length(name) - 2)
    print line
    next
  }
  if (line ~ /^[ \t]*$/) {
    blanks++
    next
  }
  flush_blanks()
  eq = index(line, "=")
  if (eq > 0) {
    k = substr(line, 1, eq - 1)
    id = cur SUBSEP k
    if (id in first) {
      i = first[id]
      if (op[i] == "del") next
      if (!done[i]) {
        print key[i] "=" val[i]
        done[i] = 1
      }
      next
    }
  }
  print line
}

END {
  emit_pending(cur)
  flush_blanks()
  for (i = 1; i <= n; i++) {
    if (shadowed[i] || op[i] != "set" || done[i]) continue
    s = sec[i]
    print ""
    print "[" s "]"
    for (j = i; j <= n; j++) {
      if (!shadowed[j] && op[j] == "set" && sec[j] == s && !done[j]) {
        print key[j] "=" val[j]
        done[j] = 1
      }
    }
  }
}
