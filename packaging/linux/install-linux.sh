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
#                          server  = Mihomo only. First start seeds config.yaml
#                                    with an inbound listeners: example when
#                                    that file is still missing.
#   --from <path>   Install this local binary instead of downloading.
#   --no-mihomo     Skip Mihomo kernel download (install later from Settings).
#   --update        Update the ssclash binary and Mihomo only. Keeps the
#                   existing mode, listen address, TLS and service file.
#   Mihomo is installed only when the release is newer than the kernel on disk.
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
UPDATE=0
MIHOMO_INSTALLED=0
MIHOMO_STATUS="skipped"
UI_BIND=""
UI_ADDR=""
TLS_CERT=""
TLS_KEY=""
TLS_SELF_SIGNED=0

err() { echo "ERROR: $*" >&2; exit 1; }
info() { echo ">> $*"; }
warn() { echo "WARNING: $*" >&2; }

# Fail when Mihomo was expected but no runnable kernel exists. --no-mihomo is OK;
# upgrade keeps exit 0 if an existing kernel at $CLASH_BIN still runs.
assert_mihomo_ready() {
	case "$MIHOMO_STATUS" in
	installed*|skipped*|kept*) return 0 ;;
	esac
	if [ -x "$CLASH_BIN" ] && "$CLASH_BIN" -v >/dev/null 2>&1; then
		warn "Mihomo update failed ($MIHOMO_STATUS) — keeping existing kernel at $CLASH_BIN"
		MIHOMO_STATUS="kept existing ($MIHOMO_STATUS)"
		return 0
	fi
	err "Mihomo kernel install failed ($MIHOMO_STATUS). Fix network/GitHub access and re-run, pass --no-mihomo to skip, or install the kernel from Settings → Mihomo kernel after SSClash is up."
}

# mihomo_installed_version prints vX.Y.Z from the kernel already on disk.
mihomo_installed_version() {
	[ -x "$CLASH_BIN" ] || return 0
	"$CLASH_BIN" -v 2>/dev/null | sed -n 's/.*\(v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -n 1
}

# version_gt is true when $1 is a strictly newer vX.Y.Z than $2.
version_gt() {
	_a=$(printf '%s\n' "$1" | sed 's/^v//')
	_b=$(printf '%s\n' "$2" | sed 's/^v//')
	case "$_a" in *.*.*) ;; *) return 1 ;; esac
	case "$_b" in *.*.*) ;; *) return 1 ;; esac
	_am=${_a%%.*}; _a=${_a#*.}; _ai=${_a%%.*}; _ap=${_a#*.}
	_bm=${_b%%.*}; _b=${_b#*.}; _bi=${_b%%.*}; _bp=${_b#*.}
	_ap=${_ap%%[!0-9]*}; _bp=${_bp%%[!0-9]*}
	if [ "$_am" -gt "$_bm" ]; then return 0; fi
	if [ "$_am" -lt "$_bm" ]; then return 1; fi
	if [ "$_ai" -gt "$_bi" ]; then return 0; fi
	if [ "$_ai" -lt "$_bi" ]; then return 1; fi
	[ "$_ap" -gt "$_bp" ]
}

install_file() {
	_src="$1"
	_dst="$2"
	_mode="${3:-755}"
	mkdir -p "$(dirname "$_dst")"
	cp -f "$_src" "$_dst"
	chmod "$_mode" "$_dst"
}

verify_downloaded_bin() {
	_f="$1"
	_label="${2:-binary}"
	[ -s "$_f" ] || { warn "$_label is empty"; return 1; }
	_sz=$(wc -c < "$_f" | tr -d ' ')
	if [ "${_sz:-0}" -lt 1000000 ]; then
		warn "$_label looks too small (${_sz} bytes) — not a release binary"
		return 1
	fi
	if head -c 256 "$_f" | grep -qiE '<!DOCTYPE|<html|Not Found|rate limit|Error'; then
		warn "$_label looks like an HTML/error page, not a binary"
		return 1
	fi
	# ELF magic 0x7f 'E' 'L' 'F' (Entware/BusyBox od has no -A; parse first line if needed)
	_elf=$(printf '\177ELF')
	_hdr=$(head -c 4 "$_f" 2>/dev/null || true)
	if [ "$_hdr" = "$_elf" ]; then
		return 0
	fi
	_hex=$(od -tx1 -N4 "$_f" 2>/dev/null | head -1 | sed 's/^[0-9a-f]* *//' | tr -d ' \n')
	case "$_hex" in
		7f454c46) return 0 ;;
	esac
	warn "$_label is not an ELF binary"
	return 1
}

stop_bin_path() {
	_bin="$1"
	[ -n "$_bin" ] || return 0
	if command -v fuser >/dev/null 2>&1; then
		fuser -k "$_bin" >/dev/null 2>&1 || true
	fi
	for _p in /proc/[0-9]*; do
		[ -L "$_p/exe" ] || continue
		_exe=$(readlink "$_p/exe" 2>/dev/null || true)
		case "$_exe" in
			"$_bin"|"$_bin"*) kill -TERM "${_p#/proc/}" 2>/dev/null || true ;;
		esac
	done
}

# fs_avail_kb prints free 1K-blocks for the filesystem holding path.
# The field before Use% works for both single-line and wrapped df output.
fs_avail_kb() {
	_line=$(df -k "$1" 2>/dev/null | tail -n 1)
	printf '%s\n' "$_line" | awk '{
		for (i = 1; i <= NF; i++) if ($i ~ /%$/) { print $(i-1); exit }
	}'
}

# path_noexec is true when the mount holding path has the noexec option.
path_noexec() {
	_dir="$1"
	[ -d "$_dir" ] || _dir=$(dirname "$_dir")
	_line=$(df "$_dir" 2>/dev/null | tail -n 1)
	_mp=$(printf '%s\n' "$_line" | awk '{print $NF}')
	[ -n "$_mp" ] || return 1
	_opts=$(awk -v mp="$_mp" '$2 == mp { print $4; exit }' /proc/mounts 2>/dev/null || true)
	case ",${_opts}," in
		*,noexec,*) return 0 ;;
	esac
	return 1
}

# install_checked_bin copies src onto dst.
# When the destination filesystem has room for the new file plus 1 MiB, the
# new file is staged beside the old one and swapped with mv. Otherwise the
# old file is removed first so a small overlay does not hold two copies.
# A failed copy deletes the partial file and never leaves .mihomo-new.* /
# .ssclash-install.*. The 5th argument "1" runs "<file> -v" before replacing
# a working binary. A failure in the download directory is retried beside the
# install: that is the directory the binary will run from.
install_checked_bin() {
	_src="$1"
	_dst="$2"
	_mode="${3:-755}"
	_label="${4:-binary}"
	_verify="${5:-0}"
	_dir=$(dirname "$_dst")
	mkdir -p "$_dir" || return 1
	rm -f "$_dir"/.mihomo-new.* "$_dir"/.ssclash-install.*

	_bytes=$(wc -c < "$_src" | tr -d ' ')
	_need=$((_bytes + 1048576))
	_free_kb=$(fs_avail_kb "$_dir")
	_free=$((${_free_kb:-0} * 1024))
	_old=0
	if [ -f "$_dst" ]; then
		_old=$(wc -c < "$_dst" | tr -d ' ')
	fi

	_verified=0
	_src_rejected=0
	if [ "$_verify" = "1" ] && ! path_noexec "$_src"; then
		chmod +x "$_src" 2>/dev/null || true
		if "$_src" -v >/dev/null 2>&1; then
			_verified=1
		else
			# /tmp is often noexec, or the host blocks new binaries there.
			# The copy beside the install is the check that matters.
			_src_rejected=1
		fi
	fi

	if [ "$_free" -ge "$_need" ]; then
		case "$_label" in
			Mihomo) _stage="$_dir/.mihomo-new.$$" ;;
			*) _stage="$_dir/.ssclash-install.$$" ;;
		esac
		rm -f "$_stage"
		if ! cp -f "$_src" "$_stage"; then
			rm -f "$_stage"
			warn "failed to stage $_label (not enough free space)"
			return 1
		fi
		if ! chmod "$_mode" "$_stage"; then
			rm -f "$_stage"
			return 1
		fi
		if [ "$_verify" = "1" ] && [ "$_verified" != "1" ]; then
			if ! "$_stage" -v >/dev/null 2>&1; then
				rm -f "$_stage"
				warn "$_label does not run on this host — keeping existing binary"
				return 1
			fi
		fi
		stop_ssclash_for_upgrade
		stop_bin_path "$_dst"
		if ! mv -f "$_stage" "$_dst"; then
			rm -f "$_stage"
			return 1
		fi
		chmod "$_mode" "$_dst"
		return 0
	fi

	if [ "$_src_rejected" = "1" ]; then
		warn "$_label could not be checked from the download directory, and there is not enough space to check it beside the install — keeping existing binary"
		return 1
	fi

	if [ $((_free + _old)) -ge "$_need" ]; then
		warn "low space: replacing $_label in place (no second copy on flash)"
		stop_ssclash_for_upgrade
		stop_bin_path "$_dst"
		rm -f "$_dst"
		if ! cp -f "$_src" "$_dst"; then
			rm -f "$_dst"
			warn "$_label replace failed — binary missing until reinstall"
			return 1
		fi
		if ! chmod "$_mode" "$_dst"; then
			rm -f "$_dst"
			return 1
		fi
		if [ "$_verify" = "1" ] && [ "$_verified" != "1" ]; then
			if ! "$_dst" -v >/dev/null 2>&1; then
				rm -f "$_dst"
				warn "$_label does not run — removed the failed install"
				return 1
			fi
		fi
		return 0
	fi

	_need_mib=$(((_need + 1048575) / 1048576))
	_free_mib=$((_free / 1048576))
	warn "not enough free space for $_label (need about ${_need_mib} MiB, free ${_free_mib} MiB) — keeping existing binary"
	return 1
}

install_bin() {
	_src="$1"
	_dst="$2"
	_mode="${3:-755}"
	_label="${4:-binary}"
	verify_downloaded_bin "$_src" "$_label" || return 1
	install_checked_bin "$_src" "$_dst" "$_mode" "$_label" 0
}

stop_ssclash_for_upgrade() {
	_running=0
	if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet ssclash.service 2>/dev/null; then
		_running=1
	fi
	pidof ssclash >/dev/null 2>&1 && _running=1
	pidof clash >/dev/null 2>&1 && _running=1
	for _p in /proc/[0-9]*; do
		[ -L "$_p/exe" ] || continue
		_exe=$(readlink "$_p/exe" 2>/dev/null || true)
		case "$_exe" in
			"$DEST"|"$DEST"*|"$CLASH_BIN"|"$CLASH_BIN"*) _running=1; break ;;
		esac
	done
	[ "$_running" = "1" ] || return 0

	info "Stopping ssclash for safe upgrade / GitHub downloads..."
	if command -v systemctl >/dev/null 2>&1; then
		systemctl stop ssclash.service 2>/dev/null || true
	fi
	_i=0
	while pidof ssclash >/dev/null 2>&1 && [ "$_i" -lt 20 ]; do
		sleep 1
		_i=$((_i + 1))
	done
	stop_bin_path "$DEST"
	stop_bin_path "$CLASH_BIN"
	if pidof clash >/dev/null 2>&1; then
		warn "stopping leftover Mihomo process..."
		kill $(pidof clash) 2>/dev/null || true
		sleep 1
		kill -9 $(pidof clash) 2>/dev/null || true
	fi
}

github_get_once() {
	_url="$1"
	_out="${2:-}"
	_max="${GITHUB_GET_MAX_TIME:-${GITHUB_CURL_MAX_TIME:-120}}"
	if command -v curl >/dev/null 2>&1; then
		if [ -n "$_out" ]; then
			curl -fsSL --retry 2 --connect-timeout 15 --max-time "$_max" -o "$_out" "$_url" 2>/dev/null \
				&& [ -s "$_out" ] && return 0
		else
			curl -fsSL --retry 2 --connect-timeout 15 --max-time "$_max" "$_url" 2>/dev/null \
				&& return 0
		fi
	fi
	if command -v wget >/dev/null 2>&1; then
		if [ -n "$_out" ]; then
			wget -T "$_max" -t 3 -qO "$_out" "$_url" 2>/dev/null \
				&& [ -s "$_out" ] && return 0
		else
			wget -T "$_max" -t 3 -qO- "$_url" 2>/dev/null \
				&& return 0
		fi
	fi
	return 1
}

github_fail_hint() {
	warn "Could not reach GitHub (DNS/network)."
	warn "Downloads run while SSClash is still up — if it routes your traffic, do not stop it manually first."
	warn "Check: getent hosts api.github.com  or  curl -fsSL https://api.github.com/zen"
}

github_get() {
	_url="$1"
	_out="${2:-}"
	if github_get_once "$_url" "$_out"; then
		return 0
	fi
	if pidof ssclash >/dev/null 2>&1 || pidof clash >/dev/null 2>&1 \
		|| { command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet ssclash.service 2>/dev/null; }; then
		warn "GitHub request failed — stopping ssclash and retrying once..."
		stop_ssclash_for_upgrade
	else
		warn "GitHub request failed — retrying once..."
	fi
	if github_get_once "$_url" "$_out"; then
		return 0
	fi
	github_fail_hint
	return 1
}

ensure_fetcher() {
	if command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1; then
		return 0
	fi
	err "curl or wget is required to download (or use --from)"
}

while [ $# -gt 0 ]; do
	case "$1" in
		--mode) MODE="${2:-}"; shift 2 ;;
		--mode=*) MODE="${1#*=}"; shift ;;
		--from) FROM="${2:-}"; shift 2 ;;
		--from=*) FROM="${1#*=}"; shift ;;
		--no-mihomo) SKIP_MIHOMO=1; shift ;;
		--update) UPDATE=1; shift ;;
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
			sed -n '2,35p' "$0" | sed 's/^# \{0,1\}//'
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

# pick_lan_ipv4 prefers RFC1918 from global addresses (avoids public WAN in hints).
pick_lan_ipv4() {
	_first=""
	for _ip in $(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1); do
		[ -z "$_ip" ] && continue
		[ -z "$_first" ] && _first="$_ip"
		case "$_ip" in
			10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*)
				echo "$_ip"
				return 0
				;;
		esac
	done
	[ -n "$_first" ] && echo "$_first"
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
if [ "$UPDATE" = 1 ]; then
	if [ -n "$MODE$UI_BIND$UI_ADDR$TLS_CERT$TLS_KEY" ] || [ "$TLS_SELF_SIGNED" = 1 ] || [ "$UI_PORT" != "9091" ]; then
		err "--update keeps mode, address and TLS; do not pass --mode, --port, --bind, --addr or --tls-*"
	fi
	[ -x "$DEST" ] || err "--update: $DEST is missing; run a normal install"
	[ -f "$UNIT" ] || err "--update: $UNIT is missing; run a normal install"
else
	finalize_ui_addr
	prepare_tls_certs
fi

[ "$(id -u)" = "0" ] || err "Run as root (sudo)."
command -v systemctl >/dev/null 2>&1 || err "systemd (systemctl) is required."

# Captured before any download: a failed GitHub request stops the service.
WAS_ACTIVE=0
if [ "$UPDATE" = 1 ] && systemctl is-active --quiet ssclash.service 2>/dev/null; then
	WAS_ACTIVE=1
fi

# ---- Install mode -----------------------------------------------------------
if [ "$UPDATE" = 1 ]; then
	MODE=$(sed -n 's/^OPERATING_MODE=//p' "$SETTINGS" 2>/dev/null | head -n 1)
	[ -n "$MODE" ] || MODE="gateway"
	info "Update: keeping install settings (mode: $MODE)"
else
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
fi

# Gateway uses conntrack to drop stale DNS/DoT sessions and ipset for DoH and port filters.
if [ "$UPDATE" != 1 ] && [ "$MODE" = "gateway" ]; then
	_missing=""
	command -v conntrack >/dev/null 2>&1 || _missing="conntrack"
	command -v ipset >/dev/null 2>&1 || _missing="${_missing:+$_missing }ipset"
	if [ -n "$_missing" ]; then
		if command -v apt-get >/dev/null 2>&1; then
			info "installing $_missing"
			DEBIAN_FRONTEND=noninteractive apt-get update -qq \
				|| warn "apt-get update failed — trying install anyway"
			DEBIAN_FRONTEND=noninteractive apt-get install -y $_missing \
				|| warn "apt-get install $_missing failed"
		else
			warn "install $_missing (apt install conntrack ipset) for DNS session flush and ipset rules"
		fi
	fi
fi

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
		MIHOMO_STATUS="skipped (--no-mihomo)"
		return 0
	fi
	if [ -z "$MIHOMO_ARCH" ]; then
		warn "Mihomo architecture unknown — install from Settings later"
		MIHOMO_STATUS="missing (unknown arch)"
		return 0
	fi
	command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || {
		warn "curl/wget not found — install Mihomo from Settings later"
		MIHOMO_STATUS="missing (no curl/wget)"
		return 0
	}
	command -v gunzip >/dev/null 2>&1 || command -v gzip >/dev/null 2>&1 || {
		warn "gunzip/gzip not found — install Mihomo from Settings later"
		MIHOMO_STATUS="missing (no gunzip)"
		return 0
	}

	info "Fetching latest Mihomo release..."
	MIHOMO_JSON=$(github_get "$MIHOMO_API") || {
		warn "Mihomo GitHub API request failed — install from Settings later"
		MIHOMO_STATUS="missing (API failed)"
		return 0
	}
	MIHOMO_VER=$(printf '%s' "$MIHOMO_JSON" \
		| grep '"tag_name"' | head -1 \
		| sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
	if [ -z "$MIHOMO_VER" ]; then
		warn "could not parse Mihomo version — install from Settings later"
		MIHOMO_STATUS="missing (parse failed)"
		return 0
	fi
	info "Mihomo: ${MIHOMO_VER}"
	_have="$(mihomo_installed_version)"
	if [ -n "$_have" ]; then
		if version_gt "$MIHOMO_VER" "$_have"; then
			info "Mihomo ${_have} is older than ${MIHOMO_VER} — updating"
		else
			info "Mihomo ${_have} is already current (release ${MIHOMO_VER}) — keeping it"
			MIHOMO_STATUS="kept (${_have})"
			return 0
		fi
	fi

	MIHOMO_URL=$(mihomo_asset_url "$MIHOMO_VER" "$MIHOMO_ARCH") || {
		warn "Mihomo asset for ${MIHOMO_ARCH} not found — install from Settings later"
		MIHOMO_STATUS="missing (no asset for ${MIHOMO_ARCH})"
		return 0
	}

	_tmp_gz="$(mktemp)"
	_tmp_bin="$(mktemp)"
	info "Downloading Mihomo kernel..."
	if ! GITHUB_GET_MAX_TIME=300 github_get "$MIHOMO_URL" "$_tmp_gz"; then
		warn "Mihomo download failed — install from Settings later"
		rm -f "$_tmp_gz" "$_tmp_bin"
		MIHOMO_STATUS="missing (download failed)"
		return 0
	fi

	if command -v gunzip >/dev/null 2>&1; then
		_gunzip='gunzip -c'
	else
		_gunzip='gzip -dc'
	fi
	if ! $_gunzip "$_tmp_gz" > "$_tmp_bin"; then
		warn "Mihomo extraction failed — keeping existing kernel; install from Settings later"
		rm -f "$_tmp_gz" "$_tmp_bin"
		MIHOMO_STATUS="missing (extract failed)"
		return 0
	fi
	rm -f "$_tmp_gz"
	if ! verify_downloaded_bin "$_tmp_bin" "Mihomo"; then
		rm -f "$_tmp_bin"
		MIHOMO_STATUS="missing (bad/wrong-arch binary)"
		return 0
	fi
	# -v runs from /tmp when that mount is executable. A second copy is written
	# beside the old kernel only when the destination filesystem has room for it.
	if ! install_checked_bin "$_tmp_bin" "$CLASH_BIN" 755 "Mihomo" 1; then
		rm -f "$_tmp_bin"
		MIHOMO_STATUS="missing (install failed)"
		return 0
	fi
	rm -f "$_tmp_bin"
	rm -f /opt/clash/bin/meta-backup 2>/dev/null || true

	MIHOMO_V=$("$CLASH_BIN" -v 2>/dev/null || true)
	info "Mihomo installed: ${MIHOMO_V:-ok}"
	MIHOMO_INSTALLED=1
	MIHOMO_STATUS="installed (${MIHOMO_V:-$MIHOMO_VER})"
}

TMP_BIN=""
cleanup() { [ -n "$TMP_BIN" ] && rm -f "$TMP_BIN"; }
trap cleanup EXIT INT TERM

if [ -n "$FROM" ]; then
	[ -f "$FROM" ] || err "Binary not found: $FROM"
	BIN_SRC="$FROM"
	info "Using local binary: $BIN_SRC"
else
	ensure_fetcher
	ARCH="$(map_arch "$(uname -m)")"
	[ -n "$ARCH" ] || err "Unsupported architecture: $(uname -m). Build locally and use --from."

	if [ "$VERSION" = "latest" ]; then
		info "Resolving latest release tag for $REPO"
		VERSION="$(github_get "https://api.github.com/repos/$REPO/releases/latest" \
			| sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n1)"
		[ -n "$VERSION" ] || err "Could not determine latest release tag."
	fi

	ASSET="ssclash-linux-$ARCH"
	URL="https://github.com/$REPO/releases/download/$VERSION/$ASSET"
	TMP_BIN="$(mktemp)"
	info "Downloading $ASSET ($VERSION)"
	GITHUB_GET_MAX_TIME=300 github_get "$URL" "$TMP_BIN" \
		|| err "Download failed: $URL"
	BIN_SRC="$TMP_BIN"
fi

info "Creating working directory $ROOT"
mkdir -p "$ROOT/bin" "$ROOT/.ssclash" "$ROOT/local-rules" "$ROOT/rule-providers" "$ROOT/proxy-providers" "$ROOT/subscriptions" "$ROOT/ui"

info "Installing binary -> $DEST"
install_bin "$BIN_SRC" "$DEST" 755 "ssclash" || err "ssclash install failed (bad download?)"

install_mihomo
assert_mihomo_ready

if [ "$UPDATE" = 1 ]; then
	info "Keeping systemd unit $UNIT"
	_kept_addr=$(sed -n 's/^Environment=SSCLASH_ADDR=//p' "$UNIT" | head -n 1)
	_kept_cert=$(sed -n 's/^Environment=SSCLASH_TLS_CERT=//p' "$UNIT" | head -n 1)
	[ -n "$_kept_addr" ] && UI_ADDR="$_kept_addr"
	[ -n "$_kept_cert" ] && TLS_CERT="$_kept_cert"
	if [ "$WAS_ACTIVE" = 1 ]; then
		systemctl start ssclash.service
	else
		info "ssclash.service was not running — binary updated, service left stopped"
	fi
else
	info "Recording operating mode in $SETTINGS"
	if [ -f "$SETTINGS" ] && grep -q '^OPERATING_MODE=' "$SETTINGS" 2>/dev/null; then
		# Keep existing OPERATING_MODE on upgrade unless this install explicitly chose one
		# via interactive prompt / --mode (MODE is always set before this point).
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
fi

LAN_IP="$(pick_lan_ipv4)"
[ -n "$LAN_IP" ] || LAN_IP="<lan-ip>"
UI_HOST=$(ui_effective_host "$LAN_IP")
UI_P=$(ui_effective_port)
SCHEME=$(ui_scheme)
if [ "$UPDATE" = 1 ]; then
	_done="updated"
else
	_done="installed"
fi

cat <<EOF

==========================================================================
 SSClash-Go $_done ($MODE mode) — everything under $ROOT.

 Summary:
   ssclash:  $DEST (${VERSION:-installed})
   Mihomo:   ${MIHOMO_STATUS}

 1. Open the web UI:   ${SCHEME}://${UI_HOST}:${UI_P}
    (set the admin password on first visit)
EOF
case "$MIHOMO_STATUS" in
	installed*|kept*)
		cat <<EOF
 2. Settings -> edit config.yaml, then Start.
EOF
		;;
	skipped*)
		cat <<EOF
 2. Settings -> download the Mihomo kernel, edit config.yaml, then Start.
EOF
		;;
esac
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
 A fresh install seeds config.yaml with an inbound listeners: example; an
 existing file is kept. Replace the marked placeholders and open those ports
 in the host firewall.
EOF
fi
cat <<EOF

 Security: the UI listens on :9091 on all interfaces by default. Bind
 it to the admin network only with SSCLASH_ADDR in $UNIT if needed.

 Re-run installer with --port / --bind / --tls-self-signed to set listen
 address and HTTPS at install time, or edit $UNIT manually.
==========================================================================
EOF
