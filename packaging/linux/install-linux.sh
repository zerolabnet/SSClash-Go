#!/bin/sh
# SSClash-Go installer for generic Linux (systemd).
#
# Installs the binary and working tree under /opt/clash. Gateway prerequisites
# (IP forwarding, kernel modules, optional NAT masquerade) are applied at
# runtime by ssclash when the proxy starts — nothing is written to /etc except
# the systemd unit.
#
# Remote one-liner:
#   curl -fsSL https://raw.githubusercontent.com/zerolabnet/SSClash-Go/main/packaging/linux/install-linux.sh | sudo sh
#
# Offline / local binary:
#   sudo ./install-linux.sh --from ./dist/ssclash-linux-amd64
#
#   sudo ./install-linux.sh --from ./dist/ssclash-linux-amd64 --port 8443 --tls-self-signed
#
# Options:
#   --mode gateway|server  Install mode (prompted when omitted).
#                          gateway = transparent proxy (firewall/routing/DNS).
#                          server  = Mihomo only (inbound listeners:).
#   --from <path>   Install this local binary instead of downloading.
#   --no-mihomo     Skip Mihomo kernel download (install later from Settings).
#   --version <tag> Download a specific release tag (default: latest).
#   --port <n>      Web UI port (default 9091; all interfaces)
#   --bind <ip>     Bind web UI to this IP (with --port, default 9091)
#   --addr <host:port>  Full SSCLASH_ADDR (overrides --port / --bind)
#   --tls-cert <path>   TLS certificate (PEM); requires --tls-key
#   --tls-key <path>    TLS private key (PEM); requires --tls-cert
#   --tls-self-signed   Generate $ROOT/.ssclash/tls.{crt,key} (needs openssl)
#   -h, --help      Show this help.
set -eu

REPO="zerolabnet/SSClash-Go"
MIHOMO_API="https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"
ROOT=/opt/clash
DEST="$ROOT/bin/ssclash"
CLASH_BIN="$ROOT/bin/clash"
UNIT=/etc/systemd/system/ssclash.service
SETTINGS="$ROOT/.ssclash/settings"
UI_PORT=9091

FROM=""
VERSION="latest"
MODE=""
SKIP_MIHOMO=0
MIHOMO_INSTALLED=0
UI_BIND=""
UI_ADDR=""
TLS_CERT=""
TLS_KEY=""
TLS_SELF_SIGNED=0

err() { echo "ERROR: $*" >&2; exit 1; }
info() { echo ">> $*"; }

install_file() {
	_src="$1"
	_dst="$2"
	_mode="${3:-755}"
	mkdir -p "$(dirname "$_dst")"
	cp -f "$_src" "$_dst"
	chmod "$_mode" "$_dst"
}
warn() { echo "WARNING: $*" >&2; }

while [ $# -gt 0 ]; do
	case "$1" in
		--mode) MODE="${2:-}"; shift 2 ;;
		--mode=*) MODE="${1#*=}"; shift ;;
		--from) FROM="${2:-}"; shift 2 ;;
		--from=*) FROM="${1#*=}"; shift ;;
		--no-mihomo) SKIP_MIHOMO=1; shift ;;
		--version) VERSION="${2:-}"; shift 2 ;;
		--version=*) VERSION="${1#*=}"; shift ;;
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
			sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'
			exit 0 ;;
		*) echo "Unknown option: $1" >&2; exit 1 ;;
	esac
done

validate_ui_port() {
	case "$UI_PORT" in
		''|*[!0-9]*) err "invalid --port: $UI_PORT" ;;
	esac
	if [ "$UI_PORT" -lt 1 ] || [ "$UI_PORT" -gt 65535 ]; then
		err "invalid --port (use 1-65535): $UI_PORT"
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
		command -v openssl >/dev/null 2>&1 || err "openssl required for --tls-self-signed"
		info "Generating self-signed TLS cert..."
		openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
			-keyout "$TLS_KEY" -out "$TLS_CERT" -subj "/CN=ssclash" \
			|| err "openssl failed"
		chmod 0600 "$TLS_KEY"
	fi
	if [ -n "$TLS_CERT" ] || [ -n "$TLS_KEY" ]; then
		[ -n "$TLS_CERT" ] && [ -n "$TLS_KEY" ] \
			|| err "--tls-cert and --tls-key are required together"
		[ -f "$TLS_CERT" ] || err "TLS cert not found: $TLS_CERT"
		[ -f "$TLS_KEY" ] || err "TLS key not found: $TLS_KEY"
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

validate_ui_port
finalize_ui_addr
prepare_tls_certs

[ "$(id -u)" = "0" ] || err "Run as root (sudo)."
command -v systemctl >/dev/null 2>&1 || err "systemd (systemctl) is required."

# ---- Install mode -----------------------------------------------------------
if [ -z "$MODE" ]; then
	printf "Install mode:\n  [1] Gateway (transparent proxy: firewall, routing, DNS)\n  [2] Server  (Mihomo only, inbound listeners:)\nChoose [1/2] (default 1): "
	read -r m </dev/tty 2>/dev/null || m=""
	case "$m" in
		2|server) MODE="server" ;;
		*) MODE="gateway" ;;
	esac
fi
case "$MODE" in
	gateway|server) ;;
	*) err "Invalid --mode '$MODE' (use gateway or server)." ;;
esac
info "Install mode: $MODE"

map_arch() {
	case "$1" in
		x86_64|amd64) echo "amd64" ;;
		aarch64|arm64) echo "arm64" ;;
		armv7l|armv7) echo "armv7" ;;
		armv6l) echo "armv6" ;;
		armv5l) echo "armv5" ;;
		i386|i486|i586|i686) echo "386" ;;
		riscv64) echo "riscv64" ;;
		loongarch64) echo "loong64" ;;
		ppc64le|powerpc64le) echo "ppc64le" ;;
		s390x) echo "s390x" ;;
		mips64el) echo "mips64le" ;;
		mips64) echo "mips64" ;;
		mipsel) echo "mipsle-softfloat" ;;
		mips) echo "mips-softfloat" ;;
		*) echo "" ;;
	esac
}

MIHOMO_ARCH="$(map_arch "$(uname -m)")"
[ -n "$MIHOMO_ARCH" ] && info "Mihomo kernel: mihomo-linux-${MIHOMO_ARCH}"

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
	command -v curl >/dev/null 2>&1 || {
		warn "curl not found — install Mihomo from Settings later"
		return 0
	}
	command -v gunzip >/dev/null 2>&1 || command -v gzip >/dev/null 2>&1 || {
		warn "gunzip/gzip not found — install Mihomo from Settings later"
		return 0
	}

	info "Fetching latest Mihomo release..."
	MIHOMO_JSON=$(curl -fsSL --max-time 20 "$MIHOMO_API") || {
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

	info "Downloading Mihomo kernel..."
	if ! curl -fSL --retry 2 --connect-timeout 15 --max-time 300 \
		"$MIHOMO_URL" -o /tmp/clash.gz; then
		warn "Mihomo download failed — install from Settings later"
		rm -f /tmp/clash.gz
		return 0
	fi

	mkdir -p "$(dirname "$CLASH_BIN")"
	if command -v gunzip >/dev/null 2>&1; then
		_gunzip='gunzip -c'
	else
		_gunzip='gzip -dc'
	fi
	if ! $_gunzip /tmp/clash.gz > "$CLASH_BIN"; then
		warn "Mihomo extraction failed — install from Settings later"
		rm -f /tmp/clash.gz "$CLASH_BIN"
		return 0
	fi
	chmod +x "$CLASH_BIN"
	rm -f /tmp/clash.gz /opt/clash/bin/meta-backup 2>/dev/null || true

	MIHOMO_V=$("$CLASH_BIN" -v 2>/dev/null || true)
	info "Mihomo installed: ${MIHOMO_V:-ok}"
	MIHOMO_INSTALLED=1
}

TMP_BIN=""
cleanup() { [ -n "$TMP_BIN" ] && rm -f "$TMP_BIN"; }
trap cleanup EXIT INT TERM

if [ -n "$FROM" ]; then
	[ -f "$FROM" ] || err "Binary not found: $FROM"
	BIN_SRC="$FROM"
	info "Using local binary: $BIN_SRC"
else
	command -v curl >/dev/null 2>&1 || err "curl is required to download the binary (or use --from)."
	ARCH="$(map_arch "$(uname -m)")"
	[ -n "$ARCH" ] || err "Unsupported architecture: $(uname -m). Build locally and use --from."

	if [ "$VERSION" = "latest" ]; then
		info "Resolving latest release tag for $REPO"
		VERSION="$(curl -fsSL --max-time 20 "https://api.github.com/repos/$REPO/releases/latest" \
			| sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n1)"
		[ -n "$VERSION" ] || err "Could not determine latest release tag."
	fi

	ASSET="ssclash-linux-$ARCH"
	URL="https://github.com/$REPO/releases/download/$VERSION/$ASSET"
	TMP_BIN="$(mktemp)"
	info "Downloading $ASSET ($VERSION)"
	curl -fL --max-time 300 -o "$TMP_BIN" "$URL" \
		|| err "Download failed: $URL"
	BIN_SRC="$TMP_BIN"
fi

info "Creating working directory $ROOT"
mkdir -p "$ROOT/bin" "$ROOT/.ssclash" "$ROOT/local-rules" "$ROOT/rule-providers" "$ROOT/proxy-providers" "$ROOT/subscriptions" "$ROOT/ui"

info "Installing binary -> $DEST"
install_file "$BIN_SRC" "$DEST" 755

install_mihomo

info "Recording operating mode in $SETTINGS"
if [ -f "$SETTINGS" ] && grep -q '^OPERATING_MODE=' "$SETTINGS" 2>/dev/null; then
	tmp="$SETTINGS.tmp"
	sed "s/^OPERATING_MODE=.*/OPERATING_MODE=$MODE/" "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
else
	printf 'OPERATING_MODE=%s\n' "$MODE" >> "$SETTINGS"
fi

info "Installing systemd unit -> $UNIT"
UNIT_EXTRA=""
if [ -n "$UI_ADDR" ]; then
	UNIT_EXTRA="${UNIT_EXTRA}
Environment=SSCLASH_ADDR=${UI_ADDR}"
	info "web UI listen: ${UI_ADDR}"
else
	UNIT_EXTRA="${UNIT_EXTRA}
# Listen address (default :9091 on all interfaces when unset). Examples:
#   :8443              — different port, all interfaces
#   192.168.1.1:9091   — LAN IP only (not WAN)
#   127.0.0.1:9091     — localhost only
# Environment=SSCLASH_ADDR=:9091"
fi
if [ -n "$TLS_CERT" ]; then
	UNIT_EXTRA="${UNIT_EXTRA}
Environment=SSCLASH_TLS_CERT=${TLS_CERT}
Environment=SSCLASH_TLS_KEY=${TLS_KEY}"
	info "HTTPS enabled: ${TLS_CERT}"
else
	UNIT_EXTRA="${UNIT_EXTRA}
# HTTPS web UI — uncomment after placing cert/key under $ROOT/.ssclash/:
# Environment=SSCLASH_TLS_CERT=$ROOT/.ssclash/tls.crt
# Environment=SSCLASH_TLS_KEY=$ROOT/.ssclash/tls.key"
fi

cat > "$UNIT" <<EOF
[Unit]
Description=SSClash-Go proxy manager (Mihomo)
Documentation=https://github.com/zerolabnet/SSClash-Go
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$DEST serve
Environment=SSCLASH_ROOT=$ROOT${UNIT_EXTRA}
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576
ExecStopPost=-$DEST fw stop

[Install]
WantedBy=multi-user.target
EOF

info "Starting ssclash service"
systemctl daemon-reload
systemctl enable ssclash.service >/dev/null 2>&1 || true
systemctl restart ssclash.service

LAN_IP="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)"
[ -n "$LAN_IP" ] || LAN_IP="<lan-ip>"
UI_HOST=$(ui_effective_host "$LAN_IP")
UI_P=$(ui_effective_port)
SCHEME=$(ui_scheme)

cat <<EOF

==========================================================================
 SSClash-Go installed ($MODE mode) — everything under $ROOT.

 1. Open the web UI:   ${SCHEME}://${UI_HOST}:${UI_P}
    (set the admin password on first visit)
EOF
if [ "$MIHOMO_INSTALLED" = "1" ]; then
	cat <<EOF
 2. Settings -> edit config.yaml, then Start.
EOF
else
	cat <<EOF
 2. Settings -> download the Mihomo kernel, edit config.yaml, then Start.
EOF
fi
if [ "$MODE" = "gateway" ]; then
	cat <<EOF

 Gateway: transparent proxy for LAN clients. Enable "NAT masquerade on WAN"
 in Settings if this host is their default gateway. IP forwarding and kernel
 modules are applied when you Start the proxy (nothing written to /etc).

 Point clients' gateway AND DNS at this host ($LAN_IP), or hand that out via
 your own DHCP server — SSClash does not configure DHCP/DNS.
EOF
else
	cat <<EOF

 Server: Mihomo runs as a proxy server (no firewall/routing/DNS from SSClash).
 Define inbound listeners: in Configuration and open those ports in your host
 firewall.
EOF
fi
cat <<EOF

 Security: the UI listens on :9091 on all interfaces by default. Bind
 it to the admin network only with SSCLASH_ADDR in $UNIT if needed.

 Re-run installer with --port / --bind / --tls-self-signed to set listen
 address and HTTPS at install time, or edit $UNIT manually.
==========================================================================
EOF
