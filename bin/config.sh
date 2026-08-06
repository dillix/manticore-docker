#!/bin/sh
# =============================================================================
# Manticore Search Docker Stack — configuration helper
# =============================================================================
# This script runs inside the `config` service container, which uses the same
# pinned image as the daemon (manticoresearch/manticore:27.1.5). That image
# ships GNU wget, sed, awk and base64 — but no curl and no jq — so everything
# here speaks to the engine over HTTP with wget and parses JSON with sed.
#
# It manages two things:
#   - the .env file (deployment scenario, domain, ACME email, application
#     username, admin token);
#   - the engine's own users, passwords, bearer tokens and grants.
#
# Manticore 27.1.5 authenticates natively on both the HTTP and MySQL
# protocols. The reverse proxy authenticates nothing.
#
# Invocation (always through the host-side wrapper, never directly):
#   ./config <subcommand> [args...]
#
# Subcommands:
#   setup                Interactive wizard (host wrapper drives two phases)
#   show                 .env plus the engine's users and grants
#   check                Authenticated query — proves the engine executes SQL
#   domain <fqdn>        Set MANTICORE_DOMAIN
#   email <addr>         Set MANTICORE_ACME_EMAIL
#   username <name>      Set MANTICORE_USERNAME and create the user
#   password change      New password for the application user
#   token rotate         New MANTICORE_ADMIN_TOKEN
#
# `admin reset` lives entirely in the host wrapper: it needs a local searchd
# CLI call that cannot be made over the network.
#
# The script does NOT need executable bit (+x) — it is run as
#   /bin/sh /work/bin/config.sh ...
# from the container's entrypoint.
# =============================================================================

set -eu

# -----------------------------------------------------------------------------
# Globals & environment
# -----------------------------------------------------------------------------

ENV_FILE=".env"
ENV_EXAMPLE=".env.example"

# Host UID/GID for restoring .env ownership after we write to it as root.
# Set by docker-compose.yml from $(id -u) / $(id -g) on the host.
HOST_UID="${HOST_UID:-1000}"
HOST_GID="${HOST_GID:-1000}"

# Set by the host-side wrapper ./config to "yes" if the manticore-caddy
# container is currently running, "no" otherwise. Defaults to "unknown"
# when invoked directly via `docker compose run` (without the wrapper) —
# in that case we cannot tell from inside the container, so we fall back
# to showing both branches in setup next-steps.
CADDY_RUNNING="${CADDY_RUNNING:-unknown}"

# Set to 1 by the host-side wrapper. Some phases depend on work only the
# wrapper can do, and refuse to run without it.
CONFIG_WRAPPER="${CONFIG_WRAPPER:-0}"

# The engine. The config service joins the `manticore` compose network, so
# the daemon is reachable by service name.
MC_HOST="manticore"
MC_PORT="9308"
MC_SQL_PATH="/sql?mode=raw"
MC_SQL_URL="http://${MC_HOST}:${MC_PORT}${MC_SQL_PATH}"

# The admin account the bootstrap creates. The engine has no way to rename a
# user, so this is fixed; the host wrapper uses the same name.
ADMIN_USER="admin"

# Exactly what the search_api_manticore module needs, and nothing more.
# Measured, one grant at a time, against the endpoints the module actually
# calls:
#   read   — POST /search, and every DESCRIBE / SHOW CREATE TABLE
#   write  — POST /bulk (indexing), POST /delete, TRUNCATE
#   schema — CREATE/DROP/ALTER TABLE, and SHOW STATUS
# `schema` is NOT optional for a search-only site: SHOW STATUS is the
# module's availability probe, so without it the module reports the backend
# as down even though search and indexing work perfectly.
# `admin` and `replication` are never granted.
APP_GRANTS="read write schema"

# Validation regex patterns (POSIX BRE/ERE).
DOMAIN_RE='^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$'
EMAIL_RE='^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'
# 1-32 characters from [A-Za-z0-9_-]. Do NOT loosen this without measuring:
# a `'` breaks CREATE USER outright, and a `:` produces a user that is
# created successfully and then fails authentication forever, because the
# colon is HTTP Basic's separator between username and password. This set
# excludes both.
USERNAME_RE='^[A-Za-z0-9_-]{1,32}$'
# The deployment scenario recorded in MANTICORE_SCENARIO. Lowercase is
# accepted at the prompt and normalised to uppercase before it is written,
# so only A and B ever reach .env.
SCENARIO_RE='^[ABab]$'

# The placeholders .env.example ships. Neither can work anywhere, so the
# wizard knows them by value: it strips them from the defaults it offers for
# Scenario B, and says so out loud when Scenario A keeps the email one.
#
# These are copies of MANTICORE_DOMAIN and MANTICORE_ACME_EMAIL in
# .env.example, which says the same thing at those two keys. Change them as
# a pair — once the two copies disagree, the wizard no longer recognises the
# placeholder and starts offering search.example.com as a real default.
PLACEHOLDER_DOMAIN="search.example.com"
PLACEHOLDER_EMAIL="admin@example.com"

# Authorization header used by every engine call. Set by mc_auth_admin (the
# admin bearer token from .env) or mc_auth_basic (a username and password,
# which is how the Drupal module authenticates).
MC_AUTH_HEADER=""

# Response body of the last mc_post call, for error reporting.
MC_LAST_BODY=""

# Operator-visible engine users, newline-separated, loaded by mc_load_users.
# An engine can legitimately have an empty list, so emptiness cannot double
# as "not loaded yet" — hence the separate flag.
MC_USERS=""
MC_USERS_LOADED=no

# -----------------------------------------------------------------------------
# Output helpers (with terminal-aware coloring)
# -----------------------------------------------------------------------------

if [ -t 1 ]; then
    C_RESET="$(printf '\033[0m')"
    C_RED="$(printf '\033[31m')"
    C_GREEN="$(printf '\033[32m')"
    C_YELLOW="$(printf '\033[33m')"
    C_BLUE="$(printf '\033[36m')"
    C_BOLD="$(printf '\033[1m')"
else
    C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_BOLD=""
fi

info()  { printf '%s%s%s\n'   "$C_BLUE"   "$*" "$C_RESET"; }
ok()    { printf '%s%s%s\n'   "$C_GREEN"  "$*" "$C_RESET"; }
warn()  { printf '%s%s%s\n'   "$C_YELLOW" "$*" "$C_RESET" >&2; }
err()   { printf '%s%s%s\n'   "$C_RED"    "$*" "$C_RESET" >&2; }
bold()  { printf '%s%s%s\n'   "$C_BOLD"   "$*" "$C_RESET"; }

# -----------------------------------------------------------------------------
# .env file helpers
# -----------------------------------------------------------------------------

# Ensure .env exists; create from .env.example or as an empty file otherwise.
ensure_env_file() {
    if [ -f "$ENV_FILE" ]; then
        return 0
    fi
    if [ -f "$ENV_EXAMPLE" ]; then
        cp "$ENV_EXAMPLE" "$ENV_FILE"
        info "$ENV_FILE was missing — created from $ENV_EXAMPLE."
    else
        : > "$ENV_FILE"
        info "$ENV_FILE was missing — created empty."
    fi
}

# Read a variable from .env. Echoes the value (everything after the first '=').
# If the key is not present, prints nothing and returns 1.
#   Usage: value=$(get_env_var MANTICORE_DOMAIN)
get_env_var() {
    local key="$1"
    [ -f "$ENV_FILE" ] || return 1
    # The first matching line; strip the "KEY=" prefix.
    sed -n "s/^${key}=\(.*\)$/\1/p" "$ENV_FILE" | head -n 1
}

# Set or replace a variable in .env. Idempotent.
#   Usage: set_env_var MANTICORE_DOMAIN search.example.com
# Uses a custom sed delimiter (|) because none of the values written here can
# contain one, while '/' appears in ordinary values like email addresses.
# The value is passed through unchanged; ampersands and backslashes are
# escaped below because sed treats them specially in a replacement.
set_env_var() {
    local key="$1"
    local value="$2"
    ensure_env_file
    if grep -q "^${key}=" "$ENV_FILE"; then
        local esc
        esc=$(printf '%s\n' "$value" | sed 's/[&\\]/\\&/g')
        sed -i "s|^${key}=.*|${key}=${esc}|" "$ENV_FILE"
    else
        printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
    fi
}

# Remove a variable's line from .env. Any comment block above it is left
# alone — .env.example is the documented copy, and an operator's own notes
# are not ours to delete.
del_env_var() {
    local key="$1"
    [ -f "$ENV_FILE" ] || return 0
    grep -q "^${key}=" "$ENV_FILE" || return 0
    sed -i "/^${key}=/d" "$ENV_FILE"
}

# Restore ownership of .env to the host user, and keep it private: it holds
# the admin token, which is a root-equivalent credential for the engine.
# A .env freshly copied from .env.example would otherwise inherit that
# file's mode.
restore_env_ownership() {
    [ -f "$ENV_FILE" ] || return 0
    chown "${HOST_UID}:${HOST_GID}" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
}

# Print a reminder that running Caddy needs to be recreated to pick up
# changes to environment-substituted values.
#
# Only MANTICORE_DOMAIN and MANTICORE_ACME_EMAIL reach Caddy — it holds no
# credentials any more — so only those two commands call this.
#
# The behaviour depends on CADDY_RUNNING (set by the ./config wrapper):
#   - "yes":     stay silent. The wrapper will recreate Caddy silently
#                after the script exits with code 10.
#   - "no":      stay silent. Nothing is running, so there's nothing to
#                recreate; the new value will take effect on next 'up'.
#   - "unknown": print a generic reminder. We're being invoked directly
#                via `docker compose run` (without the wrapper), so we
#                can't tell what's running and the wrapper won't act.
remind_recreate_caddy() {
    case "$CADDY_RUNNING" in
        yes|no)
            return 0
            ;;
        *)
            info ""
            info "If the stack is currently running, recreate Caddy so the"
            info "change takes effect:"
            info "  docker compose --profile public up -d --force-recreate caddy"
            ;;
    esac
}

# Print a diff-style preview of a planned change.
# Returns 0 if there is a change to apply, 1 if new == current (no-op).
#   Usage:
#     if preview_change KEY new_value; then
#         # there is something to apply
#     else
#         # nothing changed, caller should skip
#     fi
preview_change() {
    local key="$1"
    local new_value="$2"
    local current
    current=$(get_env_var "$key" 2>/dev/null || true)

    if [ "$current" = "$new_value" ]; then
        info "No change: $key is already '$current'."
        return 1
    fi

    echo ""
    if [ -n "$current" ]; then
        printf '  %s- %s=%s%s\n' "$C_RED"   "$key" "$current"   "$C_RESET"
        printf '  %s+ %s=%s%s\n' "$C_GREEN" "$key" "$new_value" "$C_RESET"
    else
        printf '  %s+ %s=%s%s\n' "$C_GREEN" "$key" "$new_value" "$C_RESET"
    fi
    echo ""
    return 0
}

# Ask Y/N. Returns 0 for yes, 1 otherwise. Default is N.
confirm() {
    local prompt="${1:-Continue?}"
    printf '%s [y/N] ' "$prompt"
    local answer
    read -r answer || answer=""
    case "$answer" in
        y|Y|yes|YES) return 0 ;;
        *)           return 1 ;;
    esac
}

# Mask a bearer token for display: enough to recognise, not enough to use.
mask_token() {
    local token="$1"
    [ -z "$token" ] && { printf '(not set)'; return; }
    printf '%s...' "$(printf '%s' "$token" | cut -c1-6)"
}

# -----------------------------------------------------------------------------
# Validation
# -----------------------------------------------------------------------------

validate_domain() {
    printf '%s' "$1" | grep -Eq "$DOMAIN_RE"
}

validate_email() {
    printf '%s' "$1" | grep -Eq "$EMAIL_RE"
}

validate_username() {
    printf '%s' "$1" | grep -Eq "$USERNAME_RE"
}

validate_scenario() {
    printf '%s' "$1" | grep -Eq "$SCENARIO_RE"
}

# One-line description of a scenario, for `show` and the wizard's summary.
# An unrecognised value is echoed back rather than guessed at: .env is the
# operator's file, and inventing a meaning for something we did not write
# would be worse than admitting we do not know it.
scenario_label() {
    case "${1:-}" in
        A) printf 'A — single VPS, no reverse proxy' ;;
        B) printf 'B — bundled Caddy on a public domain' ;;
        "") printf '(not recorded)' ;;
        *) printf '%s (unrecognised)' "$1" ;;
    esac
}

# -----------------------------------------------------------------------------
# Password handling
# -----------------------------------------------------------------------------

# Generate a 24-character password from a safe, copy-paste-friendly alphabet.
# The alphabet is `[A-Za-z0-9_.-]` (65 characters, ~144 bits of entropy
# over 24 characters) — every character in this set is:
#   - shell-safe (no quoting needed in bash/zsh/sh, even in double quotes
#     where `!` would trigger history expansion)
#   - URL-safe (no percent-encoding needed if the password ever lands in
#     a connection string)
#   - regex- and JSON-neutral
#
# It is also safe for the engine, which is now the part that matters, and
# that is measured rather than assumed:
#   - `'` and `\` are the ONLY two characters that break CREATE USER (both
#     produce a SQL syntax error). Neither is in this set.
#   - the engine's minimum password length is 8; 24 clears it comfortably.
#   - a `:` would be harmless in a password (HTTP Basic splits on the first
#     one) but fatal in a username, and this set excludes it either way.
# Do not widen the alphabet without re-measuring those three facts.
generate_password() {
    tr -dc 'A-Za-z0-9_.-' </dev/urandom | head -c 24
}

# Guard against an empty generated password. Without this, an empty value
# reaches the daemon and comes back as "password must be at least 8
# characters", which sends the operator looking in the wrong place.
require_password() {
    [ -n "${1:-}" ] && return 0
    err "Password generation failed (empty value from /dev/urandom)."
    return 1
}

# -----------------------------------------------------------------------------
# Engine helpers
# -----------------------------------------------------------------------------

# Authenticate as the admin, with the bearer token from .env.
mc_auth_admin() {
    local token
    token=$(get_env_var MANTICORE_ADMIN_TOKEN 2>/dev/null || true)
    if [ -z "$token" ]; then
        err "No MANTICORE_ADMIN_TOKEN in $ENV_FILE."
        echo "" >&2
        echo "The engine needs an admin credential before it can be managed." >&2
        echo "Run the setup wizard:" >&2
        echo "  ./config setup" >&2
        return 1
    fi
    MC_AUTH_HEADER="Authorization: Bearer ${token}"
}

# Authenticate as an ordinary user with a password — the same way the Drupal
# module does. base64 without -w0, which is a GNU coreutils extension: the
# encoded value here is far too short to wrap, but `tr -d` costs nothing and
# does not care which base64 is installed.
mc_auth_basic() {
    local credentials
    credentials=$(printf '%s:%s' "$1" "$2" | base64 | tr -d '\n')
    MC_AUTH_HEADER="Authorization: Basic ${credentials}"
}

# Explain a failed engine call, using the daemon's own words wherever it
# gives us any.
mc_report_failure() {
    local _ec="$1"
    local _body="$2"
    local _msg
    _msg=$(printf '%s' "$_body" | tr -d '\n' |
        sed -n 's/.*"error":"\([^"]*\)".*/\1/p')

    # The daemon's own words lead, because they are the useful part. The
    # wget exit code rides along in brackets rather than on a line of its
    # own: it is what separates 401 (6) from 403 (8) from "nothing is
    # listening" (4), so it must stay recoverable — but a whole extra line
    # of it, on every failure, would bury the message that matters.
    [ -n "$_msg" ] && err "manticore: $_msg [wget $_ec]"

    # Below, only what the body did not already say. The 4 and 6 branches
    # name their condition outright, so they do not repeat the code.
    case "$_ec" in
        0) [ -n "$_msg" ] || err "manticore: unexpected response from the daemon [wget 0]." ;;
        4) err "manticore: cannot reach the daemon at ${MC_HOST}:${MC_PORT} — is the stack running?" ;;
        6)
            # Deliberately does not name a cause. HTTP 401 here means the
            # daemon refused the request, and it uses the same status and an
            # authentication-shaped message both when a credential is wrong
            # and when a statement is one this user may not run at all
            # (SET PASSWORD ... FOR is the known example). Note that a 401
            # carries no response body, even with --content-on-error, so
            # there is nothing else to report.
            err "manticore: the daemon rejected this request (HTTP 401)."
            ;;
        *) [ -n "$_msg" ] || err "manticore: request failed [wget $_ec]." ;;
    esac
}

# Run a statement over /sql?mode=raw. Prints the response body on success;
# on failure explains why and returns 1.
#
# --content-on-error is MANDATORY. GNU wget throws the response body away on
# any non-2xx, and Manticore reports SQL errors as HTTP 500 — so without it a
# failing statement yields zero bytes and the operator learns nothing.
#
# Detection combines wget's exit code with a test for an empty "error"
# field, because failures arrive in two different shapes: HTTP-level
# {"error":"..."} and SQL-level [{...,"error":"...","warning":""}] returned
# with HTTP 200.
mc_sql() {
    local _body _ec
    if [ -z "$MC_AUTH_HEADER" ]; then
        err "Internal error: mc_sql called before authentication was set up."
        return 1
    fi
    _ec=0
    # `|| _ec=$?` rather than a bare assignment: `set -e` would otherwise
    # abort the script on the very failures this function exists to report.
    _body=$(wget -q --content-on-error -O - \
                 --header="$MC_AUTH_HEADER" \
                 --post-data="$1" "$MC_SQL_URL" 2>/dev/null) || _ec=$?
    if [ "$_ec" -ne 0 ] || ! printf '%s' "$_body" | tr -d '\n' | grep -q '"error":""'; then
        mc_report_failure "$_ec" "$_body"
        return 1
    fi
    printf '%s' "$_body"
}

# POST to an arbitrary endpoint with the current credential. Stores the body
# in MC_LAST_BODY and returns wget's exit code, so callers can tell 401
# (exit 6) from 403 (exit 8).
#
# Separate from mc_sql on purpose: mc_sql's success test is SQL-shaped and
# only meaningful on /sql?mode=raw.
#   Usage: mc_post <path> <body> [content-type]
mc_post() {
    local _path="$1"
    local _body="$2"
    local _ctype="${3:-}"
    local _ec=0
    if [ -n "$_ctype" ]; then
        MC_LAST_BODY=$(wget -q --content-on-error -O - \
            --header="$MC_AUTH_HEADER" \
            --header="Content-Type: $_ctype" \
            --post-data="$_body" \
            "http://${MC_HOST}:${MC_PORT}${_path}" 2>/dev/null) || _ec=$?
    else
        MC_LAST_BODY=$(wget -q --content-on-error -O - \
            --header="$MC_AUTH_HEADER" \
            --post-data="$_body" \
            "http://${MC_HOST}:${MC_PORT}${_path}" 2>/dev/null) || _ec=$?
    fi
    return "$_ec"
}

# Run a statement and extract the raw bearer token it returns.
#
# The same extraction lives in the host wrapper's mint_admin_token(), which
# cannot source this file — keep the two in step.
#
# Three details matter:
#   - Isolate the "data" array first, so a greedy match cannot run across
#     rows.
#   - Anchor on `"token":"` INCLUDING the quote. The response also carries a
#     schema block containing {"token":{"type":"string"}}, and a brace
#     instead of a quote is what keeps the pattern off it.
#   - Match by NAME, never by position: CREATE USER returns
#     (token, username, generated_at) while TOKEN returns (username, token).
mc_token() {
    local _r _t
    _r=$(mc_sql "$1") || return 1
    _t=$(printf '%s' "$_r" | tr -d '\n' |
         sed 's/.*"data":\[//; s/\].*//' |
         sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
    # Not paranoia: SHOW TOKEN FOR a nonexistent user answers HTTP 200 with
    # an empty data array and no error at all, which passes every other
    # test here. Without this check that would be written out as a valid
    # empty credential.
    if [ -z "$_t" ]; then
        err "manticore: no token in the response."
        return 1
    fi
    printf '%s' "$_t"
}

# Issue (mint or rotate) a bearer token for one named user.
#
# This is the ONLY place a TOKEN statement is built, and it is a function
# rather than an inline statement for one reason: `TOKEN` with no username
# does not fail, it rotates the credential of whatever identity the
# connection is authenticated as. Over the /cli endpoint that identity is
# the engine's internal `system.buddy` account, and rotating it breaks Buddy
# permanently — no restart, re-mint or repair recovers it; the data volume
# has to be destroyed. So: never build this statement by concatenation
# elsewhere, and never let the username be empty or internal.
mc_issue_token() {
    local user="${1:-}"
    if [ -z "$user" ]; then
        err "Refusing to issue a token without a username."
        err "A bare TOKEN statement would rotate the credential of the"
        err "connection's own identity, which can permanently break the"
        err "engine's internal Buddy account."
        return 1
    fi
    case "$user" in
        system.*)
            err "Refusing to issue a token for the internal user '$user'."
            err "Rotating an internal credential permanently breaks it."
            return 1
            ;;
    esac
    mc_token "TOKEN '$user'"
}

# Split the `data` array of a /sql?mode=raw response into one JSON row per
# line, so the row patterns below cannot match across rows.
mc_rows() {
    tr -d '\n' | sed 's/.*"data":\[//; s/\].*//; s/},{/}\
{/g'
}

# Operator-visible users, one per line.
#
# SHOW USERS returns a single `username` column — no type, no flag, no
# created-at. The `system.` name prefix is therefore the ONLY way to tell an
# internal account from one an operator made, which is why every list here
# filters it out: the script must never offer to drop, grant on, or re-token
# an internal user.
mc_user_list() {
    local body
    body=$(mc_sql 'SHOW USERS') || return 1
    printf '%s' "$body" | mc_rows |
        sed -n 's/.*"username":"\([^"]*\)".*/\1/p' |
        awk '$0 !~ /^system\./'
}

# Read the user list once, into MC_USERS, and fail loudly if the engine
# cannot be asked.
#
# mc_user_exists deliberately does NOT call the engine itself: as a pipeline
# ending in grep it would report a stopped daemon or a rejected token as
# "that user does not exist", and the caller would go on to offer to create
# a user that is already there. Every caller loads the list first, so a
# failure to reach the engine surfaces as a failure.
mc_load_users() {
    MC_USERS=$(mc_user_list) || return 1
    MC_USERS_LOADED=yes
}

# Answers only from a list that was actually loaded. Returning "no such
# user" for an unloaded list would put the silent wrong answer back, one
# level up: the caller would go on to create a user that already exists. An
# empty list IS a valid answer, so the flag is what distinguishes the two.
mc_user_exists() {
    if [ "$MC_USERS_LOADED" != "yes" ]; then
        err "Internal error: mc_user_exists called before mc_load_users."
        exit 70
    fi
    printf '%s\n' "$MC_USERS" | grep -qx "$1"
}

# Grants, as "username action target" lines, internal users filtered.
mc_permissions() {
    local body
    body=$(mc_sql 'SHOW PERMISSIONS') || return 1
    printf '%s' "$body" | mc_rows |
        sed -n 's/.*"username":"\([^"]*\)".*"action":"\([^"]*\)".*"target":"\([^"]*\)".*/\1 \2 \3/p' |
        awk '$1 !~ /^system\./'
}

# Grant the application grants that are missing, and only those.
#
# Issuing them unconditionally would mean relying on a duplicate GRANT being
# harmless, which has not been established. Reading the current state first
# avoids the question entirely. This script never issues REVOKE, so a
# permission row's presence means the grant is in force.
mc_ensure_grants() {
    local user="$1"
    local perms action
    perms=$(mc_permissions) || return 1
    for action in $APP_GRANTS; do
        if printf '%s\n' "$perms" |
                awk -v u="$user" -v a="$action" \
                    '$1 == u && $2 == a && $3 == "*" { found = 1 }
                     END { exit !found }'; then
            info "  grant $action: already present"
        else
            mc_sql "GRANT $action ON * TO '$user'" >/dev/null || return 1
            ok "  grant $action: granted"
        fi
    done
}

# Create the application user with the given password.
#
# CREATE USER also mints a bearer token for the new user and returns it,
# whether or not anyone asked for one — so the user HAS a token from the
# moment it exists. We deliberately discard it: the Drupal module can only
# authenticate with a username and password today, and an unused credential
# is one more thing that could leak. It is not that no token was issued.
mc_create_user() {
    local user="$1"
    local password="$2"
    mc_sql "CREATE USER '$user' IDENTIFIED BY '$password'" >/dev/null || return 1
}

mc_set_password() {
    local user="$1"
    local password="$2"
    mc_sql "SET PASSWORD '$password' FOR '$user'" >/dev/null || return 1
}

# Report one application-credential probe, naming the grant it exercises.
#   Usage: app_probe <label> <grant> <path> <body> [content-type]
app_probe() {
    local label="$1"
    local grant="$2"
    local _ec=0
    shift 2
    mc_post "$@" || _ec=$?

    if [ "$_ec" -eq 0 ]; then
        ok "  $label: OK (grant '$grant')"
        return 0
    fi

    err "  $label: FAILED (grant '$grant')"
    local _msg
    _msg=$(printf '%s' "$MC_LAST_BODY" | tr -d '\n' |
        sed -n 's/.*"error":"\([^"]*\)".*/\1/p')
    [ -n "$_msg" ] && err "    manticore: $_msg"
    case "$_ec" in
        # Measured: wget exits 6 on 401 and 8 on 403, which is exactly the
        # difference between "this credential was refused" and "this
        # credential is fine but lacks the grant".
        6) err "    HTTP 401 — the daemon did not accept this username and password." ;;
        8) err "    HTTP 403 — authenticated, but the '$grant' grant is missing." ;;
        4) err "    Cannot reach the daemon at ${MC_HOST}:${MC_PORT}." ;;
        *) err "    wget exit $_ec." ;;
    esac
    return 1
}

# Verify the credential the operator is about to paste into Drupal.
#
# The admin `check` only proves that the engine answers THIS SCRIPT. It says
# nothing about the application user, so while its password is still in hand
# we use it: authenticate over HTTP Basic — the module's own transport — and
# exercise all three grants, against a scratch table created and dropped
# here so nothing is left behind.
#
# Requires the admin credential to be the current one on entry, and restores
# it before returning.
#
# The restore and the scratch-table drop both live in mc_verify_cleanup, and
# every exit from this function goes through it — including Ctrl-C, via the
# trap. Leaving that to a single tail-end block would mean any early return
# added later silently left the script authenticated as the application user
# and a cfgcheck_* table behind in the operator's index list.
MC_VERIFY_ADMIN_HEADER=""
MC_VERIFY_TABLE=""

mc_verify_cleanup() {
    if [ -n "$MC_VERIFY_ADMIN_HEADER" ]; then
        MC_AUTH_HEADER="$MC_VERIFY_ADMIN_HEADER"
        MC_VERIFY_ADMIN_HEADER=""
    fi
    if [ -n "$MC_VERIFY_TABLE" ]; then
        mc_sql "DROP TABLE IF EXISTS $MC_VERIFY_TABLE" >/dev/null 2>&1 ||
            warn "Could not drop the scratch table '$MC_VERIFY_TABLE'."
        MC_VERIFY_TABLE=""
    fi
}

mc_verify_app() {
    local user="$1"
    local password="$2"
    local failures=0

    MC_VERIFY_ADMIN_HEADER="$MC_AUTH_HEADER"
    MC_VERIFY_TABLE="cfgcheck_$(tr -dc 'a-z0-9' </dev/urandom | head -c 8)"
    trap 'mc_verify_cleanup; trap - INT TERM HUP; exit 130' INT TERM HUP

    info "Verifying the application credential ($user) over HTTP Basic..."

    if ! mc_sql "CREATE TABLE $MC_VERIFY_TABLE (title text)" >/dev/null; then
        warn "Could not create a scratch table; skipping the credential check."
        # Nothing to drop — creation is what failed.
        MC_VERIFY_TABLE=""
        mc_verify_cleanup
        trap - INT TERM HUP
        return 1
    fi

    mc_auth_basic "$user" "$password"

    # Indexing first, so the read probe has something to find. The module
    # indexes through /bulk with `replace` operations; the trailing newline
    # is part of the ndjson format.
    app_probe "index a document (/bulk)" "write" \
        "/bulk" \
        "{\"replace\":{\"table\":\"$MC_VERIFY_TABLE\",\"id\":1,\"doc\":{\"title\":\"config probe\"}}}
" \
        "application/x-ndjson" || failures=$((failures + 1))

    app_probe "search (/search)" "read" \
        "/search" \
        "{\"table\":\"$MC_VERIFY_TABLE\",\"query\":{\"match\":{\"title\":\"probe\"}}}" \
        "application/json" || failures=$((failures + 1))

    # SHOW STATUS is the module's isAvailable() probe. If this one fails,
    # Drupal reports the whole backend as down while search and indexing
    # would in fact work.
    app_probe "availability probe (SHOW STATUS)" "schema" \
        "$MC_SQL_PATH" "SHOW STATUS" || failures=$((failures + 1))

    mc_verify_cleanup
    trap - INT TERM HUP

    [ "$failures" -eq 0 ] && return 0
    return 1
}

# Print the application password, once.
show_password() {
    local user="$1"
    local password="$2"
    echo ""
    bold "============================================================"
    bold "  PASSWORD for '$user' (save this NOW — shown only once):"
    echo ""
    printf '      %s%s%s\n' "$C_BOLD" "$password" "$C_RESET"
    echo ""
    bold "============================================================"
    echo ""
    echo "It is not stored in $ENV_FILE, or anywhere else in this repo."
    echo "Put it straight into the Drupal Key entity your Search API"
    echo "server uses, alongside the username '$user'."
    echo ""
}

# -----------------------------------------------------------------------------
# Subcommand: show
# -----------------------------------------------------------------------------
cmd_show() {
    if [ ! -f "$ENV_FILE" ]; then
        warn "No $ENV_FILE found. Run './config setup' to create one."
        return 1
    fi
    local scenario domain email username token
    scenario=$(get_env_var MANTICORE_SCENARIO || true)
    domain=$(get_env_var MANTICORE_DOMAIN || true)
    email=$(get_env_var MANTICORE_ACME_EMAIL || true)
    username=$(get_env_var MANTICORE_USERNAME || true)
    token=$(get_env_var MANTICORE_ADMIN_TOKEN || true)

    bold "Current configuration ($ENV_FILE)"
    printf '\n'
    if [ -n "$scenario" ]; then
        printf '  MANTICORE_SCENARIO     = %s\n' "$(scenario_label "$scenario")"
    else
        printf '  MANTICORE_SCENARIO     = %s%s%s\n' \
            "$C_YELLOW" "$(scenario_label "")" "$C_RESET"
    fi
    printf '  MANTICORE_DOMAIN       = %s\n'  "${domain:-${C_YELLOW}(not set)${C_RESET}}"
    printf '  MANTICORE_ACME_EMAIL   = %s\n'  "${email:-${C_YELLOW}(not set)${C_RESET}}"
    printf '  MANTICORE_USERNAME     = %s\n'  "${username:-${C_YELLOW}(not set)${C_RESET}}"
    printf '  MANTICORE_ADMIN_TOKEN  = %s\n'  "$(mask_token "$token")"
    printf '\n'
    if [ -z "$scenario" ]; then
        # No value is inferred. MANTICORE_DOMAIN=localhost in particular is
        # not proof of Scenario A — a Scenario B operator may legitimately
        # have used it — and which scenario a host runs is the operator's
        # decision, not ours to guess.
        echo "  This $ENV_FILE predates MANTICORE_SCENARIO. Everything works"
        echo "  without it; the next './config setup' records your answer."
        printf '\n'
    fi
    echo "  The application user's password is not stored here."
    echo "  Issue a new one with './config password change'."
    printf '\n'

    # The engine's own state. This is best-effort on purpose: a stopped
    # stack or a missing token is exactly the sort of thing an operator runs
    # `show` to diagnose, so it warns instead of failing.
    bold "Engine users and grants"
    printf '\n'
    if ! mc_auth_admin 2>/dev/null; then
        warn "  No admin token in $ENV_FILE — cannot query the engine."
        warn "  Run './config setup'."
        printf '\n'
        return 0
    fi

    local users perms user
    if ! users=$(mc_user_list); then
        warn "  Could not read the engine's users (see the error above)."
        printf '\n'
        return 0
    fi

    perms=$(mc_permissions || true)
    for user in $users; do
        printf '  %s\n' "$user"
        printf '%s\n' "$perms" | awk -v u="$user" '$1 == u { printf "      %s on %s\n", $2, $3 }'
    done
    printf '\n'
    echo "  Internal (system.*) accounts are deliberately not listed."
    printf '\n'
}

# -----------------------------------------------------------------------------
# Subcommand: check
# -----------------------------------------------------------------------------
# An authenticated query. The compose healthcheck deliberately accepts an
# unauthenticated 401 as "alive", because it has to be green before any admin
# exists — so it proves the daemon is listening, not that it can execute
# anything. This closes that gap.
cmd_check() {
    mc_auth_admin || return 1
    info "Running an authenticated query against ${MC_HOST}:${MC_PORT}..."
    if mc_sql 'SELECT 1' >/dev/null; then
        ok "The engine accepted the admin token and executed a query."
        echo ""
        echo "Note: this checks the admin credential from $ENV_FILE. The"
        echo "application user's password is not stored, so it cannot be"
        echo "checked here — './config password change' verifies a new one"
        echo "at the moment it is issued."
        return 0
    fi
    return 1
}

# -----------------------------------------------------------------------------
# Subcommand: domain <value>
# -----------------------------------------------------------------------------
cmd_domain() {
    local value="${1:-}"
    if [ -z "$value" ]; then
        err "Error: domain value required."
        echo "Usage: ./config domain <fqdn>" >&2
        return 1
    fi
    if ! validate_domain "$value"; then
        err "Error: '$value' is not a valid domain name."
        echo "Expected: lowercase letters, digits, hyphens, dots." >&2
        echo "Example: search.example.com" >&2
        return 1
    fi
    if ! preview_change MANTICORE_DOMAIN "$value"; then
        return 0
    fi
    if confirm "Apply this change?"; then
        set_env_var MANTICORE_DOMAIN "$value"
        restore_env_ownership
        ok "Updated MANTICORE_DOMAIN."
        remind_recreate_caddy
        return 10
    else
        info "Aborted. $ENV_FILE was not modified."
        return 0
    fi
}

# -----------------------------------------------------------------------------
# Subcommand: email <value>
# -----------------------------------------------------------------------------
cmd_email() {
    local value="${1:-}"
    if [ -z "$value" ]; then
        err "Error: email value required."
        echo "Usage: ./config email <addr>" >&2
        return 1
    fi
    if ! validate_email "$value"; then
        err "Error: '$value' is not a valid email address."
        return 1
    fi
    if ! preview_change MANTICORE_ACME_EMAIL "$value"; then
        return 0
    fi
    if confirm "Apply this change?"; then
        set_env_var MANTICORE_ACME_EMAIL "$value"
        restore_env_ownership
        ok "Updated MANTICORE_ACME_EMAIL."
        remind_recreate_caddy
        return 10
    else
        info "Aborted. $ENV_FILE was not modified."
        return 0
    fi
}

# -----------------------------------------------------------------------------
# Subcommand: username <value>
# -----------------------------------------------------------------------------
# Changes MANTICORE_USERNAME and makes the engine match.
#
# The engine has no rename: there is no ALTER USER and no RENAME USER, only
# CREATE and DROP. A "rename" is therefore a new user with a new password,
# and the old one is dropped separately and only if the operator says so.
# That also means the Drupal Key entity has to be updated — the old password
# cannot be carried across.
cmd_username() {
    local value="${1:-}"
    if [ -z "$value" ]; then
        err "Error: username value required."
        echo "Usage: ./config username <name>" >&2
        return 1
    fi
    if ! validate_username "$value"; then
        err "Error: '$value' is not a valid username."
        echo "Expected: 1-32 chars, letters/digits/underscore/hyphen." >&2
        echo "A colon in particular would break HTTP Basic authentication." >&2
        return 1
    fi

    mc_auth_admin || return 1
    mc_load_users || return 1

    local current
    current=$(get_env_var MANTICORE_USERNAME 2>/dev/null || true)

    if [ "$current" = "$value" ] && mc_user_exists "$value"; then
        info "No change: MANTICORE_USERNAME is already '$value' and the user exists."
        return 0
    fi

    if [ "$current" != "$value" ]; then
        echo ""
        info "This creates the user '$value' in the engine and points"
        info "$ENV_FILE at it. The engine cannot rename a user, so '$value'"
        info "gets a NEW password — Drupal's Key entity must be updated."
        preview_change MANTICORE_USERNAME "$value" || true
        if ! confirm "Apply this change?"; then
            info "Aborted. $ENV_FILE was not modified."
            return 0
        fi
    fi

    local password=""
    if mc_user_exists "$value"; then
        info "The user '$value' already exists in the engine; keeping its"
        info "current password. Use './config password change' to issue a"
        info "new one."
    else
        password=$(generate_password)
        require_password "$password" || return 1
        mc_create_user "$value" "$password" || return 1
        ok "Created engine user '$value'."
    fi

    mc_ensure_grants "$value" || return 1

    set_env_var MANTICORE_USERNAME "$value"
    restore_env_ownership
    ok "Updated MANTICORE_USERNAME."

    if [ -n "$password" ]; then
        mc_verify_app "$value" "$password" ||
            warn "The new credential did not pass every check — see above."
        show_password "$value" "$password"
    fi

    # The old user is left in place unless the operator says otherwise:
    # dropping it invalidates whatever is still using it.
    #
    # Reloaded because the list was read before '$value' was created — the
    # answer for '$current' would not change, but reasoning about which
    # snapshot is current is exactly the trap this pattern exists to close.
    mc_load_users || return 1
    if [ -n "$current" ] && [ "$current" != "$value" ] && mc_user_exists "$current"; then
        echo ""
        info "The previous user '$current' still exists in the engine, with"
        info "its own password and grants. Anything still configured with it"
        info "keeps working until it is dropped."
        if confirm "Drop the engine user '$current'?"; then
            mc_sql "DROP USER '$current'" >/dev/null || return 1
            ok "Dropped engine user '$current'."
        else
            info "Kept '$current'. Dropping it later is a manual step — there"
            info "is no subcommand for it, and this prompt will not appear"
            info "again. As the admin, the statement is:"
            info "  DROP USER '$current';"
        fi
    fi

    # Nothing Caddy reads has changed, so no recreate is needed.
    return 0
}

# -----------------------------------------------------------------------------
# Subcommand: password change
# Prompts for the new password interactively (with confirmation) — never
# accepts the password as an argument, since CLI arguments leak through
# shell history, process listings (ps aux), and SSH session logs.
# -----------------------------------------------------------------------------
cmd_password_change() {
    # Reject any positional argument — guards against accidental misuse
    # with a clear, actionable error.
    if [ $# -gt 0 ]; then
        err "Error: 'password change' does not accept arguments."
        echo "" >&2
        echo "Passwords passed on the command line are stored in shell history" >&2
        echo "and visible in process listings — that is unsafe." >&2
        echo "" >&2
        echo "Run the command without arguments:" >&2
        echo "" >&2
        echo "  ./config password change" >&2
        return 1
    fi

    mc_auth_admin || return 1
    mc_load_users || return 1

    local user
    user=$(get_env_var MANTICORE_USERNAME 2>/dev/null || true)
    if [ -z "$user" ]; then
        err "No MANTICORE_USERNAME in $ENV_FILE."
        echo "Run './config setup' first." >&2
        return 1
    fi
    if ! mc_user_exists "$user"; then
        err "The engine has no user '$user'."
        echo "Create it with './config username $user'." >&2
        return 1
    fi

    bold "New password for the application user '$user'"
    echo ""
    echo "  1) Generate a strong random password (recommended)"
    echo "  2) Enter your own password"
    echo ""
    local choice password generated=no
    while :; do
        printf '%sChoice%s [1]: ' "$C_BOLD" "$C_RESET"
        read -r choice || choice=""
        [ -z "$choice" ] && choice="1"
        case "$choice" in
            1) password=$(generate_password); generated=yes; break ;;
            2) password=$(prompt_password_with_confirm); break ;;
            *) err "  Please answer 1 or 2." ;;
        esac
    done
    require_password "$password" || return 1

    echo ""
    warn "This replaces the password Drupal is using right now. Indexing and"
    warn "search will fail until the Key entity is updated."
    if ! confirm "Change the password for '$user'?"; then
        info "Aborted. Nothing was changed."
        [ "$generated" = "yes" ] && info "The generated password was discarded."
        return 0
    fi

    mc_set_password "$user" "$password" || return 1
    ok "Password changed in the engine."

    # Verify with the password we just set, before it is displayed and
    # forgotten — the same three probes the wizard runs.
    mc_verify_app "$user" "$password" ||
        warn "The new credential did not pass every check — see above."

    show_password "$user" "$password"
    return 0
}

# -----------------------------------------------------------------------------
# Subcommand: password (router)
# -----------------------------------------------------------------------------
cmd_password() {
    local action="${1:-}"
    shift 2>/dev/null || true
    case "$action" in
        change) cmd_password_change "$@" ;;
        "")
            err "Error: password subcommand required."
            echo "" >&2
            echo "Available actions:" >&2
            echo "  change            New password for the application user" >&2
            return 1
            ;;
        *)
            err "Error: unknown password subcommand: $action"
            echo "Try: change" >&2
            return 1
            ;;
    esac
}

# -----------------------------------------------------------------------------
# Subcommand: token rotate
# -----------------------------------------------------------------------------
cmd_token_rotate() {
    mc_auth_admin || return 1

    echo ""
    warn "Rotating the admin token invalidates the current one immediately."
    warn "Anything using MANTICORE_ADMIN_TOKEN elsewhere will stop working."
    if ! confirm "Rotate the admin token?"; then
        info "Aborted. Nothing was changed."
        return 0
    fi

    local token
    token=$(mc_issue_token "$ADMIN_USER") || return 1

    set_env_var MANTICORE_ADMIN_TOKEN "$token"
    restore_env_ownership
    ok "Wrote a new MANTICORE_ADMIN_TOKEN to $ENV_FILE."

    # Prove the value we just stored actually works.
    mc_auth_admin || return 1
    if mc_sql 'SELECT 1' >/dev/null; then
        ok "The new token authenticates."
    else
        err "The new token did not authenticate — see the error above."
        return 1
    fi

    # Caddy holds no credentials, so nothing needs recreating.
    return 0
}

cmd_token() {
    local action="${1:-}"
    shift 2>/dev/null || true
    case "$action" in
        rotate) cmd_token_rotate "$@" ;;
        "")
            err "Error: token subcommand required."
            echo "" >&2
            echo "Available actions:" >&2
            echo "  rotate            Issue a new admin token" >&2
            return 1
            ;;
        *)
            err "Error: unknown token subcommand: $action"
            echo "Try: rotate" >&2
            return 1
            ;;
    esac
}

# -----------------------------------------------------------------------------
# Subcommand: setup — interactive wizard
# -----------------------------------------------------------------------------

# Read a value with prompt, default, and validator.
#   Usage: prompt_value PROMPT DEFAULT VALIDATOR_FN ERROR_HINT
#   - DEFAULT: shown in [brackets] if non-empty; used when user enters blank.
#     Pass empty string if there is no default (e.g. username).
#   - VALIDATOR_FN: name of a function that returns 0 if value is valid.
#     Pass empty string to skip validation.
#   - ERROR_HINT: shown on invalid input before re-prompting.
# Echoes the accepted value on stdout.
prompt_value() {
    local prompt="$1"
    local default_value="$2"
    local validator="$3"
    local hint="$4"
    local value
    while :; do
        if [ -n "$default_value" ]; then
            printf '%s%s%s [%s]: ' "$C_BOLD" "$prompt" "$C_RESET" "$default_value" >&2
        else
            printf '%s%s%s: ' "$C_BOLD" "$prompt" "$C_RESET" >&2
        fi
        read -r value || value=""
        # Apply default on blank input.
        if [ -z "$value" ] && [ -n "$default_value" ]; then
            value="$default_value"
        fi
        if [ -z "$value" ]; then
            err "  This field is required." >&2
            continue
        fi
        if [ -n "$validator" ] && ! "$validator" "$value"; then
            err "  Invalid: $hint" >&2
            continue
        fi
        printf '%s' "$value"
        return 0
    done
}

# Read a password from stdin without echoing it. Re-prompts on mismatch.
# Returns the accepted plaintext on stdout.
prompt_password_with_confirm() {
    local pwd1 pwd2
    # Show rules up front so the user knows what is acceptable before
    # typing anything. The two forbidden characters are not a style
    # preference: they are the only two the engine's CREATE USER cannot
    # parse.
    echo "Password rules:" >&2
    echo "  - At least 8 characters (the engine's own minimum)." >&2
    echo "  - A single quote (') and a backslash (\\) are not allowed —" >&2
    echo "    the engine cannot parse either one." >&2
    echo "  - Anything else is accepted, but avoid \$ \" \` ! if you plan" >&2
    echo "    to paste the password into a shell command unquoted." >&2
    echo "" >&2
    while :; do
        printf '%sEnter password%s (input hidden): ' "$C_BOLD" "$C_RESET" >&2
        stty -echo 2>/dev/null || true
        read -r pwd1 || pwd1=""
        stty echo 2>/dev/null || true
        printf '\n' >&2

        if [ -z "$pwd1" ]; then
            err "  Password cannot be empty." >&2
            continue
        fi
        if [ "${#pwd1}" -lt 8 ]; then
            err "  Password must be at least 8 characters." >&2
            continue
        fi
        case "$pwd1" in
            *\'*|*\\*)
                err "  Remove the single quote or backslash — the engine" >&2
                err "  cannot parse either in a password." >&2
                continue
                ;;
        esac

        printf '%sConfirm password%s (input hidden): ' "$C_BOLD" "$C_RESET" >&2
        stty -echo 2>/dev/null || true
        read -r pwd2 || pwd2=""
        stty echo 2>/dev/null || true
        printf '\n' >&2

        if [ "$pwd1" != "$pwd2" ]; then
            err "  Passwords do not match. Please try again." >&2
            continue
        fi
        printf '%s' "$pwd1"
        return 0
    done
}

# Refuse a phase that only makes sense when the host wrapper is driving.
require_wrapper() {
    [ "$CONFIG_WRAPPER" = "1" ] && return 0
    err "Error: '$1' is part of './config setup' and needs the host wrapper."
    echo "" >&2
    echo "The engine's admin is bootstrapped by a local searchd call that" >&2
    echo "cannot be made from this container. Run:" >&2
    echo "  ./config setup" >&2
    return 1
}

# Tell the operator which upgrade they are in the middle of, before anything
# is written. There are two distinct 1.0.0 starting points and they need
# different things said to them.
announce_env_state() {
    local hash token

    if [ ! -f "$ENV_FILE" ]; then
        hash=""
        token=""
    else
        hash=$(get_env_var MANTICORE_PASSWORD_HASH 2>/dev/null || true)
        token=$(get_env_var MANTICORE_ADMIN_TOKEN 2>/dev/null || true)
    fi

    if [ -n "$token" ]; then
        return 0
    fi

    echo ""
    if [ -n "$hash" ]; then
        # 1.0.0 Scenario B: Caddy was checking a bcrypt hash from .env.
        bold "Upgrading from 1.0.0 (Caddy Basic Auth)"
        echo ""
        echo "Authentication has moved from the Caddy reverse proxy into the"
        echo "Manticore engine, which now checks credentials itself on both"
        echo "the HTTP and MySQL protocols."
        echo ""
        echo "  - MANTICORE_PASSWORD_HASH is no longer used by anything and"
        echo "    will be removed from $ENV_FILE."
        echo "  - The application user is created in the engine, with a new"
        echo "    password shown to you once."
        echo "  - Caddy keeps doing TLS, and nothing else."
        echo ""
        echo "On the Drupal side this is a small change: the connector's"
        echo "settings keep the same shape (URL, username, password key), so"
        echo "only the value inside the Key entity needs updating."
    else
        # Either a fresh install, or 1.0.0 Scenario A, which had no
        # credentials at all. The second case is the one that can surprise
        # someone, so it is spelled out.
        bold "Manticore now requires credentials"
        echo ""
        echo "The engine authenticates every request, in every deployment —"
        echo "including a local one with no reverse proxy in front of it."
        echo ""
        echo "If you are upgrading from 1.0.0 without Caddy, this is new:"
        echo "requests that used to work with no credentials will return"
        echo "HTTP 401 from now on. Your Drupal connector needs a username"
        echo "and a Key entity holding the password for the first time."
        echo ""
        echo "Your indexed data is not affected."
    fi
    echo ""
    confirm "Continue?" || return 1
}

# Phase 1 of the wizard: collect .env values. Touches nothing else, so
# aborting here leaves the engine exactly as it was.
#   Exit 11 = values written, the wrapper should continue.
#   Exit 0  = aborted or nothing to do.
cmd_setup_collect() {
    require_wrapper setup-collect || return 1

    bold "============================================================"
    bold "  Manticore Search Docker Stack — interactive setup"
    bold "============================================================"

    announce_env_state || { info "Aborted. Nothing was changed."; return 0; }

    if [ -f "$ENV_FILE" ]; then
        local cur_scenario cur_domain cur_email cur_username
        cur_scenario=$(get_env_var MANTICORE_SCENARIO 2>/dev/null || true)
        cur_domain=$(get_env_var MANTICORE_DOMAIN 2>/dev/null || true)
        cur_email=$(get_env_var MANTICORE_ACME_EMAIL 2>/dev/null || true)
        cur_username=$(get_env_var MANTICORE_USERNAME 2>/dev/null || true)

        # MANTICORE_SCENARIO is deliberately NOT counted here. A .env written
        # before that key existed is complete in every way that matters, and
        # letting its absence skip the overwrite confirmation below would make
        # the wizard less careful with older installs, not more.
        local empty_count=0
        [ -z "$cur_domain" ]   && empty_count=$((empty_count + 1))
        [ -z "$cur_email" ]    && empty_count=$((empty_count + 1))
        [ -z "$cur_username" ] && empty_count=$((empty_count + 1))

        # Note: .env.example ships with non-empty placeholders for all
        # three fields (search.example.com, admin@example.com, drupal).
        # Those count as "filled" for the empty_count above, but they are
        # placeholders, not real values. The wizard treats them as defaults
        # and the user can accept or override.
        if [ "$empty_count" -eq 0 ]; then
            warn ".env already exists and is fully populated."
            echo "" >&2
            echo "Current values:" >&2
            echo "  MANTICORE_SCENARIO   = $(scenario_label "$cur_scenario")" >&2
            echo "  MANTICORE_DOMAIN     = $cur_domain" >&2
            echo "  MANTICORE_ACME_EMAIL = $cur_email" >&2
            echo "  MANTICORE_USERNAME   = $cur_username" >&2
            echo "" >&2
            if ! confirm "Re-run setup and overwrite these values?"; then
                info "Aborted. No changes made."
                return 0
            fi
        else
            info ".env exists with $empty_count empty field(s); continuing setup."
        fi
    else
        info "Creating $ENV_FILE from $ENV_EXAMPLE."
        ensure_env_file
    fi
    echo ""

    # Step 1: the deployment scenario.
    #
    # Labelled without a total on purpose: the total is 3 or 4, and the
    # answer to this very question is what decides which. Every label after
    # this one carries $total_steps.
    #
    # The scenario is asked, never inferred — not from COMPOSE_PROFILES, not
    # from the current MANTICORE_DOMAIN, not from anything else. Which
    # scenario a host runs is the operator's decision.
    bold "Step 1 — Deployment scenario"
    echo "A — single VPS. Manticore listens on 127.0.0.1 only, for a Drupal"
    echo "    site on this same host (or your own reverse proxy in front)."
    echo "    No Caddy, no public port, no domain needed."
    echo "B — dedicated Manticore VPS with the bundled Caddy reverse proxy,"
    echo "    started with '--profile public'. Caddy terminates TLS on a"
    echo "    public domain and obtains a Let's Encrypt certificate."
    echo ""
    # An already-recorded scenario is offered as the default, so a re-run
    # does not make the operator answer this again.
    local default_scenario
    default_scenario=$(get_env_var MANTICORE_SCENARIO 2>/dev/null || true)
    local new_scenario
    new_scenario=$(prompt_value "Scenario (A or B)" "$default_scenario" \
        validate_scenario "answer A or B")
    # Lowercase is accepted above; only A or B is ever written.
    new_scenario=$(printf '%s' "$new_scenario" | tr 'ab' 'AB')
    echo ""

    local total_steps
    if [ "$new_scenario" = "A" ]; then
        total_steps=3
    else
        total_steps=4
    fi
    info "Scenario $new_scenario — $total_steps steps in total."
    echo ""

    local new_domain default_email placeholder_email=no
    if [ "$new_scenario" = "A" ]; then
        # Scenario A has no Caddy, so there is nothing to ask a domain for.
        #
        # 'localhost' is deliberate, and it is not a stand-in for "unset". If
        # someone later starts '--profile public' on this host by mistake,
        # Caddy sees a local hostname, issues a self-signed certificate from
        # its internal CA and stays quiet. A non-resolving hostname would
        # instead send it into repeated Let's Encrypt attempts against a
        # domain that can never validate.
        new_domain="localhost"

        # The ACME email is still asked. Nothing reads it in Scenario A —
        # with a local hostname Caddy uses its internal CA and never contacts
        # an ACME endpoint — but the Caddyfile's `tls {$MANTICORE_ACME_EMAIL}`
        # needs an argument to parse at all, so the key cannot be left empty.
        # A default is offered and any fallback to the placeholder is
        # announced below: an invented value silently written into a
        # production .env is one nobody can account for months later.
        bold "Step 2 of $total_steps — ACME email"
        echo "Not used in Scenario A: with a local hostname Caddy uses its"
        echo "internal CA and never contacts Let's Encrypt. It is asked"
        echo "because the value must not be empty, and because it is already"
        echo "correct if you later switch to Scenario B."
        echo "Rules: standard email form, e.g. $PLACEHOLDER_EMAIL."
        echo ""
        default_email=$(get_env_var MANTICORE_ACME_EMAIL 2>/dev/null || true)
        # Unlike Scenario B below, the placeholder is NOT stripped here: it
        # is a perfectly good answer for a deployment that never uses it, and
        # leaving the operator with no default at all would only invite an
        # invented address.
        [ -z "$default_email" ] && default_email="$PLACEHOLDER_EMAIL"
    else
        bold "Step 2 of $total_steps — Domain name"
        echo "The fully-qualified hostname pointing at this VPS, with a public"
        echo "DNS A record. Example: $PLACEHOLDER_DOMAIN"
        echo "Rules: lowercase letters, digits, hyphens and dots only."
        echo ""
        local default_domain
        default_domain=$(get_env_var MANTICORE_DOMAIN 2>/dev/null || true)
        # Strip the placeholder from .env.example so the user is not nudged
        # into accepting it accidentally.
        [ "$default_domain" = "$PLACEHOLDER_DOMAIN" ] && default_domain=""
        new_domain=$(prompt_value "Domain" "$default_domain" validate_domain \
            "lowercase letters, digits, hyphens and dots only")
        echo ""

        bold "Step 3 of $total_steps — ACME email"
        echo "Email address used by Let's Encrypt for renewal notices."
        echo "Rules: standard email form, e.g. $PLACEHOLDER_EMAIL."
        echo ""
        default_email=$(get_env_var MANTICORE_ACME_EMAIL 2>/dev/null || true)
        [ "$default_email" = "$PLACEHOLDER_EMAIL" ] && default_email=""
    fi

    local new_email
    new_email=$(prompt_value "Email" "$default_email" validate_email \
        "must look like name@domain.tld")
    if [ "$new_scenario" = "A" ] && [ "$new_email" = "$PLACEHOLDER_EMAIL" ]; then
        placeholder_email=yes
    fi
    echo ""

    # Last step: username. Same in both scenarios.
    bold "Step $total_steps of $total_steps — Application username"
    echo "The engine user the Drupal site will authenticate as. It will be"
    echo "created with exactly the grants the module needs, and a password"
    echo "shown to you once at the end."
    echo "Rules: 1-32 characters, ASCII letters/digits/underscore/hyphen."
    echo ""
    # Unlike the domain and email placeholders above, 'drupal' is NOT
    # stripped. Those two are stripped because search.example.com and
    # admin@example.com cannot work anywhere, so offering them as a default
    # only invites a broken deployment. 'drupal' is a working value and the
    # documented default — blanking it would force the operator to retype
    # their real username on every re-run of the wizard.
    local default_username
    default_username=$(get_env_var MANTICORE_USERNAME 2>/dev/null || true)
    local new_username
    new_username=$(prompt_value "Username" "$default_username" validate_username \
        "1-32 chars, letters/digits/underscore/hyphen")
    echo ""

    bold "Summary"
    echo ""
    echo "  MANTICORE_SCENARIO   = $(scenario_label "$new_scenario")"
    if [ "$new_scenario" = "A" ]; then
        echo "  MANTICORE_DOMAIN     = $new_domain (not asked for; Caddy only,"
        echo "                         and only if you start --profile public)"
    else
        echo "  MANTICORE_DOMAIN     = $new_domain"
    fi
    echo "  MANTICORE_ACME_EMAIL = $new_email"
    echo "  MANTICORE_USERNAME   = $new_username"
    if [ "$placeholder_email" = "yes" ]; then
        echo ""
        warn "The ACME email above is the placeholder from $ENV_EXAMPLE. It is"
        warn "written because the value cannot be empty, and nothing in"
        warn "Scenario A reads it. Set a real one before switching to"
        warn "Scenario B:  ./config email you@example.com"
    fi
    echo ""
    echo "Next, the engine's admin is bootstrapped and the user above is"
    echo "created. Nothing has been changed yet."
    echo ""

    if ! confirm "Write these values to $ENV_FILE and continue?"; then
        warn "Aborted. $ENV_FILE was not modified."
        return 0
    fi

    set_env_var MANTICORE_SCENARIO   "$new_scenario"
    set_env_var MANTICORE_DOMAIN     "$new_domain"
    set_env_var MANTICORE_ACME_EMAIL "$new_email"
    set_env_var MANTICORE_USERNAME   "$new_username"

    # Dead since authentication moved into the engine.
    if [ -n "$(get_env_var MANTICORE_PASSWORD_HASH 2>/dev/null || true)" ]; then
        del_env_var MANTICORE_PASSWORD_HASH
        info "Removed MANTICORE_PASSWORD_HASH — nothing reads it any more."
    fi

    restore_env_ownership
    ok "$ENV_FILE written."
    return 11
}

# Phase 2 of the wizard: everything that needs the engine. By the time this
# runs the host wrapper has bootstrapped the admin and written
# MANTICORE_ADMIN_TOKEN.
cmd_setup_provision() {
    require_wrapper setup-provision || return 1

    mc_auth_admin || return 1
    mc_load_users || return 1

    local user
    user=$(get_env_var MANTICORE_USERNAME 2>/dev/null || true)
    if [ -z "$user" ]; then
        err "No MANTICORE_USERNAME in $ENV_FILE."
        return 1
    fi

    echo ""
    bold "Application user"
    echo ""

    local password=""
    if mc_user_exists "$user"; then
        info "The engine already has a user '$user'."
        echo ""
        echo "Answering 'no' keeps its current password, so a Drupal site"
        echo "already configured with it keeps working."
        echo ""
        if confirm "Issue a new password for '$user'?"; then
            password=$(generate_password)
            require_password "$password" || return 1
            mc_set_password "$user" "$password" || return 1
            ok "New password set for '$user'."
        else
            info "Keeping the existing password for '$user'."
        fi
    else
        password=$(generate_password)
        require_password "$password" || return 1
        mc_create_user "$user" "$password" || return 1
        ok "Created engine user '$user'."
    fi

    echo ""
    info "Grants for '$user':"
    mc_ensure_grants "$user" || return 1

    echo ""
    info "Checking that the engine executes queries..."
    if mc_sql 'SELECT 1' >/dev/null; then
        ok "Admin credential works."
    else
        return 1
    fi

    local verify_failed=no
    if [ -n "$password" ]; then
        echo ""
        mc_verify_app "$user" "$password" || verify_failed=yes
    fi

    echo ""
    ok "Setup complete."

    if [ "$verify_failed" = "yes" ]; then
        echo ""
        warn "One or more checks on the application credential failed — see"
        warn "above. The password is shown below regardless, since you will"
        warn "need it either way."
    fi

    if [ -n "$password" ]; then
        show_password "$user" "$password"
    else
        echo ""
        info "The password for '$user' was left unchanged and is not shown."
        info "Issue a new one with './config password change'."
        echo ""
    fi

    local domain scenario
    domain=$(get_env_var MANTICORE_DOMAIN 2>/dev/null || true)
    scenario=$(get_env_var MANTICORE_SCENARIO 2>/dev/null || true)

    # Scenario A has no Caddy, no public port and no certificate to wait
    # for, so it gets its own closing block. Anything else — including a
    # .env written before MANTICORE_SCENARIO existed — keeps the Scenario B
    # instructions this wizard has always printed.
    if [ "$scenario" = "A" ]; then
        bold "Next steps:"
        echo ""
        echo "  # 1. The manticore service is already running. It listens on"
        echo "  #    127.0.0.1:9308 (HTTP, used by Drupal) and 127.0.0.1:9306"
        echo "  #    (MySQL protocol). Neither port is reachable from outside"
        echo "  #    this host."
        echo ""
        echo "  # 2. Test locally, as the application user:"
        echo "  curl -s -u '$user:<the-password-above>' \\"
        echo "       http://127.0.0.1:9308/sql?mode=raw -d 'SHOW STATUS'"
        echo ""
        echo "  # 3. Put the username and password into Drupal: Search API"
        echo "  #    server settings, with the password held in a Key entity."
        echo "  #    Point it at http://127.0.0.1:9308 — the literal IPv4"
        echo "  #    address, not 'localhost', which resolves to ::1 first on"
        echo "  #    many systems while this port is bound to IPv4 only."
        echo ""
        return 10
    fi

    bold "Next steps:"
    echo ""
    echo "  # 1. Make sure the DNS A record for '$domain' points to this VPS."
    echo ""

    case "$CADDY_RUNNING" in
        yes)
            echo "  # 2. Caddy is already running with the previous values."
            echo "  #    This wrapper will recreate it automatically when"
            echo "  #    the wizard exits — no further action needed."
            ;;
        no)
            echo "  # 2. Start the stack with the public profile:"
            echo "  docker compose --profile public up -d"
            ;;
        *)
            echo "  # 2a. If the stack is NOT yet running, start it:"
            echo "  docker compose --profile public up -d"
            echo ""
            echo "  # 2b. If the stack IS already running, recreate Caddy so it"
            echo "  #     picks up the new values (container env vars are fixed"
            echo "  #     at container creation time, not reread from .env):"
            echo "  docker compose --profile public up -d --force-recreate caddy"
            ;;
    esac
    echo ""
    echo "  # 3. Watch Caddy obtain the Let's Encrypt certificate (10-30s):"
    echo "  docker compose logs -f caddy"
    echo ""
    echo "  # 4. Test from anywhere, as the application user:"
    echo "  curl -s -u '$user:<the-password-above>' \\"
    echo "       https://$domain/sql?mode=raw -d 'SHOW STATUS'"
    echo ""
    echo "  # 5. Put the username and password into Drupal: Search API server"
    echo "  #    settings, with the password held in a Key entity."
    echo ""
    return 10
}

# -----------------------------------------------------------------------------
# Usage / help
# -----------------------------------------------------------------------------
print_usage() {
    cat >&2 <<'USAGE'
Usage:
  ./config <subcommand> [args...]

Subcommands:
  setup                         Interactive wizard for first-time config
  show                          Display .env plus the engine's users/grants
  check                         Authenticated query against the engine
  domain <fqdn>                 Set MANTICORE_DOMAIN
  email <addr>                  Set MANTICORE_ACME_EMAIL
  username <name>               Set MANTICORE_USERNAME and create the user
  password change               New password for the application user
  token rotate                  New admin token in .env
  admin reset                   Wipe all engine users and start again

Examples:
  ./config setup
  ./config show
  ./config check
  ./config domain search.example.com
  ./config email admin@example.com
  ./config username drupal
  ./config password change
  ./config token rotate
USAGE
}

# -----------------------------------------------------------------------------
# Main router
# -----------------------------------------------------------------------------

main() {
    local cmd="${1:-}"
    shift 2>/dev/null || true

    case "$cmd" in
        show)             cmd_show "$@" ;;
        check)            cmd_check "$@" ;;
        domain)           cmd_domain "$@" ;;
        email)            cmd_email "$@" ;;
        username)         cmd_username "$@" ;;
        password)         cmd_password "$@" ;;
        token)            cmd_token "$@" ;;
        setup-collect)    cmd_setup_collect "$@" ;;
        setup-provision)  cmd_setup_provision "$@" ;;
        setup)
            # The wizard needs the host-side bootstrap in the middle, so the
            # wrapper drives it in phases rather than this script running it
            # end to end.
            err "Error: run the wizard through the host wrapper:"
            echo "  ./config setup" >&2
            return 1
            ;;
        admin)
            err "Error: 'admin' is handled by the host wrapper:"
            echo "  ./config admin reset" >&2
            return 1
            ;;
        help|-h|--help)
            print_usage
            ;;
        "")
            err "Error: subcommand required."
            print_usage
            return 1
            ;;
        *)
            err "Error: unknown subcommand: $cmd"
            print_usage
            return 1
            ;;
    esac
}

main "$@"
