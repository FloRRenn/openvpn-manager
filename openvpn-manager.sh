#!/bin/bash
# =============================================================================
# openvpn-manager.sh  —  v5
#
# OpenVPN manager with per-user tunnel mode, full CLI support, and config file.
#
# TUNNEL MODES (per user):
#   split  —  only allowed server IPs route through VPN; internet stays local
#   full   —  ALL traffic goes through VPN (classic VPN behaviour)
#
# COMMANDS:
#   install                   Install OpenVPN server
#   add-user <name> [flags]   Add a user
#   edit-user <name> [flags]  Change a user's mode or servers
#   delete-user <name>        Revoke a user
#   list-users                Show all users, modes, and server access
#   fix                       Re-apply split-tunnel patches (fix lost internet)
#
# GLOBAL FLAGS (any command):
#   -c, --config <file>       Load defaults from a config file
#   -v, --verbose             Verbose output
#   -y, --yes                 Auto-confirm prompts
#
# ADD-USER / EDIT-USER FLAGS:
#   -m, --mode <full|split>   Tunnel mode for this user  (default: split)
#   -s, --servers <list>      Comma-separated IPs/CIDRs  (required for split)
#   -p, --password            Prompt for client key password
#
# CONFIG FILE  (~/.openvpn-manager.conf or specified with -c):
#   default_mode=split
#   default_servers=10.10.1.0/24
#
#   [alice]
#   mode=split
#   servers=10.10.1.5/32,10.10.2.0/24
#
#   [bob]
#   mode=full
#
# EXAMPLES:
#   sudo ./openvpn-manager.sh install
#   sudo ./openvpn-manager.sh add-user alice --mode split --servers 10.10.1.5/32
#   sudo ./openvpn-manager.sh add-user bob   --mode full
#   sudo ./openvpn-manager.sh add-user carol --config /etc/vpn-users.conf
#   sudo ./openvpn-manager.sh edit-user alice --servers 10.10.1.5/32,10.10.2.0/24
#   sudo ./openvpn-manager.sh list-users
#   sudo ./openvpn-manager.sh delete-user bob
#   sudo ./openvpn-manager.sh fix
# =============================================================================

set -euo pipefail

# --------------------------------------------------------------------------- #
# Colours
# --------------------------------------------------------------------------- #
R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m' C='\033[0;36m'
BOLD='\033[1m' DIM='\033[2m' NC='\033[0m'

info()    { echo -e "${C}[INFO]${NC}  $*"; }
ok()      { echo -e "${G}[OK]${NC}    $*"; }
warn()    { echo -e "${Y}[WARN]${NC}  $*"; }
err()     { echo -e "${R}[ERR]${NC}   $*" >&2; }
die()     { err "$*"; exit 1; }
verbose() { [[ "$OPT_VERBOSE" == "1" ]] && echo -e "${DIM}[DBG]  $*${NC}" || true; }
banner()  { echo -e "\n${BOLD}${C}━━━  $*  ━━━${NC}\n"; }
ask()     { echo -ne "${BOLD}$1${NC}${2:+ ${DIM}($2)${NC}}: "; }

# --------------------------------------------------------------------------- #
# Runtime state
# --------------------------------------------------------------------------- #
INSTALLER_URL="https://raw.githubusercontent.com/angristan/openvpn-install/master/openvpn-install.sh"
INSTALLER="/tmp/openvpn-install.sh"
ACL_DB="/etc/openvpn/user-acl.conf"
DEFAULT_CONFIG_FILE="${HOME}/.openvpn-manager.conf"

# OpenVPN management interface (used for status queries and kick)
MGMT_HOST="127.0.0.1"
MGMT_PORT="7505"
MGMT_TIMEOUT="3"   # seconds to wait for management socket response

OPENVPN_CONF=""
CCD_DIR=""

# Global option defaults
OPT_VERBOSE="0"
OPT_YES="0"
OPT_CONFIG_FILE=""
OPT_INTERVAL="5"    # monitor refresh interval (seconds)

# Per-command option defaults (overridden by config file then CLI flags)
OPT_MODE=""
OPT_SERVERS=""
OPT_PASSWORD="0"

# --------------------------------------------------------------------------- #
# Config file parser
#
# Supports ini-style files:
#   default_mode=split
#   default_servers=10.0.0.1/32
#
#   [alice]
#   mode=full
#
#   [bob]
#   mode=split
#   servers=10.10.1.5/32,10.10.2.0/24
# --------------------------------------------------------------------------- #
load_config_file() {
    local file="$1" target_user="${2:-}"

    [[ -f "$file" ]] || { verbose "Config file not found: $file"; return 0; }
    verbose "Loading config: $file"

    local current_section="__global__"

    while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
        # Strip comments and trim whitespace
        local line
        line="${raw_line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" ]] && continue

        # Section header [username]
        if [[ "$line" =~ ^\[([a-zA-Z0-9_-]+)\]$ ]]; then
            current_section="${BASH_REMATCH[1]}"
            verbose "  section: [$current_section]"
            continue
        fi

        # Key=value pair
        if [[ "$line" =~ ^([a-zA-Z0-9_]+)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
            local key="${BASH_REMATCH[1]}" value="${BASH_REMATCH[2]}"

            if [[ "$current_section" == "__global__" ]]; then
                # Global defaults
                case "$key" in
                    default_mode)    [[ -z "$OPT_MODE"    ]] && OPT_MODE="$value" ;;
                    default_servers) [[ -z "$OPT_SERVERS" ]] && OPT_SERVERS="$value" ;;
                esac
                verbose "  global: $key=$value"

            elif [[ -n "$target_user" && "$current_section" == "$target_user" ]]; then
                # Per-user section matching the requested user
                case "$key" in
                    mode)    OPT_MODE="$value" ;;
                    servers) OPT_SERVERS="$value" ;;
                esac
                verbose "  user[$current_section]: $key=$value"
            fi
        fi
    done < "$file"
}

# --------------------------------------------------------------------------- #
# Parse global flags from argument list — strips them out, leaves the rest
# Sets: OPT_VERBOSE, OPT_YES, OPT_CONFIG_FILE
# Returns remaining args in PARSED_ARGS array
# --------------------------------------------------------------------------- #
parse_global_flags() {
    PARSED_ARGS=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -v|--verbose) OPT_VERBOSE="1"; shift ;;
            -y|--yes)     OPT_YES="1";     shift ;;
            -n|--interval)
                [[ -z "${2:-}" ]] && die "--interval requires a number"
                OPT_INTERVAL="$2"; shift 2 ;;
            -c|--config)
                [[ -z "${2:-}" ]] && die "--config requires a file path"
                OPT_CONFIG_FILE="$2"; shift 2 ;;
            *) PARSED_ARGS+=("$1"); shift ;;
        esac
    done
}

# --------------------------------------------------------------------------- #
# Parse add-user / edit-user flags
# Sets: OPT_MODE, OPT_SERVERS, OPT_PASSWORD
# --------------------------------------------------------------------------- #
parse_user_flags() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -m|--mode)
                [[ -z "${2:-}" ]] && die "--mode requires full or split"
                OPT_MODE="$2"; shift 2 ;;
            -s|--servers)
                [[ -z "${2:-}" ]] && die "--servers requires a value"
                OPT_SERVERS="$2"; shift 2 ;;
            -p|--password)
                OPT_PASSWORD="1"; shift ;;
            -*) die "Unknown flag: $1" ;;
            *)  shift ;;  # positional (already consumed as username)
        esac
    done
}

# --------------------------------------------------------------------------- #
# Validate mode value
# --------------------------------------------------------------------------- #
validate_mode() {
    local mode="$1"
    case "$mode" in
        split|full) return 0 ;;
        *) die "Invalid mode '$mode'. Use 'split' or 'full'." ;;
    esac
}

# --------------------------------------------------------------------------- #
# Validate and normalise a comma/space separated server list -> space separated
# --------------------------------------------------------------------------- #
validate_servers() {
    local raw="$1"
    local out=""
    # Accept comma or space separated
    local servers_arr
    IFS=', ' read -ra servers_arr <<< "$raw"
    for s in "${servers_arr[@]}"; do
        [[ -z "$s" ]] && continue
        if [[ "$s" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(\/[0-9]+)?$ ]]; then
            [[ "$s" != */* ]] && s="${s}/32"
            out+="${s} "
        else
            die "Invalid server address: '$s'  (use x.x.x.x or x.x.x.x/prefix)"
        fi
    done
    echo "${out% }"
}

# --------------------------------------------------------------------------- #
# CIDR -> "network netmask" for OpenVPN push route
# --------------------------------------------------------------------------- #
cidr_to_route() {
    local cidr="$1"
    local ip="${cidr%/*}" prefix="${cidr#*/}"
    local mask="" i bits octet
    for i in 1 2 3 4; do
        bits=$(( prefix > 8 ? 8 : (prefix < 0 ? 0 : prefix) ))
        prefix=$(( prefix - bits ))
        octet=$(( bits == 8 ? 255 : (bits == 0 ? 0 : 256 - (1 << (8 - bits)) ) ))
        mask+="$octet"; (( i < 4 )) && mask+="."
    done
    echo "$ip $mask"
}

# --------------------------------------------------------------------------- #
# OpenVPN server config detection
# --------------------------------------------------------------------------- #
find_conf() {
    local candidates=(
        "/etc/openvpn/server/server.conf"
        "/etc/openvpn/server.conf"
    )
    for f in "${candidates[@]}"; do
        if [[ -f "$f" ]]; then
            OPENVPN_CONF="$f"
            CCD_DIR="$(dirname "$f")/ccd"
            verbose "Resolved OPENVPN_CONF=$OPENVPN_CONF"
            return 0
        fi
    done
    local found
    found=$(find /etc/openvpn -name "server.conf" 2>/dev/null | head -1 || true)
    if [[ -n "$found" ]]; then
        OPENVPN_CONF="$found"
        CCD_DIR="$(dirname "$found")/ccd"
        verbose "Resolved OPENVPN_CONF=$OPENVPN_CONF (via find)"
        return 0
    fi
    return 1
}

need_root()    { [[ $EUID -eq 0 ]] || die "Run as root: sudo $0"; }
need_install() { find_conf || die "OpenVPN not installed. Run: sudo $0 install"; }

# --------------------------------------------------------------------------- #
# Restart OpenVPN
# --------------------------------------------------------------------------- #
restart_vpn() {
    info "Restarting OpenVPN..."
    local units=("openvpn-server@server" "openvpn@server" "openvpn")
    for unit in "${units[@]}"; do
        if systemctl restart "$unit" 2>/dev/null; then
            ok "Restarted ($unit)"; return 0
        fi
    done
    warn "Could not auto-restart. Run: systemctl restart openvpn-server@server"
}

# --------------------------------------------------------------------------- #
# Apply split-tunnel base patches to server.conf  (idempotent)
#
# Removes the three directives that cause internet loss on split tunnel:
#   redirect-gateway  →  hijacks client default route
#   dhcp-option DNS   →  overrides client DNS resolver
#   global push route →  pushed to all users, moved to per-user CCD
# --------------------------------------------------------------------------- #
apply_split_tunnel_base() {
    find_conf || die "server.conf not found."
    info "Patching $OPENVPN_CONF for split tunnel base..."

    if grep -Eq '^push "redirect-gateway' "$OPENVPN_CONF"; then
        sed -i -E 's|^(push "redirect-gateway[^"]*")|# [split-tunnel] \1|g' "$OPENVPN_CONF"
        ok "Disabled redirect-gateway"
    fi

    if grep -Eq '^push "dhcp-option DNS' "$OPENVPN_CONF"; then
        sed -i -E 's|^(push "dhcp-option DNS[^"]*")|# [split-tunnel] \1|g' "$OPENVPN_CONF"
        ok "Disabled pushed DNS"
    fi

    if grep -Eq '^push "route ' "$OPENVPN_CONF"; then
        sed -i -E 's|^(push "route [^"]*")|# [split-tunnel moved-to-ccd] \1|g' "$OPENVPN_CONF"
        ok "Moved global route pushes to CCD"
    fi

    mkdir -p "$CCD_DIR"
    if ! grep -q "^client-config-dir" "$OPENVPN_CONF"; then
        printf '\n# Per-user access control\nclient-config-dir %s\n' "$CCD_DIR" \
            >> "$OPENVPN_CONF"
        ok "Enabled client-config-dir -> $CCD_DIR"
    fi

    touch "$ACL_DB"
}

# --------------------------------------------------------------------------- #
# Write CCD file for one user based on their tunnel mode
# --------------------------------------------------------------------------- #
write_ccd() {
    local user="$1" mode="$2" servers="${3:-}"
    mkdir -p "$CCD_DIR"

    {
        echo "# User   : $user"
        echo "# Mode   : $mode"
        echo "# Updated: $(date)"
        echo ""

        if [[ "$mode" == "full" ]]; then
            # Full tunnel: push default gateway override
            echo 'push "redirect-gateway def1 bypass-dhcp"'
            echo 'push "dhcp-option DNS 1.1.1.1"'
            echo 'push "dhcp-option DNS 8.8.8.8"'
        else
            # Split tunnel: push only the allowed server routes
            if [[ -n "$servers" ]]; then
                for cidr in $servers; do
                    echo "push \"route $(cidr_to_route "$cidr")\""
                done
            fi
        fi
    } > "$CCD_DIR/$user"

    verbose "Wrote CCD: $CCD_DIR/$user"
}

# --------------------------------------------------------------------------- #
# ACL DB helpers  (format:  username|mode|servers)
# --------------------------------------------------------------------------- #
acl_save() {
    local user="$1" mode="$2" servers="${3:-}"
    sed -i "/^${user}|/d" "$ACL_DB" 2>/dev/null || true
    echo "${user}|${mode}|${servers}" >> "$ACL_DB"
}

acl_get() {
    local user="$1" field="$2"  # field: mode | servers
    local line
    line=$(grep "^${user}|" "$ACL_DB" 2>/dev/null || true)
    [[ -z "$line" ]] && echo "" && return
    case "$field" in
        mode)    echo "$line" | cut -d'|' -f2 ;;
        servers) echo "$line" | cut -d'|' -f3 ;;
    esac
}

acl_remove() {
    sed -i "/^${1}|/d" "$ACL_DB" 2>/dev/null || true
}

# --------------------------------------------------------------------------- #
# Confirm prompt  (skipped with -y / --yes)
# --------------------------------------------------------------------------- #
confirm() {
    local msg="$1"
    [[ "$OPT_YES" == "1" ]] && return 0
    ask "$msg" "y/N"; local ans; read -r ans
    [[ "${ans,,}" == "y" ]]
}

# --------------------------------------------------------------------------- #
# Ensure installer is downloaded
# --------------------------------------------------------------------------- #
get_installer() {
    if [[ ! -f "$INSTALLER" ]]; then
        info "Downloading angristan/openvpn-install..."
        curl -fsSL -o "$INSTALLER" "$INSTALLER_URL" || die "Download failed."
        chmod +x "$INSTALLER"
        ok "Installer ready."
    else
        verbose "Installer already cached: $INSTALLER"
    fi
}

# ==========================================================================  #
# CMD: install
# ==========================================================================  #
cmd_install() {
    banner "Install OpenVPN"

    get_installer

    # Patch installer before running — keeps server.conf clean for split tunnel
    local patched="/tmp/openvpn-install-split.sh"
    cp "$INSTALLER" "$patched"
    sed -i \
        -e 's|push "redirect-gateway def1 bypass-dhcp"|# [split-tunnel] redirect-gateway removed|g' \
        -e 's|^\(push "dhcp-option DNS\)|# [split-tunnel] \1|g' \
        "$patched"
    chmod +x "$patched"
    verbose "Patched installer -> $patched"

    echo ""
    warn "The OpenVPN installer will run now. Answer its prompts as normal."
    warn "Split tunnel base config is applied automatically after."
    echo ""
    [[ "$OPT_YES" == "1" ]] || read -rp "Press ENTER to continue..."

    bash "$patched" interactive

    info "Locating server.conf..."
    find_conf || die "server.conf not found — did the install complete?"
    ok "Found: $OPENVPN_CONF"

    apply_split_tunnel_base
    restart_vpn

    echo ""
    ok "OpenVPN installed."
    echo -e "\n  ${BOLD}Next:${NC} sudo $0 add-user <name> [--mode split|full]\n"
}

# ==========================================================================  #
# CMD: add-user  /  edit-user
# ==========================================================================  #
cmd_upsert_user() {
    local is_edit="${1:-0}"
    local cmd_label="Add"
    [[ "$is_edit" == "1" ]] && cmd_label="Edit"

    need_install
    banner "$cmd_label User"

    # ── Username ─────────────────────────────────────────────────────────── #
    local username="${USER_NAME:-}"
    if [[ -z "$username" ]]; then
        ask "Username" "alphanumeric"
        read -r username
    fi
    [[ -n "$username" ]]                   || die "Username cannot be empty."
    [[ "$username" =~ ^[a-zA-Z0-9_-]+$ ]] || die "Alphanumeric only (a-z 0-9 _ -)."

    # For edit-user, verify user exists
    if [[ "$is_edit" == "1" ]]; then
        [[ -f "$CCD_DIR/$username" ]] || die "User '$username' not found. Check list-users."
    fi

    echo -e "  ${BOLD}User:${NC} $username\n"

    # ── Load config file (global defaults, then per-user section) ─────────── #
    local cfg_file="${OPT_CONFIG_FILE:-}"
    [[ -z "$cfg_file" && -f "$DEFAULT_CONFIG_FILE" ]] && cfg_file="$DEFAULT_CONFIG_FILE"
    if [[ -n "$cfg_file" ]]; then
        load_config_file "$cfg_file" "$username"
        verbose "After config load: mode=${OPT_MODE:-unset} servers=${OPT_SERVERS:-unset}"
    fi

    # ── Determine tunnel mode ─────────────────────────────────────────────── #
    local mode="${OPT_MODE:-}"

    # For edit, fall back to existing mode if not specified
    if [[ -z "$mode" && "$is_edit" == "1" ]]; then
        mode=$(acl_get "$username" "mode")
        verbose "Inherited existing mode: $mode"
    fi

    if [[ -z "$mode" ]]; then
        echo -e "${DIM}Tunnel mode:${NC}"
        echo -e "  ${C}1)${NC} split  — client keeps internet; only allowed servers route through VPN"
        echo -e "  ${C}2)${NC} full   — ALL client traffic goes through VPN"
        echo ""
        ask "Mode" "1=split, 2=full, or type split/full"
        local mode_input; read -r mode_input
        case "$mode_input" in
            1|split) mode="split" ;;
            2|full)  mode="full"  ;;
            *) die "Invalid mode. Enter 1, 2, split, or full." ;;
        esac
    fi

    validate_mode "$mode"
    ok "Mode: ${BOLD}$mode${NC}"

    # ── Determine allowed servers (split mode only) ───────────────────────── #
    local servers=""
    if [[ "$mode" == "split" ]]; then
        local raw_servers="${OPT_SERVERS:-}"

        # For edit, fall back to existing servers
        if [[ -z "$raw_servers" && "$is_edit" == "1" ]]; then
            raw_servers=$(acl_get "$username" "servers")
            verbose "Inherited existing servers: $raw_servers"
        fi

        if [[ -n "$raw_servers" ]]; then
            # Validate/normalise from flag or config
            servers=$(validate_servers "$raw_servers")
        else
            # Interactive server entry
            echo ""
            echo -e "${DIM}Enter the IP or subnet for each server this user may reach."
            echo -e "  10.10.1.5        single host  (/32 assumed)"
            echo -e "  10.10.1.5/32     single host  (explicit)"
            echo -e "  10.10.2.0/24     entire subnet"
            echo -e "Blank line = done.${NC}\n"

            local srv_arr=() i=1
            while true; do
                ask "  Server $i" "blank to finish"
                local entry; read -r entry
                [[ -z "$entry" ]] && break

                if [[ "$entry" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(\/[0-9]+)?$ ]]; then
                    [[ "$entry" != */* ]] && entry="${entry}/32"
                    srv_arr+=("$entry")
                    echo -e "    ${G}✓${NC} $entry"
                    (( i++ ))
                else
                    warn "Invalid: '$entry'  —  use x.x.x.x or x.x.x.x/prefix"
                fi
            done

            if (( ${#srv_arr[@]} == 0 )); then
                warn "No servers added — user will have no routed access over VPN."
                confirm "Continue with no servers?" || { info "Aborted."; exit 0; }
            fi

            servers="${srv_arr[*]:-}"
        fi
    fi

    # ── Generate certificate (add-user only) ─────────────────────────────── #
    if [[ "$is_edit" == "0" ]]; then
        echo ""
        get_installer
        info "Generating certificate for '$username'..."

        local cert_args=("client" "add" "$username")
        [[ "$OPT_PASSWORD" == "1" ]] && cert_args+=("--password")

        if bash "$INSTALLER" "${cert_args[@]}"; then
            ok "Certificate created."
        else
            warn "CLI mode failed — opening interactive menu."
            warn "Choose 'Add a new user', name: ${BOLD}$username${NC}"
            [[ "$OPT_YES" == "1" ]] || read -rp "Press ENTER..."
            bash "$INSTALLER" interactive
        fi
    fi

    # ── Ensure split-tunnel base is applied ───────────────────────────────── #
    echo ""
    info "Verifying split-tunnel base config..."
    apply_split_tunnel_base

    # ── Write CCD file ────────────────────────────────────────────────────── #
    write_ccd "$username" "$mode" "$servers"
    ok "CCD written -> $CCD_DIR/$username"

    # ── Save to ACL DB ────────────────────────────────────────────────────── #
    acl_save "$username" "$mode" "$servers"
    ok "ACL saved."

    restart_vpn

    # ── Summary ───────────────────────────────────────────────────────────── #
    local ovpn=""
    [[ "$is_edit" == "0" ]] && ovpn=$(find /root /home -name "${username}.ovpn" 2>/dev/null | head -1 || true)

    echo ""
    echo -e "${G}${BOLD}  User '$username' ${is_edit:+updated}${is_edit:+}${is_edit:0:1}${NC}"
    [[ "$is_edit" == "1" ]] && echo -e "${G}${BOLD}  User '$username' updated${NC}" || echo -e "${G}${BOLD}  User '$username' created${NC}"
    echo ""
    echo -e "  ${BOLD}Mode:${NC}    $mode"

    if [[ "$mode" == "split" ]]; then
        if [[ -n "$servers" ]]; then
            echo -e "  ${BOLD}Servers:${NC}"
            for s in $servers; do echo -e "    ${G}→${NC} $s"; done
        else
            echo -e "  ${BOLD}Servers:${NC}  ${Y}none${NC}"
        fi
        echo ""
        echo -e "  ${BOLD}Behaviour:${NC}"
        echo -e "    ${G}✓${NC} Internet stays on client's own connection"
        echo -e "    ${G}✓${NC} Client uses their own DNS"
        echo -e "    ${G}✓${NC} Only allowed server IPs go through VPN"
    else
        echo ""
        echo -e "  ${BOLD}Behaviour:${NC}"
        echo -e "    ${Y}!${NC} ALL client traffic routes through VPN"
        echo -e "    ${Y}!${NC} Client DNS is overridden by VPN DNS"
    fi

    echo ""
    [[ -n "$ovpn" ]] && echo -e "  ${BOLD}Config:${NC} $ovpn\n  ${DIM}scp root@<vpn>:$ovpn ./${NC}\n"
}

# ==========================================================================  #
# CMD: list-users
# ==========================================================================  #
cmd_list_users() {
    need_install
    banner "VPN Users"

    if [[ ! -s "$ACL_DB" ]]; then
        info "No users yet. Run: sudo $0 add-user"
        return
    fi

    printf "\n  ${BOLD}%-22s  %-8s  %-8s  %s${NC}\n" "USER" "MODE" "CCD" "ALLOWED SERVERS"
    printf "  %-22s  %-8s  %-8s  %s\n"               "----" "----" "---" "---------------"

    while IFS='|' read -r user mode servers; do
        [[ -z "$user" ]] && continue
        local ccd_ok="${G}ok${NC}"
        [[ ! -f "$CCD_DIR/$user" ]] && ccd_ok="${R}miss${NC}"

        local mode_label
        [[ "$mode" == "full" ]] && mode_label="${Y}full${NC}" || mode_label="${G}split${NC}"

        printf "  %-22s  " "$user"
        echo -ne "$mode_label"
        printf "    "
        echo -ne "$ccd_ok"
        printf "      %s\n" "${servers:--}"
    done < "$ACL_DB"

    echo -e "\n  ${DIM}ACL: $ACL_DB  |  CCD: $CCD_DIR${NC}\n"
}

# ==========================================================================  #
# CMD: delete-user
# ==========================================================================  #
cmd_delete_user() {
    need_install
    banner "Delete VPN User"

    [[ -s "$ACL_DB" ]] || { info "No users found."; exit 0; }

    local username="${USER_NAME:-}"

    if [[ -z "$username" ]]; then
        # Interactive selection
        echo -e "${BOLD}Users:${NC}\n"
        local i=1
        declare -a ulist
        while IFS='|' read -r user mode _; do
            [[ -z "$user" ]] && continue
            local ml="${G}split${NC}"; [[ "$mode" == "full" ]] && ml="${Y}full${NC}"
            printf "  ${C}%d)${NC} %-20s " "$i" "$user"
            echo -e "$ml"
            ulist+=("$user"); (( i++ ))
        done < "$ACL_DB"

        echo ""
        ask "Number to delete" "q to cancel"
        local choice; read -r choice
        [[ "$choice" == "q" || -z "$choice" ]] && exit 0

        local idx=$(( choice - 1 ))
        username="${ulist[$idx]:-}"
        [[ -z "$username" ]] && die "Invalid selection."
    fi

    echo ""
    warn "Will revoke '$username' and remove all their access."
    confirm "Are you sure?" || { info "Aborted."; exit 0; }

    get_installer
    info "Revoking certificate..."
    if bash "$INSTALLER" client revoke "$username" 2>/dev/null; then
        ok "Certificate revoked."
    else
        warn "CLI revoke failed — opening interactive menu."
        bash "$INSTALLER" interactive
    fi

    [[ -f "$CCD_DIR/$username" ]] && { rm -f "$CCD_DIR/$username"; ok "CCD removed."; }
    acl_remove "$username"
    ok "ACL entry removed."

    restart_vpn
    echo ""
    ok "User '$username' deleted."
    echo ""
}

# ==========================================================================  #
# CMD: fix
# ==========================================================================  #
cmd_fix() {
    need_install
    banner "Fix Split Tunnel"
    warn "Re-applying split-tunnel base patches to server.conf."
    warn "Clients must reconnect after this."
    echo ""
    apply_split_tunnel_base
    restart_vpn
    echo ""
    ok "Done. Reconnect VPN clients — internet should be restored."
    echo ""
}

# ==========================================================================  #
# CMD: show-config  — display effective config for a user
# ==========================================================================  #
cmd_show_config() {
    local username="${USER_NAME:-}"
    [[ -z "$username" ]] && { ask "Username"; read -r username; }

    banner "Effective Config: $username"

    # Start from defaults
    local eff_mode="${OPT_MODE:-split}"
    local eff_servers="${OPT_SERVERS:-}"

    # Load config file
    local cfg_file="${OPT_CONFIG_FILE:-}"
    [[ -z "$cfg_file" && -f "$DEFAULT_CONFIG_FILE" ]] && cfg_file="$DEFAULT_CONFIG_FILE"
    [[ -n "$cfg_file" ]] && load_config_file "$cfg_file" "$username"
    [[ -n "$OPT_MODE" ]]    && eff_mode="$OPT_MODE"
    [[ -n "$OPT_SERVERS" ]] && eff_servers="$OPT_SERVERS"

    # Check saved ACL DB
    local saved_mode saved_servers
    saved_mode=$(acl_get "$username" "mode" 2>/dev/null || true)
    saved_servers=$(acl_get "$username" "servers" 2>/dev/null || true)

    echo -e "  ${BOLD}Source${NC}                 ${BOLD}Mode${NC}     ${BOLD}Servers${NC}"
    echo -e "  ------                 ----     -------"
    echo -e "  built-in default       split    (none)"
    [[ -n "$cfg_file"      ]] && echo -e "  config file ($cfg_file)"
    [[ -n "$saved_mode"    ]] && echo -e "  acl db                 $saved_mode  ${saved_servers:-(none)}"
    echo ""
    echo -e "  ${BOLD}Effective:${NC}             $eff_mode     ${eff_servers:-(none)}"
    echo ""
}

# ==========================================================================  #
# Management interface helpers
#
# OpenVPN exposes a TCP management socket when server.conf contains:
#   management 127.0.0.1 7505
#
# We send commands to it via nc (netcat) with a short timeout.
# Supported commands used here:
#   status 2       →  detailed client list (CSV format)
#   kill <cn>      →  disconnect client by Common Name
#   signal SIGUSR1 →  soft restart (optional)
# ==========================================================================  #

# Enable the management interface in server.conf (idempotent)
enable_mgmt() {
    find_conf || die "server.conf not found."
    if ! grep -q "^management " "$OPENVPN_CONF"; then
        printf '\n# Management interface\nmanagement %s %s\n' \
            "$MGMT_HOST" "$MGMT_PORT" >> "$OPENVPN_CONF"
        ok "Management interface enabled (${MGMT_HOST}:${MGMT_PORT})"
        restart_vpn
    else
        verbose "Management interface already configured."
    fi
}

# Send one command to the management socket, return output (strips prompt lines)
mgmt_cmd() {
    local cmd="$1"
    # Check nc is available
    if ! command -v nc &>/dev/null; then
        die "netcat (nc) is required for management interface. Install it first:\n  apt install netcat-openbsd  OR  yum install nmap-ncat"
    fi
    # Send command followed by 'quit', capture output, strip OpenVPN banner/prompts
    local out
    out=$(printf '%s\nquit\n' "$cmd" \
        | nc -w "$MGMT_TIMEOUT" "$MGMT_HOST" "$MGMT_PORT" 2>/dev/null \
        | grep -v '^>' \
        | grep -v '^INFO:' \
        || true)
    echo "$out"
}

# Check management socket is reachable
mgmt_check() {
    if ! nc -z -w "$MGMT_TIMEOUT" "$MGMT_HOST" "$MGMT_PORT" 2>/dev/null; then
        err "Cannot reach management interface at ${MGMT_HOST}:${MGMT_PORT}"
        err "Make sure OpenVPN is running and management is enabled."
        err "Run: sudo $0 fix  to enable it, then reconnect."
        return 1
    fi
    return 0
}

# Parse 'status 2' output into display rows
# status 2 CSV columns (CLIENT_LIST):
#   Common Name, Real Address, VPN IP, Bytes Received, Bytes Sent, Connected Since, VPN IP v6, Username
parse_status() {
    local raw="$1"
    declare -g -a STATUS_ROWS=()
    while IFS=',' read -r cn real_addr vpn_ip bytes_rx bytes_tx since _rest; do
        [[ "$cn" == "CLIENT_LIST" ]] && continue   # header row
        [[ -z "$cn" ]] && continue
        # Humanise byte counts
        local rx_h tx_h
        rx_h=$(humanise_bytes "$bytes_rx")
        tx_h=$(humanise_bytes "$bytes_tx")
        STATUS_ROWS+=("${cn}|${real_addr}|${vpn_ip}|${rx_h}|${tx_h}|${since}")
    done <<< "$(echo "$raw" | grep '^CLIENT_LIST')"
}

humanise_bytes() {
    local b="${1:-0}"
    if   (( b >= 1073741824 )); then printf "%.1fG" "$(echo "scale=1; $b/1073741824" | bc)"
    elif (( b >= 1048576    )); then printf "%.1fM" "$(echo "scale=1; $b/1048576"    | bc)"
    elif (( b >= 1024       )); then printf "%.1fK" "$(echo "scale=1; $b/1024"       | bc)"
    else printf "%dB" "$b"
    fi
}

# Render the status table to stdout
render_status_table() {
    local rows=("$@")
    if (( ${#rows[@]} == 0 )); then
        echo -e "  ${DIM}No clients currently connected.${NC}"
        return
    fi

    printf "\n  ${BOLD}%-20s  %-22s  %-15s  %-8s  %-8s  %s${NC}\n" \
        "USER" "REAL ADDRESS" "VPN IP" "↓ RX" "↑ TX" "CONNECTED SINCE"
    printf "  %-20s  %-22s  %-15s  %-8s  %-8s  %s\n" \
        "----" "------------" "------" "----" "----" "---------------"

    for row in "${rows[@]}"; do
        IFS='|' read -r cn real vpn rx tx since <<< "$row"
        # Lookup mode from ACL DB
        local mode_label=""
        if [[ -s "$ACL_DB" ]]; then
            local m; m=$(grep "^${cn}|" "$ACL_DB" 2>/dev/null | cut -d'|' -f2 || true)
            [[ "$m" == "full"  ]] && mode_label=" ${Y}[full]${NC}"
            [[ "$m" == "split" ]] && mode_label=" ${G}[split]${NC}"
        fi
        printf "  %-20s  %-22s  %-15s  %-8s  %-8s  %s" \
            "$cn" "$real" "$vpn" "$rx" "$tx" "$since"
        echo -e "$mode_label"
    done
    echo ""
}

# ==========================================================================  #
# CMD: status  —  one-shot connected client table
# ==========================================================================  #
cmd_status() {
    need_install
    banner "Connected Clients"

    enable_mgmt
    mgmt_check || exit 1

    local raw
    raw=$(mgmt_cmd "status 2")
    verbose "Raw management output:\n$raw"

    parse_status "$raw"
    render_status_table "${STATUS_ROWS[@]+"${STATUS_ROWS[@]}"}"

    # Summary line
    local count=${#STATUS_ROWS[@]}
    echo -e "  ${BOLD}Total connected:${NC} $count"
    echo ""
}

# ==========================================================================  #
# CMD: monitor  —  live auto-refreshing connection table
# ==========================================================================  #
cmd_monitor() {
    need_install
    enable_mgmt
    mgmt_check || exit 1

    local interval="$OPT_INTERVAL"
    echo ""
    info "Live monitor  (refresh every ${interval}s)  —  press Ctrl+C to exit"
    echo ""

    # Trap Ctrl+C to restore terminal cleanly
    trap 'echo -e "\n${NC}"; tput cnorm 2>/dev/null || true; exit 0' INT TERM

    # Hide cursor for cleaner output
    tput civis 2>/dev/null || true

    while true; do
        local raw
        raw=$(mgmt_cmd "status 2" 2>/dev/null || true)
        parse_status "$raw"

        # Move cursor to top and redraw
        clear
        echo -e "${BOLD}${C}  OpenVPN — Live Connections${NC}   ${DIM}$(date '+%Y-%m-%d %H:%M:%S')   interval: ${interval}s   Ctrl+C to exit${NC}"
        echo -e "  ${DIM}Server: $OPENVPN_CONF${NC}"

        render_status_table "${STATUS_ROWS[@]+"${STATUS_ROWS[@]}"}"

        local count=${#STATUS_ROWS[@]}
        echo -e "  ${BOLD}Total connected:${NC} $count"
        echo ""
        echo -e "  ${DIM}To disconnect a user: sudo $0 kick <username>${NC}"

        sleep "$interval"
    done
}

# ==========================================================================  #
# CMD: kick  —  force-disconnect a connected user
# ==========================================================================  #
cmd_kick() {
    need_install
    banner "Kick User"

    enable_mgmt
    mgmt_check || exit 1

    # ── Resolve target username ───────────────────────────────────────────── #
    local target="${USER_NAME:-}"

    if [[ -z "$target" ]]; then
        # Show who is connected and let the operator pick
        local raw
        raw=$(mgmt_cmd "status 2")
        parse_status "$raw"

        if (( ${#STATUS_ROWS[@]} == 0 )); then
            info "No clients are currently connected."
            exit 0
        fi

        echo -e "${BOLD}Connected clients:${NC}\n"
        local i=1
        declare -a cn_list=()
        for row in "${STATUS_ROWS[@]}"; do
            IFS='|' read -r cn real vpn rx tx since <<< "$row"
            printf "  ${C}%d)${NC} %-20s  ${DIM}%s  vpn:%s  since:%s${NC}\n" \
                "$i" "$cn" "$real" "$vpn" "$since"
            cn_list+=("$cn")
            (( i++ ))
        done

        echo ""
        ask "Number to kick" "q to cancel"
        local choice; read -r choice
        [[ "$choice" == "q" || -z "$choice" ]] && exit 0

        local idx=$(( choice - 1 ))
        target="${cn_list[$idx]:-}"
        [[ -z "$target" ]] && die "Invalid selection."
    fi

    echo ""
    warn "Will force-disconnect '$target' immediately."
    confirm "Are you sure?" || { info "Aborted."; exit 0; }

    # ── Send kill command ─────────────────────────────────────────────────── #
    info "Sending disconnect to '$target'..."
    local response
    response=$(mgmt_cmd "kill $target")
    verbose "Management response: $response"

    if echo "$response" | grep -qi "SUCCESS"; then
        ok "User '$target' has been disconnected."
    elif echo "$response" | grep -qi "ERROR"; then
        warn "Management reported: $response"
        warn "User may not be connected right now."
    else
        # Some versions respond differently — check if they appear in status
        sleep 1
        local raw_after
        raw_after=$(mgmt_cmd "status 2")
        if echo "$raw_after" | grep -q "CLIENT_LIST,${target},"; then
            warn "User '$target' may still be connected. Response: $response"
        else
            ok "User '$target' appears to have been disconnected."
        fi
    fi
    echo ""
}


# ==========================================================================  #
# Help
# ==========================================================================  #
show_help() {
    echo ""
    echo -e "${BOLD}openvpn-manager.sh${NC}  v5  —  per-user tunnel mode + monitoring + force-disconnect"
    echo ""
    echo -e "  ${BOLD}Commands:${NC}"
    echo -e "    ${C}install${NC}                       Install OpenVPN server"
    echo -e "    ${C}add-user${NC}   <n> [flags]        Add a new VPN user"
    echo -e "    ${C}edit-user${NC}  <n> [flags]        Change a user's mode or server access"
    echo -e "    ${C}delete-user${NC} <n>               Revoke a user's certificate"
    echo -e "    ${C}list-users${NC}                    Show all users, modes, and access"
    echo -e "    ${C}status${NC}                        Show currently connected clients"
    echo -e "    ${C}monitor${NC}                       Live auto-refreshing connection table"
    echo -e "    ${C}kick${NC}       <n>                Force-disconnect a connected user"
    echo -e "    ${C}show-config${NC} <n>               Show effective config for a user"
    echo -e "    ${C}fix${NC}                           Re-apply split-tunnel (fix internet)"
    echo ""
    echo -e "  ${BOLD}User Flags:${NC}  (for add-user and edit-user)"
    echo -e "    ${C}-m, --mode <split|full>${NC}       Tunnel mode                default: split"
    echo -e "    ${C}-s, --servers <list>${NC}          Allowed IPs/CIDRs          comma-separated"
    echo -e "    ${C}-p, --password${NC}                Prompt for key password"
    echo ""
    echo -e "  ${BOLD}Global Flags:${NC}"
    echo -e "    ${C}-c, --config <file>${NC}           Load from config file"
    echo -e "    ${C}-n, --interval <secs>${NC}         Monitor refresh interval   default: 5"
    echo -e "    ${C}-v, --verbose${NC}                 Debug output"
    echo -e "    ${C}-y, --yes${NC}                     Auto-confirm all prompts"
    echo ""
    echo -e "  ${BOLD}Config File${NC}  (default: ~/.openvpn-manager.conf)"
    echo -e "    ${DIM}default_mode=split${NC}"
    echo -e "    ${DIM}default_servers=10.10.1.0/24${NC}"
    echo -e ""
    echo -e "    ${DIM}[alice]${NC}"
    echo -e "    ${DIM}mode=split${NC}"
    echo -e "    ${DIM}servers=10.10.1.5/32,10.10.2.0/24${NC}"
    echo -e ""
    echo -e "    ${DIM}[bob]${NC}"
    echo -e "    ${DIM}mode=full${NC}"
    echo ""
    echo -e "  ${BOLD}Examples:${NC}"
    echo -e "    ${DIM}sudo $0 install${NC}"
    echo -e "    ${DIM}sudo $0 add-user alice --mode split --servers 10.10.1.5/32${NC}"
    echo -e "    ${DIM}sudo $0 add-user bob   --mode full${NC}"
    echo -e "    ${DIM}sudo $0 add-user carol --config /etc/vpn-users.conf${NC}"
    echo -e "    ${DIM}sudo $0 status${NC}"
    echo -e "    ${DIM}sudo $0 monitor --interval 10${NC}"
    echo -e "    ${DIM}sudo $0 kick alice${NC}"
    echo -e "    ${DIM}sudo $0 edit-user alice --servers 10.10.1.5/32,10.10.2.0/24${NC}"
    echo -e "    ${DIM}sudo $0 delete-user bob${NC}"
    echo -e "    ${DIM}sudo $0 list-users${NC}"
    echo -e "    ${DIM}sudo $0 fix${NC}"
    echo ""
}

# ==========================================================================  #
# Entrypoint
# ==========================================================================  #
need_root

# Separate the command from the flags
RAW_CMD="${1:-}"; shift || true

# Parse global flags first (works on all remaining args)
declare -a PARSED_ARGS=()
parse_global_flags "$@"
set -- "${PARSED_ARGS[@]+"${PARSED_ARGS[@]}"}"

# Extract positional username arg if present (first non-flag arg after command)
USER_NAME="${1:-}"; shift || true

# Parse per-user flags from what's left
parse_user_flags "$@"

verbose "CMD=$RAW_CMD USER=${USER_NAME:-} MODE=${OPT_MODE:-} SERVERS=${OPT_SERVERS:-} YES=$OPT_YES INTERVAL=$OPT_INTERVAL"

case "$RAW_CMD" in
    install)      cmd_install ;;
    add-user)     cmd_upsert_user 0 ;;
    edit-user)    cmd_upsert_user 1 ;;
    delete-user)  cmd_delete_user ;;
    list-users)   cmd_list_users ;;
    status)       cmd_status ;;
    monitor)      cmd_monitor ;;
    kick)         cmd_kick ;;
    show-config)  cmd_show_config ;;
    fix)          cmd_fix ;;
    help|-h|--help) show_help ;;
    *)            show_help ;;
esac
