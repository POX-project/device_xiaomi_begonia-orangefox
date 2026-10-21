#!/system/bin/sh
# Shared helpers for the foxweb CGI endpoints.

FOXWIFI=${FOXWIFI_BIN:-/system/bin/foxwifi}
FOXWEB_BIN=${FOXWEB_BIN:-/system/bin/foxweb}
TOKEN_FILE=/tmp/foxweb.token
BODY=

json_header() {
    printf 'Content-Type: application/json\r\nCache-Control: no-store\r\n\r\n'
}

text_header() {
    printf 'Content-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\n\r\n'
}

json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\r\n'
}

urldecode() {
    s=$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/+/ /g; s/%/\\x/g')
    printf '%b' "$s"
}

query_param() {
    printf '%s' "${QUERY_STRING:-}" | tr '&' '\n' \
        | sed -n "s/^$1=//p" | head -n 1 | while IFS= read -r v; do urldecode "$v"; done
}

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
    printf '%s' "$BODY" | tr '&' '\n' \
        | sed -n "s/^$1=//p" | head -n 1 | while IFS= read -r v; do urldecode "$v"; done
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
