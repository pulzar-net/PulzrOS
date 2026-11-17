# The part of libubox's jshn.sh pulzr-wifi-uplink uses, for
# scripts/test-wifi-uplink.sh: flat objects of strings and integers.
json_init() { _J='{'; _JS=''; }
json_add_string() {
    _J="${_J}${_JS}\"$1\":\"$(printf '%s' "$2" | sed 's/\\/\\\\/g; s/"/\\"/g')\""; _JS=','
}
json_add_int() { _J="${_J}${_JS}\"$1\":$2"; _JS=','; }
json_dump() { printf '%s}\n' "${_J}"; }
