#!/system/bin/sh
# Shared helpers for the foxweb CGI endpoints.

FOXWIFI=${FOXWIFI_BIN:-/system/bin/foxwifi}
FOXWEB_BIN=${FOXWEB_BIN:-/system/bin/foxweb}
FOXADB_BIN=${FOXADB_BIN:-/system/bin/foxadb}
TOKEN_FILE=${FOXWEB_TOKEN_FILE:-/tmp/foxweb.token}
BODY=

# The file manager is deliberately limited to the two writable trees that
# exist in recovery.  Resolve them once so /sdcard may safely be a symlink or
# a bind mount to /data/media/0.
FOX_ROOT_SD=${FOX_ROOT_SD:-/sdcard}
FOX_ROOT_TMP=${FOX_ROOT_TMP:-/tmp}
ROOT_SD=$(readlink -f "$FOX_ROOT_SD" 2>/dev/null)
ROOT_TMP=$(readlink -f "$FOX_ROOT_TMP" 2>/dev/null)
[ -n "$ROOT_SD" ] || ROOT_SD=$FOX_ROOT_SD
[ -n "$ROOT_TMP" ] || ROOT_TMP=$FOX_ROOT_TMP
DISPLAY_SD=/sdcard
DISPLAY_TMP=/tmp

json_header() {
    printf 'Content-Type: application/json\r\nCache-Control: no-store\r\n\r\n'
}

text_header() {
    printf 'Content-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\n\r\n'
}

json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\r\n' | tr '\t' ' '
}

# Canonicalise a path.  BusyBox readlink -f resolves symlinks and also accepts
# a path whose final component does not exist yet on some builds, but callers
# still check the resulting type before using it.
canon_path() {
    [ -n "$1" ] || return 1
    _canon=$(readlink -f "$1" 2>/dev/null) || return 1
    [ -n "$_canon" ] || return 1
    printf '%s' "$_canon"
}

# Test an already-canonical path against the two allowed roots.
allowed_canon() {
    case "$1" in
        "$ROOT_SD"|"$ROOT_SD"/*|"$ROOT_TMP"|"$ROOT_TMP"/*) return 0 ;;
    esac
    return 1
}

# Resolve a user-supplied path and print the canonical path if it belongs to
# /sdcard or /tmp.  Symlinks that escape either root are rejected here.
resolve_allowed() {
    _resolved=$(canon_path "$1") || return 1
    allowed_canon "$_resolved" || return 1
    printf '%s' "$_resolved"
}

# Present the resolved path as the friendly /sdcard or /tmp path.  UI paths
# remain stable even when /sdcard resolves to /data/media/0.
display_path() {
    case "$1" in
        "$ROOT_SD")     printf '%s' "$DISPLAY_SD" ;;
        "$ROOT_SD"/*)   printf '%s%s' "$DISPLAY_SD" "${1#"$ROOT_SD"}" ;;
        "$ROOT_TMP")    printf '%s' "$DISPLAY_TMP" ;;
        "$ROOT_TMP"/*)  printf '%s%s' "$DISPLAY_TMP" "${1#"$ROOT_TMP"}" ;;
        *)              printf '%s' "$1" ;;
    esac
}

# A single path component, suitable for mkdir/rename/upload.  Reject slashes,
# dot components, backslashes and control characters.
safe_name() {
    [ -n "$1" ] || return 1
    case "$1" in
        .|..|*/*|*\\*) return 1 ;;
        *[[:cntrl:]]*) return 1 ;;
    esac
    return 0
}

file_size() {
    stat -c %s "$1" 2>/dev/null || wc -c < "$1" 2>/dev/null
}

file_mtime() {
    stat -c %Y "$1" 2>/dev/null || echo 0
}

# CONTENT_LENGTH must be present for uploads; refusing an unknown length avoids
# creating a file that silently stops halfway through.
content_length() {
    _len=${CONTENT_LENGTH:-}
    [ -n "$_len" ] || return 1
    case "$_len" in
        *[!0-9]*) return 1 ;;
    esac
    printf '%s' "$_len"
}

# Decode application/x-www-form-urlencoded data without relying on a
# particular shell's printf \x support.  Values are short, so a small awk
# decoder is cheap and portable to BusyBox/toybox userlands.
urldecode() {
    printf '%s' "$1" | LC_ALL=C awk '
        function hexval(c) {
            c = tolower(c)
            return index("0123456789abcdef", c) - 1
        }
        function hex2dec(h, a, b) {
            if (length(h) != 2) return -1
            a = hexval(substr(h, 1, 1))
            b = hexval(substr(h, 2, 1))
            if (a < 0 || b < 0) return -1
            return a * 16 + b
        }
        {
            s = $0
            out = ""
            for (i = 1; i <= length(s); i++) {
                c = substr(s, i, 1)
                if (c == "+") {
                    out = out " "
                } else if (c == "%" && i + 2 <= length(s)) {
                    n = hex2dec(substr(s, i + 1, 2))
                    if (n >= 0) {
                        out = out sprintf("%c", n)
                        i += 2
                    } else {
                        out = out c
                    }
                } else {
                    out = out c
                }
            }
            printf "%s", out
        }'
}

query_param() {
    # Use command substitution rather than "while read": a request with a
    # single parameter has no trailing newline, and some shells' read returns
    # nonzero at EOF even though it did read the value.
    _value=$(printf '%s\n' "${QUERY_STRING:-}" | tr '&' '\n' \
        | sed -n "s/^$1=//p" | head -n 1)
    urldecode "$_value"
}

# CGI scripts that need more than one body field must call read_body directly
# in the parent shell before the first body_param call.  A command substitution
# runs in a subshell, so the cached BODY would otherwise be discarded after
# each field and the remaining fields would see an exhausted stdin.
read_body() {
    [ -n "$BODY" ] && return 0
    len=${CONTENT_LENGTH:-0}
    case "$len" in
        ''|*[!0-9]*) len=0 ;;
    esac
    [ "$len" -gt 8192 ] && len=8192
    BODY=$(head -c "$len" 2>/dev/null)
}

body_param() {
    read_body
    _value=$(printf '%s\n' "$BODY" | tr '&' '\n' \
        | sed -n "s/^$1=//p" | head -n 1)
    urldecode "$_value"
}

json_error() {
    printf 'Status: %s\r\n' "$1"
    json_header
    printf '{"ok":false,"error":"%s"}\n' "$(json_escape "$2")"
    exit 0
}

token_ok() {
    want=$(cat "$TOKEN_FILE" 2>/dev/null)
    # Fail closed: never allow mutations just because the token file vanished.
    [ -n "$want" ] || return 1
    got=${HTTP_X_FOX_TOKEN:-}
    [ -z "$got" ] && got=$(query_param token)
    [ "$got" = "$want" ]
}

require_token() {
    token_ok || json_error "401 Unauthorized" "invalid or missing access token"
}

require_post() {
    [ "${REQUEST_METHOD:-GET}" = POST ] || json_error "405 Method Not Allowed" "POST required"
}
