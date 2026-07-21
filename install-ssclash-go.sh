#!/bin/sh
# SSClash-Go bootstrap installer — detects platform and runs the matching script.
#
# OpenWrt / Keenetic:
#   wget -T 30 -qO- https://github.com/zerolabnet/SSClash-Go/raw/refs/heads/main/install-ssclash-go.sh | ash
#
# Linux (systemd):
#   curl -fsSL https://github.com/zerolabnet/SSClash-Go/raw/refs/heads/main/install-ssclash-go.sh | sudo sh
#
# Override detection: SSCLASH_PLATFORM=openwrt|keenetic|linux
set -e

echo "[ssclash-go] bootstrap loaded" >&2

REPO="zerolabnet/SSClash-Go"
BRANCH="${SSCLASH_INSTALL_BRANCH:-main}"
GITHUB_RAW="https://github.com/${REPO}/raw/refs/heads/${BRANCH}"

say()  { echo "[ssclash-go] $*"; }
warn() { echo "[ssclash-go] ! $*" >&2; }
die()  { echo "[ssclash-go] ERROR: $*" >&2; exit 1; }

detect_platform() {
	if [ -n "${SSCLASH_PLATFORM:-}" ]; then
		case "$(echo "$SSCLASH_PLATFORM" | tr 'A-Z' 'a-z')" in
			openwrt)  echo openwrt; return 0 ;;
			keenetic) echo keenetic; return 0 ;;
			linux)    echo linux; return 0 ;;
			*) die "unknown SSCLASH_PLATFORM=$SSCLASH_PLATFORM (use openwrt, keenetic, linux)" ;;
		esac
	fi
	if [ -f /etc/openwrt_release ]; then
		echo openwrt
		return 0
	fi
	for m in /bin/ndm /bin/ndmc /usr/sbin/ndmc /etc/ndm; do
		if [ -e "$m" ]; then
			echo keenetic
			return 0
		fi
	done
	echo linux
}

ssclash_is_running() {
	pidof ssclash >/dev/null 2>&1 && return 0
	[ -f /opt/var/run/ssclash.pid ] && kill -0 "$(cat /opt/var/run/ssclash.pid 2>/dev/null)" 2>/dev/null && return 0
	command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet ssclash.service 2>/dev/null && return 0
	return 1
}

# Stop SSClash (and its Mihomo child) so transparent proxy does not break GitHub
# downloads and so in-use binaries can be replaced safely.
stop_ssclash_if_running() {
	ssclash_is_running || pidof clash >/dev/null 2>&1 || return 0

	_stopped=0
	if [ -x /etc/init.d/ssclash ]; then
		warn "stopping /etc/init.d/ssclash for reliable download / upgrade..."
		/etc/init.d/ssclash stop 2>/dev/null || true
		_stopped=1
	elif [ -x /opt/etc/init.d/S99ssclash ]; then
		warn "stopping /opt/etc/init.d/S99ssclash for reliable download / upgrade..."
		/opt/etc/init.d/S99ssclash stop 2>/dev/null || true
		_stopped=1
	elif command -v systemctl >/dev/null 2>&1; then
		warn "stopping ssclash.service for reliable download / upgrade..."
		systemctl stop ssclash.service 2>/dev/null || true
		_stopped=1
	elif pidof ssclash >/dev/null 2>&1; then
		warn "stopping leftover ssclash process..."
		kill $(pidof ssclash) 2>/dev/null || true
		_stopped=1
	fi
	if [ "$_stopped" = "1" ] || pidof ssclash >/dev/null 2>&1 || pidof clash >/dev/null 2>&1; then
		_i=0
		while pidof ssclash >/dev/null 2>&1 && [ "$_i" -lt 20 ]; do
			sleep 1
			_i=$((_i + 1))
		done
		if pidof clash >/dev/null 2>&1; then
			warn "stopping leftover Mihomo (clash) process..."
			kill $(pidof clash) 2>/dev/null || true
			sleep 1
			kill -9 $(pidof clash) 2>/dev/null || true
		fi
	fi
}

fetch_url_once() {
	_url="$1"
	_out="$2"
	_max="${SSCLASH_FETCH_MAX_TIME:-120}"
	if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
		die "wget or curl required"
	fi
	if command -v curl >/dev/null 2>&1; then
		if curl -fsSL --retry 2 --connect-timeout 15 --max-time "$_max" -o "$_out" "$_url" 2>/dev/null \
			&& [ -s "$_out" ]; then
			return 0
		fi
	fi
	if command -v wget >/dev/null 2>&1; then
		if wget -T "$_max" -t 3 -qO "$_out" "$_url" 2>/dev/null \
			&& [ -s "$_out" ]; then
			return 0
		fi
	fi
	return 1
}

fetch_url() {
	_url="$1"
	_out="$2"
	if fetch_url_once "$_url" "$_out"; then
		return 0
	fi
	warn "download failed — stopping ssclash (if running) and retrying once..."
	stop_ssclash_if_running
	fetch_url_once "$_url" "$_out"
	return $?
}

fetch_installer() {
	_out="$1"
	_path="$2"
	_url="${GITHUB_RAW}/${_path}"
	say "fetching ${_path}..."
	if fetch_url "$_url" "$_out"; then
		return 0
	fi
	die "download failed: ${_url} (check DNS/HTTPS: nslookup github.com; install ca-bundle if needed)"
}

verify_installer() {
	_file="$1"
	if grep -q 'github_get\|install_bin\|install_file' "$_file" 2>/dev/null; then
		return 0
	fi
	die "downloaded installer looks invalid — save manually: wget -O /tmp/i.sh ${GITHUB_RAW}/${subpath}"
}

platform=$(detect_platform)
case "$platform" in
	openwrt)  subpath="packaging/openwrt/install-openwrt.sh" ;;
	keenetic) subpath="packaging/keenetic/install-keenetic.sh" ;;
	linux)    subpath="packaging/linux/install-linux.sh" ;;
	*) die "unsupported platform: $platform" ;;
esac

say "platform: ${platform}"

TMP="$(mktemp)"
cleanup() { rm -f "$TMP"; }
trap cleanup EXIT INT HUP TERM

fetch_installer "$TMP" "$subpath"
verify_installer "$TMP"

exec sh "$TMP" "$@"
