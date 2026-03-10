# openvpn-manager

A wrapper around [angristan/openvpn-install](https://github.com/angristan/openvpn-install) that adds **per-user tunnel modes**, **server access control**, and **config file support** on top of a standard OpenVPN server.

---

## Features

- **Split tunnel** — client keeps their own internet and DNS; only traffic to allowed server IPs goes through VPN
- **Full tunnel** — all client traffic routes through VPN (classic mode)
- **Per-user mode** — Alice can be split tunnel, Bob can be full tunnel, on the same server
- **Server ACL** — in split mode, each user only sees the servers you explicitly allow
- **Config file** — define all users and their settings in a single `.conf` file
- **Full CLI** — every option is available as a command-line flag; scriptable with `--yes`

---

## Requirements

- Linux server (Debian / Ubuntu / Fedora / CentOS / Arch — anything supported by angristan's installer)
- `systemd`
- `curl`
- Root access (`sudo`)

---

## Quick Start

```bash
# Download
curl -O https://your-server/openvpn-manager.sh
chmod +x openvpn-manager.sh

# Install OpenVPN
sudo ./openvpn-manager.sh install

# Add users
sudo ./openvpn-manager.sh add-user alice --mode split --servers 10.10.1.5/32
sudo ./openvpn-manager.sh add-user bob   --mode full

# Check who has access to what
sudo ./openvpn-manager.sh list-users
```

---

## Commands

```
sudo ./openvpn-manager.sh <command> [username] [flags]
```

| Command | Description |
|---|---|
| `install` | Install OpenVPN server with split-tunnel base config |
| `add-user <name>` | Add a new VPN user with certificate and access rules |
| `edit-user <name>` | Change an existing user's tunnel mode or server access |
| `delete-user <name>` | Revoke a user's certificate and remove their access |
| `list-users` | Show all users, their tunnel mode, and allowed servers |
| `show-config <name>` | Show the effective resolved config for a user |
| `status` | Show currently connected clients with transfer stats |
| `monitor` | Live auto-refreshing connection table (Ctrl+C to exit) |
| `kick <n>` | Force-disconnect a connected user immediately |
| `fix` | Re-apply split-tunnel patches (restores internet if lost) |

---

## Flags

### Global flags (any command)

| Flag | Description |
|---|---|
| `-c, --config <file>` | Load user settings from a config file |
| `-n, --interval <secs>` | Monitor refresh interval (default: 5) |
| `-v, --verbose` | Show debug output |
| `-y, --yes` | Auto-confirm all prompts (for scripting) |

### User flags (`add-user`, `edit-user`)

| Flag | Description | Default |
|---|---|---|
| `-m, --mode <split\|full>` | Tunnel mode for this user | `split` |
| `-s, --servers <list>` | Allowed IPs/CIDRs, comma or space separated | — |
| `-p, --password` | Prompt for a client private key password | off |

---

## Tunnel Modes

### Split tunnel (default)

Only traffic destined for the servers you define goes through the VPN. The client keeps their own internet connection and DNS resolver untouched.

```
Client                VPN Server
  ├── google.com   ──→  own ISP (not VPN)
  ├── 10.10.1.5    ──→  VPN tunnel  ──→  server
  └── 10.10.2.0/24 ──→  VPN tunnel  ──→  subnet
```

Use this when you want clients to access internal resources without affecting their internet browsing.

### Full tunnel

All client traffic — including internet — is routed through the VPN server.

```
Client                VPN Server
  └── everything   ──→  VPN tunnel  ──→  internet / servers
```

Use this when you want clients to appear to come from the VPN server's IP, or need to enforce internet traffic inspection.

---

## Usage Examples

### Adding users

```bash
# Split tunnel — access one server
sudo ./openvpn-manager.sh add-user alice --mode split --servers 10.10.1.5/32

# Split tunnel — access multiple servers
sudo ./openvpn-manager.sh add-user charlie --mode split --servers 10.10.1.5/32,10.10.1.20/32

# Split tunnel — access an entire subnet
sudo ./openvpn-manager.sh add-user devteam --mode split --servers 10.10.2.0/24

# Full tunnel
sudo ./openvpn-manager.sh add-user bob --mode full

# From config file (see Config File section)
sudo ./openvpn-manager.sh add-user alice --config /etc/openvpn-manager.conf

# With private key password
sudo ./openvpn-manager.sh add-user alice --mode split --servers 10.10.1.5/32 --password

# Non-interactive (for scripting)
sudo ./openvpn-manager.sh add-user alice --mode full --yes
```

### Editing users

```bash
# Change Alice from split to full tunnel
sudo ./openvpn-manager.sh edit-user alice --mode full

# Update Bob's allowed servers (mode stays the same)
sudo ./openvpn-manager.sh edit-user bob --servers 10.10.1.5/32,10.10.2.0/24

# Switch back to split with new servers
sudo ./openvpn-manager.sh edit-user alice --mode split --servers 10.10.3.0/24
```

### Managing users

```bash
# List all users
sudo ./openvpn-manager.sh list-users

# See resolved effective config for a user
sudo ./openvpn-manager.sh show-config alice

# Delete a user
sudo ./openvpn-manager.sh delete-user bob

# Delete without confirmation prompt
sudo ./openvpn-manager.sh delete-user bob --yes
```

### Fixing internet after connecting

```bash
# If a client loses internet after connecting, re-apply split-tunnel patches
sudo ./openvpn-manager.sh fix
```

---

## Config File

You can define all users and their settings in a config file instead of typing flags each time.

**Default location:** `~/.openvpn-manager.conf` (auto-loaded if it exists)  
**Custom location:** pass with `--config /path/to/file`

### Format

```ini
# Global defaults — apply to all users unless overridden
default_mode=split
default_servers=10.10.1.0/24   # optional

# Per-user sections
[alice]
mode=split
servers=10.10.1.5/32,10.10.2.0/24

[bob]
mode=full

[charlie]
mode=split
servers=10.10.1.10/32,10.10.1.20/32

[devteam]
mode=split
servers=10.10.2.0/24

[admin]
mode=full
```

### Using the config file

```bash
# Add users — settings are read from their [section]
sudo ./openvpn-manager.sh add-user alice   --config /etc/openvpn-manager.conf
sudo ./openvpn-manager.sh add-user bob     --config /etc/openvpn-manager.conf
sudo ./openvpn-manager.sh add-user charlie --config /etc/openvpn-manager.conf
```

### Settings priority (highest to lowest)

```
CLI flags  →  config file [user section]  →  config file global defaults  →  built-in default (split)
```

CLI flags always win. Config file fills in anything not explicitly provided on the command line.

---

## How It Works

### Server-side: Client Config Directory (CCD)

OpenVPN's CCD feature lets the server push different directives to each client at connect time. This manager writes one file per user at `/etc/openvpn/server/ccd/<username>`.

**Split tunnel CCD file** (`/etc/openvpn/server/ccd/alice`):
```
push "route 10.10.1.5 255.255.255.255"
push "route 10.10.2.0 255.255.255.0"
```

**Full tunnel CCD file** (`/etc/openvpn/server/ccd/bob`):
```
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 1.1.1.1"
push "dhcp-option DNS 8.8.8.8"
```

### Why internet breaks without the fix

angristan's installer pushes three directives to **all** clients by default:

| Directive | Effect |
|---|---|
| `push "redirect-gateway def1"` | Overrides client's default route → all internet goes through VPN |
| `push "dhcp-option DNS 1.1.1.1"` | Overrides client's DNS resolver → DNS may break |
| `push "route ..."` (global) | Broad routes go to all users, not just allowed ones |

This manager removes all three from `server.conf` on install (and on every `add-user`) and moves routing control entirely into per-user CCD files.

---

## File Locations

| File | Purpose |
|---|---|
| `/etc/openvpn/server/server.conf` | OpenVPN server config |
| `/etc/openvpn/server/ccd/<user>` | Per-user push directives (CCD) |
| `/etc/openvpn/user-acl.conf` | ACL database (user\|mode\|servers) |
| `~/.openvpn-manager.conf` | Default config file (auto-loaded) |
| `/tmp/openvpn-install.sh` | Cached angristan installer |

---

## Scripting / Automation

Use `--yes` to suppress all confirmation prompts.

```bash
#!/bin/bash
CFG=/etc/openvpn-manager.conf

USERS=(alice bob charlie devteam admin)
for user in "${USERS[@]}"; do
    sudo ./openvpn-manager.sh add-user "$user" --config "$CFG" --yes
done
```

JSON-friendly listing (pipe through `column` or `jq` as needed):
```bash
sudo ./openvpn-manager.sh list-users
```

---

## Monitoring Connections

### One-shot status

```bash
sudo ./openvpn-manager.sh status
```

Output:

```
━━━  Connected Clients  ━━━

  USER                  REAL ADDRESS            VPN IP           ↓ RX      ↑ TX      CONNECTED SINCE
  ----                  ------------            ------           ----      ----      ---------------
  alice                 203.0.113.45:52341      10.8.0.2         4.2M      1.1M      2024-01-15 14:32:01  [split]
  bob                   198.51.100.22:41892     10.8.0.3         800.0K    200.0K    2024-01-15 09:15:44  [full]

  Total connected: 2
```

### Live monitor

```bash
# Refresh every 5 seconds (default)
sudo ./openvpn-manager.sh monitor

# Custom refresh interval
sudo ./openvpn-manager.sh monitor --interval 10

# Press Ctrl+C to exit
```

### Force-disconnect a user

```bash
# With username directly
sudo ./openvpn-manager.sh kick alice

# Interactive — shows connected clients to choose from
sudo ./openvpn-manager.sh kick

# Skip confirmation
sudo ./openvpn-manager.sh kick alice --yes
```

> **Note:** `kick` disconnects the session immediately. The user can reconnect unless their certificate has been revoked. To permanently remove access, use `delete-user`.

### How monitoring works

The manager uses OpenVPN's built-in **management interface** — a TCP socket on `127.0.0.1:7505` that accepts real-time commands. On first use of `status`, `monitor`, or `kick`, the socket is enabled automatically in `server.conf`.

`kick` sends a `kill <common_name>` command to the socket, which OpenVPN executes immediately.

Requires `nc` (netcat): `apt install netcat-openbsd` or `yum install nmap-ncat`.

---

## Troubleshooting

**Client loses internet after connecting**
```bash
sudo ./openvpn-manager.sh fix
# Then reconnect your VPN client
```

**`server.conf` not found**
```bash
# Check where angristan put it
find /etc/openvpn -name "server.conf"
```

**Certificate generation fails (CLI mode)**  
The script falls back to angristan's interactive menu automatically. Choose "Add a new user" and enter the same username you passed to `add-user`.

**Check what's being pushed to a specific user**
```bash
cat /etc/openvpn/server/ccd/<username>
```

**Verify split-tunnel patches are applied**
```bash
grep -E 'redirect-gateway|dhcp-option DNS' /etc/openvpn/server/server.conf
# All matching lines should be commented out with # [split-tunnel]
```

---

## License

MIT
