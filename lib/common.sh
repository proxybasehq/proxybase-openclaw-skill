#!/usr/bin/env bash
# common.sh — Shared utility functions for ProxyBase skill scripts
# Source this at the top of every script:
#   source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# ─── Path setup ──────────────────────────────────────────────────────
# Resolve paths relative to the script that sources us.
# If LIB_DIR is already set (by an earlier source), skip re-computation.
if [[ -z "${_PROXYBASE_COMMON_LOADED:-}" ]]; then
    _PROXYBASE_COMMON_LOADED=1

    LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    SKILL_DIR="$(dirname "$LIB_DIR")"
    SCRIPT_DIR="$SKILL_DIR/scripts"
    STATE_DIR="$SKILL_DIR/state"
    ORDERS_FILE="$STATE_DIR/orders.json"
    CREDS_FILE="$STATE_DIR/credentials.env"
    PROXY_ENV_FILE="$STATE_DIR/.proxy-env"
    LOCK_FILE="$STATE_DIR/orders.lock"

    PROXYBASE_API_URL="${PROXYBASE_API_URL:-https://api.proxybase.xyz/v1}"

    # Ensure state dir exists
    mkdir -p "$STATE_DIR"
fi

# ─── Input validation & sanitization ─────────────────────────────────
# Validates values from API responses contain only safe characters,
# preventing shell injection if the upstream API is compromised.
validate_safe_string() {
    local VALUE="$1"
    local CONTEXT="$2"  # username, password, host, port, order_id, api_key, package_id, proxy_url

    if [[ -z "$VALUE" ]]; then
        return 1
    fi

    case "$CONTEXT" in
        username)
            # Proxy usernames: alphanumeric, underscore, hyphen, dot
            [[ "$VALUE" =~ ^[a-zA-Z0-9._-]+$ ]] || { echo "SECURITY: Invalid characters in proxy username — rejecting" >&2; return 1; }
            ;;
        password)
            # Proxy passwords: alphanumeric + safe URL-unreserved chars (no shell metacharacters)
            [[ "$VALUE" =~ ^[a-zA-Z0-9._!*+-]+$ ]] || { echo "SECURITY: Invalid characters in proxy password — rejecting" >&2; return 1; }
            ;;
        host)
            # Hostnames: alphanumeric, dots, hyphens
            [[ "$VALUE" =~ ^[a-zA-Z0-9.-]+$ ]] || { echo "SECURITY: Invalid characters in proxy host — rejecting" >&2; return 1; }
            ;;
        port)
            # Numeric only, valid port range
            [[ "$VALUE" =~ ^[0-9]+$ ]] && [[ "$VALUE" -ge 1 && "$VALUE" -le 65535 ]] || { echo "SECURITY: Invalid proxy port — rejecting" >&2; return 1; }
            ;;
        order_id)
            # Order IDs: alphanumeric, hyphens, underscores
            [[ "$VALUE" =~ ^[a-zA-Z0-9_-]+$ ]] || { echo "SECURITY: Invalid characters in order_id — rejecting" >&2; return 1; }
            ;;
        api_key)
            # API keys: alphanumeric, underscores, hyphens (pk_xxx format)
            [[ "$VALUE" =~ ^[a-zA-Z0-9_-]+$ ]] || { echo "SECURITY: Invalid characters in API key — rejecting" >&2; return 1; }
            ;;
        package_id)
            # Package IDs: alphanumeric, underscores, hyphens
            [[ "$VALUE" =~ ^[a-zA-Z0-9_-]+$ ]] || { echo "SECURITY: Invalid characters in package_id — rejecting" >&2; return 1; }
            ;;
        proxy_url)
            # Full proxy URL: must match socks5://user:pass@host:port pattern
            [[ "$VALUE" =~ ^socks5://[a-zA-Z0-9._-]+:[a-zA-Z0-9._!*+-]+@[a-zA-Z0-9.-]+:[0-9]+$ ]] || { echo "SECURITY: Invalid proxy URL format — rejecting" >&2; return 1; }
            ;;
        *)
            # Generic: reject common shell metacharacters
            if [[ "$VALUE" =~ [\$\`\"\'\'\;\&\|\>\<\(\)\{\}\\] ]]; then
                echo "SECURITY: Unsafe characters detected in $CONTEXT — rejecting" >&2
                return 1
            fi
            ;;
    esac
    return 0
}

# Build a validated proxy URL from individual fields.
# Sets the PROXY_URL variable on success.
build_safe_proxy_url() {
    local _HOST="$1" _PORT="$2" _USER="$3" _PASS="$4"

    validate_safe_string "$_HOST" "host" || return 1
    validate_safe_string "$_PORT" "port" || return 1
    validate_safe_string "$_USER" "username" || return 1
    validate_safe_string "$_PASS" "password" || return 1

    PROXY_URL="socks5://${_USER}:${_PASS}@${_HOST}:${_PORT}"
    return 0
}

# Write proxy env file with single-quoted values to prevent shell expansion on source.
write_proxy_env_file() {
    local _FILE="$1" _OID="$2" _URL="$3" _LABEL="${4:-}"

    validate_safe_string "$_URL" "proxy_url" || return 1

    {
        printf '# ProxyBase SOCKS5 proxy — Order %s%s\n' "$_OID" "${_LABEL:+ ($_LABEL)}"
        printf '# Generated %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
        printf "export ALL_PROXY='%s'\n" "$_URL"
        printf "export HTTPS_PROXY='%s'\n" "$_URL"
        printf "export HTTP_PROXY='%s'\n" "$_URL"
        printf "export NO_PROXY='localhost,127.0.0.1,api.proxybase.xyz'\n"
        printf "export PROXYBASE_SOCKS5='%s'\n" "$_URL"
    } > "$_FILE"
    chmod 600 "$_FILE"
}

# Write credentials file with single-quoted values to prevent shell expansion on source.
write_credentials_file() {
    local _FILE="$1" _KEY="$2" _URL="$3" _AGENT_ID="${4:-unknown}"

    validate_safe_string "$_KEY" "api_key" || return 1

    {
        printf '# ProxyBase credentials — generated %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
        printf '# Agent ID: %s\n' "$_AGENT_ID"
        printf "export PROXYBASE_API_KEY='%s'\n" "$_KEY"
        printf "export PROXYBASE_API_URL='%s'\n" "$_URL"
    } > "$_FILE"
    chmod 600 "$_FILE"
}

# ─── File locking ────────────────────────────────────────────────────
# Usage:
#   acquire_lock          # blocks until lock acquired
#   release_lock          # release the lock (also automatic on exit)
#
# Uses flock(1) when available, falls back to a mkdir-based spinlock.

_LOCK_FD=""
_LOCK_METHOD=""

acquire_lock() {
    if command -v flock &>/dev/null; then
        _LOCK_METHOD="flock"
        exec 9>"$LOCK_FILE"
        if ! flock -n 9 2>/dev/null; then
            echo "ProxyBase: Waiting for state lock..." >&2
            flock 9
        fi
        _LOCK_FD=9
    else
        # Fallback: mkdir-based lock (atomic on all POSIX systems)
        _LOCK_METHOD="mkdir"
        local LOCK_DIR="${LOCK_FILE}.d"
        local ATTEMPTS=0
        while ! mkdir "$LOCK_DIR" 2>/dev/null; do
            # Staleness detection: if lock dir is older than 120s, assume the
            # holder was killed (SIGKILL / crash) and force-remove.
            if [[ -d "$LOCK_DIR" ]]; then
                local LOCK_AGE=0
                if command -v stat &>/dev/null; then
                    # macOS stat vs GNU stat
                    if stat -f%m "$LOCK_DIR" &>/dev/null; then
                        LOCK_AGE=$(( $(date +%s) - $(stat -f%m "$LOCK_DIR") ))
                    elif stat -c%Y "$LOCK_DIR" &>/dev/null; then
                        LOCK_AGE=$(( $(date +%s) - $(stat -c%Y "$LOCK_DIR") ))
                    fi
                fi
                if [[ $LOCK_AGE -gt 120 ]]; then
                    echo "ProxyBase: Removing stale lock (age=${LOCK_AGE}s)" >&2
                    rm -rf "$LOCK_DIR" 2>/dev/null
                    continue
                fi
            fi

            ATTEMPTS=$((ATTEMPTS + 1))
            if [[ $ATTEMPTS -ge 60 ]]; then
                echo "ERROR: Could not acquire state lock after 30s — stale lock?" >&2
                echo "  Remove manually: rm -rf $LOCK_DIR" >&2
                return 1
            fi
            if [[ $ATTEMPTS -eq 1 ]]; then
                echo "ProxyBase: Waiting for state lock..." >&2
            fi
            sleep 0.5
        done
    fi
}

release_lock() {
    if [[ "$_LOCK_METHOD" == "flock" && -n "$_LOCK_FD" ]]; then
        flock -u 9 2>/dev/null || true
        exec 9>&- 2>/dev/null || true
        rm -f "$LOCK_FILE" 2>/dev/null
    elif [[ "$_LOCK_METHOD" == "mkdir" ]]; then
        rm -rf "${LOCK_FILE}.d" 2>/dev/null
    fi
    _LOCK_FD=""
    _LOCK_METHOD=""
}

# Auto-release lock on script exit
trap 'release_lock' EXIT

# ─── JSON validation ─────────────────────────────────────────────────
# validate_json <string>
#   Returns 0 if the string is valid JSON, 1 otherwise.
validate_json() {
    local data="$1"
    if [[ -z "$data" ]]; then
        return 1
    fi
    echo "$data" | jq empty >/dev/null 2>&1
}

# ─── Safe API call ───────────────────────────────────────────────────
# api_call <method> <path> [curl_extra_args...]
#   Makes a curl call and validates the response is JSON.
#   Sets two global vars:  API_RESPONSE  API_HTTP_CODE
#   Returns 0 on success, 1 on network/parse error, 2 on HTTP error.
#
# Tmpfile lifecycle: cleaned up via a trap stack that restores the
# previous EXIT trap after the function returns, ensuring no /tmp leaks
# even on SIGINT/SIGTERM mid-curl.
api_call() {
    local METHOD="$1"
    shift
    local PATH_="$1"
    shift

    local TMPFILE
    TMPFILE=$(mktemp)

    # Push a local cleanup trap (restores the outer trap on return)
    local _PREV_TRAP
    _PREV_TRAP=$(trap -p EXIT | sed "s/^trap -- '//;s/' EXIT$//")
    trap "rm -f '$TMPFILE'; ${_PREV_TRAP:-release_lock}" EXIT

    API_HTTP_CODE=$(curl -s -o "$TMPFILE" -w "%{http_code}" \
        -X "$METHOD" \
        "${PROXYBASE_API_URL}${PATH_}" \
        -H "X-API-Key: ${PROXYBASE_API_KEY:-}" \
        --connect-timeout 10 \
        --max-time 20 \
        "$@" 2>/dev/null) || {
        rm -f "$TMPFILE"
        trap "${_PREV_TRAP:-release_lock}" EXIT
        API_RESPONSE='{"error":"network_error","message":"curl failed"}'
        API_HTTP_CODE="000"
        return 1
    }

    API_RESPONSE=$(cat "$TMPFILE")
    rm -f "$TMPFILE"

    # Restore previous EXIT trap
    trap "${_PREV_TRAP:-release_lock}" EXIT

    # Check for HTML error pages / non-JSON responses
    if ! validate_json "$API_RESPONSE"; then
        local SNIPPET="${API_RESPONSE:0:200}"
        API_RESPONSE=$(jq -n --arg code "$API_HTTP_CODE" --arg body "$SNIPPET" \
            '{"error":"invalid_json","message":"API returned non-JSON response","http_code":$code,"body_preview":$body}')
        return 1
    fi

    # Check HTTP status codes
    case "$API_HTTP_CODE" in
        2*) return 0 ;;          # 2xx — success
        429)
            # Rate limited — extract Retry-After if present
            return 2
            ;;
        *)
            return 2
            ;;
    esac
}

# ─── Retry wrapper ───────────────────────────────────────────────────
# api_call_with_retry <method> <path> [curl_extra_args...]
#   Calls api_call with up to 3 retries for network/429 errors.
#   Waits 2s, 5s, 10s between retries. On 429, respects Retry-After if present.
api_call_with_retry() {
    local DELAYS=(2 5 10)
    local ATTEMPT=0

    while [[ $ATTEMPT -le 3 ]]; do
        local RC=0
        api_call "$@" || RC=$?

        if [[ $RC -eq 0 ]]; then
            return 0
        fi

        # Don't retry 4xx errors (except 429) — they are client errors
        if [[ "$API_HTTP_CODE" =~ ^4[0-9][0-9]$ && "$API_HTTP_CODE" != "429" ]]; then
            return $RC
        fi

        if [[ $ATTEMPT -ge 3 ]]; then
            return $RC
        fi

        # On 429, check Retry-After
        local WAIT=${DELAYS[$ATTEMPT]:-10}
        if [[ "$API_HTTP_CODE" == "429" ]]; then
            local RA
            RA=$(echo "$API_RESPONSE" | jq -r '.retry_after // empty' 2>/dev/null)
            if [[ -n "$RA" && "$RA" =~ ^[0-9]+$ ]]; then
                WAIT=$RA
            fi
        fi

        echo "ProxyBase: Request failed (HTTP $API_HTTP_CODE), retrying in ${WAIT}s... (attempt $((ATTEMPT+1))/3)" >&2
        sleep "$WAIT"
        ATTEMPT=$((ATTEMPT + 1))
    done

    return 1
}

# ─── Credentials loading ─────────────────────────────────────────────
# load_credentials [--required]
#   Loads PROXYBASE_API_KEY from state/credentials.env if not already set.
#   With --required: exits 1 if no key is available.
load_credentials() {
    local REQUIRED=false
    [[ "${1:-}" == "--required" ]] && REQUIRED=true

    if [[ -z "${PROXYBASE_API_KEY:-}" ]]; then
        if [[ -f "$CREDS_FILE" ]]; then
            source "$CREDS_FILE"
        fi
    fi

    if [[ "$REQUIRED" == true && -z "${PROXYBASE_API_KEY:-}" ]]; then
        echo "ProxyBase: No API key found. Attempting auto-registration..." >&2
        
        # Source the registration script to fetch and export a new key inline
        if [[ -f "$SCRIPT_DIR/proxybase-register.sh" ]]; then
            # Use `source` so the ENV vars bleed up into our current shell context
            source "$SCRIPT_DIR/proxybase-register.sh" || {
                echo "ERROR: Auto-registration failed." >&2
                return 1
            }
        else
            echo "ERROR: proxybase-register.sh not found at $SCRIPT_DIR/proxybase-register.sh. Cannot auto-register." >&2
            return 1
        fi
        
        # If it's still missing after auto-register, fail out
        if [[ -z "${PROXYBASE_API_KEY:-}" ]]; then
            echo "ERROR: Auto-registration completed but PROXYBASE_API_KEY is still not set." >&2
            return 1
        fi
    fi
}

# ─── Orders file helpers ─────────────────────────────────────────────
# init_orders_file
#   Creates orders.json if it doesn't exist yet.
init_orders_file() {
    if [[ ! -f "$ORDERS_FILE" ]]; then
        echo '{"orders":[]}' > "$ORDERS_FILE"
    fi
}

# update_order_field <order_id> <field> <value>
#   Updates a single field on an order in orders.json (under lock).
update_order_field() {
    local OID="$1" FIELD="$2" VALUE="$3"

    if [[ ! -f "$ORDERS_FILE" ]]; then
        return 1
    fi

    local UPDATED
    UPDATED=$(jq --arg oid "$OID" --arg f "$FIELD" --arg v "$VALUE" \
        '(.orders[] | select(.order_id == $oid))[$f] = $v' "$ORDERS_FILE" 2>/dev/null)

    if [[ -n "$UPDATED" ]] && validate_json "$UPDATED"; then
        echo "$UPDATED" > "$ORDERS_FILE"
    else
        echo "WARN: Failed to update order $OID field $FIELD — state file may be corrupt" >&2
    fi
}
