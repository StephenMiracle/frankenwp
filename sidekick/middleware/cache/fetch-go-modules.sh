#!/bin/bash
# Populate the Go module cache for a single module.
#
# The Go proxy occasionally resets the TLS connection while downloading the
# larger module zips, and Go does not retry a half-written archive. This
# helper downloads the archive with curl using range requests (-C -) until the
# file reaches the full Content-Length, so the next `go build` finds a
# complete module in the cache instead of a truncated one.
#
# Usage: fetch-go-modules.sh <module> <version> [<module> <version> ...]
set -u

GOMODCACHE="$(go env GOMODCACHE)"
DL="$GOMODCACHE/cache/download"

# Uppercase letters are escaped as "!lower" in the module cache path.
escape() {
    printf '%s' "$1" | sed -e 's/\([A-Z]\)/!\l\1/g'
}

fetch_one() {
    mod="$1"
    ver="$2"
    esc="$(escape "$mod")"
    dir="$DL/$esc/@v"
    url="https://proxy.golang.org/$esc/@v/$ver"

    mkdir -p "$dir"

    # .info and .mod are small - a plain download is enough.
    for ext in info mod; do
        f="$dir/$ver.$ext"
        if [ ! -s "$f" ]; then
            curl -sSL --retry 5 --retry-all-errors --retry-delay 1 --max-time 120 \
                 -o "$f" "$url.$ext" || true
        fi
    done

    zip="$dir/$ver.zip"

    # The full size of the body, used to detect a complete download.
    expected=$(curl -sSLI --max-time 120 "$url.zip" 2>/dev/null \
               | tr -d '\r' | awk 'tolower($1)=="content-length:"{v=$2} END{print v+0}')

    prev=0
    for attempt in 1 2 3 4 5 6 7 8 9 10 11 12; do
        cur=$(stat -c %s "$zip" 2>/dev/null || echo 0)

        # Already complete?
        if [ -n "$expected" ] && [ "$cur" = "$expected" ]; then
            break
        fi

        # The file did not grow on the previous attempt - we are stuck.
        if [ "$cur" = "$prev" ] && [ "$cur" -gt 0 ]; then
            # Force a clean restart if the partial file is not progressing.
            if [ -n "$expected" ] && [ "$cur" -lt "$expected" ]; then
                rm -f "$zip"
            else
                break
            fi
        fi
        prev="$cur"

        if [ "$cur" -eq 0 ]; then
            curl -sSL --max-time 600 -o "$zip" "$url.zip" >/dev/null 2>&1 || true
        else
            curl -sSL -C - --max-time 600 -o "$zip" "$url.zip" >/dev/null 2>&1 || true
        fi
    done

    cur=$(stat -c %s "$zip" 2>/dev/null || echo 0)

    if [ "$cur" -gt 0 ] && { [ -z "$expected" ] || [ "$cur" = "$expected" ]; }; then
        echo "  cached $mod@$ver ($cur bytes)"
        return 0
    fi

    echo "  FAILED $mod@$ver ($cur of $expected bytes)"
    return 1
}

rc=0
while [ $# -ge 2 ]; do
    fetch_one "$1" "$2" || rc=1
    shift 2
done
exit $rc
