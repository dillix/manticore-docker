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
#   setup                         Interactive wizard for first-time config
#   password generate             Generate a random password, hash, write
#   password change               Prompt for password interactively, hash, write
#   domain <fqdn>                 Set MANTICORE_DOMAIN
#   email <addr>                  Set MANTICORE_ACME_EMAIL
#   username <name>               Set MANTICORE_USERNAME
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

# Print a reminder that running Caddy needs to be recreated to pick up
# changes to environment-substituted values (username, password hash, etc).
# Call this after a successful set_env_var on any auth-related field.
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
# The alphabet is `[A-Za-z0-9_.-]` (65 characters, ~144 bits of entropy
# over 24 characters) — every character in this set is:
#   - shell-safe (no quoting needed in bash/zsh/sh, even in double quotes
#     where `!` would trigger history expansion)
#   - URL-safe (no percent-encoding needed if the password ever lands in
#     a connection string)
#   - regex- and JSON-neutral
generate_password() {
    tr -dc 'A-Za-z0-9_.-' </dev/urandom | head -c 24
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
        remind_recreate_caddy
        return 10
    else
        info "Aborted. $ENV_FILE was not modified."
        return 0
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

    if ! preview_change MANTICORE_PASSWORD_HASH "$escaped_hash"; then
        return 0
    fi
    if confirm "Apply this change?"; then
        set_env_var MANTICORE_PASSWORD_HASH "$escaped_hash"
        restore_env_ownership
        ok "Updated MANTICORE_PASSWORD_HASH."
        remind_recreate_caddy
        return 10
    else
        info "Aborted. $ENV_FILE was not modified."
        warn "The generated password above is now lost. Re-run to generate a new one."
        return 0
    fi
}

# -----------------------------------------------------------------------------
# Subcommand: password change
# Prompts for the new password interactively (with confirmation) — never
# accepts the password as an argument, since CLI arguments leak through
# shell history, process listings (ps aux), and SSH session logs.
# For automation, ship a pre-populated .env via your deployment tool
# instead of invoking this command.
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
        echo "Run the command without arguments to enter your password" >&2
        echo "interactively (input is hidden):" >&2
        echo "" >&2
        echo "  ./config password change" >&2
        echo "" >&2
        echo "For automation, deploy a pre-populated .env file via your" >&2
        echo "configuration management tool instead." >&2
        return 1
    fi

    local plaintext
    plaintext=$(prompt_password_with_confirm)

    local escaped_hash
    escaped_hash=$(hash_password_for_env "$plaintext")

    # Wipe plaintext from memory as soon as possible. POSIX sh has no
    # explicit memory zeroing primitive, but unsetting the variable
    # removes the value from the shell's scope at minimum.
    plaintext=""
    unset plaintext

    if ! preview_change MANTICORE_PASSWORD_HASH "$escaped_hash"; then
        return 0
    fi
    if confirm "Apply this change?"; then
        set_env_var MANTICORE_PASSWORD_HASH "$escaped_hash"
        restore_env_ownership
        ok "Updated MANTICORE_PASSWORD_HASH."
        remind_recreate_caddy
        return 10
    else
        info "Aborted. $ENV_FILE was not modified."
        return 0
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
            echo "  change            Prompt for password interactively" >&2
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
    # typing anything. We deliberately do not enforce a complex
    # character-class policy — for a bcrypt-hashed Basic Auth secret,
    # length matters far more than character variety.
    echo "Password rules:" >&2
    echo "  - At least 8 characters." >&2
    echo "  - Any printable characters are allowed." >&2
    echo "  - Avoid \$ ' \" \\ \` \! if you plan to paste the password" >&2
    echo "    into a shell command without single quotes." >&2
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

cmd_setup() {
    bold "============================================================"
    bold "  Manticore Search Docker Stack — interactive setup"
    bold "============================================================"
    echo ""

    # Step 1: existing .env check.
    if [ -f "$ENV_FILE" ]; then
        local cur_domain cur_email cur_username cur_hash
        cur_domain=$(get_env_var MANTICORE_DOMAIN 2>/dev/null || true)
        cur_email=$(get_env_var MANTICORE_ACME_EMAIL 2>/dev/null || true)
        cur_username=$(get_env_var MANTICORE_USERNAME 2>/dev/null || true)
        cur_hash=$(get_env_var MANTICORE_PASSWORD_HASH 2>/dev/null || true)

        local empty_count=0
        [ -z "$cur_domain" ]   && empty_count=$((empty_count + 1))
        [ -z "$cur_email" ]    && empty_count=$((empty_count + 1))
        [ -z "$cur_username" ] && empty_count=$((empty_count + 1))
        [ -z "$cur_hash" ]     && empty_count=$((empty_count + 1))

        # Note: .env.example ships with non-empty placeholders for the first
        # three fields (search.example.com, admin@example.com, drupal).
        # Those count as "filled" for the empty_count above, but they are
        # placeholders, not real values. The wizard treats them as defaults
        # and the user can accept or override.
        if [ "$empty_count" -eq 0 ]; then
            warn ".env already exists and is fully populated."
            echo "" >&2
            echo "Current values:" >&2
            echo "  MANTICORE_DOMAIN       = $cur_domain" >&2
            echo "  MANTICORE_ACME_EMAIL   = $cur_email" >&2
            echo "  MANTICORE_USERNAME     = $cur_username" >&2
            echo "  MANTICORE_PASSWORD_HASH= $(mask_hash "$cur_hash")" >&2
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

    # Step 2: domain.
    bold "Step 1 of 4 — Domain name"
    echo "The fully-qualified hostname pointing at this VPS, with a public"
    echo "DNS A record. Example: search.example.com"
    echo "Rules: lowercase letters, digits, hyphens and dots only."
    echo ""
    local default_domain
    default_domain=$(get_env_var MANTICORE_DOMAIN 2>/dev/null || true)
    # Strip the placeholder from .env.example so the user is not nudged
    # into accepting it accidentally.
    [ "$default_domain" = "search.example.com" ] && default_domain=""
    local new_domain
    new_domain=$(prompt_value "Domain" "$default_domain" validate_domain \
        "lowercase letters, digits, hyphens and dots only")
    echo ""

    # Step 3: email.
    bold "Step 2 of 4 — ACME email"
    echo "Email address used by Let's Encrypt for renewal notices."
    echo "Rules: standard email form, e.g. admin@example.com."
    echo ""
    local default_email
    default_email=$(get_env_var MANTICORE_ACME_EMAIL 2>/dev/null || true)
    [ "$default_email" = "admin@example.com" ] && default_email=""
    local new_email
    new_email=$(prompt_value "Email" "$default_email" validate_email \
        "must look like name@domain.tld")
    echo ""

    # Step 4: username.
    bold "Step 3 of 4 — HTTP Basic Auth username"
    echo "Username the Drupal application will authenticate as."
    echo "Rules: 1-32 characters, ASCII letters/digits/underscore/hyphen."
    echo ""
    local default_username
    default_username=$(get_env_var MANTICORE_USERNAME 2>/dev/null || true)
    [ "$default_username" = "drupal" ] && default_username=""
    local new_username
    new_username=$(prompt_value "Username" "$default_username" validate_username \
        "1-32 chars, letters/digits/underscore/hyphen")
    echo ""

    # Step 5: password.
    bold "Step 4 of 4 — HTTP Basic Auth password"
    echo "How would you like to set the password?"
    echo ""
    echo "  1) Generate a strong random password (recommended)"
    echo "  2) Enter your own password"
    echo ""
    local choice new_password
    while :; do
        printf '%sChoice%s [1]: ' "$C_BOLD" "$C_RESET"
        read -r choice || choice=""
        [ -z "$choice" ] && choice="1"
        case "$choice" in
            1)
                new_password=$(generate_password)
                echo ""
                bold "============================================================"
                bold "  PASSWORD (save this NOW — it will not be shown again):"
                echo ""
                printf '      %s%s%s\n' "$C_BOLD" "$new_password" "$C_RESET"
                echo ""
                bold "============================================================"
                break
                ;;
            2)
                new_password=$(prompt_password_with_confirm)
                break
                ;;
            *)
                err "  Please answer 1 or 2."
                ;;
        esac
    done
    echo ""

    # Step 6: summary + final confirmation.
    local new_hash
    new_hash=$(hash_password_for_env "$new_password")

    bold "Summary"
    echo ""
    echo "  MANTICORE_DOMAIN       = $new_domain"
    echo "  MANTICORE_ACME_EMAIL   = $new_email"
    echo "  MANTICORE_USERNAME     = $new_username"
    echo "  MANTICORE_PASSWORD_HASH= $(mask_hash "$new_hash")"
    echo ""

    if ! confirm "Write these values to $ENV_FILE?"; then
        warn "Aborted. $ENV_FILE was not modified."
        if [ "$choice" = "1" ]; then
            warn "The generated password is now lost."
        fi
        return 0
    fi

    # Step 7: write everything.
    set_env_var MANTICORE_DOMAIN         "$new_domain"
    set_env_var MANTICORE_ACME_EMAIL     "$new_email"
    set_env_var MANTICORE_USERNAME       "$new_username"
    set_env_var MANTICORE_PASSWORD_HASH  "$new_hash"
    restore_env_ownership

    echo ""
    ok "Setup complete. $ENV_FILE has been written."    echo ""
    bold "Next steps:"
    echo ""
    echo "  # 1. Make sure DNS A record for '$new_domain' points to this VPS."
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
    echo "  # 4. Test from anywhere:"
    echo "  curl -u '$new_username:<the-password-above>' \\"
    echo "       https://$new_domain/cli -d 'SHOW STATUS'"
    echo ""
    return 10
}

# -----------------------------------------------------------------------------
# Usage / help
# -----------------------------------------------------------------------------
print_usage() {
    cat >&2 <<'USAGE'
Usage:
  docker compose run --rm -it config <subcommand> [args...]

  Or via the host-side wrapper:
  ./config <subcommand> [args...]

Subcommands:
  setup                         Interactive wizard for first-time config
  show                          Display current .env (hash masked)
  domain <fqdn>                 Set MANTICORE_DOMAIN
  email <addr>                  Set MANTICORE_ACME_EMAIL
  username <name>               Set MANTICORE_USERNAME
  password generate             Generate a random password and hash
  password change               Prompt for password interactively and hash

Examples:
  ./config setup
  ./config show
  ./config domain search.example.com
  ./config email admin@example.com
  ./config username drupal
  ./config password generate
  ./config password change
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
