📖 Read this in other languages:
- [Русский](README.ru.md)

<p align="center">
  <img src=".github/assets/images/logos/SSClash.png" alt="SSClash" width="200">
</p>

<p align="center"><em>Super Simple Clash — centralized selective bypass with Mihomo (Clash.Meta)</em></p>

<p align="center">Here's the step-by-step process for installing and configuring SSClash on your router or Linux gateway.</p>

This repository is the official distribution of **SSClash** — a self-contained
daemon with an embedded web UI. No LuCI package or OpenWrt SDK is required. It
is the successor to the original
[zerolabnet/SSClash](https://github.com/zerolabnet/SSClash) LuCI application
while keeping the same `/opt/clash` layout and feature set.

## Highlights

- **One binary, every architecture.** Pre-built static binaries for amd64, arm64, armv5/6/7, 386, loong64, riscv64, ppc64le, s390x and mips/mipsle variants. The web UI is embedded in the daemon.
- **Embedded web UI** — **Configuration**, **Settings**, **Rule Lists**, built-in **Proxies / Connections / Rules / Core Logs** dashboard, and **System Log** — with YAML editing, service control, interface/kernel management and live streams.
- **External Mihomo core**, fully managed: download/update from GitHub releases (arch auto-detected), start/stop/restart, `clash -t` validation and hot reload via the Mihomo API.
- **Native firewall engine**: atomic `nft -f -` ruleset (`table inet clash`) or iptables/ipset fallback; **TPROXY / HYBRID / TUN / MIXED / MIXED2** modes; exclude/explicit interface model; QUIC blocking; optional drop of forwarded IPv6; optional kill switch while Mihomo is down; optional DoT/DoH blocking when Mihomo DNS interception is active; reserved destination networks; port filter; per-client source bypass; optional proxying of the router's own traffic; optional DSCP bypass and force proxy; fake-ip whitelist optimisation; subscription server-IP bypass.
- **Policy routing** via `ip rule`/`ip route` (tables `100`/`101`, fwmarks `0x1`/`0x2`/`0x3` on OpenWrt and Linux; Keenetic uses `0x80000000`/`0x10000000` with mask `0x90000000`).
- **Secure by default**: first-run admin password (PBKDF2-HMAC-SHA256), HMAC session cookies, CSRF protection, optional HTTPS.
- **Platform support**: OpenWrt, generic Linux (systemd), and Keenetic (Entware).

## Directory layout

Everything lives under `/opt/clash` by default (`SSCLASH_ROOT` overrides this):

```
/opt/clash/
├── bin/ssclash          # SSClash daemon
├── bin/clash            # Mihomo kernel
├── config.yaml
├── configs/             # named profiles
├── local-rules/         # user rule lists (was lst/ in LuCI SSClash)
├── rule-providers/      # downloaded rule providers (was ruleset/)
├── proxy-providers/     # downloaded proxy providers (was proxy_providers/)
├── subscriptions/       # pasted link lists (file providers)
├── ui/                  # external dashboard files
├── .ssclash/            # settings, password, session, doh-custom.txt, OpenWrt dnsmasq backup
└── (runtime) /tmp/ssclash/  # caches, tmpfs symlinks, subscription and DoH list IP caches
```

### Migrating from LuCI SSClash

| LuCI SSClash | SSClash (Go) |
|---|---|
| `lst/` | `local-rules/` |
| `ruleset/` | `rule-providers/` |
| `proxy_providers/` | `proxy-providers/` |
| `settings` at root | `.ssclash/settings` |
| `/tmp/clash/` | `/tmp/ssclash/` |

The Go edition reads the same `config.yaml` and Mihomo kernel path. Rename directories as above if you upgrade in place.

# Setup Guide

## Autoinstall scripts

Each installer fetches the matching release binary, sets up `/opt/clash`, downloads the Mihomo kernel when that release is newer than the one already installed, and registers the OS service. Use `--no-mihomo` to skip the kernel. Use `--update` on an existing install to replace only the SSClash binary and Mihomo; mode, listen address, TLS and the service file stay as they are.

**OpenWrt** (run on the router):

```bash
wget -T 30 -qO- https://github.com/zerolabnet/SSClash-Go/raw/refs/heads/main/install-ssclash-go.sh | ash
```

SSClash **stops itself** before upgrade when the service is already running (so GitHub downloads work through transparent proxy and binaries can be replaced safely).

**Generic Linux** (systemd):

```bash
curl -fsSL https://github.com/zerolabnet/SSClash-Go/raw/refs/heads/main/install-ssclash-go.sh | sudo sh
```

**Keenetic** (Entware over SSH as root). Firmware BusyBox `wget` has no HTTPS (often segfaults / `not an http or ftp url`). Install Entware `wget-ssl` first:

```bash
opkg update && opkg install wget-ssl ca-certificates
export PATH="/opt/bin:/opt/sbin:$PATH"
wget -T 30 -qO- https://github.com/zerolabnet/SSClash-Go/raw/refs/heads/main/install-ssclash-go.sh | ash
```

### Install options (all installers)

| Flag | Purpose |
|---|---|
| `--port <n>` | Web UI port (default `9091`, all interfaces) |
| `--bind <ip>` | Bind web UI to this IP (with `--port`) |
| `--addr <host:port>` | Full `SSCLASH_ADDR` (overrides `--port` / `--bind`) |
| `--root <path>` | OpenWrt only — install directory (default `/opt/clash`; kept on upgrade unless passed again) |
| `--tls-cert <path>` | TLS certificate (PEM); requires `--tls-key` |
| `--tls-key <path>` | TLS private key (PEM); requires `--tls-cert` |
| `--tls-self-signed` | Generate `$ROOT/.ssclash/tls.{crt,key}` (needs `openssl`) |
| `--mode gateway\|server` | Linux only — gateway (transparent proxy) or server. Server seeds `config.yaml` with an inbound `listeners:` example when that file is still missing |
| `--version <tag>` | Download a specific release tag (default: latest) |
| `--from <path>` | Install a local binary instead of downloading |
| `--no-mihomo` | Skip Mihomo kernel download (all installers) |
| `--update` | Replace the SSClash binary and Mihomo only. Keeps mode, listen address, TLS and the service file. Requires an existing install. `--from`, `--version` and `--no-mihomo` are allowed. Do not combine with `--mode`, `--port`, `--bind`, `--addr`, `--root` or `--tls-*` |

Examples:

```bash
wget -T 30 -qO- https://github.com/zerolabnet/SSClash-Go/raw/refs/heads/main/install-ssclash-go.sh | ash -s -- --no-mihomo
wget -T 30 -qO- https://github.com/zerolabnet/SSClash-Go/raw/refs/heads/main/install-ssclash-go.sh | ash -s -- --port 8443 --tls-self-signed
curl -fsSL https://github.com/zerolabnet/SSClash-Go/raw/refs/heads/main/install-ssclash-go.sh | sudo sh -s -- --from ./ssclash-linux-amd64 --mode gateway
```

Platform-specific scripts (same behaviour, longer URLs) live under `packaging/{openwrt,linux,keenetic}/`.

## Manual install — OpenWrt

### Step 1: Update package list

For **OpenWrt >= 25** (apk):

```bash
apk update
```

For **OpenWrt < 25** (opkg):

```bash
opkg update
```

### Step 2: Install required packages

When installing from GitHub Releases (not from a feed), install these dependencies manually:

- `kmod-tun` — TUN mode
- `kmod-nft-tproxy` — firewall4 / nftables transparent proxy
- `iptables-mod-tproxy` — firewall3 / iptables (OpenWrt < 22.03)

```bash
# nftables (firewall4) on OpenWrt >= 25:
apk add kmod-tun kmod-nft-tproxy

# nftables on older OpenWrt:
opkg install kmod-tun kmod-nft-tproxy

# iptables (firewall3):
opkg install kmod-tun iptables-mod-tproxy
```

### Step 3: Download and install SSClash

Pick the binary for your architecture from [GitHub Releases](https://github.com/zerolabnet/SSClash-Go/releases). Replace `<tag>` with that release tag:

```bash
mkdir -p /opt/clash/bin
curl -L -o /opt/clash/bin/ssclash \
  https://github.com/zerolabnet/SSClash-Go/releases/download/<tag>/ssclash-linux-arm64
chmod +x /opt/clash/bin/ssclash
```

Install the init script from the release tarball:

```bash
curl -L -o /tmp/ssclash-openwrt-service.tar.gz \
  https://github.com/zerolabnet/SSClash-Go/releases/download/<tag>/ssclash-openwrt-service.tar.gz
tar -xzf /tmp/ssclash-openwrt-service.tar.gz -C /
/etc/init.d/ssclash enable
/etc/init.d/ssclash start
```

### Offline update

The first install reaches the package feed (`opkg update` or `apk update`) and stops when that feed is unreachable. Packages already present on the router do not skip this step.

An existing install can be updated without GitHub. Save `packaging/openwrt/install-openwrt.sh` from this repository. `curl` or `wget-ssl` must already be installed: stock `uclient-fetch` (the usual `wget`) makes the script update the package index and stop. Place the new Mihomo kernel at `/opt/clash/bin/clash` (`gunzip` the matching `mihomo-linux-*.gz` and `chmod 755`). `--update` keeps the init script, listen address, TLS and install root.

```bash
sh /tmp/install-openwrt.sh --update --from /tmp/ssclash-linux-arm64 --no-mihomo
```

To replace the init script, stop the service and extract `ssclash-openwrt-service.tar.gz` (it contains `etc/init.d/ssclash`):

```bash
/etc/init.d/ssclash stop
tar -xzf /tmp/ssclash-openwrt-service.tar.gz -C /
```

### DNS on OpenWrt

OpenWrt defaults to **OpenWrt dnsmasq upstream** in Settings (not firewall redirect). The two modes are **mutually exclusive** — turning one on turns the other off:

- **OpenWrt dnsmasq upstream** (default) — on **Start**, SSClash adds `127.0.0.1#7874` to dnsmasq, sets `noresolv=1`, and reloads dnsmasq after Mihomo listens. Clients should use the router as DNS (DHCP). Original dnsmasq uci values are backed up under `.ssclash/` and restored on **Stop**.
- **Firewall redirect** — firewall-only on OpenWrt (dnsmasq unchanged). Redirects LAN port 53 (TCP/UDP) to Mihomo in netfilter. Catches hard-coded public DNS (e.g. `8.8.8.8:53`). Keep `dns.listen` on `0.0.0.0:7874` in `config.yaml`. Redirect applies on all LAN ingress (VLAN and bridge member ports included); WAN is excluded. Switching from upstream clears prior dnsmasq upstream uci.

Switch modes in **Settings** → DNS before **Start** or **Restart**.

### Block DoT / DoH

When Mihomo DNS interception is active (**Firewall redirect** or **OpenWrt dnsmasq upstream**), **Settings** → DNS offers LAN-side drops that run **before** transparent proxy / redirect:

- **Block DoT** — drops TCP/UDP to destination port `853` (e.g. Android Private DNS or a fixed DoT resolver bypassing router DNS).
- **Block known DoH (dibdot)** — drops TCP/UDP port `443` to IPv4 addresses from the [dibdot DoH IP blocklists](https://github.com/dibdot/DoH-IP-blocklists) (GPL-3; downloaded at runtime, cached under tmp, refreshed daily). **Warning:** HTTPS to those IPs (including `1.1.1.1` and `8.8.8.8`) stops working from affected LAN clients. IPv6 and DoH not on port 443 are not covered.
- **Block DoH (custom list)** — same `:443` drop for your own `https://host/path` URLs (one per line); hosts are resolved to IPv4 on save. Persistent file: `.ssclash/doh-custom.txt` (included in backup).

Rules apply on LAN ingress; WAN is skipped. **Bypass clients (firewall)** skip these drops. The router itself is unaffected (no OUTPUT rules). IPv4 only.

On the **iptables** backend, DoH blocking requires working **ipset** (installed with `iptables-mod-tproxy` on OpenWrt; Keenetic netfilter uses `xt_set`). Without ipset, only Block DoT applies and a gateway log warning is emitted.

Optional **conntrack-tools** (the `conntrack` CLI on PATH): LAN flows to port `53` are cleared when **Firewall redirect** turns on or off, and on **Stop** if redirect was installed. Port `853` is cleared only when Block DoT turns on. A repeated Apply with the same flags does not touch conntrack. Keenetic repair clears a port only when repair actually restored redirect or DoT DROP rules, not when it only re-seated an existing jump. **nft** and **iptables** share kernel conntrack. Without the tool, new packets follow the new rules immediately but old sessions linger until timeout, with a one-time gateway log warning when redirect or Block DoT is on. Installers do not install it — use `opkg install conntrack-tools` on OpenWrt or Entware if you want immediate teardown.

On **Keenetic TUN** these drops apply: SSClash marks TCP and UDP into `clash-tun`.

Toggle changes take effect on **Start**, **Restart**, or firewall **Apply**. **Refresh list** updates dibdot immediately.

## Manual install — generic Linux

Prerequisites: systemd, `nft` or `iptables`, `ip`.

```bash
curl -fsSL https://github.com/zerolabnet/SSClash-Go/raw/refs/heads/main/install-ssclash-go.sh | sudo sh -s -- --from ./ssclash-linux-amd64 --mode gateway
```

### Offline install

Save `packaging/linux/install-linux.sh` from this repository. `install-ssclash-go.sh` still downloads that script from GitHub. The installer writes the systemd unit itself; the release has no Linux service tarball. Place the Mihomo kernel at `/opt/clash/bin/clash` (`gunzip` the matching `mihomo-linux-*.gz` and `chmod 755`). The asset name follows `uname -m` (`x86_64` → `ssclash-linux-amd64`, `aarch64` → `ssclash-linux-arm64`). `nft` or `iptables`, and `ip`, must already be installed. In gateway mode the script tries `apt-get install conntrack ipset` when those commands are missing; install the packages yourself when the distro feed is unreachable. `apt-get` failure is a warning and the install continues.

```bash
sudo sh /tmp/install-linux.sh --from /tmp/ssclash-linux-amd64 --mode gateway --no-mihomo
```

An existing install keeps mode, listen address, TLS and the unit:

```bash
sudo sh /tmp/install-linux.sh --update --from /tmp/ssclash-linux-amd64 --no-mihomo
```

Gateway mode applies firewall, policy routing and platform DNS interception when you press **Start** (OpenWrt: dnsmasq upstream by default; Keenetic/Linux: firewall redirect). Server mode runs Mihomo only. A fresh `--mode server` install seeds `config.yaml` with an inbound `listeners:` example; an existing file is kept.

## Manual install — Keenetic

Install Entware on USB first. Enable **Open packages**, **Ext file system**, **Netfilter kernel modules** in Keenetic web UI → Components (reboot after enabling Netfilter — kernel `xt_TPROXY` / netfilter support; this does **not** always install a userspace `iptables` binary). SSClash needs an **xtables** userspace CLI: firmware `/sbin/iptables` when present, otherwise the installer runs `opkg install iptables-legacy` or `opkg install iptables` (either is fine if `iptables -V` does not say `nf_tables`). NDMS is **not** a TPROXY API: it rebuilds `filter`/`nat`/`mangle` and drops jumps into custom chains. The supported integration is Keenetic's official [`/opt/etc/ndm/netfilter.d`](https://support.keenetic.com/hero/kn-1012/en/42407-opkg-component-description.html) hook, which restores those jumps with the resolved xtables `iptables` binary (24-second timeout — the hook does not re-run a full Apply).

Policy routing needs the full iproute2 binary; BusyBox's `ip` applet is often
built without `rule` support. The installer runs `opkg install ip-full` when `ip rule` fails.

```bash
opkg update && opkg install wget-ssl ca-certificates
export PATH="/opt/bin:/opt/sbin:$PATH"
wget -qO- https://github.com/zerolabnet/SSClash-Go/raw/refs/heads/main/install-ssclash-go.sh | ash
```

### Offline install

Use this when the router cannot reach GitHub or the Entware feed. Download the files on another computer and copy them to the router (SCP or USB). `install-ssclash-go.sh` still fetches the platform script from GitHub, so the offline run uses `packaging/keenetic/install-keenetic.sh` copied from this repository.

Pick the release assets for `uname -m`: `aarch64` / `arm64` → `ssclash-linux-arm64` and `mihomo-linux-arm64-<tag>.gz`; `armv7l` → `armv7`; `mipsel` or `mips` → `hardfloat` when `opkg print-architecture` contains `hard`, otherwise `softfloat`. Mihomo tags and archives come from the Mihomo releases. The SSClash release also has `ssclash-keenetic-service.tar.gz`, which contains `opt/etc/init.d/S99ssclash`.

Entware packages the installer would fetch from the feed, plus every package named in their `Depends:` lines for this architecture: `iptables-legacy` (or `iptables` when `iptables -V` does not say `nf_tables`), `ip-full`, `conntrack`, `ipset`. Skip `iptables-legacy` when firmware `/sbin/iptables` is already an xtables build. `wget-ssl` and `ca-certificates` are only for the online installer. BusyBox `wget` or `curl` must still be on `PATH`: the script checks that one of them exists.

Lay the files out so the init script sits next to the installer. `--from` does not download the service tarball.

```bash
mkdir -p /tmp/ssclash-offline/etc/init.d /tmp/ssclash-offline/ipk /tmp/ssclash-svc
# from the computer: install-keenetic.sh, the binary, the .ipk files, the service tarball
tar -xzf /tmp/ssclash-keenetic-service.tar.gz -C /tmp/ssclash-svc
cp /tmp/ssclash-svc/opt/etc/init.d/S99ssclash /tmp/ssclash-offline/etc/init.d/
export PATH="/opt/bin:/opt/sbin:$PATH"
opkg install /tmp/ssclash-offline/ipk/*.ipk
mkdir -p /opt/clash/bin
gunzip -c /tmp/mihomo-linux-arm64-<tag>.gz > /opt/clash/bin/clash
chmod 755 /opt/clash/bin/clash
sh /tmp/ssclash-offline/install-keenetic.sh --from /tmp/ssclash-offline/ssclash-linux-arm64 --no-mihomo
```

The installer copies the binary to `/opt/clash/bin/ssclash` and `S99ssclash` to `/opt/etc/init.d/S99ssclash`. `--no-mihomo` leaves `/opt/clash/bin/clash` as you placed it. Replace that file the same way when you update the kernel offline.

An existing install updates without GitHub. `--update` keeps the init script, listen address, TLS and settings:

```bash
sh /tmp/ssclash-offline/install-keenetic.sh --update --from /tmp/ssclash-offline/ssclash-linux-arm64 --no-mihomo
```

Default: **HYBRID** + Exclude mode, **Auto fake-ip whitelist** enabled. NAT is handled by KeeneticOS.
DNS interception defaults to **Firewall redirect** in Settings (LAN port 53 → Mihomo).
Clients should use the router as DNS (Keenetic DHCP).

KeeneticOS rebuilds netfilter on configuration save, WAN reconnect and component
changes, which drops the jumps into the SSClash chains. Start installs an NDMS
hook at `/opt/etc/ndm/netfilter.d/50-ssclash.sh` that re-inserts `PREROUTING -j CLASH`
(and DNS/QUIC rules) with the resolved xtables `iptables` binary. A full daemon reload runs only if the
custom chains themselves are gone. Stop removes the hook.

**Firewall backend on Keenetic** is fixed to **iptables** (xtables userspace, not nftables). Settings
does not offer Auto or nftables. The installer seeds `FIREWALL_BACKEND=iptables`;
Save/API normalize any other value to iptables. Auto would also resolve to iptables
at runtime, but forced nft is refused at Apply. Entware builds whose `iptables -V` reports `nf_tables`
cannot intercept Keenetic LAN forwarding — use xtables instead (`/sbin/iptables`, `iptables-legacy`, or
Entware `iptables` when it is xtables). The installer runs `opkg install iptables-legacy` or
`opkg install iptables` when no suitable CLI exists. **Netfilter subsystem kernel modules** (Components)
are still required for kernel support (`xt_TPROXY`, …). In **TUN** mode Mihomo starts with `DISABLE_NFTABLES=1` because Keenetic has no nftables for LAN forwarding.

**Recommended proxy modes on Keenetic (in order):** **HYBRID** (installer default — SSClash
nat DNAT + TPROXY, all Options features, works with router HTTPS on 443), **MIXED2**
(TCP like HYBRID, UDP via `clash-tun` — better QUIC/UDP, no TCP 443 TPROXY issue),
**TPROXY** (if you move router management HTTPS off TCP 443, e.g. 8443), **TUN**
(SSClash MARK of TCP and UDP into `clash-tun`, same as OpenWrt).
**MIXED** (TCP TPROXY + UDP TUN) inherits the Keenetic TCP `:443` TPROXY limitation;
rarely useful here — prefer **HYBRID** or **MIXED2**.

**Keenetic access policy:** Settings → **Respect Keenetic access
policy** — select policies from the router (Internet → Connection Policies). SSClash matches
NDMS connmarks in firewall rules so only devices assigned to those policies enter the
proxy path. This includes **TUN**.

**RCI access token (KeeneticOS 5.2+):** From firmware **5.2** onward, local RCI on
`127.0.0.1:79` requires an **RCI access token**. SSClash uses RCI for
access-policy and hotspot client names. Settings → **Keenetic access policy** → **RCI access
token** — create a token in the router web UI under **Users and access**, paste it here, and
**Save**. Leave empty on older KeeneticOS that still accepts loopback RCI without a token. If
RCI is missing or rejected, SSClash falls back to `ndmc`; lists still load but names may not
match the router web UI.

**TPROXY on Keenetic and TCP 443:** KeeneticOS uses port 443 internally for `xt_TPROXY`;
LAN TCP to `:443` often never reaches SSClash (TPROXY counters stay at zero). Use **HYBRID**
(default), move router management HTTPS off TCP 443 in the Keenetic web UI (any port
except 443, e.g. 8443), or use **TUN**.

**Keenetic TUN** uses the same capture as OpenWrt and Linux: SSClash marks traffic into `clash-tun` (`auto-route: false`, `auto-redirect: false`). Access policy, bypass clients, port filter, and reserved networks apply. After upgrading from a build that used Mihomo `auto-redirect`, **Stop then Start**.

## Proxy modes (Settings)

| Mode | Capture | `config.yaml` (synced on Save / Start) | Notes |
|---|---|---|---|
| **TPROXY** | SSClash mangle TPROXY `:7894` | `tproxy-port: 7894` | Default on OpenWrt/Linux |
| **HYBRID** | TCP nat DNAT → `:7893`, UDP TPROXY `:7894` | `redir-port: 7893`, `tproxy-port: 7894` | Default on Keenetic; full Options |
| **TUN** | MARK → `clash-tun` (OpenWrt, Linux, and Keenetic) | `tun:` block (`auto-route: false`) | TUN stack in Settings |
| **MIXED** | TCP TPROXY, UDP MARK → `clash-tun` | `tproxy-port: 7894` + `tun:` | On Keenetic: TCP `:443` TPROXY issue; prefer HYBRID/MIXED2 |
| **MIXED2** | TCP nat DNAT → `:7893`, UDP MARK → `clash-tun` | `redir-port: 7893` + `tun:` (no `tproxy-port`) | HYBRID TCP path + MIXED UDP path; full Options on Keenetic |

TUN, MIXED and MIXED2 write `tun.stack` from Settings: **system**, **gvisor**, **mixed**, or **mips** (pure-Go [mipstack](https://github.com/MetaCubeX/mipstack), useful on MIPS routers).

When **Save** in Settings changes proxy mode or TUN stack, SSClash rewrites the active
`config.yaml` profile if it disagrees (same ports/blocks as the table above), validates
with `clash -t`, then restarts Mihomo when the service is running.

## Step 4: Mihomo kernel management

The autoinstall scripts download the latest Mihomo kernel automatically. On a small flash filesystem the new kernel replaces the old one instead of keeping both copies, and a failed update removes `.mihomo-new.*` instead of leaving it to fill the disk. Autoinstall streams Mihomo onto the install filesystem and does not keep a second full uncompressed copy in `/tmp`. You can also manage it from the web UI or install manually (see below).

From the web UI, go to **Settings** → **Mihomo kernel**. Pick a **Release channel** (**Stable** is the default: the latest non-prerelease; **Alpha** uses `mihomo-linux-*-alpha-*` assets), then **Check updates** or **Download / Update**. SSClash will:

- Detect the device architecture
- Check for updates, or download the kernel for the selected channel (Stable: latest non-prerelease; Alpha: `mihomo-linux-*-alpha-*`)
- Install it to `/opt/clash/bin/clash`
- Show kernel status and version

**Important:** Restart the SSClash service after a fresh kernel install.

### Manual kernel installation (optional)

Replace `<tag>` with the Mihomo release tag. The archive name is `mihomo-linux-<arch>-<tag>.gz`; the example below is arm64.

```bash
cd /opt/clash/bin
curl -L -o clash.gz \
  https://github.com/MetaCubeX/mihomo/releases/download/<tag>/mihomo-linux-arm64-<tag>.gz
gunzip clash.gz && chmod +x clash
```

See the [Mihomo releases page](https://github.com/MetaCubeX/mihomo/releases) for other architectures.

## Step 5: Configure interface processing mode

SSClash offers two interface processing modes:

### Explicit mode (recommended)

- Processes traffic **only** on selected interfaces — nothing else reaches Mihomo at the firewall level
- Best when you want tight control over which LAN/VLAN or clients enter the proxy path
- Often combined with fake-ip whitelist and `SRC-IP-CIDR` rules in `config.yaml` (see Step 7)

### Exclude mode (simple default)

- Proxies **all** traffic except interfaces you pick (typically WAN)
- Easiest whole-LAN setup if you do not need per-interface split
- Which destinations are proxied is still decided by Mihomo rules in `config.yaml`

In Exclude mode, **Auto-detect WAN** adds the detected WAN to the bypass list and **Auto-detect LAN** is inactive; in Explicit mode, **Auto-detect LAN** adds the detected LAN to the included list and **Auto-detect WAN** is inactive.

### Additional settings

- **OpenWrt dnsmasq upstream** — Settings → DNS (default on OpenWrt). Points dnsmasq at Mihomo `:7874`; mutually exclusive with firewall redirect (see [DNS on OpenWrt](#dns-on-openwrt)).
- **Firewall redirect** — Settings → DNS. Default on Keenetic and generic Linux; optional on OpenWrt. Redirects LAN port 53 (TCP/UDP) to Mihomo `:7874`.
- **Block DoT / Block DoH (dibdot) / Block DoH (custom)** — Settings → DNS when Mihomo DNS interception is active; see [Block DoT / DoH](#block-dot--doh).
- **Proxy router traffic** — Settings → Options, Gateway only, off by default. Sends the router's own outbound IPv4 TCP/UDP through Mihomo with the same firewall options as LAN clients (reserved networks, bypass clients, port filter, fake-ip whitelist). Keenetic access policies do not apply to the router's own traffic (only LAN clients are matched by policy). HYBRID and MIXED2 DNAT router TCP to 127.0.0.1:7893; other modes use policy-route marks. With firewall DNS redirect, the router's own port 53 goes to Mihomo so fake-ip works for the router. Kill switch does not apply (LAN forward drop only). Turning it off takes effect on the next Apply.
- **DSCP marks** — Settings → Options, Gateway only, off until a list has a value. A DSCP value is a mark on the IP packet. Set it in the client operating system, then type the same number here, so one application or device can skip the proxy or be forced through it while the rest of the LAN stays as configured. **DSCP bypass** (example 62) skips intercept, firewall DNS redirect, the QUIC block, and Block DoH/DoT. **DSCP force proxy** (example 63) skips interface selection and a Keenetic access policy, ignores fake-ip and the port allowlist, and does not skip the QUIC block or Block DoH/DoT. Takes effect on the next Apply.
- **Kill switch** — Settings → Options, Gateway only, off by default. While it is on and Mihomo is not running, LAN clients cannot reach the internet: forwarded traffic toward the WAN is dropped. The panel, SSH and the router's own traffic stay up. Existing WAN port-forwards (DNAT) still pass. When the WAN interface is known, LAN-to-LAN is left alone; when it is not, all forwarding is dropped. Forwarded IPv6 is dropped for the same window. Turning the option on while the proxy is already running changes nothing until the next stop. Turning it off lifts the drop immediately. Server mode never arms it. On Keenetic the NDMS hook stays while the option is on. On OpenWrt, firewall include `firewall.ssclash_ks` (`/var/etc/ssclash-ks.include`) reapplies the drop after a firewall4 reload. On generic Linux the drop remains until SSClash removes it. The window after boot before the SSClash process starts, and a SIGKILL before cleanup, are not covered.
- **Drop forwarded IPv6** — Settings → Options, Gateway only, off by default. Drops IPv6 the router would forward, including excluded interfaces and WAN-to-LAN. The router keeps its own IPv6. AAAA answers are not filtered and IPv6 forwarding is not switched off. If `ip6tables` is missing, Apply still succeeds and the gateway log warns.
- **Block QUIC traffic** — blocks UDP/443 to improve proxy effectiveness (YouTube, etc.)
- **Reserved networks (firewall)** — destination IPv4 CIDRs that skip transparent-proxy marking (Settings → Options). Defaults include RFC special-use ranges and CGNAT `100.64.0.0/10` (Tailscale/Headscale); remove that prefix if Tailnet should go through Mihomo. Mihomo `private-ips` rules are separate. In **TPROXY**, **HYBRID** and **MIXED**, table `100` also gets a scope-link route for each connected IPv4 prefix on an intercepted interface, so a fwmark source lookup still succeeds when Tailscale sets `src_valid_mark=1`. **TUN** and **MIXED2** do not add these routes.
- **Port filter (firewall)** — destination TCP/UDP ports handled in netfilter *before* Mihomo (Settings → Options). **Bypass** never enters the core (e.g. fixed BitTorrent listen ports). **Proxy-only** (when non-empty) marks only listed ports — useful on weak routers so random torrent peers never enter the core. Empty lists keep the previous “all ports” behaviour. This is not the same as Mihomo `DST-PORT` rules.
- **Bypass clients (firewall)** — source IPv4 CIDRs that skip transparent-proxy marking *and* DNS redirect, so those LAN hosts never enter Mihomo (Settings → Options). Not `config.yaml` `SRC-IP-CIDR` (that still sends packets into the core). Empty = off. With fake-ip, set a real DNS on the device. On **OpenWrt dnsmasq upstream** (default), the bypass list does not change DNS for clients using router DNS — they still resolve via dnsmasq → Mihomo; set a public DNS on bypassed clients. On **OpenWrt firewall redirect**, bypass skips DNS redirect (same as Keenetic/Linux) — use a public DNS on the bypassed client.
- **Store rules and proxy providers in RAM** — symlinks `rule-providers/` and `proxy-providers/` to tmpfs to reduce NAND wear
- **Add HWID headers to subscriptions** — Remnawave-compatible 16-character HWID on proxy-provider requests (also used when fetching a remote full config URL)
- **Backup / restore** — export or import `.ssclash/` settings and lists (including `doh-custom.txt`) from the Settings page
- **Web UI port and TLS** — set via install flags or `SSCLASH_ADDR` / `SSCLASH_TLS_*` in the init script or systemd unit
- **NAT masquerade on WAN** — Settings → Linux gateway host, generic Linux in Gateway mode only. Runtime MASQUERADE for LAN clients that use this host as their default gateway. Applied when the proxy starts; nothing is written to `/etc`. Optional WAN interface; empty uses the current default-route interface.
- **Periodic maintenance** — its own Settings card. **Auto-refresh subscription IPs** re-resolves proxy server IPs and updates firewall bypass sets (like a WAN-up refresh); in Server mode the same control only refreshes the local cache. **Auto-refresh fake-ip whitelist** is Gateway only: while the proxy runs, it rebuilds whitelist CIDRs from the same sources as Auto fake-ip whitelist and syncs nft/ipset. **Interval (minutes)** defaults to 30, accepts 5–1440, and applies while the proxy is running.
- **Firewall backend** — Settings → Traffic interception. On OpenWrt and generic Linux: **Auto**, **nftables**, or **iptables**. Keenetic has no switch.

<p align="center">
  <img src=".github/assets/images/screenshots/scr-02.png" alt="Settings — gateway mode on OpenWrt" width="800">
</p>

<p align="center">
  <img src=".github/assets/images/screenshots/scr-03.png" alt="Settings — server mode" width="800">
</p>

## Step 6: Clash configuration management

Edit `config.yaml` in the built-in ACE editor:

- **Syntax highlighting** for YAML
- **Live service control** — Start / Stop / Restart in the toolbar
- **Named profiles** — save and switch configs under `configs/`
- **Load from URL** (optional) — download a full Mihomo YAML into profile `remote` (Remnawave `/sub/{token}` falls back to `/mihomo`). Auto-update can follow the provider’s `Profile-Update-Interval` or a fixed custom interval (1–168h); **Save settings** changes URL/auto/interval without re-downloading; **Stop remote source** clears the subscription while keeping profile `remote` as a local copy. Independent of proxy-provider refresh. Empty URL keeps local-only behaviour.
- **Subscription disable/enable** — comment out proxy-provider blocks without deleting them
- **Open Dashboard** — opens the Mihomo external UI (see Step 9)
- **Listeners** — Server mode only. **Add listener** on the Configuration page builds an inbound Mihomo listener. The Listeners card appears once at least one listener exists. Outside Server mode the button and the card stay hidden.
  <img src=".github/assets/images/screenshots/scr-01.png" alt="Configuration editor" width="800">
</p>

## Step 7: Local rulesets management

Create and manage local rule files for `rule-providers`:

- **Create custom rule lists** with validation
- **Fake-IP whitelist** (`local-rules/fakeip-whitelist-ipcidr.txt`) — destination IPv4/CIDR list for `fake-ip-filter-mode: whitelist` or `rule`. With **Auto fake-ip whitelist** (Settings), the AUTO block is rebuilt on Start/apply from:
  - inline `IP-CIDR` rules in `rules:` with a non-DIRECT action (e.g. `PROXY`, a proxy-group name)
  - IP-CIDR entries in rule-providers referenced by non-DIRECT `RULE-SET` rules
  - `dns.fake-ip-filter` entries (per filter mode)
  - `SRC-IP-CIDR` is **not** copied into this file — it is handled separately by the firewall for per-client source matching
- Use **Regenerate** on the Rule Lists tab after editing rules, or **Save & Reload** / **Start** while auto-sync is enabled
- Organized file management with collapsible sections

<p align="center">
  <img src=".github/assets/images/screenshots/scr-04.png" alt="Rule Lists" width="800">
</p>

## Step 8: Real-time log monitoring

Monitor activity in **System Log**:

- **Live SSE stream** with automatic updates
- **Color-coded sources** — `clash` (Mihomo), `gateway` (firewall/routing/DNS), `ssclash` (daemon/UI)
- Filter by source and search text
- Auto-scroll to latest entries

<p align="center">
  <img src=".github/assets/images/screenshots/scr-09.png" alt="System Log" width="800">
</p>

## Step 9: Mihomo dashboard

SSClash includes a built-in dashboard with four tabs — **Proxies**, **Connections**, **Rules**, and **Core Logs** — in the same UI style as the rest of the app. The browser talks to `/api/mihomo/*`; the Mihomo `secret` and external controller stay on the server.

**System Log** (sidebar) is separate: it shows SSClash daemon, firewall, and routing messages. **Core Logs** shows the live Mihomo core log stream.

Dashboard preferences are stored under `config/*` and `cache/*` keys in the browser's `localStorage`, with optional sync to Mihomo via the core `/storage` slot when **Auto-sync settings** is enabled in the Proxies tab settings. This is separate from Mihomo's `cache.db` file (core profile data such as fake-ip mappings).

Optionally, set `external-ui` in `config.yaml` and install a third-party bundle under `ui/`. When `external-ui` is configured, **Open Dashboard** on the Configuration page opens that external UI in a new tab.

<p align="center">
  <img src=".github/assets/images/screenshots/scr-05.png" alt="Proxies" width="800">
</p>

<p align="center">
  <img src=".github/assets/images/screenshots/scr-06.png" alt="Connections" width="800">
</p>

<p align="center">
  <img src=".github/assets/images/screenshots/scr-07.png" alt="Rules" width="800">
</p>

<p align="center">
  <img src=".github/assets/images/screenshots/scr-08.png" alt="Core Logs" width="800">
</p>

## First run

1. Open `http://<host>:9091` (or your `--port` / `--bind` / TLS URL) and set the admin password.
2. Edit **Configuration** — a sensible default is seeded on first start. Add proxies or a subscription.
3. Press **Start** in the header.

The installer downloads Mihomo automatically. If it was skipped (`--no-mihomo`) or the download failed, get the kernel from **Settings → Mihomo kernel** before **Start**.

## Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `SSCLASH_ROOT` | `/opt/clash` | Working directory (config, kernel, lists) |
| `SSCLASH_TMP` | `/tmp/ssclash` | Runtime temp dir (caches, tmpfs symlinks) |
| `SSCLASH_PLATFORM` | auto | Force `openwrt`, `keenetic`, or `linux` |
| `SSCLASH_ADDR` | `:9091` | Web UI listen address |
| `SSCLASH_SECRET` | auto | Session signing secret (persisted otherwise) |
| `SSCLASH_TLS_CERT` / `SSCLASH_TLS_KEY` | — | Enable HTTPS for the web UI |
| `SSCLASH_DEBUG` | `0` | `1` — verbose boot diagnostics on stderr; extra gateway warnings. Full iptables counter dump: `ssclash fw diagnose` |
| `SSCLASH_BRAND` | `SSClash` | Product name in the authenticated UI |
| `SSCLASH_LOGIN_TITLE` | — | Optional brand on login/setup screens |

## CLI

```
ssclash [serve]              run the daemon + web UI (default)
ssclash fw start|stop|update apply / remove / refresh firewall + routing
ssclash fw validate-policy   check policy routing
ssclash fw repair-policy     repair policy routing
ssclash fw validate-forward  check forward rules
ssclash fw repair-forward    repair forward rules
ssclash fw ndm-reload        restore SSClash jumps after KeeneticOS netfilter rebuild
ssclash fw sync-killswitch   install or remove the gateway kill switch (exit 10: drop is on)
ssclash fw diagnose          log intercept wiring, policies, iptables counters (troubleshooting)
ssclash hotplug wan|tun      run WAN-up or TUN-add handlers (manual / cron)
ssclash cleanup              remove orphan Mihomo + firewall after unclean stop
ssclash setpass [password]   set the web admin password
ssclash version              print version
```

## Key constants

These must stay aligned with `config.yaml` (ports, marks, table IDs):

TPROXY port `7894`, HYBRID TCP redirect port `7893` (`redir-port`), DNS `7874`, external-controller `:9090`, fwmarks `0x1`/`0x2`/`0x3` (OpenWrt and Linux), Keenetic fwmarks `0x80000000`/`0x10000000` with mask `0x90000000`, routing tables `100`/`101`, rule prefs `1000`/`1001`, nft table `inet clash`, TUN device `clash-tun`, default fake-ip range `198.18.0.0/15`.

## Release binaries

Each [GitHub Release](https://github.com/zerolabnet/SSClash-Go/releases) includes:

| Asset | Description |
|---|---|
| `ssclash-linux-amd64`, `ssclash-linux-arm64`, … | Static daemon (16 Linux targets) |
| `ssclash-openwrt-service.tar.gz` | OpenWrt `init.d` service files |
| `ssclash-keenetic-service.tar.gz` | Keenetic Entware `S99ssclash` init script |
| `sha256sums.txt` | SHA-256 checksums |

## Uninstall

Turn **Kill switch** off and click **Save & Apply** before you stop the service, so the drop and the OpenWrt firewall include are removed.

**OpenWrt:**

```bash
/etc/init.d/ssclash stop
/etc/init.d/ssclash disable
rm -f /etc/init.d/ssclash
rm -rf /opt/clash
```

**Linux (systemd):**

```bash
sudo systemctl stop ssclash
sudo systemctl disable ssclash
sudo rm -f /etc/systemd/system/ssclash.service
sudo rm -rf /opt/clash
```

**Keenetic:**

```bash
/opt/etc/init.d/S99ssclash stop
rm -f /opt/etc/init.d/S99ssclash
rm -f /opt/etc/ndm/netfilter.d/50-ssclash.sh
rm -rf /opt/clash
```

## License

SSClash binaries and install scripts in this repository are distributed under the
[SSClash Binary Software License](LICENSE) (proprietary).

The optional **Mihomo** core is a separate third-party component with its own
license. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Support

If SSClash is useful to you, consider [donating](https://zerolab.net/donate/) to support development by [ZeroChaos](https://zerolab.net).
