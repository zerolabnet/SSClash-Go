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

fetch_url() {
	_url="$1"
	_out="$2"
	if command -v wget >/dev/null 2>&1; then
		wget -T 30 -t 1 -qO "$_out" "$_url" 2>/dev/null && [ -s "$_out" ]
	elif command -v curl >/dev/null 2>&1; then
		curl -fsSL --connect-timeout 15 --max-time 120 -o "$_out" "$_url" 2>/dev/null && [ -s "$_out" ]
	else
		die "wget or curl required"
	fi
}

fetch_installer() {
	_out="$1"
	_path="$2"
	_url="${GITHUB_RAW}/${_path}"
	say "fetching ${_path}..."
	if fetch_url "$_url" "$_out"; then
		return 0
	fi
	die "download failed: ${_url} (if GitHub hangs, try: /etc/init.d/ssclash stop and re-run)"
}

verify_installer() {
	_file="$1"
	if grep -q 'install_file' "$_file" 2>/dev/null; then
		return 0
	fi
	die "downloaded installer is outdated — save manually: wget -O /tmp/i.sh ${GITHUB_RAW}/${subpath}"
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
