#!/bin/sh
# SSClash-Go installer for Keenetic (Entware on USB).
#
# Prerequisites (Keenetic web UI -> General system settings -> Components):
#   - Open packages support
#   - Ext file system (USB drive formatted ext4, mounted with OPKG access)
#   - Netfilter subsystem kernel modules
#   - USB drive with Entware installed (see Keenetic OPKG guide)
#
# Run over SSH as root (Entware port 222 or system port 22):
#   sh install-keenetic.sh
#
# Offline / local binary:
#   sh install-keenetic.sh --from /tmp/ssclash-linux-arm64
#
#   sh install-keenetic.sh --port 8443 --tls-self-signed
#
# Options:
#   --from <path>   Install this local ssclash binary instead of downloading.
#   --version <tag> Download a specific release tag (default: latest).
#   --no-mihomo     Skip Mihomo kernel download (install later from Settings).
#   --port <n>      Web UI port (default 9091; all interfaces)
#   --bind <ip>     Bind web UI to this IP (with --port, default 9091)
#   --addr <host:port>  Full SSCLASH_ADDR (overrides --port / --bind)
#   --tls-cert <path>   TLS certificate (PEM); requires --tls-key
#   --tls-key <path>    TLS private key (PEM); requires --tls-cert
#   --tls-self-signed   Generate $ROOT/.ssclash/tls.{crt,key} (needs openssl)
#   -h, --help      Show this help.
set -eu

REPO="zerolabnet/SSClash-Go"
SSCLASH_API="https://api.github.com/repos/${REPO}/releases/latest"
MIHOMO_API="https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"

ROOT=/opt/clash
SSCLASH_BIN="$ROOT/bin/ssclash"
CLASH_BIN="$ROOT/bin/clash"
SETTINGS="$ROOT/.ssclash/settings"
UI_PORT=9091
INIT_DEST=/opt/etc/init.d/S99ssclash
PIDFILE=/opt/var/run/ssclash.pid

FROM=""
VERSION="latest"
SKIP_MIHOMO=0
UI_BIND=""
UI_ADDR=""
TLS_CERT=""
TLS_KEY=""
TLS_SELF_SIGNED=0
SSCLASH_ASSET=""
SSCLASH_BIN_URL=""
SSCLASH_SVC_URL=""
MIHOMO_ARCH=""
SSCLASH_TAG=""

say()  { echo "[ssclash] $*"; }
info() { echo "[ssclash]   $*"; }
warn() { echo "[ssclash] ! $*"; }
die()  { echo "[ssclash] ERROR: $*" >&2; exit 1; }

install_file() {
	_src="$1"
	_dst="$2"
	_mode="${3:-755}"
	mkdir -p "$(dirname "$_dst")"
	cp -f "$_src" "$_dst"
	chmod "$_mode" "$_dst"
}

while [ $# -gt 0 ]; do
	case "$1" in
		--from) FROM="${2:-}"; shift 2 ;;
		--from=*) FROM="${1#*=}"; shift ;;
		--version) VERSION="${2:-}"; shift 2 ;;
		--version=*) VERSION="${1#*=}"; shift ;;
		--no-mihomo) SKIP_MIHOMO=1; shift ;;
		--port) UI_PORT="${2:-}"; shift 2 ;;
		--port=*) UI_PORT="${1#*=}"; shift ;;
		--bind) UI_BIND="${2:-}"; shift 2 ;;
		--bind=*) UI_BIND="${1#*=}"; shift ;;
		--addr) UI_ADDR="${2:-}"; shift 2 ;;
		--addr=*) UI_ADDR="${1#*=}"; shift ;;
		--tls-cert) TLS_CERT="${2:-}"; shift 2 ;;
		--tls-cert=*) TLS_CERT="${1#*=}"; shift ;;
		--tls-key) TLS_KEY="${2:-}"; shift 2 ;;
		--tls-key=*) TLS_KEY="${1#*=}"; shift ;;
		--tls-self-signed) TLS_SELF_SIGNED=1; shift ;;
		-h|--help)
			sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
			exit 0 ;;
		*) die "Unknown option: $1" ;;
	esac
done

validate_ui_port() {
	case "$UI_PORT" in
		''|*[!0-9]*) die "invalid --port: $UI_PORT" ;;
	esac
	if [ "$UI_PORT" -lt 1 ] || [ "$UI_PORT" -gt 65535 ]; then
		die "invalid --port (use 1-65535): $UI_PORT"
	fi
}

finalize_ui_addr() {
	if [ -n "$UI_ADDR" ]; then
		return 0
	fi
	if [ -n "$UI_BIND" ]; then
		UI_ADDR="${UI_BIND}:${UI_PORT}"
	elif [ "$UI_PORT" != "9091" ]; then
		UI_ADDR=":${UI_PORT}"
	fi
}

prepare_tls_certs() {
	if [ "$TLS_SELF_SIGNED" = 1 ]; then
		TLS_CERT="$ROOT/.ssclash/tls.crt"
		TLS_KEY="$ROOT/.ssclash/tls.key"
		mkdir -p "$ROOT/.ssclash"
		command -v openssl >/dev/null 2>&1 || die "openssl required for --tls-self-signed"
		say "generating self-signed TLS cert..."
		openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
			-keyout "$TLS_KEY" -out "$TLS_CERT" -subj "/CN=ssclash" \
			|| die "openssl failed"
		chmod 0600 "$TLS_KEY"
		info "TLS cert: $TLS_CERT"
	fi
	if [ -n "$TLS_CERT" ] || [ -n "$TLS_KEY" ]; then
		[ -n "$TLS_CERT" ] && [ -n "$TLS_KEY" ] \
			|| die "--tls-cert and --tls-key are required together"
		[ -f "$TLS_CERT" ] || die "TLS cert not found: $TLS_CERT"
		[ -f "$TLS_KEY" ] || die "TLS key not found: $TLS_KEY"
	fi
}

ui_scheme() {
	if [ -n "$TLS_CERT" ]; then echo https; else echo http; fi
}

ui_effective_port() {
	if [ -n "$UI_ADDR" ]; then
		case "$UI_ADDR" in
			:*) echo "${UI_ADDR#:}" ;;
			*:* ) echo "${UI_ADDR##*:}" ;;
			*) echo "$UI_PORT" ;;
		esac
	else
		echo "$UI_PORT"
	fi
}

ui_effective_host() {
	_fallback="${1%%/*}"
	if [ -n "$UI_BIND" ]; then
		echo "${UI_BIND%%/*}"
		return
	fi
	if [ -n "$UI_ADDR" ]; then
		case "$UI_ADDR" in
			:*) echo "$_fallback" ;;
			*:* ) echo "${UI_ADDR%%:*}" | sed 's|/.*||' ;;
			*) echo "$_fallback" ;;
		esac
	else
		echo "$_fallback"
	fi
}

configure_keenetic_init() {
	_f="$INIT_DEST"
	[ -f "$_f" ] || return 0
	if [ -n "$UI_ADDR" ]; then
		sed -i "s|^[[:space:]]*# export SSCLASH_ADDR=.*|export SSCLASH_ADDR=\"${UI_ADDR}\"|" "$_f"
		info "web UI listen: ${UI_ADDR}"
	fi
	if [ -n "$TLS_CERT" ]; then
		sed -i "s|^[[:space:]]*# export SSCLASH_TLS_CERT=.*|export SSCLASH_TLS_CERT=\"${TLS_CERT}\"|" "$_f"
		sed -i "s|^[[:space:]]*# export SSCLASH_TLS_KEY=.*|export SSCLASH_TLS_KEY=\"${TLS_KEY}\"|" "$_f"
		info "HTTPS enabled: ${TLS_CERT}"
	fi
}

validate_ui_port
finalize_ui_addr
prepare_tls_certs

# ---- Environment checks ----------------------------------------------------
[ "$(id -u)" = "0" ] || die "run as root"
[ -d /opt/bin ] || die "Entware /opt not found — install OPKG/Entware on USB first"
[ -f /etc/openwrt_release ] && warn "OpenWrt detected — use packaging/openwrt/install-openwrt.sh instead"

ensure_curl() {
	if command -v curl >/dev/null 2>&1; then
		return 0
	fi
	command -v opkg >/dev/null 2>&1 || die "opkg not found"
	say "installing curl via opkg..."
	opkg update || die "opkg update failed"
	opkg install curl ca-bundle || die "failed to install curl"
}

# ---- Architecture (Keenetic Entware: mipsel, mips, aarch64) ------------------
detect_arch() {
	ARCH_RAW=$(uname -m)
	OPKG_ARCH=""
	if command -v opkg >/dev/null 2>&1; then
		OPKG_ARCH=$(opkg print-architecture 2>/dev/null | awk '/arch/ {print $3; exit}' || true)
	fi
	info "CPU: ${ARCH_RAW}, opkg arch: ${OPKG_ARCH:-unknown}"

	case "$ARCH_RAW" in
		aarch64|arm64)
			SSCLASH_ASSET="arm64"
			MIHOMO_ARCH="arm64"
			;;
		mipsel)
			if echo "$OPKG_ARCH" | grep -qi hard; then
				SSCLASH_ASSET="mipsle-hardfloat"
				MIHOMO_ARCH="mipsle-hardfloat"
			else
				SSCLASH_ASSET="mipsle-softfloat"
				MIHOMO_ARCH="mipsle-softfloat"
			fi
			;;
		mips)
			if echo "$OPKG_ARCH" | grep -qi hard; then
				SSCLASH_ASSET="mips-hardfloat"
				MIHOMO_ARCH="mips-hardfloat"
			else
				SSCLASH_ASSET="mips-softfloat"
				MIHOMO_ARCH="mips-softfloat"
			fi
			;;
		armv7l)
			SSCLASH_ASSET="armv7"
			MIHOMO_ARCH="armv7"
			;;
		*)
			die "unsupported CPU: ${ARCH_RAW} (supported: aarch64, mipsel, mips, armv7l)"
			;;
	esac

	info "ssclash asset: ssclash-linux-${SSCLASH_ASSET}"
	[ -n "$MIHOMO_ARCH" ] && info "Mihomo kernel: mihomo-linux-${MIHOMO_ARCH}"
}

fetch_ssclash_release() {
	say "fetching latest ssclash-go release..."
	RELEASE_JSON=$(curl -fsSL "$SSCLASH_API") || die "GitHub API request failed"
	SSCLASH_TAG=$(printf '%s' "$RELEASE_JSON" \
		| grep '"tag_name"' | head -1 \
		| sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
	[ -n "$SSCLASH_TAG" ] || die "could not parse release tag"
	info "release: ${SSCLASH_TAG}"

	SSCLASH_BIN_URL=$(printf '%s' "$RELEASE_JSON" \
		| grep '"browser_download_url"' \
		| grep "ssclash-linux-${SSCLASH_ASSET}\"" | head -1 \
		| sed 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
	[ -n "$SSCLASH_BIN_URL" ] || die "asset ssclash-linux-${SSCLASH_ASSET} not found in release"
	info "binary: ${SSCLASH_BIN_URL##*/}"

	SSCLASH_SVC_URL=$(printf '%s' "$RELEASE_JSON" \
		| grep '"browser_download_url"' \
		| grep 'ssclash-keenetic-service.tar.gz"' | head -1 \
		| sed 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
	[ -n "$SSCLASH_SVC_URL" ] && info "service bundle: ssclash-keenetic-service.tar.gz"
}

install_ssclash() {
	if [ -n "$FROM" ]; then
		[ -f "$FROM" ] || die "binary not found: $FROM"
		say "installing local binary: $FROM"
		mkdir -p "$ROOT/bin"
		install_file "$FROM" "$SSCLASH_BIN" 755
		return 0
	fi

	say "downloading ssclash..."
	TMP="$(mktemp)"
	curl -fSL --retry 2 --connect-timeout 15 --max-time 300 \
		"$SSCLASH_BIN_URL" -o "$TMP" || die "ssclash download failed"
	mkdir -p "$ROOT/bin"
	install_file "$TMP" "$SSCLASH_BIN" 755
	rm -f "$TMP"
	say "installed ${SSCLASH_BIN}"
}

mihomo_asset_url() {
	_ver="$1"
	_arch="$2"
	_candidates=""
	case "$_arch" in
		loong64)
			_candidates="mihomo-linux-loong64-abi2-${_ver}.gz mihomo-linux-loong64-abi1-${_ver}.gz"
			;;
		*)
			_candidates="mihomo-linux-${_arch}-${_ver}.gz"
			;;
	esac
	for _name in $_candidates; do
		_url=$(printf '%s' "$MIHOMO_JSON" \
			| grep '"browser_download_url"' \
			| grep "/${_name}\"" | head -1 \
			| sed 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
		if [ -n "$_url" ]; then
			echo "$_url"
			return 0
		fi
	done
	return 1
}

install_mihomo() {
	if [ "$SKIP_MIHOMO" = "1" ]; then
		warn "skipping Mihomo download (--no-mihomo)"
		return 0
	fi
	if [ -z "$MIHOMO_ARCH" ]; then
		warn "Mihomo architecture unknown — install from Settings later"
		return 0
	fi

	say "fetching latest Mihomo release..."
	MIHOMO_JSON=$(curl -fsSL "$MIHOMO_API") || {
		warn "Mihomo GitHub API request failed — install from Settings later"
		return 0
	}
	MIHOMO_VER=$(printf '%s' "$MIHOMO_JSON" \
		| grep '"tag_name"' | head -1 \
		| sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
	if [ -z "$MIHOMO_VER" ]; then
		warn "could not parse Mihomo version — install from Settings later"
		return 0
	fi
	info "Mihomo: ${MIHOMO_VER}"

	MIHOMO_URL=$(mihomo_asset_url "$MIHOMO_VER" "$MIHOMO_ARCH") || {
		warn "Mihomo asset for ${MIHOMO_ARCH} not found — install from Settings later"
		return 0
	}

	say "downloading Mihomo kernel..."
	if ! curl -fSL --retry 2 --connect-timeout 15 --max-time 300 \
		"$MIHOMO_URL" -o /tmp/clash.gz; then
		warn "Mihomo download failed — install from Settings later"
		rm -f /tmp/clash.gz
		return 0
	fi

	mkdir -p "$(dirname "$CLASH_BIN")"
	if ! gunzip -c /tmp/clash.gz > "$CLASH_BIN"; then
		warn "Mihomo extraction failed — install from Settings later"
		rm -f /tmp/clash.gz "$CLASH_BIN"
		return 0
	fi
	chmod +x "$CLASH_BIN"
	rm -f /tmp/clash.gz

	MIHOMO_V=$("$CLASH_BIN" -v 2>/dev/null || true)
	say "Mihomo installed: ${MIHOMO_V:-ok}"
}

install_init() {
	SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
	SRC="$SCRIPT_DIR/etc/init.d/S99ssclash"
	mkdir -p /opt/etc/init.d /opt/var/run
	if [ -f "$SRC" ]; then
		install_file "$SRC" "$INIT_DEST" 755
		say "installed Entware init -> $INIT_DEST"
		configure_keenetic_init
		return 0
	fi

	if [ -n "$SSCLASH_SVC_URL" ]; then
		say "installing Entware init from release..."
		curl -fSL "$SSCLASH_SVC_URL" -o /tmp/ssclash-keenetic-svc.tgz \
			&& tar -xzf /tmp/ssclash-keenetic-svc.tgz -C / \
			&& rm -f /tmp/ssclash-keenetic-svc.tgz \
			|| die "could not install Keenetic service bundle"
		[ -x "$INIT_DEST" ] || die "init script missing after service bundle extract: $INIT_DEST"
		say "installed Entware init -> $INIT_DEST"
		configure_keenetic_init
		return 0
	fi

	die "init script missing locally and ssclash-keenetic-service.tar.gz not found in release"
}

write_settings() {
	mkdir -p "$ROOT/.ssclash" "$ROOT/local-rules" "$ROOT/rule-providers" "$ROOT/proxy-providers" "$ROOT/subscriptions" "$ROOT/ui"
	set_kv() {
		_key="$1"
		_val="$2"
		if [ -f "$SETTINGS" ] && grep -q "^${_key}=" "$SETTINGS" 2>/dev/null; then
			_tmp="$SETTINGS.tmp"
			sed "s|^${_key}=.*|${_key}=${_val}|" "$SETTINGS" > "$_tmp" && mv "$_tmp" "$SETTINGS"
		else
			printf '%s=%s\n' "$_key" "$_val" >> "$SETTINGS"
		fi
	}
	set_kv OPERATING_MODE gateway
	set_kv PROXY_MODE tproxy
	set_kv ENABLE_NAT_MASQUERADE true
	set_kv ENABLE_DNS_UPSTREAM true
	set_kv ENABLE_DNS_REDIRECT false
	# Applies only after config.yaml uses fake-ip-filter-mode whitelist/rule.
	set_kv AUTO_FAKEIP_WHITELIST true
}

check_netfilter_modules() {
	_ok=1
	if command -v lsmod >/dev/null 2>&1; then
		lsmod 2>/dev/null | grep -qE 'nf_tables|xt_TPROXY|tproxy' || _ok=0
	fi
	for _m in nf_tables xt_TPROXY; do
		modprobe "$_m" 2>/dev/null || true
	done
	if [ "$_ok" = 0 ]; then
		warn "Netfilter kernel modules not loaded"
		warn "Enable 'Netfilter subsystem kernel modules' in Keenetic Components, then reboot"
	fi
}

start_service() {
	if [ ! -x "$INIT_DEST" ]; then
		return 0
	fi
	if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
		"$INIT_DEST" restart >/dev/null 2>&1 \
			|| warn "service restart failed — run: $INIT_DEST start"
	else
		"$INIT_DEST" start >/dev/null 2>&1 \
			|| warn "service start skipped — open the web UI and press Start"
	fi
}

lan_ip() {
	ip -4 -o addr show scope global 2>/dev/null \
		| awk '{print $4}' | cut -d/ -f1 | head -n1
}

# ---- MAIN --------------------------------------------------------------------
say "SSClash-Go installer (Keenetic / Entware)"
ensure_curl
check_netfilter_modules
detect_arch
fetch_ssclash_release
install_ssclash
write_settings
install_init
install_mihomo
start_service

IP=$(lan_ip)
[ -n "$IP" ] || IP="<router-ip>"
UI_HOST=$(ui_effective_host "$IP")
UI_P=$(ui_effective_port)
SCHEME=$(ui_scheme)

cat <<EOF

==========================================================================
 SSClash-Go installed (gateway mode) under $ROOT.

 Before first Start, verify in Keenetic web UI (Components):
   - Netfilter subsystem kernel modules — enabled
   - USB / Entware / OPKG — working

 Defaults written to $SETTINGS:
   PROXY_MODE=tproxy, ENABLE_NAT_MASQUERADE=true, AUTO_FAKEIP_WHITELIST=true
   (AUTO_FAKEIP_WHITELIST applies only when config.yaml uses fake-ip whitelist)

 1. Open web UI:  ${SCHEME}://${UI_HOST}:${UI_P}
    Set the admin password on first visit.
 2. Settings — rescan interfaces, confirm LAN/WAN and NAT masquerade.
    DNS is configured automatically at Start (see README Keenetic DNS table).
 3. Configuration — subscriptions/proxies, press Start.

 Optional: proxy only selected clients by IP — Settings → Explicit + LAN;
    config.yaml → fake-ip whitelist + SRC-IP-CIDR rules (see README).

 Service control:
   $INIT_DEST start|stop|restart

 Change port/bind/TLS later: edit SSCLASH_* exports in $INIT_DEST, then restart.

 Point LAN clients' gateway AND DNS at this router ($IP), or use a routing
 policy in Keenetic for devices that should use the proxy.
==========================================================================
EOF
