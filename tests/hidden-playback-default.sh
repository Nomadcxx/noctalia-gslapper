#!/bin/sh
set -eu

expect() {
    grep -q "$1" "$2" || {
        echo "missing: $1 in $2" >&2
        exit 1
    }
}

expect '^default = "none"$' gslapper/plugin.toml
expect 'hidden = "none"' gslapper/service.luau
expect '#hiddenFlags("none") == 0' gslapper/service.luau

echo "hidden playback default: passed"
