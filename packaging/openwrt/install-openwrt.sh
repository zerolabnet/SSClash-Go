#!/bin/sh
# SSClash-Go installer for OpenWrt (procd).
#
# Prefer the bootstrap one-liner:
#   wget -qO- https://github.com/zerolabnet/SSClash-Go/raw/refs/heads/main/install-ssclash-go.sh | ash
#
# Or save this script first (wget -q | sh is silent until download finishes):
#   wget -O /tmp/install-openwrt.sh \
#     https://github.com/zerolabnet/SSClash-Go/raw/refs/heads/main/packaging/openwrt/install-openwrt.sh
#   sh /tmp/install-openwrt.sh
#
# Options:
#   --port <n>           Web UI port (default 9091; all interfaces)
#   --bind <ip>          Bind web UI to this IP (with --port, default 9091)
#   --addr <host:port>   Full SSCLASH_ADDR (overrides --port / --bind)
#   --tls-cert <path>    TLS certificate (PEM); requires --tls-key
#   --tls-key <path>     TLS private key (PEM); requires --tls-cert
#   --tls-self-signed    Generate $ROOT/.ssclash/tls.{crt,key} (needs openssl)
#   --no-mihomo          Skip Mihomo kernel download (install later from Settings).
#   --keep-running       Do not stop ssclash on GitHub retry (upgrade without downtime).
#   -h, --help           Show this help
set -e

echo "[ssclash] installer loaded" >&2

REPO="zerolabnet/SSClash-Go"
SSCLASH_API="https://api.github.com/repos/${REPO}/releases/latest"
MIHOMO_API="https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"

ROOT=/opt/clash
SSCLASH_BIN="$ROOT/bin/ssclash"
CLASH_BIN="$ROOT/bin/clash"

PKG_UPDATED=0
PKG_MGR=""
TPROXY_PKG=""
SSCLASH_TAG=""
SSCLASH_BIN_URL=""
SSCLASH_SVC_URL=""
SSCLASH_ASSET=""
MIHOMO_ARCH=""

UI_PORT=9091
UI_BIND=""
UI_ADDR=""
TLS_CERT=""
TLS_KEY=""
TLS_SELF_SIGNED=0
SKIP_MIHOMO=0
KEEP_RUNNING=0

say()  { echo "[ssclash] $*"; }
info() { echo "[ssclash]   $*"; }
warn() { echo "[ssclash] ! $*"; }
die()  { echo "[ssclash] ERROR: $*" >&2; exit 1; }

# Copy a file into place with mode (BusyBox/OpenWrt has no coreutils install(1)).
install_file() {
	_src="$1"
	_dst="$2"
	_mode="${3:-755}"
	mkdir -p "$(dirname "$_dst")"
	cp -f "$_src" "$_dst"
	chmod "$_mode" "$_dst"
}

# GitHub/raw downloads: bypass proxy env; retry once after stopping ssclash on failure.
github_curl() {
	if curl -fsSL --retry 2 --connect-timeout 15 --max-time 120 \
		"$@"; then
		return 0
	fi
	if [ "$KEEP_RUNNING" = "1" ] || [ "${SSCLASH_INSTALL_KEEP_RUNNING:-0}" = "1" ]; then
		return 1
	fi
	if pidof ssclash >/dev/null 2>&1; then
		warn "GitHub request failed — stopping ssclash and retrying once..."
		/etc/init.d/ssclash stop || true
		curl -fsSL --retry 2 --connect-timeout 15 --max-time 120 \
			"$@"
		return $?
	fi
	return 1
}

parse_install_options() {
	while [ $# -gt 0 ]; do
		case "$1" in
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
			--no-mihomo) SKIP_MIHOMO=1; shift ;;
			--keep-running) KEEP_RUNNING=1; shift ;;
			-h|--help)
				sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'
				exit 0 ;;
			*) die "Unknown option: $1 (try --help)" ;;
		esac
	done
}

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
			*:*:*) echo "${UI_ADDR##*:}" ;;
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

openwrt_lan_ip() {
	_ip=$(uci -q get network.lan.ipaddr 2>/dev/null || true)
	if [ -z "$_ip" ]; then
		echo "<router-ip>"
		return
	fi
	echo "${_ip%%/*}"
}

configure_openwrt_init() {
	_f="/etc/init.d/ssclash"
	[ -f "$_f" ] || return 0
	if [ -n "$UI_ADDR" ]; then
		sed -i "s|^[[:space:]]*# procd_set_param env SSCLASH_ADDR=.*|	procd_set_param env SSCLASH_ADDR=\"${UI_ADDR}\"|" "$_f"
		info "web UI listen: ${UI_ADDR}"
	fi
	if [ -n "$TLS_CERT" ]; then
		sed -i "s|^[[:space:]]*# procd_set_param env SSCLASH_TLS_CERT=.*|	procd_set_param env SSCLASH_TLS_CERT=\"${TLS_CERT}\"|" "$_f"
		sed -i "s|^[[:space:]]*# procd_set_param env SSCLASH_TLS_KEY=.*|	procd_set_param env SSCLASH_TLS_KEY=\"${TLS_KEY}\"|" "$_f"
		info "HTTPS enabled: ${TLS_CERT}"
	fi
}

# ---- 0. curl (needed for GitHub API + downloads) ----------------------------
ensure_curl() {
	if command -v curl >/dev/null 2>&1; then
		return 0
	fi
	warn "curl not found — installing..."
	if [ "$PKG_MGR" = "apk" ]; then
		apk update || die "apk update failed"
		apk add curl || die "failed to install curl"
	else
		opkg update || die "opkg update failed"
		opkg install curl || die "failed to install curl"
	fi
	command -v curl >/dev/null 2>&1 || die "curl still unavailable after install"
	PKG_UPDATED=1
	say "curl installed"
}

# ---- 1. OpenWrt version + package manager -----------------------------------
detect_openwrt() {
	[ -f /etc/openwrt_release ] || die "not OpenWrt (/etc/openwrt_release missing)"
	. /etc/openwrt_release

	OW_RELEASE="${DISTRIB_RELEASE:-unknown}"
	OW_MAJOR=$(echo "$OW_RELEASE" | cut -d. -f1)
	info "OpenWrt ${OW_RELEASE}"

	if command -v apk >/dev/null 2>&1; then
		PKG_MGR="apk"
	elif command -v opkg >/dev/null 2>&1; then
		PKG_MGR="opkg"
	else
		die "no supported package manager (apk/opkg)"
	fi
	info "package manager: ${PKG_MGR}"

	if [ "${OW_MAJOR:-0}" -le 21 ] 2>/dev/null; then
		TPROXY_PKG="iptables-mod-tproxy"
	else
		TPROXY_PKG="kmod-nft-tproxy"
	fi
	info "tproxy package: ${TPROXY_PKG}"
}

# ---- 2. Architecture → ssclash binary + mihomo kernel asset names ----------
detect_arch() {
	ARCH_RAW=$(uname -m)
	. /etc/openwrt_release
	ARCH_PKG="${DISTRIB_ARCH:-}"

	info "CPU: ${ARCH_RAW}, DISTRIB_ARCH: ${ARCH_PKG:-unknown}"

	SSCLASH_ASSET=""
	MIHOMO_ARCH=""

	case "$ARCH_PKG" in
		aarch64_*)      SSCLASH_ASSET="arm64"; MIHOMO_ARCH="arm64" ;;
		x86_64)         SSCLASH_ASSET="amd64"; MIHOMO_ARCH="amd64-compatible" ;;
		i386_*)         SSCLASH_ASSET="386";   MIHOMO_ARCH="386" ;;
		riscv64_*)      SSCLASH_ASSET="riscv64"; MIHOMO_ARCH="riscv64" ;;
		loongarch64_*)  SSCLASH_ASSET="loong64"; MIHOMO_ARCH="loong64" ;;
		powerpc64le_*)  SSCLASH_ASSET="ppc64le"; MIHOMO_ARCH="ppc64le" ;;
		s390x)          SSCLASH_ASSET="s390x";   MIHOMO_ARCH="s390x" ;;
		arm_*)
			case "$ARCH_PKG" in
				*cortex-a*)     SSCLASH_ASSET="armv7"; MIHOMO_ARCH="armv7" ;;
				*_neon-vfp*)    SSCLASH_ASSET="armv7"; MIHOMO_ARCH="armv7" ;;
				*_neon*|*_vfp*) SSCLASH_ASSET="armv6"; MIHOMO_ARCH="armv6" ;;
				*)              SSCLASH_ASSET="armv5"; MIHOMO_ARCH="armv5" ;;
			esac
			;;
		mips64el_*)     SSCLASH_ASSET="mips64le"; MIHOMO_ARCH="mips64le" ;;
		mips64_*)       SSCLASH_ASSET="mips64";   MIHOMO_ARCH="mips64" ;;
		mipsel_*)
			case "$ARCH_PKG" in
				*hardfloat*) SSCLASH_ASSET="mipsle-hardfloat"; MIHOMO_ARCH="mipsle-hardfloat" ;;
				*)           SSCLASH_ASSET="mipsle-softfloat"; MIHOMO_ARCH="mipsle-softfloat" ;;
			esac
			;;
		mips_*)
			case "$ARCH_PKG" in
				*hardfloat*) SSCLASH_ASSET="mips-hardfloat"; MIHOMO_ARCH="mips-hardfloat" ;;
				*)           SSCLASH_ASSET="mips-softfloat"; MIHOMO_ARCH="mips-softfloat" ;;
			esac
			;;
	esac

	if [ -z "$SSCLASH_ASSET" ]; then
		warn "DISTRIB_ARCH '${ARCH_PKG}' not recognised — trying uname -m"
		case "$ARCH_RAW" in
			aarch64)         SSCLASH_ASSET="arm64"; MIHOMO_ARCH="arm64" ;;
			armv7l)          SSCLASH_ASSET="armv7"; MIHOMO_ARCH="armv7" ;;
			armv6l)          SSCLASH_ASSET="armv6"; MIHOMO_ARCH="armv6" ;;
			armv5l|armv5tel) SSCLASH_ASSET="armv5"; MIHOMO_ARCH="armv5" ;;
			x86_64)          SSCLASH_ASSET="amd64"; MIHOMO_ARCH="amd64-compatible" ;;
			i686|i386)       SSCLASH_ASSET="386";   MIHOMO_ARCH="386" ;;
			riscv64)         SSCLASH_ASSET="riscv64"; MIHOMO_ARCH="riscv64" ;;
			loongarch64)     SSCLASH_ASSET="loong64"; MIHOMO_ARCH="loong64" ;;
			ppc64le|powerpc64le) SSCLASH_ASSET="ppc64le"; MIHOMO_ARCH="ppc64le" ;;
			s390x)           SSCLASH_ASSET="s390x";   MIHOMO_ARCH="s390x" ;;
			mips64el)        SSCLASH_ASSET="mips64le"; MIHOMO_ARCH="mips64le" ;;
			mips64)          SSCLASH_ASSET="mips64";   MIHOMO_ARCH="mips64" ;;
			mipsel)          SSCLASH_ASSET="mipsle-softfloat"; MIHOMO_ARCH="mipsle-softfloat" ;;
			mips)            SSCLASH_ASSET="mips-softfloat";   MIHOMO_ARCH="mips-softfloat" ;;
		esac
	fi

	[ -n "$SSCLASH_ASSET" ] || die "unsupported architecture: ${ARCH_PKG:-$ARCH_RAW}"
	info "ssclash asset: ssclash-linux-${SSCLASH_ASSET}"
	[ -n "$MIHOMO_ARCH" ] && info "Mihomo kernel: mihomo-linux-${MIHOMO_ARCH}"
}

# ---- 3. Package index -------------------------------------------------------
pkg_update() {
	if [ "$PKG_UPDATED" = "1" ]; then
		return 0
	fi
	say "updating package index..."
	if [ "$PKG_MGR" = "apk" ]; then
		apk update || die "apk update failed"
	else
		opkg update || die "opkg update failed"
	fi
	PKG_UPDATED=1
}

# ---- 4. Dependencies --------------------------------------------------------
install_deps() {
	DEPS="$TPROXY_PKG kmod-tun ca-bundle"
	if [ "$TPROXY_PKG" = "iptables-mod-tproxy" ]; then
		DEPS="$DEPS ipset"
	fi
	say "installing dependencies: $DEPS"
	if [ "$PKG_MGR" = "apk" ]; then
		apk add $DEPS || die "dependency install failed"
	else
		opkg install $DEPS || die "dependency install failed"
	fi
}

# ---- 5. Latest ssclash-go release (GitHub API) ------------------------------
fetch_ssclash_release() {
	say "fetching latest ssclash-go release..."
	RELEASE_JSON=$(github_curl "$SSCLASH_API") || die "GitHub API request failed (try: /etc/init.d/ssclash stop, then re-run)"
	[ -n "$RELEASE_JSON" ] || die "empty GitHub API response"

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
		| grep 'ssclash-openwrt-service.tar.gz"' | head -1 \
		| sed 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
}

# ---- 6. ssclash binary ------------------------------------------------------
install_ssclash() {
	say "downloading ssclash..."
	TMP="$(mktemp)"
	curl -fSL --retry 2 --connect-timeout 15 --max-time 300 \
		"$SSCLASH_BIN_URL" -o "$TMP" || die "ssclash download failed"
	mkdir -p "$ROOT/bin"
	install_file "$TMP" "$SSCLASH_BIN" 755
	rm -f "$TMP"
	say "installed ${SSCLASH_BIN}"
}

# ---- 7. procd service -------------------------------------------------------
install_service() {
	mkdir -p "$ROOT/.ssclash" "$ROOT/local-rules" "$ROOT/rule-providers" "$ROOT/proxy-providers" "$ROOT/subscriptions" "$ROOT/ui"

	SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
	if [ -f "$SCRIPT_DIR/etc/init.d/ssclash" ]; then
		install_file "$SCRIPT_DIR/etc/init.d/ssclash" /etc/init.d/ssclash 755
		return 0
	fi

	if [ -n "$SSCLASH_SVC_URL" ]; then
		say "installing init.d service from release..."
		github_curl "$SSCLASH_SVC_URL" -o /tmp/ssclash-svc.tgz \
			&& tar -xzf /tmp/ssclash-svc.tgz -C / \
			&& rm -f /tmp/ssclash-svc.tgz \
			|| warn "could not install service bundle"
	else
		warn "init.d/ssclash not found locally and no service bundle in release"
	fi
	configure_openwrt_init
}

# Pick a mihomo .gz asset URL from the release JSON (handles loong64 ABI variants).
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

# ---- 8. mihomo kernel (GitHub API) ------------------------------------------
install_mihomo() {
	if [ "$SKIP_MIHOMO" = "1" ]; then
		warn "skipping Mihomo download (--no-mihomo)"
		return 0
	fi
	if [ -z "$MIHOMO_ARCH" ]; then
		warn "Mihomo architecture not determined — install manually from Settings"
		return 0
	fi

	say "fetching latest Mihomo release..."
	MIHOMO_JSON=$(github_curl "$MIHOMO_API") || {
		warn "Mihomo GitHub API request failed — install from Settings later"
		return 0
	}
	[ -n "$MIHOMO_JSON" ] || {
		warn "empty Mihomo API response — install from Settings later"
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
	info "url: ${MIHOMO_URL}"

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
	rm -f /tmp/clash.gz /opt/clash/bin/meta-backup 2>/dev/null || true

	MIHOMO_V=$("$CLASH_BIN" -v 2>/dev/null || true)
	say "Mihomo installed: ${MIHOMO_V:-ok}"
}

# ---- MAIN -------------------------------------------------------------------
parse_install_options "$@"
validate_ui_port
finalize_ui_addr
prepare_tls_certs

[ "$(id -u)" = "0" ] || die "run as root"

say "SSClash-Go installer"
detect_openwrt
ensure_curl
detect_arch
fetch_ssclash_release
pkg_update
install_deps

SSCLASH_WAS_ENABLED=0
if [ -x /etc/init.d/ssclash ] && /etc/init.d/ssclash enabled 2>/dev/null; then
	SSCLASH_WAS_ENABLED=1
	info "service was enabled — will restore after upgrade"
fi

install_ssclash
install_service

if [ "$SSCLASH_WAS_ENABLED" = "1" ]; then
	/etc/init.d/ssclash enable
fi

install_mihomo

/etc/init.d/ssclash enable
if pidof ssclash >/dev/null 2>&1; then
	/etc/init.d/ssclash restart >/dev/null 2>&1 \
		|| warn "service restart failed — run: /etc/init.d/ssclash start"
else
	/etc/init.d/ssclash start >/dev/null 2>&1 \
		|| warn "service start skipped — open the web UI and press Start"
fi

IP=$(openwrt_lan_ip)
UI_HOST=$(ui_effective_host "$IP")
UI_P=$(ui_effective_port)
SCHEME=$(ui_scheme)
cat <<EOF

 HTTPS (optional): use --tls-self-signed or --tls-cert/--tls-key on install.
   Change port/bind later: uncomment SSCLASH_ADDR in /etc/init.d/ssclash.

EOF
say "done. Open ${SCHEME}://${UI_HOST}:${UI_P}, set the admin password, then Start."
