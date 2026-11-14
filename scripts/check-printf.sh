#!/bin/sh
#
# Every printf in the feed hands as many arguments as its format asks for.
#
# This exists because a shipped image reported malformed JSON twice in one
# afternoon, both times the same way: a field was added to `pulzr-claim`'s
# facts format and the matching argument was not. sh does not complain — the
# missing %s takes whatever came next, so `{"sshHostKey":"{...system json..."}`
# went out over HTTPS and Pulzar Cloud answered 400. Nothing on the gateway
# notices; the reports simply stop counting, which is the worst kind of broken.
#
# Deliberately crude: it reads the format string's specifiers and counts the
# arguments after it, across line continuations. A printf whose arguments are
# not literal words is skipped rather than guessed at.

set -eu

fail=0

for file in $(find feed -type f -path '*/files/*' -perm -u+x); do
    head -n1 "${file}" | grep -q '^#!/bin/sh' || continue

    awk -v file="${file}" '
        # Join continuation lines so a printf spread over three lines is one.
        { line = $0
          while (sub(/\\$/, "", line) && (getline next_line) > 0)
              line = line next_line
          buffer[NR] = line }

        END {
            for (n in buffer) {
                line = buffer[n]
                if (line !~ /printf[ \t]+'"'"'/) continue
                # The format string: between the first pair of single quotes.
                rest = substr(line, index(line, "printf") + 6)
                if (substr(rest, match(rest, /[^ \t]/), 1) != "'"'"'") continue
                rest = substr(rest, match(rest, /[^ \t]/) + 1)
                close_at = index(rest, "'"'"'")
                if (close_at == 0) continue
                format = substr(rest, 1, close_at - 1)
                args = substr(rest, close_at + 1)

                # Specifiers, ignoring %% which prints a literal percent.
                wanted = 0
                copy = format
                gsub(/%%/, "", copy)
                wanted = gsub(/%[-0-9.]*[a-zA-Z]/, "", copy)
                if (wanted == 0) continue

                # Arguments: quoted words or $(...) substitutions. A line with
                # anything else in it is not one this check can read.
                given = 0
                readable = 1
                while (match(args, /^[ \t]*("[^"]*"|\$\([^)]*\)|[^ \t]+)/)) {
                    token = substr(args, RSTART, RLENGTH)
                    args = substr(args, RSTART + RLENGTH)
                    sub(/^[ \t]+/, "", token)
                    if (token == "") continue
                    if (token !~ /^("|\$\()/) { readable = 0; break }
                    given++
                }
                if (!readable) continue

                if (given != wanted) {
                    printf "%s: printf wants %d arguments, given %d\n",
                           file, wanted, given
                    printf "  %.100s\n", format
                    bad = 1
                }
            }
            exit bad ? 1 : 0
        }
    ' "${file}" || fail=1
done

[ "${fail}" = 0 ] || exit 1
echo "printf arguments ok"
