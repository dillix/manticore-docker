#!/bin/sh
# =============================================================================
# Manticore Search Docker Stack — configuration helper
# =============================================================================
# This script runs inside the `config` service container (caddy:2-alpine).
# It manipulates the .env file via a single entrypoint with subcommands.
#
# Invocation (always via Compose, never directly):
#   docker compose run --rm -it config <subcommand> [args...]
#
# Subcommands:
#   show                          Display current .env (password hash masked)
#   password generate             Generate a random password, hash, write
#   password change <plaintext>   Hash the given password, write
#   domain <fqdn>                 Set MANTICORE_DOMAIN
#   email <addr>                  Set MANTICORE_ACME_EMAIL
#   username <name>               Set MANTICORE_USERNAME
#   setup                         Interactive wizard (added in Step 2)
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

# Validation regex patterns (POSIX BRE/ERE).
DOMAIN_RE='^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$'
EMAIL_RE='^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'
USERNAME_RE='^[A-Za-z0-9_-]{1,32}$'

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
# Uses a custom sed delimiter (|) because bcrypt hashes contain '/' but
# never '|'. The value is passed through unchanged — caller is responsible
# for any required escaping (e.g. doubling $ for Compose interpolation).
set_env_var() {
    local key="$1"
    local value="$2"
    ensure_env_file
    if grep -q "^${key}=" "$ENV_FILE"; then
        # Replace existing line. Escape ampersands and backslashes that are
        # special to sed's replacement; the | delimiter handles slashes.
        local esc
        esc=$(printf '%s\n' "$value" | sed 's/[&\\]/\\&/g')
        sed -i "s|^${key}=.*|${key}=${esc}|" "$ENV_FILE"
    else
        printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
    fi
}

# Restore ownership of .env to the host user.
restore_env_ownership() {
    [ -f "$ENV_FILE" ] || return 0
    chown "${HOST_UID}:${HOST_GID}" "$ENV_FILE"
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

# Mask a bcrypt hash for display: show prefix and length, hide body.
mask_hash() {
    local hash="$1"
    [ -z "$hash" ] && { printf '(not set)'; return; }
    # Bcrypt hashes look like $2a$14$XXXXXXXX... or, in our .env, $$2a$$14$$XX...
    # Either way, show the first 10 chars and replace the rest with ••••••••
    local prefix
    prefix=$(printf '%s' "$hash" | cut -c1-10)
    printf '%s••••••••' "$prefix"
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

# -----------------------------------------------------------------------------
# Password handling
# -----------------------------------------------------------------------------

# Generate a 24-character password from a safe, copy-paste-friendly alphabet.
generate_password() {
    tr -dc 'A-Za-z0-9!_.-' </dev/urandom | head -c 24
}

# Hash a plaintext password with bcrypt, then double every '$' so the value
# survives Compose interpolation when read from .env.
hash_password_for_env() {
    local plaintext="$1"
    local raw_hash
    raw_hash=$(caddy hash-password --plaintext "$plaintext")
    printf '%s' "$raw_hash" | sed 's/\$/$$/g'
}

# -----------------------------------------------------------------------------
# Subcommand: show
# -----------------------------------------------------------------------------
cmd_show() {
    if [ ! -f "$ENV_FILE" ]; then
        warn "No $ENV_FILE found. Run 'config setup' to create one."
        return 1
    fi
    local domain email username hash
    domain=$(get_env_var MANTICORE_DOMAIN || true)
    email=$(get_env_var MANTICORE_ACME_EMAIL || true)
    username=$(get_env_var MANTICORE_USERNAME || true)
    hash=$(get_env_var MANTICORE_PASSWORD_HASH || true)

    bold "Current configuration ($ENV_FILE)"
    printf '\n'
    printf '  MANTICORE_DOMAIN       = %s\n'  "${domain:-${C_YELLOW}(not set)${C_RESET}}"
    printf '  MANTICORE_ACME_EMAIL   = %s\n'  "${email:-${C_YELLOW}(not set)${C_RESET}}"
    printf '  MANTICORE_USERNAME     = %s\n'  "${username:-${C_YELLOW}(not set)${C_RESET}}"
    printf '  MANTICORE_PASSWORD_HASH= %s\n'  "$(mask_hash "$hash")"
    printf '\n'
}

# -----------------------------------------------------------------------------
# Subcommand: domain <value>
# -----------------------------------------------------------------------------
cmd_domain() {
    local value="${1:-}"
    if [ -z "$value" ]; then
        err "Error: domain value required."
        echo "Usage: docker compose run --rm -it config domain <fqdn>" >&2
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
    else
        info "Aborted. $ENV_FILE was not modified."
    fi
}

# -----------------------------------------------------------------------------
# Subcommand: email <value>
# -----------------------------------------------------------------------------
cmd_email() {
    local value="${1:-}"
    if [ -z "$value" ]; then
        err "Error: email value required."
        echo "Usage: docker compose run --rm -it config email <addr>" >&2
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
    else
        info "Aborted. $ENV_FILE was not modified."
    fi
}

# -----------------------------------------------------------------------------
# Subcommand: username <value>
# -----------------------------------------------------------------------------
cmd_username() {
    local value="${1:-}"
    if [ -z "$value" ]; then
        err "Error: username value required."
        echo "Usage: docker compose run --rm -it config username <name>" >&2
        return 1
    fi
    if ! validate_username "$value"; then
        err "Error: '$value' is not a valid username."
        echo "Expected: 1-32 chars, letters/digits/underscore/hyphen." >&2
        return 1
    fi
    if ! preview_change MANTICORE_USERNAME "$value"; then
        return 0
    fi
    if confirm "Apply this change?"; then
        set_env_var MANTICORE_USERNAME "$value"
        restore_env_ownership
        ok "Updated MANTICORE_USERNAME."
    else
        info "Aborted. $ENV_FILE was not modified."
    fi
}

# -----------------------------------------------------------------------------
# Subcommand: password generate
# -----------------------------------------------------------------------------
cmd_password_generate() {
    local password escaped_hash
    password=$(generate_password)
    escaped_hash=$(hash_password_for_env "$password")

    echo ""
    bold "============================================================"
    bold "  PASSWORD (save this NOW — it will not be shown again):"
    echo ""
    printf '      %s%s%s\n' "$C_BOLD" "$password" "$C_RESET"
    echo ""
    bold "============================================================"
    echo ""

    preview_change MANTICORE_PASSWORD_HASH "$escaped_hash"
    if confirm "Apply this change?"; then
        set_env_var MANTICORE_PASSWORD_HASH "$escaped_hash"
        restore_env_ownership
        ok "Updated MANTICORE_PASSWORD_HASH."
    else
        info "Aborted. $ENV_FILE was not modified."
        warn "The generated password above is now lost. Re-run to generate a new one."
    fi
}

# -----------------------------------------------------------------------------
# Subcommand: password change <plaintext>
# -----------------------------------------------------------------------------
cmd_password_change() {
    local plaintext="${1:-}"
    if [ -z "$plaintext" ]; then
        err "Error: password value required."
        echo "Usage: docker compose run --rm -it config password change 'your-password'" >&2
        echo "" >&2
        echo "Wrap the password in single quotes to avoid shell expansion." >&2
        return 1
    fi
    local escaped_hash
    escaped_hash=$(hash_password_for_env "$plaintext")

    preview_change MANTICORE_PASSWORD_HASH "$escaped_hash"
    if confirm "Apply this change?"; then
        set_env_var MANTICORE_PASSWORD_HASH "$escaped_hash"
        restore_env_ownership
        ok "Updated MANTICORE_PASSWORD_HASH."
    else
        info "Aborted. $ENV_FILE was not modified."
    fi
}

# -----------------------------------------------------------------------------
# Subcommand: password (router)
# -----------------------------------------------------------------------------
cmd_password() {
    local action="${1:-}"
    shift 2>/dev/null || true
    case "$action" in
        generate) cmd_password_generate "$@" ;;
        change)   cmd_password_change "$@" ;;
        "")
            err "Error: password subcommand required."
            echo "" >&2
            echo "Available actions:" >&2
            echo "  generate          Generate a random password" >&2
            echo "  change <pwd>      Set a specific password" >&2
            return 1
            ;;
        *)
            err "Error: unknown password subcommand: $action"
            echo "Try: generate, change" >&2
            return 1
            ;;
    esac
}

# -----------------------------------------------------------------------------
# Subcommand: setup (placeholder for Step 2)
# -----------------------------------------------------------------------------
cmd_setup() {
    warn "The interactive setup wizard is not yet implemented (coming in Step 2)."
    echo "" >&2
    echo "For now, run the individual subcommands:" >&2
    echo "  config domain <fqdn>" >&2
    echo "  config email <addr>" >&2
    echo "  config username <name>" >&2
    echo "  config password generate" >&2
    return 1
}

# -----------------------------------------------------------------------------
# Usage / help
# -----------------------------------------------------------------------------
print_usage() {
    cat >&2 <<'USAGE'
Usage:
  docker compose run --rm -it config <subcommand> [args...]

Subcommands:
  show                          Display current .env (hash masked)
  setup                         Interactive wizard (coming soon)
  domain <fqdn>                 Set MANTICORE_DOMAIN
  email <addr>                  Set MANTICORE_ACME_EMAIL
  username <name>               Set MANTICORE_USERNAME
  password generate             Generate a random password and hash
  password change <plaintext>   Hash and set a specific password

Examples:
  docker compose run --rm -it config show
  docker compose run --rm -it config domain search.example.com
  docker compose run --rm -it config email admin@example.com
  docker compose run --rm -it config username drupal
  docker compose run --rm -it config password generate
  docker compose run --rm -it config password change 'my-strong-password'
USAGE
}

# -----------------------------------------------------------------------------
# Main router
# -----------------------------------------------------------------------------

main() {
    local cmd="${1:-}"
    shift 2>/dev/null || true

    case "$cmd" in
        show)     cmd_show "$@" ;;
        domain)   cmd_domain "$@" ;;
        email)    cmd_email "$@" ;;
        username) cmd_username "$@" ;;
        password) cmd_password "$@" ;;
        setup)    cmd_setup "$@" ;;
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
