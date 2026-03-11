#!/bin/bash
# =============================================================================
# openvpn-manager.sh  —  v5
#
# OpenVPN manager: per-user tunnel mode, server ACL, config file,
# live monitoring, force-disconnect, diagnostics.
#
# TUNNEL MODES (per user):
#   split  —  only allowed server IPs route through VPN; internet stays local
#   full   —  ALL traffic goes through VPN (classic VPN behaviour)
#
# COMMANDS:
#   install                    Install OpenVPN server
#   add-user    <name> [flags] Add a user
#   edit-user   <name> [flags] Change a user's mode or servers
#   delete-user <name>         Revoke a user
#   list-users                 Show all users, modes, and server access
#   status                     Show currently connected clients (one-shot)
#   monitor                    Live auto-refreshing connection table
#   kick        <name>         Force-disconnect a connected user
#   diagnose    [name]         Check all causes of cert verification failure
#   regen-client <name>        Revoke + re-issue a user's certificate
#   show-config <name>         Show resolved effective config for a user
#   fix                        Re-apply split-tunnel patches (fix lost internet)
#
# GLOBAL FLAGS:
#   -c, --config <file>        Load defaults from a config file
#   -n, --interval <secs>      Monitor refresh interval (default: 5)
#   -v, --verbose              Verbose output
#   -y, --yes                  Auto-confirm prompts
#
# ADD-USER / EDIT-USER FLAGS:
#   -m, --mode <full|split>    Tunnel mode  (default: split)
#   -s, --servers <list>       Comma-separated IPs/CIDRs
#   -p, --password             Prompt for client key passphrase
#
# CONFIG FILE  (~/.openvpn-manager.conf or -c <file>):
#   default_mode=split
#   default_servers=10.10.1.0/24
#
#   [alice]
#   mode=split
#   servers=10.10.1.5/32,10.10.2.0/24
#
#   [bob]
#   mode=full
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

MGMT_HOST="127.0.0.1"
MGMT_PORT="7505"
MGMT_TIMEOUT="3"

OPENVPN_CONF=""
CCD_DIR=""

OPT_VERBOSE="0"
OPT_YES="0"
OPT_CONFIG_FILE=""
OPT_INTERVAL="5"
OPT_MODE=""
OPT_SERVERS=""
OPT_PASSWORD="0"

# --------------------------------------------------------------------------- #
# Config file parser  (ini-style)
# --------------------------------------------------------------------------- #
load_config_file() {
    local file="$1" target_user="${2:-}"
    [[ -f "$file" ]] || { verbose "Config file not found: $file"; return 0; }
    verbose "Loading config: $file"

    local current_section="__global__"

    while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
        local line="${raw_line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" ]] && continue

        if [[ "$line" =~ ^\[([a-zA-Z0-9_-]+)\]$ ]]; then
            current_section="${BASH_REMATCH[1]}"
            continue
        fi

        if [[ "$line" =~ ^([a-zA-Z0-9_]+)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
            local key="${BASH_REMATCH[1]}" value="${BASH_REMATCH[2]}"
            if [[ "$current_section" == "__global__" ]]; then
                case "$key" in
                    default_mode)    [[ -z "$OPT_MODE"    ]] && OPT_MODE="$value" ;;
                    default_servers) [[ -z "$OPT_SERVERS" ]] && OPT_SERVERS="$value" ;;
                esac
            elif [[ -n "$target_user" && "$current_section" == "$target_user" ]]; then
                case "$key" in
                    mode)    OPT_MODE="$value" ;;
                    servers) OPT_SERVERS="$value" ;;
                esac
            fi
        fi
    done < "$file"
}

# --------------------------------------------------------------------------- #
# Flag parsers
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

parse_user_flags() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -m|--mode)
                [[ -z "${2:-}" ]] && die "--mode requires full or split"
                OPT_MODE="$2"; shift 2 ;;
            -s|--servers)
                [[ -z "${2:-}" ]] && die "--servers requires a value"
                OPT_SERVERS="$2"; shift 2 ;;
            -p|--password) OPT_PASSWORD="1"; shift ;;
            -*) die "Unknown flag: $1" ;;
            *)  shift ;;
        esac
    done
}

# --------------------------------------------------------------------------- #
# Validation helpers
# --------------------------------------------------------------------------- #
validate_mode() {
    case "$1" in
        split|full) return 0 ;;
        *) die "Invalid mode '$1'. Use 'split' or 'full'." ;;
    esac
}

validate_servers() {
    local raw="$1" out="" s
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
# server.conf auto-detection
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
        return 0
    fi
    return 1
}

need_root()    { [[ $EUID -eq 0 ]] || die "Run as root: sudo $0"; }
need_install() { find_conf || die "OpenVPN not installed. Run: sudo $0 install"; }

# --------------------------------------------------------------------------- #
# Restart OpenVPN (tries all known unit names)
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
# Split-tunnel base patches  (idempotent)
# Removes three directives that angristan writes which break split tunnel:
#   redirect-gateway  →  overrides client default route
#   dhcp-option DNS   →  overrides client DNS
#   global push route →  goes to all users; moved to per-user CCD instead
# --------------------------------------------------------------------------- #
apply_split_tunnel_base() {
    find_conf || die "server.conf not found."
    info "Patching $OPENVPN_CONF for split tunnel..."

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
        printf '\n# Per-user access control\nclient-config-dir %s\n' "$CCD_DIR" >> "$OPENVPN_CONF"
        ok "Enabled client-config-dir -> $CCD_DIR"
    fi

    touch "$ACL_DB"
}

# --------------------------------------------------------------------------- #
# Write CCD file for one user
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
            echo 'push "redirect-gateway def1 bypass-dhcp"'
            echo 'push "dhcp-option DNS 1.1.1.1"'
            echo 'push "dhcp-option DNS 8.8.8.8"'
        else
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
# ACL DB helpers  (format: username|mode|servers)
# --------------------------------------------------------------------------- #
acl_save() {
    local user="$1" mode="$2" servers="${3:-}"
    sed -i "/^${user}|/d" "$ACL_DB" 2>/dev/null || true
    echo "${user}|${mode}|${servers}" >> "$ACL_DB"
}

acl_get() {
    local user="$1" field="$2"
    local line
    line=$(grep "^${user}|" "$ACL_DB" 2>/dev/null || true)
    [[ -z "$line" ]] && echo "" && return
    case "$field" in
        mode)    echo "$line" | cut -d'|' -f2 ;;
        servers) echo "$line" | cut -d'|' -f3 ;;
    esac
}

acl_remove() { sed -i "/^${1}|/d" "$ACL_DB" 2>/dev/null || true; }

# --------------------------------------------------------------------------- #
# Confirm prompt  (auto-yes with -y / --yes)
# --------------------------------------------------------------------------- #
confirm() {
    [[ "$OPT_YES" == "1" ]] && return 0
    ask "$1" "y/N"
    local ans; read -r ans
    [[ "${ans,,}" == "y" ]]
}

# --------------------------------------------------------------------------- #
# Installer download + cache validation
# --------------------------------------------------------------------------- #
get_installer() {
    local need_download=0
    if [[ ! -f "$INSTALLER" ]]; then
        need_download=1
    elif ! grep -q 'client add' "$INSTALLER" 2>/dev/null; then
        warn "Cached installer outdated — re-downloading..."
        need_download=1
    fi
    if [[ "$need_download" == "1" ]]; then
        info "Downloading angristan/openvpn-install..."
        curl -fsSL -o "$INSTALLER" "$INSTALLER_URL" || die "Download failed."
        chmod +x "$INSTALLER"
        ok "Installer ready."
    else
        verbose "Installer cached: $INSTALLER"
    fi
}

# ==========================================================================  #
# Management interface
# ==========================================================================  #

enable_mgmt() {
    find_conf || die "server.conf not found."
    if ! grep -q "^management " "$OPENVPN_CONF"; then
        printf '\n# Management interface\nmanagement %s %s\n' "$MGMT_HOST" "$MGMT_PORT" >> "$OPENVPN_CONF"
        ok "Management interface enabled (${MGMT_HOST}:${MGMT_PORT})"
        restart_vpn
    else
        verbose "Management interface already configured."
    fi
}

mgmt_cmd() {
    if ! command -v nc &>/dev/null; then
        die "netcat (nc) required. Install: apt install netcat-openbsd  OR  yum install nmap-ncat"
    fi
    local out
    out=$(printf '%s\nquit\n' "$1" \
        | nc -w "$MGMT_TIMEOUT" "$MGMT_HOST" "$MGMT_PORT" 2>/dev/null \
        | grep -v '^>' | grep -v '^INFO:' || true)
    echo "$out"
}

mgmt_check() {
    if ! nc -z -w "$MGMT_TIMEOUT" "$MGMT_HOST" "$MGMT_PORT" 2>/dev/null; then
        err "Cannot reach management interface at ${MGMT_HOST}:${MGMT_PORT}"
        err "Ensure OpenVPN is running. Run: sudo $0 fix"
        return 1
    fi
}

humanise_bytes() {
    local b="${1:-0}"
    if   (( b >= 1073741824 )); then printf "%.1fG" "$(echo "scale=1; $b/1073741824" | bc)"
    elif (( b >= 1048576    )); then printf "%.1fM" "$(echo "scale=1; $b/1048576"    | bc)"
    elif (( b >= 1024       )); then printf "%.1fK" "$(echo "scale=1; $b/1024"       | bc)"
    else printf "%dB" "$b"
    fi
}

# Parse 'status 2' CSV output -> STATUS_ROWS global array (user|real|vpnip|rx|tx|since)
parse_status() {
    STATUS_ROWS=()
    while IFS=',' read -r cn real_addr vpn_ip bytes_rx bytes_tx since _rest; do
        [[ "$cn" == "CLIENT_LIST" ]] && continue
        [[ -z "$cn" ]] && continue
        STATUS_ROWS+=("${cn}|${real_addr}|${vpn_ip}|$(humanise_bytes "$bytes_rx")|$(humanise_bytes "$bytes_tx")|${since}")
    done <<< "$(echo "$1" | grep '^CLIENT_LIST')"
}

render_status_table() {
    if (( ${#STATUS_ROWS[@]} == 0 )); then
        echo -e "  ${DIM}No clients currently connected.${NC}"
        return
    fi
    printf "\n  ${BOLD}%-20s  %-22s  %-15s  %-8s  %-8s  %s${NC}\n" \
        "USER" "REAL ADDRESS" "VPN IP" "↓ RX" "↑ TX" "CONNECTED SINCE"
    printf "  %-20s  %-22s  %-15s  %-8s  %-8s  %s\n" \
        "----" "------------" "------" "----" "----" "---------------"
    local row cn real vpn rx tx since m mode_label
    for row in "${STATUS_ROWS[@]}"; do
        IFS='|' read -r cn real vpn rx tx since <<< "$row"
        mode_label=""
        if [[ -s "$ACL_DB" ]]; then
            m=$(grep "^${cn}|" "$ACL_DB" 2>/dev/null | cut -d'|' -f2 || true)
            [[ "$m" == "full"  ]] && mode_label=" ${Y}[full]${NC}"
            [[ "$m" == "split" ]] && mode_label=" ${G}[split]${NC}"
        fi
        printf "  %-20s  %-22s  %-15s  %-8s  %-8s  %s" "$cn" "$real" "$vpn" "$rx" "$tx" "$since"
        echo -e "$mode_label"
    done
    echo ""
}

# ==========================================================================  #
# CMD: install
# ==========================================================================  #
cmd_install() {
    banner "Install OpenVPN"
    get_installer

    local patched="/tmp/openvpn-install-split.sh"
    cp "$INSTALLER" "$patched"
    sed -i \
        -e 's|push "redirect-gateway def1 bypass-dhcp"|# [split-tunnel] redirect-gateway removed|g' \
        -e 's|^\(push "dhcp-option DNS\)|# [split-tunnel] \1|g' \
        "$patched"
    chmod +x "$patched"

    echo ""
    warn "The OpenVPN installer will run now. Answer its prompts as normal."
    warn "Split tunnel config is applied automatically after."
    echo ""
    [[ "$OPT_YES" == "1" ]] || read -rp "Press ENTER to continue..."

    bash "$patched" interactive

    info "Locating server.conf..."
    find_conf || die "server.conf not found — did the install complete?"
    ok "Found: $OPENVPN_CONF"

    apply_split_tunnel_base
    restart_vpn

    echo ""
    ok "OpenVPN installed with split tunnel."
    echo -e "\n  Next: ${BOLD}sudo $0 add-user <name> [--mode split|full]${NC}\n"
}

# ==========================================================================  #
# CMD: add-user  /  edit-user
# ==========================================================================  #
cmd_upsert_user() {
    local is_edit="${1:-0}"
    need_install
    banner "${is_edit:+Edit}${is_edit:-Add} User"

    # ── Username ─────────────────────────────────────────────────────────── #
    local username="${USER_NAME:-}"
    if [[ -z "$username" ]]; then
        ask "Username" "alphanumeric"
        read -r username
    fi
    [[ -n "$username" ]]                   || die "Username cannot be empty."
    [[ "$username" =~ ^[a-zA-Z0-9_-]+$ ]] || die "Alphanumeric only (a-z 0-9 _ -)."
    if [[ "$is_edit" == "1" ]]; then
        [[ -f "$CCD_DIR/$username" ]] || die "User '$username' not found. Run: sudo $0 list-users"
    fi
    echo -e "  ${BOLD}User:${NC} $username\n"

    # ── Config file ───────────────────────────────────────────────────────── #
    local cfg_file="${OPT_CONFIG_FILE:-}"
    [[ -z "$cfg_file" && -f "$DEFAULT_CONFIG_FILE" ]] && cfg_file="$DEFAULT_CONFIG_FILE"
    [[ -n "$cfg_file" ]] && load_config_file "$cfg_file" "$username"

    # ── Tunnel mode ───────────────────────────────────────────────────────── #
    local mode="${OPT_MODE:-}"
    if [[ -z "$mode" && "$is_edit" == "1" ]]; then
        mode=$(acl_get "$username" "mode")
    fi
    if [[ -z "$mode" ]]; then
        echo -e "${DIM}Tunnel mode:${NC}"
        echo -e "  ${C}1)${NC} split  — client keeps internet; only allowed servers route through VPN"
        echo -e "  ${C}2)${NC} full   — ALL client traffic goes through VPN"
        echo ""
        ask "Mode" "1=split  2=full"
        local mode_input; read -r mode_input
        case "$mode_input" in
            1|split) mode="split" ;;
            2|full)  mode="full"  ;;
            *) die "Invalid mode. Enter 1, 2, split, or full." ;;
        esac
    fi
    validate_mode "$mode"
    ok "Mode: ${BOLD}$mode${NC}"

    # ── Allowed servers (split only) ──────────────────────────────────────── #
    local servers=""
    if [[ "$mode" == "split" ]]; then
        local raw_servers="${OPT_SERVERS:-}"
        if [[ -z "$raw_servers" && "$is_edit" == "1" ]]; then
            raw_servers=$(acl_get "$username" "servers")
        fi
        if [[ -n "$raw_servers" ]]; then
            servers=$(validate_servers "$raw_servers")
        else
            echo ""
            echo -e "${DIM}Enter the IP or subnet for each server this user may reach."
            echo -e "  10.10.1.5        single host  (/32 assumed)"
            echo -e "  10.10.1.5/32     single host"
            echo -e "  10.10.2.0/24     entire subnet"
            echo -e "Blank line = done.${NC}\n"

            local srv_arr=() i=1 entry
            while true; do
                ask "  Server $i" "blank to finish"
                read -r entry
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

        local cert_args=("client" "add" "$username")
        if [[ "$OPT_PASSWORD" == "1" ]]; then
            info "Generating password-protected certificate for '$username'..."
            cert_args+=("--password")
        else
            info "Generating passwordless certificate for '$username'..."
        fi

        verbose "Running: bash $INSTALLER ${cert_args[*]}"
        if bash "$INSTALLER" "${cert_args[@]}"; then
            ok "Certificate created."
        else
            die "Certificate generation failed.\nRe-run manually: bash $INSTALLER client add $username"
        fi
    fi

    # ── Ensure split-tunnel base is intact ────────────────────────────────── #
    echo ""
    info "Verifying split-tunnel base config..."
    apply_split_tunnel_base

    # ── Write CCD + save ACL ─────────────────────────────────────────────── #
    write_ccd "$username" "$mode" "$servers"
    ok "CCD written -> $CCD_DIR/$username"

    acl_save "$username" "$mode" "$servers"
    ok "ACL saved."

    restart_vpn

    # ── Summary ───────────────────────────────────────────────────────────── #
    local ovpn=""
    [[ "$is_edit" == "0" ]] && ovpn=$(find /root /home -name "${username}.ovpn" 2>/dev/null | head -1 || true)

    echo ""
    if [[ "$is_edit" == "1" ]]; then
        echo -e "${G}${BOLD}  User '$username' updated${NC}"
    else
        echo -e "${G}${BOLD}  User '$username' created${NC}"
    fi
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

    local user mode servers ccd_ok mode_label
    while IFS='|' read -r user mode servers; do
        [[ -z "$user" ]] && continue
        ccd_ok="${G}ok${NC}"; [[ ! -f "$CCD_DIR/$user" ]] && ccd_ok="${R}miss${NC}"
        mode_label="${G}split${NC}"; [[ "$mode" == "full" ]] && mode_label="${Y}full${NC}"
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
        echo -e "${BOLD}Users:${NC}\n"
        local i=1 user mode ml
        declare -a ulist=()
        while IFS='|' read -r user mode _; do
            [[ -z "$user" ]] && continue
            ml="${G}split${NC}"; [[ "$mode" == "full" ]] && ml="${Y}full${NC}"
            printf "  ${C}%d)${NC} %-20s " "$i" "$user"; echo -e "$ml"
            ulist+=("$user"); (( i++ ))
        done < "$ACL_DB"

        echo ""
        ask "Number to delete" "q to cancel"
        local choice; read -r choice
        [[ "$choice" == "q" || -z "$choice" ]] && exit 0
        username="${ulist[$(( choice - 1 ))]:-}"
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
# CMD: status
# ==========================================================================  #
cmd_status() {
    need_install
    banner "Connected Clients"
    enable_mgmt
    mgmt_check || exit 1

    local raw
    raw=$(mgmt_cmd "status 2")
    parse_status "$raw"
    render_status_table
    echo -e "  ${BOLD}Total connected:${NC} ${#STATUS_ROWS[@]}\n"
}

# ==========================================================================  #
# CMD: monitor
# ==========================================================================  #
cmd_monitor() {
    need_install
    enable_mgmt
    mgmt_check || exit 1

    local interval="$OPT_INTERVAL"
    info "Live monitor  (refresh every ${interval}s)  —  Ctrl+C to exit"

    trap 'echo -e "\n${NC}"; tput cnorm 2>/dev/null || true; exit 0' INT TERM
    tput civis 2>/dev/null || true

    while true; do
        local raw
        raw=$(mgmt_cmd "status 2" 2>/dev/null || true)
        parse_status "$raw"
        clear
        echo -e "${BOLD}${C}  OpenVPN — Live Connections${NC}   ${DIM}$(date '+%Y-%m-%d %H:%M:%S')   interval: ${interval}s   Ctrl+C to exit${NC}"
        echo -e "  ${DIM}$OPENVPN_CONF${NC}"
        render_status_table
        echo -e "  ${BOLD}Total connected:${NC} ${#STATUS_ROWS[@]}"
        echo -e "\n  ${DIM}To disconnect: sudo $0 kick <username>${NC}"
        sleep "$interval"
    done
}

# ==========================================================================  #
# CMD: kick
# ==========================================================================  #
cmd_kick() {
    need_install
    banner "Kick User"
    enable_mgmt
    mgmt_check || exit 1

    local target="${USER_NAME:-}"
    if [[ -z "$target" ]]; then
        local raw
        raw=$(mgmt_cmd "status 2")
        parse_status "$raw"

        if (( ${#STATUS_ROWS[@]} == 0 )); then
            info "No clients are currently connected."
            exit 0
        fi

        echo -e "${BOLD}Connected clients:${NC}\n"
        local i=1 row cn real vpn rx tx since
        declare -a cn_list=()
        for row in "${STATUS_ROWS[@]}"; do
            IFS='|' read -r cn real vpn rx tx since <<< "$row"
            printf "  ${C}%d)${NC} %-20s  ${DIM}%s  vpn:%s  since:%s${NC}\n" "$i" "$cn" "$real" "$vpn" "$since"
            cn_list+=("$cn"); (( i++ ))
        done

        echo ""
        ask "Number to kick" "q to cancel"
        local choice; read -r choice
        [[ "$choice" == "q" || -z "$choice" ]] && exit 0
        target="${cn_list[$(( choice - 1 ))]:-}"
        [[ -z "$target" ]] && die "Invalid selection."
    fi

    echo ""
    warn "Will force-disconnect '$target' immediately."
    confirm "Are you sure?" || { info "Aborted."; exit 0; }

    info "Disconnecting '$target'..."
    local response
    response=$(mgmt_cmd "kill $target")

    if echo "$response" | grep -qi "SUCCESS"; then
        ok "User '$target' disconnected."
    elif echo "$response" | grep -qi "ERROR"; then
        warn "Response: $response"
        warn "User may not be connected right now."
    else
        sleep 1
        if mgmt_cmd "status 2" | grep -q "CLIENT_LIST,${target},"; then
            warn "User '$target' may still be connected. Response: $response"
        else
            ok "User '$target' appears to have been disconnected."
        fi
    fi
    echo ""
}

# ==========================================================================  #
# CMD: diagnose
# Checks all known causes of "peer certificate verification failure"
# ==========================================================================  #
cmd_diagnose() {
    need_install
    banner "Certificate Diagnostics"

    local username="${USER_NAME:-}"
    local issues=0 warnings=0

    chk_ok()   { echo -e "  ${G}✓${NC}  $*"; }
    chk_fail() { echo -e "  ${R}✗${NC}  ${BOLD}$*${NC}"; (( issues++ )) || true; }
    chk_warn() { echo -e "  ${Y}!${NC}  $*"; (( warnings++ )) || true; }
    chk_info() { echo -e "  ${DIM}    $*${NC}"; }

    # 1. Server clock
    echo -e "${BOLD}1. Server clock${NC}"
    chk_info "Server time: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    if command -v timedatectl &>/dev/null; then
        local sync_status
        sync_status=$(timedatectl show --property=NTPSynchronized --value 2>/dev/null || echo "unknown")
        if [[ "$sync_status" == "yes" ]]; then
            chk_ok "NTP synchronised"
        else
            chk_fail "NTP NOT synchronised — clock skew invalidates certificates"
            chk_info "Fix: timedatectl set-ntp true && systemctl restart systemd-timesyncd"
        fi
    else
        chk_warn "Cannot verify NTP sync (timedatectl not found)"
    fi
    echo ""

    # 2. CA certificate
    echo -e "${BOLD}2. CA certificate${NC}"
    local ca_file
    ca_file="$(dirname "$OPENVPN_CONF")/ca.crt"
    [[ ! -f "$ca_file" ]] && ca_file=$(find /etc/openvpn -name "ca.crt" 2>/dev/null | head -1 || true)

    if [[ -f "$ca_file" ]]; then
        chk_ok "CA cert: $ca_file"
        local ca_end days_left now_epoch ca_end_epoch
        ca_end=$(openssl x509 -in "$ca_file" -noout -enddate 2>/dev/null | cut -d= -f2 || true)
        if [[ -n "$ca_end" ]]; then
            ca_end_epoch=$(date -d "$ca_end" +%s 2>/dev/null || echo 0)
            now_epoch=$(date +%s)
            days_left=$(( (ca_end_epoch - now_epoch) / 86400 ))
            if   (( days_left <  0 )); then chk_fail "CA cert EXPIRED ($ca_end)"
                 chk_info "Fix: regenerate CA with easy-rsa"
            elif (( days_left < 30 )); then chk_warn "CA cert expires in ${days_left} days"
            else                            chk_ok   "CA cert valid for ${days_left} more days"
            fi
        fi
    else
        chk_fail "CA certificate not found"
        chk_info "Expected: $(dirname "$OPENVPN_CONF")/ca.crt"
    fi
    echo ""

    # 3. Server certificate
    echo -e "${BOLD}3. Server certificate${NC}"
    local server_cert=""
    local conf_cert
    conf_cert=$(grep '^cert ' "$OPENVPN_CONF" 2>/dev/null | awk '{print $2}' || true)
    [[ -n "$conf_cert" && -f "$conf_cert" ]] && server_cert="$conf_cert"
    [[ -z "$server_cert" ]] && server_cert=$(find /etc/openvpn -name "server.crt" 2>/dev/null | head -1 || true)

    if [[ -f "$server_cert" ]]; then
        chk_ok "Server cert: $server_cert"
        local eku
        eku=$(openssl x509 -in "$server_cert" -noout -text 2>/dev/null | grep -A1 "Extended Key Usage" | tail -1 || true)
        if echo "$eku" | grep -qi "TLS Web Server"; then
            chk_ok "Has TLS Web Server Authentication EKU"
        else
            chk_fail "Missing 'TLS Web Server Authentication' EKU"
            chk_info "Fix: regenerate server cert with easy-rsa using 'server' profile"
        fi
        local srv_end srv_days now2
        srv_end=$(openssl x509 -in "$server_cert" -noout -enddate 2>/dev/null | cut -d= -f2 || true)
        if [[ -n "$srv_end" ]]; then
            now2=$(date +%s)
            local srv_end_epoch
            srv_end_epoch=$(date -d "$srv_end" +%s 2>/dev/null || echo 0)
            srv_days=$(( (srv_end_epoch - now2) / 86400 ))
            if   (( srv_days <  0 )); then chk_fail "Server cert EXPIRED ($srv_end)"
            elif (( srv_days < 30 )); then chk_warn "Server cert expires in ${srv_days} days"
            else                           chk_ok   "Server cert valid for ${srv_days} more days"
            fi
        fi
        local srv_cn
        srv_cn=$(openssl x509 -in "$server_cert" -noout -subject 2>/dev/null | sed 's/.*CN\s*=\s*//' | sed 's/[,\/].*//' || true)
        [[ -n "$srv_cn" ]] && chk_info "Server cert CN: $srv_cn"
    else
        chk_fail "Server certificate not found"
    fi
    echo ""

    # 4. TLS key
    echo -e "${BOLD}4. TLS key (tls-auth / tls-crypt)${NC}"
    local tls_key
    tls_key=$(grep -E '^tls-(auth|crypt|crypt-v2)' "$OPENVPN_CONF" 2>/dev/null | awk '{print $2}' | head -1 || true)
    if [[ -n "$tls_key" ]]; then
        if [[ -f "$tls_key" ]]; then
            chk_ok "TLS key: $tls_key"
            chk_info "This key must be embedded in the client .ovpn"
        else
            chk_fail "TLS key missing: $tls_key"
        fi
    else
        chk_info "No tls-auth/tls-crypt configured"
    fi
    echo ""

    # 5. Client certificate (if username given)
    if [[ -n "$username" ]]; then
        echo -e "${BOLD}5. Client certificate: '$username'${NC}"
        local client_cert="" pki_dir
        pki_dir=$(find /etc/openvpn -name "issued" -type d 2>/dev/null | head -1 || true)
        [[ -n "$pki_dir" && -f "$pki_dir/${username}.crt" ]] && client_cert="$pki_dir/${username}.crt"
        [[ -z "$client_cert" ]] && client_cert=$(find /etc/openvpn -name "${username}.crt" 2>/dev/null | head -1 || true)

        if [[ -f "$client_cert" ]]; then
            chk_ok "Client cert: $client_cert"
            local crl_file
            crl_file=$(grep '^crl-verify' "$OPENVPN_CONF" 2>/dev/null | awk '{print $2}' || true)
            if [[ -f "$crl_file" && -f "${ca_file:-}" ]]; then
                if openssl verify -crl_check -CAfile "$ca_file" -CRLfile "$crl_file" "$client_cert" &>/dev/null; then
                    chk_ok "Client cert is not revoked"
                else
                    chk_fail "Client cert for '$username' is REVOKED"
                    chk_info "Fix: sudo $0 regen-client $username"
                fi
            fi
            local cli_end cli_days now3 cli_end_epoch
            cli_end=$(openssl x509 -in "$client_cert" -noout -enddate 2>/dev/null | cut -d= -f2 || true)
            if [[ -n "$cli_end" ]]; then
                now3=$(date +%s)
                cli_end_epoch=$(date -d "$cli_end" +%s 2>/dev/null || echo 0)
                cli_days=$(( (cli_end_epoch - now3) / 86400 ))
                if   (( cli_days <  0 )); then chk_fail "Client cert EXPIRED"
                     chk_info "Fix: sudo $0 regen-client $username"
                elif (( cli_days < 30 )); then chk_warn "Client cert expires in ${cli_days} days"
                else                           chk_ok   "Client cert valid for ${cli_days} more days"
                fi
            fi
        else
            chk_warn "Client cert for '$username' not found on server"
        fi
        echo ""
    fi

    # 6. verify-x509-name
    echo -e "${BOLD}6. Hostname / CN verification${NC}"
    local vxn
    vxn=$(grep '^verify-x509-name' "$OPENVPN_CONF" 2>/dev/null || true)
    if [[ -n "$vxn" ]]; then
        chk_warn "server.conf has: $vxn"
        chk_info "Client .ovpn must have the matching verify-x509-name line"
    else
        chk_ok "No verify-x509-name set (uses remote-cert-tls)"
    fi
    echo ""

    # Summary
    echo -e "${BOLD}━━━  Summary  ━━━${NC}\n"
    if (( issues == 0 && warnings == 0 )); then
        ok "No server-side issues found."
        echo ""
        echo -e "  ${BOLD}If client still fails, check client-side:${NC}"
        echo -e "    ${Y}1)${NC} .ovpn has stale CA cert → sudo $0 regen-client <name>"
        echo -e "    ${Y}2)${NC} Client clock is wrong → sync it on the device"
        echo -e "       ${DIM}Windows: w32tm /resync    macOS: sntp -sS time.apple.com${NC}"
        echo -e "    ${Y}3)${NC} .ovpn was built against a different server install"
        echo -e "    ${Y}4)${NC} Client OpenVPN version too old (< 2.4)"
    else
        (( issues   > 0 )) && err   "$issues issue(s) — see ${R}✗${NC} items above"
        (( warnings > 0 )) && warn  "$warnings warning(s) — see ${Y}!${NC} items above"
    fi
    echo ""
}

# ==========================================================================  #
# CMD: regen-client
# Revoke + re-issue certificate, keeping existing mode/server ACL
# ==========================================================================  #
cmd_regen_client() {
    need_install
    banner "Regenerate Client Certificate"

    local username="${USER_NAME:-}"
    if [[ -z "$username" ]]; then
        ask "Username"
        read -r username
    fi
    [[ -n "$username" ]] || die "Username required."

    get_installer
    warn "This revokes the old certificate and issues a new one."
    warn "The user must use the new .ovpn file after this."
    echo ""
    confirm "Continue?" || { info "Aborted."; exit 0; }

    info "Revoking old certificate..."
    bash "$INSTALLER" client revoke "$username" 2>/dev/null && ok "Old cert revoked." || warn "Revoke step skipped."

    info "Issuing new certificate..."
    local cert_args=("client" "add" "$username")
    [[ "$OPT_PASSWORD" == "1" ]] && cert_args+=("--password")
    bash "$INSTALLER" "${cert_args[@]}" || die "Failed to issue new certificate."
    ok "New certificate issued."

    # Re-apply CCD (preserves existing mode and server access)
    local saved_mode saved_servers
    saved_mode=$(acl_get "$username" "mode" 2>/dev/null || echo "split")
    saved_servers=$(acl_get "$username" "servers" 2>/dev/null || echo "")
    write_ccd "$username" "$saved_mode" "$saved_servers"
    ok "CCD re-applied (mode: $saved_mode)."

    local ovpn
    ovpn=$(find /root /home -name "${username}.ovpn" 2>/dev/null | head -1 || true)
    echo ""
    ok "Client config regenerated for '$username'."
    [[ -n "$ovpn" ]] && echo -e "  ${BOLD}New config:${NC} $ovpn\n  ${DIM}scp root@<vpn>:$ovpn ./${NC}"
    echo -e "\n  ${Y}→${NC} Replace the old .ovpn on the client device with this new file.\n"
}

# ==========================================================================  #
# CMD: fix
# ==========================================================================  #
cmd_fix() {
    need_install
    banner "Fix Split Tunnel"
    warn "Re-applying split-tunnel patches to server.conf."
    warn "Clients must reconnect after this."
    echo ""
    apply_split_tunnel_base
    restart_vpn
    echo ""
    ok "Done. Reconnect VPN clients — internet should be restored."
    echo ""
}

# ==========================================================================  #
# CMD: show-config
# ==========================================================================  #
cmd_show_config() {
    local username="${USER_NAME:-}"
    [[ -z "$username" ]] && { ask "Username"; read -r username; }
    banner "Effective Config: $username"

    local cfg_file="${OPT_CONFIG_FILE:-}"
    [[ -z "$cfg_file" && -f "$DEFAULT_CONFIG_FILE" ]] && cfg_file="$DEFAULT_CONFIG_FILE"
    [[ -n "$cfg_file" ]] && load_config_file "$cfg_file" "$username"

    local saved_mode saved_servers
    saved_mode=$(acl_get "$username" "mode" 2>/dev/null || true)
    saved_servers=$(acl_get "$username" "servers" 2>/dev/null || true)

    echo -e "  ${BOLD}Source${NC}              ${BOLD}Mode${NC}     ${BOLD}Servers${NC}"
    echo -e "  ------              ----     -------"
    echo -e "  built-in default    split    (none)"
    [[ -n "$cfg_file"      ]] && echo -e "  config file         ${OPT_MODE:-(unset)}    ${OPT_SERVERS:-(none)}"
    [[ -n "$saved_mode"    ]] && echo -e "  acl db              $saved_mode    ${saved_servers:-(none)}"
    echo ""
    echo -e "  ${BOLD}CCD file:${NC}  ${CCD_DIR}/$username"
    [[ -f "$CCD_DIR/$username" ]] && { echo ""; cat "$CCD_DIR/$username"; }
    echo ""
}

# ==========================================================================  #
# Help
# ==========================================================================  #
show_help() {
    echo ""
    echo -e "${BOLD}openvpn-manager.sh${NC}  v5"
    echo -e "${DIM}Per-user tunnel mode · split/full · monitoring · force-disconnect · diagnostics${NC}"
    echo ""
    echo -e "  ${BOLD}Commands:${NC}"
    echo -e "    ${C}install${NC}                       Install OpenVPN server"
    echo -e "    ${C}add-user${NC}    <name> [flags]    Add a new VPN user (passwordless by default)"
    echo -e "    ${C}edit-user${NC}   <name> [flags]    Change a user's mode or server access"
    echo -e "    ${C}delete-user${NC} <name>            Revoke a user's certificate"
    echo -e "    ${C}list-users${NC}                    Show all users, modes, and access"
    echo -e "    ${C}status${NC}                        One-shot snapshot of connected clients"
    echo -e "    ${C}monitor${NC}                       Live auto-refreshing connection table"
    echo -e "    ${C}kick${NC}        <name>            Force-disconnect a connected user"
    echo -e "    ${C}diagnose${NC}    [name]            Check cert verification failure causes"
    echo -e "    ${C}regen-client${NC} <name>           Revoke + re-issue a user's certificate"
    echo -e "    ${C}show-config${NC} <name>            Show effective config for a user"
    echo -e "    ${C}fix${NC}                           Re-apply split-tunnel (fix internet)"
    echo ""
    echo -e "  ${BOLD}User Flags:${NC}  (add-user, edit-user)"
    echo -e "    ${C}-m, --mode <split|full>${NC}       Tunnel mode              default: split"
    echo -e "    ${C}-s, --servers <list>${NC}          Allowed IPs/CIDRs        comma-separated"
    echo -e "    ${C}-p, --password${NC}                Prompt for key passphrase"
    echo ""
    echo -e "  ${BOLD}Global Flags:${NC}"
    echo -e "    ${C}-c, --config <file>${NC}           Load from config file"
    echo -e "    ${C}-n, --interval <secs>${NC}         Monitor refresh interval  default: 5"
    echo -e "    ${C}-v, --verbose${NC}                 Debug output"
    echo -e "    ${C}-y, --yes${NC}                     Auto-confirm all prompts"
    echo ""
    echo -e "  ${BOLD}Config File${NC}  (~/.openvpn-manager.conf)"
    echo -e "    ${DIM}default_mode=split${NC}"
    echo -e "    ${DIM}[alice]${NC}"
    echo -e "    ${DIM}mode=split${NC}"
    echo -e "    ${DIM}servers=10.10.1.5/32,10.10.2.0/24${NC}"
    echo -e "    ${DIM}[bob]${NC}"
    echo -e "    ${DIM}mode=full${NC}"
    echo ""
    echo -e "  ${BOLD}Examples:${NC}"
    echo -e "    ${DIM}sudo $0 install${NC}"
    echo -e "    ${DIM}sudo $0 add-user alice --mode split --servers 10.10.1.5/32${NC}"
    echo -e "    ${DIM}sudo $0 add-user bob --mode full${NC}"
    echo -e "    ${DIM}sudo $0 edit-user alice --servers 10.10.1.5/32,10.10.2.0/24${NC}"
    echo -e "    ${DIM}sudo $0 status${NC}"
    echo -e "    ${DIM}sudo $0 monitor --interval 10${NC}"
    echo -e "    ${DIM}sudo $0 kick alice${NC}"
    echo -e "    ${DIM}sudo $0 diagnose alice${NC}"
    echo -e "    ${DIM}sudo $0 regen-client alice${NC}"
    echo -e "    ${DIM}sudo $0 list-users${NC}"
    echo -e "    ${DIM}sudo $0 fix${NC}"
    echo ""
}

# ==========================================================================  #
# Entrypoint
# ==========================================================================  #
need_root

RAW_CMD="${1:-}"; shift || true

declare -a PARSED_ARGS=()
parse_global_flags "$@"
set -- "${PARSED_ARGS[@]+"${PARSED_ARGS[@]}"}"

USER_NAME="${1:-}"; shift || true
parse_user_flags "$@"

verbose "CMD=$RAW_CMD USER=${USER_NAME:-} MODE=${OPT_MODE:-} SERVERS=${OPT_SERVERS:-} YES=$OPT_YES INTERVAL=$OPT_INTERVAL"

case "$RAW_CMD" in
    install)       cmd_install ;;
    add-user)      cmd_upsert_user 0 ;;
    edit-user)     cmd_upsert_user 1 ;;
    delete-user)   cmd_delete_user ;;
    list-users)    cmd_list_users ;;
    status)        cmd_status ;;
    monitor)       cmd_monitor ;;
    kick)          cmd_kick ;;
    diagnose)      cmd_diagnose ;;
    regen-client)  cmd_regen_client ;;
    show-config)   cmd_show_config ;;
    fix)           cmd_fix ;;
    help|-h|--help) show_help ;;
    *)             show_help ;;
esac