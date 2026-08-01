#!/bin/sh

command -v uci >/dev/null 2>&1 || return 0

radio_count="$(uci -q show wireless | grep -c '=wifi-device$')"
[ "$radio_count" -gt 0 ] 2>/dev/null || return 0

country_count="$(uci -q show wireless | grep -Ec "\.country='[A-Z][A-Z]'$")"
[ "$country_count" -ge "$radio_count" ] 2>/dev/null && return 0

cat <<'EOF'
NOTICE: One or more Wi-Fi radios have no regulatory country selected.
6 GHz will not start with country 00. Set the correct country in LuCI, or run:
  flint3-set-country <CC>
EOF
