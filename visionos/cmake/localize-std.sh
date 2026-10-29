#!/usr/bin/env bash
# Makes the std:: instances left in the game's relocatable object local to it (framework.cmake).
# ld -r's -unexported_symbols_list turns the object's global std definitions local, but not the
# weak ones it marks "automatically hidden" (inline instances: std::string(const char*),
# __assign_no_alias, vector growth...). Left external, the final link would keep the game's copy
# for the whole framework, and Aurora, Dawn and the host would allocate their strings in the
# game's heap. nmedit -R makes them local; the build fails if any std weak external is left.
#
#   localize-std.sh <object>
set -euo pipefail
object="$1"
list="$(mktemp)"
trap 'rm -f "${list}"' EXIT
nm -m "${object}" | awk '/weak external/ && $NF ~ /^__Z(Z|GVZ|T[VIS])?N?K?St3__1/ {print $NF}' | sort -u > "${list}"
if [[ -s "${list}" ]]; then
    xcrun nmedit -R "${list}" "${object}"
fi
left="$(nm -m "${object}" | awk '/weak external/ && $NF ~ /^__Z(Z|GVZ|T[VIS])?N?K?St3__1/ {print $NF}')"
if [[ -n "${left}" ]]; then
    echo "localize-std.sh: std weak externals are still external in ${object}:" >&2
    echo "${left}" | head >&2
    exit 1
fi
echo "localize-std.sh: $(wc -l < "${list}" | tr -d ' ') std instances made local"
