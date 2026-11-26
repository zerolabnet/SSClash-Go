#!/bin/sh
# SSClash-Go installer for OpenWrt (procd).
#
# Prefer the bootstrap command. It saves the file first, so a failed
# download prints an error instead of exiting with no output:
#   echo "[ssclash-go] downloading installer..." >&2
#   if wget -T 30 -O /tmp/install-ssclash-go.sh \
#     https://github.com/zerolabnet/SSClash-Go/raw/refs/heads/main/install-ssclash-go.sh \
#     && [ -s /tmp/install-ssclash-go.sh ]; then
#     ash /tmp/install-ssclash-go.sh
#   else
#     echo "[ssclash-go] ERROR: download failed" >&2
#     false
#   fi
#
# Or save this script first:
#   wget -T 30 -O /tmp/install-openwrt.sh \
#     https://github.com/zerolabnet/SSClash-Go/raw/refs/heads/main/packaging/openwrt/install-openwrt.sh
#   sh /tmp/install-openwrt.sh
#
# Options:
#   --port <n>           Web UI port (default 9091; all interfaces)
#   --bind <ip>          Bind web UI to this IP (with --port, default 9091)
#   --addr <host:port>   Full SSCLASH_ADDR (overrides --port / --bind)
#   --root <path>        Install directory (default /opt/clash)
#   --tls-cert <path>    TLS certificate (PEM); requires --tls-key
#   --tls-key <path>     TLS private key (PEM); requires --tls-cert
#   --tls-self-signed    Generate $ROOT/.ssclash/tls.{crt,key} (needs openssl)
#   --from <path>        Install this local ssclash binary instead of downloading.
#   --version <tag>      Download a specific release tag (default: latest).
#   --kernel <id>        Kernel id: mihomo-stable, mihomo-alpha, prizrak-core,
#                        prizrak-kroha, skip, or keep. On a terminal, a menu is
#                        shown when --kernel is omitted. Without a terminal the
#                        default is mihomo-stable, or keep with --update.
#   --update             Update the ssclash binary and kernel only. Keeps the
#                        listen address, TLS, install root and service file.
#                        On a terminal with an existing install, the installer asks
#                        update or reinstall when --update is omitted. The kernel
#                        menu then defaults to keep current.
#   A kernel on disk is kept when it matches the selected track. A different
#   track is installed even when the x.y.z version looks the same.
#   On a terminal the installer prints a banner, then menus for an existing
#   install, the kernel, the web UI port, and optional self-signed HTTPS.
#   Flags skip the matching question. Without a terminal the defaults are a
#   fresh install unless --update, kernel mihomo-stable (or keep with --update),
#   port 9091, and HTTP.
#   -h, --help           Show this help
set -e

REPO="zerolabnet/SSClash-Go"
GITHUB_RAW="https://github.com/${REPO}/raw/refs/heads/main"
SSCLASH_API="https://api.github.com/repos/${REPO}/releases/latest"
MIHOMO_STABLE_API="https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"
MIHOMO_ALPHA_API="https://api.github.com/repos/MetaCubeX/mihomo/releases/tags/Prerelease-Alpha"
PRIZRAK_API="https://api.github.com/repos/legiz-ru/Prizrak-Core/releases/latest"

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
MIHOMO_STATUS="skipped"

UI_PORT=9091
UI_BIND=""
UI_ADDR=""
TLS_CERT=""
TLS_KEY=""
TLS_SELF_SIGNED=0
FROM=""
VERSION="latest"
KERNEL_TRACK=""
UPDATE=0
ROOT_EXPLICIT=0

say()  { echo "[ssclash] $*"; }
info() { echo "[ssclash]   $*"; }
warn() { echo "[ssclash] ! $*"; }
die()  { echo "[ssclash] ERROR: $*" >&2; exit 1; }

assert_mihomo_ready() {
	case "$MIHOMO_STATUS" in
	installed*|skipped*|kept*) return 0 ;;
	esac
	if [ -x "$CLASH_BIN" ] && "$CLASH_BIN" -v >/dev/null 2>&1; then
		warn "Kernel update failed ($MIHOMO_STATUS) — keeping existing kernel at $CLASH_BIN"
		MIHOMO_STATUS="kept existing ($MIHOMO_STATUS)"
		return 0
	fi
	die "Kernel install failed ($MIHOMO_STATUS). Fix network/GitHub access and re-run, pass --kernel=skip, or install the kernel from Settings after SSClash is up."
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

# KERNEL-SELECT-BEGIN
# normalize_kernel_track prints a canonical KERNEL_TRACK, or returns 1.
normalize_kernel_track() {
	case "$1" in
		mihomo-stable|mihomo-alpha|prizrak-core|prizrak-kroha|skip|keep)
			printf '%s\n' "$1"
			;;
		*)
			return 1
			;;
	esac
}

# kernel_token_from_text reads a kernel -v blob. Revision and alpha win over x.y.z.
kernel_token_from_text() {
	_text=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
	_p=$(printf '%s\n' "$_text" | sed -n 's/.*\(v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*-r[0-9][0-9]*\(-kroha\)\{0,1\}\).*/\1/p' | head -n 1)
	if [ -n "$_p" ]; then
		printf '%s\n' "$_p"
		return 0
	fi
	_a=$(printf '%s\n' "$_text" | sed -n 's/.*alpha[-_ ]\{0,1\}\([0-9a-f]\{7,\}\).*/\1/p' | head -n 1)
	if [ -n "$_a" ]; then
		printf 'alpha-%s\n' "$_a"
		return 0
	fi
	_v=$(printf '%s\n' "$_text" | sed -n 's/.*\(v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -n 1)
	[ -n "$_v" ] && printf '%s\n' "$_v"
}

kernel_token_track() {
	case "$1" in
		*-kroha) printf '%s\n' prizrak-kroha ;;
		alpha-*) printf '%s\n' mihomo-alpha ;;
		v*-r[0-9]*) printf '%s\n' prizrak-core ;;
		v*) printf '%s\n' mihomo-stable ;;
		*) return 1 ;;
	esac
}

# kernel_should_keep is true when the on-disk token can stay for this track.
# $1 installed token (may be empty), $2 release token, $3 KERNEL_TRACK.
kernel_should_keep() {
	_have=$1
	_rel=$2
	_track=$3
	[ -n "$_have" ] || return 1
	_have_track=$(kernel_token_track "$_have") || return 1
	[ "$_have_track" = "$_track" ] || return 1
	[ "$_have" = "$_rel" ] && return 0
	if [ "$_track" = mihomo-stable ]; then
		version_gt "$_rel" "$_have" && return 1
		return 0
	fi
	return 1
}

# kernel_release_token prints the keep-token for a track. $1 track, $2 tag, $3 json.
kernel_release_token() {
	_track=$1
	_tag=$2
	_json=$3
	case "$_track" in
		mihomo-stable)
			printf '%s\n' "$_tag"
			;;
		prizrak-core)
			printf '%s\n' "$_tag" | grep -q '^v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*-r[0-9][0-9]*$' || return 1
			printf '%s\n' "$_tag"
			;;
		prizrak-kroha)
			printf '%s\n' "$_tag" | grep -q '^v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*-r[0-9][0-9]*$' || return 1
			printf '%s-kroha\n' "$_tag"
			;;
		mihomo-alpha)
			_h=$(printf '%s\n' "$_json" | tr '[:upper:]' '[:lower:]' | sed -n 's/.*-alpha-\([0-9a-f]\{7,\}\)\.gz.*/\1/p' | head -n 1)
			if [ -n "$_h" ]; then
				printf 'alpha-%s\n' "$_h"
			else
				printf '%s\n' Prerelease-Alpha
			fi
			;;
		*)
			return 1
			;;
	esac
}

# select_kernel_track sets KERNEL_TRACK. A /dev/tty menu runs only when it is empty.
select_kernel_track() {
	if [ -n "${KERNEL_TRACK:-}" ]; then
		return 0
	fi
	if ! ( : <>/dev/tty ) >/dev/null 2>&1; then
		if [ "${UPDATE:-0}" = 1 ]; then
			KERNEL_TRACK=keep
		else
			KERNEL_TRACK=mihomo-stable
		fi
		return 0
	fi
	if [ "${UPDATE:-0}" = 1 ]; then
		{
			printf '%s\n' \
				'Choose a kernel:' \
				'  1) keep current' \
				'  2) mihomo-stable' \
				'  3) mihomo-alpha' \
				'  4) prizrak-core' \
				'  5) prizrak-kroha' \
				'  6) skip (install later from Settings)'
			while :; do
				printf 'Select [1]: '
				if ! IFS= read -r _choice; then
					printf '\n%s\n' 'No selection. Using 1) keep current.'
					KERNEL_TRACK=keep
					return 0
				fi
				case "$_choice" in
					''|1) KERNEL_TRACK=keep; return 0 ;;
					2) KERNEL_TRACK=mihomo-stable; return 0 ;;
					3) KERNEL_TRACK=mihomo-alpha; return 0 ;;
					4) KERNEL_TRACK=prizrak-core; return 0 ;;
					5) KERNEL_TRACK=prizrak-kroha; return 0 ;;
					6) KERNEL_TRACK=skip; return 0 ;;
					*) printf '%s\n' 'Invalid choice. Enter 1, 2, 3, 4, 5, or 6.' ;;
				esac
			done
		} </dev/tty >/dev/tty
		return 0
	fi
	{
		printf '%s\n' \
			'Choose a kernel:' \
			'  1) mihomo-stable' \
			'  2) mihomo-alpha' \
			'  3) prizrak-core' \
			'  4) prizrak-kroha' \
			'  5) skip (install later from Settings)'
		while :; do
			printf 'Select [1]: '
			if ! IFS= read -r _choice; then
				printf '\n%s\n' 'No selection. Using 1) mihomo-stable.'
				KERNEL_TRACK=mihomo-stable
				return 0
			fi
			case "$_choice" in
				''|1) KERNEL_TRACK=mihomo-stable; return 0 ;;
				2) KERNEL_TRACK=mihomo-alpha; return 0 ;;
				3) KERNEL_TRACK=prizrak-core; return 0 ;;
				4) KERNEL_TRACK=prizrak-kroha; return 0 ;;
				5) KERNEL_TRACK=skip; return 0 ;;
				*) printf '%s\n' 'Invalid choice. Enter 1, 2, 3, 4, or 5.' ;;
			esac
		done
	} </dev/tty >/dev/tty
}
# KERNEL-SELECT-END

# Copy a non-executable file into place (init scripts, etc.).
install_file() {
	_src="$1"
	_dst="$2"
	_mode="${3:-755}"
	mkdir -p "$(dirname "$_dst")"
	cp -f "$_src" "$_dst"
	chmod "$_mode" "$_dst"
}

# Reject HTML/error pages mistaken for release binaries.
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

# asset_digest prints the sha256 hex GitHub stores in the asset digest field.
# Each asset object lists name before digest.
asset_digest() {
	_json=$1
	_name=$2
	[ -n "$_json" ] && [ -n "$_name" ] || return 1
	printf '%s' "$_json" | awk -v asset="$_name" '
		BEGIN { RS = "\"name\"" }
		NR == 1 { next }
		{
			if (index($0, ": \"" asset "\"") != 1 && index($0, ":\"" asset "\"") != 1)
				next
			if (match($0, /sha256:[0-9A-Fa-f]+/)) {
				hex = substr($0, RSTART + 7, RLENGTH - 7)
				if (length(hex) == 64) {
					print hex
					exit
				}
			}
			exit 1
		}
	'
}

check_sha256() {
	_file=$1
	# BusyBox tr often has no character classes. [:space:] then deletes a, c, and e.
	_want=$(printf '%s' "$2" | tr 'A-F' 'a-f' | tr -d ' \t\r\n')
	[ -n "$_file" ] && [ -s "$_file" ] || return 1
	_wlen=$(printf '%s' "$_want" | wc -c | tr -d ' ')
	[ "${_wlen:-0}" -eq 64 ] || return 1
	case "$_want" in
		*[!0-9a-f]*) return 1 ;;
	esac

	_got=""
	if command -v sha256sum >/dev/null 2>&1; then
		_got=$(sha256sum "$_file" 2>/dev/null | awk 'NR==1 { print tolower($1); exit }') || _got=""
	fi
	if [ -z "$_got" ] && command -v shasum >/dev/null 2>&1; then
		_got=$(shasum -a 256 "$_file" 2>/dev/null | awk 'NR==1 { print tolower($1); exit }') || _got=""
	fi
	if [ -z "$_got" ] && command -v openssl >/dev/null 2>&1; then
		_got=$(openssl dgst -sha256 "$_file" 2>/dev/null | awk 'NR==1 { print tolower($NF); exit }') || _got=""
	fi
	_glen=$(printf '%s' "$_got" | wc -c | tr -d ' ')
	[ "${_glen:-0}" -eq 64 ] || return 1
	case "$_got" in
		*[!0-9a-f]*) return 1 ;;
	esac
	[ "$_got" = "$_want" ]
}

# Stop processes whose /proc/*/exe resolves to this path (avoids random "clash" names).
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
# When free space covers the new file plus 1 MiB, the new file is staged
# beside the old one and swapped with mv. Otherwise the old file is removed
# first when free space plus the old file's size covers the new file. The
# 1 MiB margin is only for holding both copies during the swap.
# A failed copy deletes the partial file and never leaves .mihomo-new.* /
# .ssclash-install.*. The 5th argument "1" runs "<file> -v" before replacing
# a working binary. If the download directory cannot run it, the copy on the
# install path is checked instead.
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
	if [ "$_verify" = "1" ] && ! path_noexec "$_src"; then
		chmod +x "$_src" 2>/dev/null || true
		if "$_src" -v >/dev/null 2>&1; then
			_verified=1
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

	if [ $((_free + _old)) -ge "$_bytes" ]; then
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

# Stop ssclash + leftover Mihomo so GitHub works and binaries can be replaced.
stop_ssclash_for_upgrade() {
	_running=0
	pidof ssclash >/dev/null 2>&1 && _running=1
	pidof clash >/dev/null 2>&1 && _running=1
	for _p in /proc/[0-9]*; do
		[ -L "$_p/exe" ] || continue
		_exe=$(readlink "$_p/exe" 2>/dev/null || true)
		case "$_exe" in
			"$SSCLASH_BIN"|"$SSCLASH_BIN"*|"$CLASH_BIN"|"$CLASH_BIN"*) _running=1; break ;;
		esac
	done
	[ "$_running" = "1" ] || return 0

	say "stopping ssclash for safe upgrade / GitHub downloads..."
	if [ -x /etc/init.d/ssclash ]; then
		/etc/init.d/ssclash stop 2>/dev/null || true
	fi
	_i=0
	while pidof ssclash >/dev/null 2>&1 && [ "$_i" -lt 20 ]; do
		sleep 1
		_i=$((_i + 1))
	done
	stop_bin_path "$SSCLASH_BIN"
	stop_bin_path "$CLASH_BIN"
	if pidof clash >/dev/null 2>&1; then
		warn "stopping leftover Mihomo process..."
		kill $(pidof clash) 2>/dev/null || true
		sleep 1
		kill -9 $(pidof clash) 2>/dev/null || true
	fi
}

# Fetch from GitHub. Usage: github_get <url> [outfile]
# Without outfile, body goes to stdout. Tries curl, then wget.
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
		# No -t: stock OpenWrt wget is often uclient-fetch (rejects GNU-only flags).
		if [ -n "$_out" ]; then
			wget -T "$_max" -qO "$_out" "$_url" 2>/dev/null \
				&& [ -s "$_out" ] && return 0
		else
			wget -T "$_max" -qO- "$_url" 2>/dev/null \
				&& return 0
		fi
	fi
	return 1
}

github_fail_hint() {
	warn "Could not reach GitHub (DNS/network)."
	warn "Downloads run while SSClash is still up — if it routes your traffic, do not stop it manually first."
	warn "Check: nslookup api.github.com   or   wget -qO- https://api.github.com/zen"
	warn "If HTTPS fails: opkg update && opkg install ca-bundle wget-ssl   (or: apk add ca-bundle wget-ssl)"
}

github_get() {
	_url="$1"
	_out="${2:-}"
	if github_get_once "$_url" "$_out"; then
		return 0
	fi
	if pidof ssclash >/dev/null 2>&1 || pidof clash >/dev/null 2>&1; then
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

parse_install_options() {
	while [ $# -gt 0 ]; do
		case "$1" in
			--port) UI_PORT="${2:-}"; shift 2 ;;
			--port=*) UI_PORT="${1#*=}"; shift ;;
			--bind) UI_BIND="${2:-}"; shift 2 ;;
			--bind=*) UI_BIND="${1#*=}"; shift ;;
			--addr) UI_ADDR="${2:-}"; shift 2 ;;
			--addr=*) UI_ADDR="${1#*=}"; shift ;;
			--root)
				[ -n "${2:-}" ] || die "--root requires a path"
				ROOT=$2
				ROOT_EXPLICIT=1
				shift 2
				;;
			--root=*)
				ROOT=${1#*=}
				[ -n "$ROOT" ] || die "--root requires a path"
				ROOT_EXPLICIT=1
				shift
				;;
			--tls-cert) TLS_CERT="${2:-}"; shift 2 ;;
			--tls-cert=*) TLS_CERT="${1#*=}"; shift ;;
			--tls-key) TLS_KEY="${2:-}"; shift 2 ;;
			--tls-key=*) TLS_KEY="${1#*=}"; shift ;;
			--tls-self-signed) TLS_SELF_SIGNED=1; shift ;;
			--from) FROM="${2:-}"; shift 2 ;;
			--from=*) FROM="${1#*=}"; shift ;;
			--version) VERSION="${2:-}"; shift 2 ;;
			--version=*) VERSION="${1#*=}"; shift ;;
						--kernel)
				[ -n "${2:-}" ] || die "--kernel requires an id (mihomo-stable, mihomo-alpha, prizrak-core, prizrak-kroha, skip, keep)"
				KERNEL_TRACK=$(normalize_kernel_track "$2") \
					|| die "unknown --kernel: $2 (mihomo-stable, mihomo-alpha, prizrak-core, prizrak-kroha, skip, keep)"
				shift 2
				;;
			--kernel=*)
				_karg=${1#*=}
				[ -n "$_karg" ] || die "--kernel requires an id (mihomo-stable, mihomo-alpha, prizrak-core, prizrak-kroha, skip, keep)"
				KERNEL_TRACK=$(normalize_kernel_track "$_karg") \
					|| die "unknown --kernel: $_karg (mihomo-stable, mihomo-alpha, prizrak-core, prizrak-kroha, skip, keep)"
				shift
				;;
			--update) UPDATE=1; shift ;;
			-h|--help)
				awk 'NR>1 && /^set -e/{exit} NR>1 {sub(/^# ?/,""); print}' "$0"
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

validate_root() {
	case "$ROOT" in
		/*) ;;
		*) die "--root must be an absolute path: $ROOT" ;;
	esac
	case "$ROOT" in
		*..*) die "--root must not contain .." ;;
		*[!A-Za-z0-9/_.-]*) die "invalid --root (letters, digits, / _ . - only): $ROOT" ;;
	esac
	ROOT=${ROOT%/}
	[ -n "$ROOT" ] && [ "$ROOT" != "/" ] || die "--root must be a directory below /"
	if [ -d "$ROOT" ]; then
		[ -w "$ROOT" ] || die "$ROOT is not writable. Pass --root under a writable mount such as /data"
		return 0
	fi
	mkdir -p "$ROOT" 2>/dev/null || die "cannot create $ROOT (read-only filesystem?). Pass --root under a writable mount such as /data"
}

# Re-runs without --root keep ROOT from the installed init script.
apply_install_paths() {
	if [ "$ROOT_EXPLICIT" != 1 ] && [ -f /etc/init.d/ssclash ]; then
		_existing=$(sed -n 's/^ROOT=//p' /etc/init.d/ssclash | head -1 | tr -d '"' | tr -d "'")
		if [ -n "$_existing" ]; then
			ROOT=$_existing
			info "keeping existing install root: $ROOT"
		fi
	fi
	validate_root
	SSCLASH_BIN="$ROOT/bin/ssclash"
	CLASH_BIN="$ROOT/bin/clash"
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
	if [ -n "$_ip" ]; then
		echo "${_ip%%/*}"
		return
	fi
	_ip=$(pick_lan_ipv4)
	if [ -n "$_ip" ]; then
		echo "$_ip"
		return
	fi
	echo "<router-ip>"
}

# iface_skipped is true for container, tunnel, and other non-LAN interfaces.
iface_skipped() {
	case "$1" in
		''|lo|lo[0-9]*|docker*|veth*|virbr*|cni*|flannel*|kube*|nerdctl*|podman*|zt*|tun*|wg*|tailscale*)
			return 0
			;;
		br-lan|br0)
			return 1
			;;
		br-*)
			return 0
			;;
	esac
	return 1
}

# iface_lan is true for names that usually hold a LAN address.
iface_lan() {
	case "$1" in
		br-lan|lan|br0|eth*|en*|wlan*|wlp*|wl*)
			return 0
			;;
	esac
	return 1
}

# ipv4_docker17 is true for Docker's default bridge, 172.17.0.0/16.
ipv4_docker17() {
	case "$1" in
		172.17.*) return 0 ;;
	esac
	return 1
}

# ipv4_rfc1918 is true for private IPv4 except 172.17.0.0/16.
ipv4_rfc1918() {
	case "$1" in
		10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*)
			if ipv4_docker17 "$1"; then
				return 1
			fi
			return 0
			;;
	esac
	return 1
}

# pick_lan_ipv4 prints one IPv4 for the UI hint.
# A private route-get src wins, so Docker 172.17.0.1 loses to a real LAN route.
# A private address on a LAN-like iface beats a public WAN src.
# Virtual ifaces are skipped. 172.17.0.0/16 is only a last resort.
pick_lan_ipv4() {
	_route_src=""
	for _via in 1.1.1.1 8.8.8.8; do
		_line=$(ip -4 route get "$_via" 2>/dev/null | head -n 1 || true)
		[ -n "$_line" ] || continue
		_src=$(printf '%s\n' "$_line" | sed -n 's/.* src[[:space:]][[:space:]]*\([0-9.][0-9.]*\).*/\1/p' | head -n 1)
		_dev=$(printf '%s\n' "$_line" | sed -n 's/.* dev[[:space:]][[:space:]]*\([^ ][^ ]*\).*/\1/p' | head -n 1)
		[ -n "$_src" ] || continue
		if iface_skipped "$_dev"; then
			continue
		fi
		if ipv4_docker17 "$_src"; then
			continue
		fi
		_route_src=$_src
		break
	done

	_lan_rfc=""
	_any_rfc=""
	_lan_glob=""
	_any_glob=""
	_last=""
	_addrs=$(ip -4 -o addr show scope global 2>/dev/null | awk '{ printf "%s=%s\n", $2, $4 }' || true)
	for _pair in $_addrs; do
		_if=${_pair%%=*}
		_cidr=${_pair#*=}
		_ip=${_cidr%%/*}
		[ -n "$_ip" ] || continue
		if iface_skipped "$_if"; then
			continue
		fi
		if [ -z "$_last" ]; then
			_last=$_ip
		fi
		if ipv4_docker17 "$_ip"; then
			continue
		fi
		if [ -z "$_any_glob" ]; then
			_any_glob=$_ip
		fi
		if iface_lan "$_if" && [ -z "$_lan_glob" ]; then
			_lan_glob=$_ip
		fi
		if ipv4_rfc1918 "$_ip"; then
			if [ -z "$_any_rfc" ]; then
				_any_rfc=$_ip
			fi
			if iface_lan "$_if" && [ -z "$_lan_rfc" ]; then
				_lan_rfc=$_ip
			fi
		fi
	done

	if [ -n "$_route_src" ] && ipv4_rfc1918 "$_route_src"; then
		printf '%s\n' "$_route_src"
		return 0
	fi
	if [ -n "$_lan_rfc" ]; then
		printf '%s\n' "$_lan_rfc"
		return 0
	fi
	if [ -n "$_route_src" ]; then
		printf '%s\n' "$_route_src"
		return 0
	fi
	if [ -n "$_any_rfc" ]; then
		printf '%s\n' "$_any_rfc"
		return 0
	fi
	if [ -n "$_lan_glob" ]; then
		printf '%s\n' "$_lan_glob"
		return 0
	fi
	if [ -n "$_any_glob" ]; then
		printf '%s\n' "$_any_glob"
		return 0
	fi
	if [ -n "$_last" ]; then
		printf '%s\n' "$_last"
	fi
}

# reconfigure_requested is true when flags already choose a fresh install.
reconfigure_requested() {
	if [ -n "$UI_BIND$UI_ADDR$TLS_CERT$TLS_KEY" ]; then
		return 0
	fi
	if [ "$TLS_SELF_SIGNED" = 1 ]; then
		return 0
	fi
	if [ "$UI_PORT" != 9091 ]; then
		return 0
	fi
	if [ "$ROOT_EXPLICIT" = 1 ]; then
		return 0
	fi
	return 1
}

print_banner() {
	cat <<'EOF'
================================================
  SSClash-Go
  by ZeroChaos
  https://zerolab.net
================================================
EOF
}

# tty_ok is true when /dev/tty can take prompts, including curl|sh.
tty_ok() {
	( : <>/dev/tty ) >/dev/null 2>&1
}

# prompt_install_action may set UPDATE.
# $1 is 1 when a binary or service file already exists.
# $2 is 1 when that install is complete enough to update.
prompt_install_action() {
	if [ "$UPDATE" = 1 ]; then
		return 0
	fi
	if reconfigure_requested; then
		return 0
	fi
	if [ "${1:-0}" != 1 ]; then
		return 0
	fi
	if ! tty_ok; then
		return 0
	fi
	_def=2
	if [ "${2:-0}" = 1 ]; then
		_def=1
	fi
	{
		printf '%s\n' \
			'An existing installation was found.' \
			'  1) Update (binary and kernel only; keep mode, address, TLS, and service)' \
			'  2) Fresh install / reinstall'
		while :; do
			printf 'Select [%s]: ' "$_def"
			if ! IFS= read -r _choice; then
				printf '\n'
				_choice=$_def
			fi
			case "$_choice" in
				'') _choice=$_def ;;
			esac
			case "$_choice" in
				1) UPDATE=1; return 0 ;;
				2) UPDATE=0; return 0 ;;
				*) printf '%s\n' 'Invalid choice. Enter 1 or 2.' ;;
			esac
		done
	} </dev/tty >/dev/tty
}

# prompt_ui_port asks only on a fresh install when the port is still 9091.
prompt_ui_port() {
	if [ "$UPDATE" = 1 ]; then
		return 0
	fi
	if [ "$UI_PORT" != 9091 ]; then
		return 0
	fi
	if [ -n "$UI_BIND$UI_ADDR" ]; then
		return 0
	fi
	if ! tty_ok; then
		return 0
	fi
	while :; do
		printf 'Web UI port [9091]: ' >/dev/tty
		if ! IFS= read -r _choice </dev/tty; then
			return 0
		fi
		if [ -z "$_choice" ]; then
			return 0
		fi
		case "$_choice" in
			*[!0-9]*)
				printf '%s\n' 'Enter a port from 1 to 65535.' >/dev/tty
				continue
				;;
		esac
		if [ "${#_choice}" -gt 5 ]; then
			printf '%s\n' 'Enter a port from 1 to 65535.' >/dev/tty
			continue
		fi
		_n=$_choice
		while :; do
			case "$_n" in
				0*) _n=${_n#0} ;;
				*) break ;;
			esac
		done
		if [ -n "$_n" ] && [ "$_n" -ge 1 ] && [ "$_n" -le 65535 ]; then
			UI_PORT=$_n
			return 0
		fi
		printf '%s\n' 'Enter a port from 1 to 65535.' >/dev/tty
	done
}

# prompt_tls_self_signed asks only on a fresh install with no TLS flags.
prompt_tls_self_signed() {
	if [ "$UPDATE" = 1 ]; then
		return 0
	fi
	if [ "$TLS_SELF_SIGNED" = 1 ]; then
		return 0
	fi
	if [ -n "$TLS_CERT$TLS_KEY" ]; then
		return 0
	fi
	if ! tty_ok; then
		return 0
	fi
	{
		printf '%s\n' \
			'Web UI HTTPS (self-signed certificate)?' \
			'  1) No (HTTP)' \
			'  2) Yes'
		while :; do
			printf 'Select [1]: '
			if ! IFS= read -r _choice; then
				printf '\n'
				return 0
			fi
			case "$_choice" in
				''|1) return 0 ;;
				2) TLS_SELF_SIGNED=1; return 0 ;;
				*) printf '%s\n' 'Invalid choice. Enter 1 or 2.' ;;
			esac
		done
	} </dev/tty >/dev/tty
}

# kernel_summary_text is "skip", "keep (token)", or "id (token)".
kernel_summary_text() {
	if [ "$KERNEL_TRACK" = skip ]; then
		printf '%s\n' skip
		return 0
	fi
	_tok=""
	if [ -x "$CLASH_BIN" ]; then
		_tok=$(kernel_token_from_text "$("$CLASH_BIN" -v 2>/dev/null || true)" || true)
	fi
	if [ "$KERNEL_TRACK" = keep ]; then
		if [ -n "$_tok" ]; then
			printf 'keep (%s)\n' "$_tok"
		else
			printf '%s\n' keep
		fi
		return 0
	fi
	if [ -n "$_tok" ]; then
		printf '%s (%s)\n' "$KERNEL_TRACK" "$_tok"
		return 0
	fi
	printf '%s (not installed)\n' "$KERNEL_TRACK"
}

# print_install_summary "$ip" ["$mode"] ["$hint"]
print_install_summary() {
	_ip=$1
	_mode=${2:-}
	_hint=${3:-}
	if [ "$UPDATE" = 1 ]; then
		_word=updated
	else
		_word=installed
	fi
	_scheme=$(ui_scheme)
	_host=$(ui_effective_host "$_ip")
	_port=$(ui_effective_port)
	_kern=$(kernel_summary_text)
	printf '\n%s\n' '------------------------------------------------'
	printf ' SSClash-Go %s\n' "$_word"
	printf '\n'
	printf ' UI:     %s\n' "${_scheme}://${_host}:${_port}"
	printf ' Kernel: %s\n' "$_kern"
	if [ -n "$_mode" ]; then
		printf ' Mode:   %s\n' "$_mode"
	fi
	printf ' Root:   %s\n' "$ROOT"
	printf '\n'
	printf '%s\n' ' Open the UI, set the admin password, then Start.'
	if [ "$KERNEL_TRACK" = skip ]; then
		printf '%s\n' ' Install a kernel from Settings before Start.'
	fi
	if [ -n "$_hint" ]; then
		printf ' %s\n' "$_hint"
	fi
	printf '%s\n' '------------------------------------------------'
}


configure_openwrt_init() {
	_f="/etc/init.d/ssclash"
	[ -f "$_f" ] || return 0
	sed -i "s|^ROOT=.*|ROOT=${ROOT}|" "$_f"
	info "install root: ${ROOT}"
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

# True when /usr/bin/wget is uclient-fetch/BusyBox (HTTPS often weak vs wget-ssl).
wget_is_limited() {
	command -v wget >/dev/null 2>&1 || return 0
	_w=$(command -v wget)
	_t=$(readlink -f "$_w" 2>/dev/null || readlink "$_w" 2>/dev/null || echo "$_w")
	case "$_t" in
		*uclient*|*busybox*) return 0 ;;
	esac
	# GNU wget-ssl installs as alternatives → /usr/libexec/wget-ssl
	[ -x /usr/libexec/wget-ssl ] && return 1
	return 1
}

# ---- 0. curl or HTTPS-capable wget (needed for GitHub API + downloads) -------
ensure_fetcher() {
	if command -v curl >/dev/null 2>&1; then
		return 0
	fi
	if command -v wget >/dev/null 2>&1 && ! wget_is_limited; then
		return 0
	fi
	if command -v wget >/dev/null 2>&1 && wget_is_limited; then
		warn "stock wget looks like uclient-fetch/BusyBox — installing wget-ssl for GitHub HTTPS..."
	else
		warn "neither curl nor wget found — installing wget-ssl (or curl)..."
	fi
	pkg_update
	if [ "$PKG_MGR" = "apk" ]; then
		apk add ca-bundle wget-ssl 2>/dev/null \
			|| apk add ca-bundle curl 2>/dev/null \
			|| die "failed to install wget-ssl/curl"
	else
		opkg install ca-bundle >/dev/null 2>&1 || true
		opkg install wget-ssl 2>/dev/null \
			|| opkg install curl 2>/dev/null \
			|| die "failed to install wget-ssl/curl"
	fi
	if command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1; then
		say "HTTPS fetch tool ready"
		return 0
	fi
	die "curl/wget still unavailable after install"
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
		x86_64)         SSCLASH_ASSET="amd64"; MIHOMO_ARCH="amd64" ;;
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
			x86_64)          SSCLASH_ASSET="amd64"; MIHOMO_ARCH="amd64" ;;
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
	[ -n "$MIHOMO_ARCH" ] && info "kernel arch: ${MIHOMO_ARCH}"
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
	# wget-ssl: stock OpenWrt wget is often uclient-fetch; GitHub HTTPS needs real SSL wget.
	DEPS="$TPROXY_PKG kmod-tun ca-bundle wget-ssl"
	say "installing dependencies: $DEPS"
	if [ "$PKG_MGR" = "apk" ]; then
		apk add $DEPS || die "dependency install failed"
		apk add conntrack ipset || warn "conntrack/ipset install failed (DNS session flush and ipset rules may be skipped)"
	else
		opkg install $DEPS || die "dependency install failed"
		opkg install conntrack ipset || warn "conntrack/ipset install failed (DNS session flush and ipset rules may be skipped)"
	fi
}

# ---- 5. Latest ssclash-go release (GitHub API) ------------------------------
fetch_ssclash_release() {
	if [ -n "$FROM" ]; then
		return 0
	fi
	if [ "$VERSION" != "latest" ]; then
		SSCLASH_TAG="$VERSION"
		SSCLASH_BIN_URL="https://github.com/${REPO}/releases/download/${SSCLASH_TAG}/ssclash-linux-${SSCLASH_ASSET}"
		SSCLASH_SVC_URL="https://github.com/${REPO}/releases/download/${SSCLASH_TAG}/ssclash-openwrt-service.tar.gz"
		info "release: ${SSCLASH_TAG}"
		info "binary: ${SSCLASH_BIN_URL##*/}"
		return 0
	fi
	say "fetching latest ssclash-go release..."
	RELEASE_JSON=$(github_get "$SSCLASH_API") || die "GitHub API request failed"
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
	if [ -n "$FROM" ]; then
		[ -f "$FROM" ] || die "binary not found: $FROM"
		say "installing local binary: $FROM"
		install_bin "$FROM" "$SSCLASH_BIN" 755 "ssclash" || die "ssclash install failed"
		if ! "$SSCLASH_BIN" version >/dev/null 2>&1 && ! "$SSCLASH_BIN" -h >/dev/null 2>&1; then
			warn "ssclash installed but did not respond to version/-h (check arch)"
		fi
		say "installed ${SSCLASH_BIN}"
		return 0
	fi
	say "downloading ssclash..."
	TMP="$(mktemp)"
	_asset=${SSCLASH_BIN_URL##*/}
	_want=$(asset_digest "$RELEASE_JSON" "$_asset") || {
		rm -f "$TMP"
		die "release has no sha256 for ${_asset}"
	}
	if ! GITHUB_GET_MAX_TIME=300 github_get "$SSCLASH_BIN_URL" "$TMP"; then
		rm -f "$TMP"
		die "ssclash download failed"
	fi
	if ! check_sha256 "$TMP" "$_want"; then
		rm -f "$TMP"
		die "sha256 mismatch for ${_asset}"
	fi
	if ! install_bin "$TMP" "$SSCLASH_BIN" 755 "ssclash"; then
		rm -f "$TMP"
		die "ssclash install failed (bad download?)"
	fi
	rm -f "$TMP"
	if ! "$SSCLASH_BIN" version >/dev/null 2>&1 && ! "$SSCLASH_BIN" -h >/dev/null 2>&1; then
		warn "ssclash installed but did not respond to version/-h (check arch)"
	fi
	say "installed ${SSCLASH_BIN}"
}

# ---- 7. procd service -------------------------------------------------------
install_init_from_raw() {
	_url="${GITHUB_RAW}/packaging/openwrt/etc/init.d/ssclash"
	_tmp="/tmp/ssclash-init.$$"
	say "fetching init.d/ssclash from repository..."
	if github_get "$_url" "$_tmp" && [ -s "$_tmp" ]; then
		install_file "$_tmp" /etc/init.d/ssclash 755
		rm -f "$_tmp"
		return 0
	fi
	rm -f "$_tmp"
	return 1
}

install_service() {
	mkdir -p "$ROOT/.ssclash" "$ROOT/local-rules" "$ROOT/rule-providers" "$ROOT/proxy-providers" "$ROOT/subscriptions" "$ROOT/ui"

	SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
	if [ -f "$SCRIPT_DIR/etc/init.d/ssclash" ]; then
		install_file "$SCRIPT_DIR/etc/init.d/ssclash" /etc/init.d/ssclash 755
		configure_openwrt_init
		return 0
	fi

	_svc_ok=0
	if [ -n "$SSCLASH_SVC_URL" ]; then
		say "installing init.d service from release..."
		info "downloading ssclash-openwrt-service.tar.gz (${SSCLASH_TAG:-release})..."
		if GITHUB_GET_MAX_TIME=120 github_get "$SSCLASH_SVC_URL" /tmp/ssclash-svc.tgz; then
			info "extracting service files..."
			if tar -xzf /tmp/ssclash-svc.tgz -C /; then
				_svc_ok=1
			else
				warn "could not extract service bundle"
			fi
			rm -f /tmp/ssclash-svc.tgz
		else
			warn "could not download service bundle from release"
		fi
	fi

	if [ "$_svc_ok" = "0" ]; then
		install_init_from_raw || warn "init.d/ssclash not installed — copy from release or re-run installer"
	fi
	configure_openwrt_init
}

# Pick a mihomo .gz asset URL from the release JSON (handles loong64 ABI variants).
has_cpu_flag() {
	case " $1 " in
		*" $2 "*) return 0 ;;
	esac
	return 1
}

# The unsuffixed linux-amd64 file is an x86-64-v3 build.
# $3 is the filename prefix (default mihomo).
amd64_mihomo_names() {
	_ver=$1
	_flags=$2
	_prefix=${3:-mihomo}
	_v2=1
	for _f in cx16 lahf_lm popcnt pni sse4_1 sse4_2 ssse3; do
		has_cpu_flag "$_flags" "$_f" || _v2=0
	done
	_v3=0
	if [ "$_v2" = 1 ]; then
		_v3=1
		for _f in avx avx2 bmi1 bmi2 f16c fma abm movbe osxsave; do
			has_cpu_flag "$_flags" "$_f" || _v3=0
		done
	fi
	if [ "$_v3" = 1 ]; then
		echo "${_prefix}-linux-amd64-v3-${_ver}.gz ${_prefix}-linux-amd64-v2-${_ver}.gz ${_prefix}-linux-amd64-v1-${_ver}.gz ${_prefix}-linux-amd64-compatible-${_ver}.gz ${_prefix}-linux-amd64-${_ver}.gz"
		return 0
	fi
	if [ "$_v2" = 1 ]; then
		echo "${_prefix}-linux-amd64-v2-${_ver}.gz ${_prefix}-linux-amd64-v1-${_ver}.gz ${_prefix}-linux-amd64-compatible-${_ver}.gz ${_prefix}-linux-amd64-${_ver}.gz"
		return 0
	fi
	echo "${_prefix}-linux-amd64-v1-${_ver}.gz ${_prefix}-linux-amd64-compatible-${_ver}.gz ${_prefix}-linux-amd64-${_ver}.gz"
}

# KERNEL-ASSET-BEGIN
# kernel_json_urls prints one browser_download_url per line.
kernel_json_urls() {
	printf '%s\n' "$MIHOMO_JSON" | sed 's/"browser_download_url"/\
"browser_download_url"/g' \
		| sed -n 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}

# json_asset_url prints the URL whose basename is $1.
json_asset_url() {
	_name=$1
	_url=$(kernel_json_urls | while IFS= read -r _u; do
		_base=${_u##*/}
		if [ "$_base" = "$_name" ]; then
			printf '%s\n' "$_u"
			break
		fi
	done)
	[ -n "$_url" ] || return 1
	printf '%s\n' "$_url"
}

# kernel_compressed_name is the -compressed- twin of a plain .gz name.
kernel_compressed_name() {
	_name=$1
	_tag=$2
	_suffix="-${_tag}.gz"
	case "$_name" in
		*"$_suffix")
			_stem=${_name%"$_suffix"}
			printf '%s\n' "${_stem}-compressed-${_tag}.gz"
			;;
		*)
			return 1
			;;
	esac
}

# kernel_gzip_url prefix tag arch leveled compressed
# leveled=1 uses the amd64 v3/v2/v1/compatible ladder. compressed=1 tries the twin.
kernel_gzip_url() {
	_prefix=$1
	_ver=$2
	_arch=$3
	_leveled=$4
	_compressed=$5
	_candidates=""
	case "$_arch" in
		loong64)
			_candidates="${_prefix}-linux-loong64-abi2-${_ver}.gz ${_prefix}-linux-loong64-abi1-${_ver}.gz"
			;;
		amd64)
			if [ "$_leveled" = 1 ]; then
				_flags=$(awk '/^flags/ { sub(/^flags[^:]*:[[:space:]]*/, ""); print; exit }' /proc/cpuinfo 2>/dev/null || true)
				_candidates=$(amd64_mihomo_names "$_ver" "$_flags" "$_prefix")
			else
				_candidates="${_prefix}-linux-amd64-${_ver}.gz"
			fi
			;;
		*)
			_candidates="${_prefix}-linux-${_arch}-${_ver}.gz"
			;;
	esac
	for _name in $_candidates; do
		if _url=$(json_asset_url "$_name"); then
			printf '%s\n' "$_url"
			return 0
		fi
		if [ "$_compressed" = 1 ]; then
			_alt=$(kernel_compressed_name "$_name" "$_ver") || continue
			if _url=$(json_asset_url "$_alt"); then
				printf '%s\n' "$_url"
				return 0
			fi
		fi
	done
	return 1
}

kernel_alpha_prefixes() {
	_arch=$1
	case "$_arch" in
		loong64)
			printf '%s\n' "mihomo-linux-loong64-abi2-alpha- mihomo-linux-loong64-abi1-alpha-"
			;;
		amd64)
			_flags=$(awk '/^flags/ { sub(/^flags[^:]*:[[:space:]]*/, ""); print; exit }' /proc/cpuinfo 2>/dev/null || true)
			_names=$(amd64_mihomo_names HASHPLACE "$_flags" mihomo)
			_out=""
			for _n in $_names; do
				_n=${_n%.gz}
				_n=${_n%-HASHPLACE}
				_out="${_out}${_n}-alpha- "
			done
			printf '%s\n' "$_out"
			;;
		*)
			printf '%s\n' "mihomo-linux-${_arch}-alpha-"
			;;
	esac
}

# kernel_alpha_match reads URLs on stdin and prints the first hash asset for prefix $1.
# The match stays outside $(...) so a case ")" does not close the substitution.
kernel_alpha_match() {
	_prefix=$1
	while IFS= read -r _u; do
		_base=${_u##*/}
		case "$_base" in
			"${_prefix}"*.gz) ;;
			*) continue ;;
		esac
		_mid=${_base#"$_prefix"}
		_mid=${_mid%.gz}
		case "$_mid" in
			''|*[!0-9a-fA-F]*) continue ;;
		esac
		if [ "${#_mid}" -ge 7 ]; then
			printf '%s\n' "$_u"
			break
		fi
	done
}

# kernel_alpha_url picks mihomo-linux-<arch>-alpha-<hash>.gz, amd64 ladder first.
kernel_alpha_url() {
	_arch=$1
	_prefixes=$(kernel_alpha_prefixes "$_arch")
	for _prefix in $_prefixes; do
		_url=$(kernel_json_urls | kernel_alpha_match "$_prefix")
		if [ -n "$_url" ]; then
			printf '%s\n' "$_url"
			return 0
		fi
	done
	return 1
}

# fetch_kernel_asset fills MIHOMO_JSON, MIHOMO_VER, and MIHOMO_URL.
# Returns 1 when the caller should stop (kept, or a soft failure already recorded).
fetch_kernel_asset() {
	case "$KERNEL_TRACK" in
		mihomo-stable) _api=$MIHOMO_STABLE_API; _label="Mihomo Stable" ;;
		mihomo-alpha) _api=$MIHOMO_ALPHA_API; _label="Mihomo Alpha" ;;
		prizrak-core) _api=$PRIZRAK_API; _label="Prizrak Core" ;;
		prizrak-kroha) _api=$PRIZRAK_API; _label="Prizrak Kroha" ;;
		*)
			warn "unknown kernel track ${KERNEL_TRACK}"
			MIHOMO_STATUS="missing (bad track)"
			return 1
			;;
	esac
	info "Fetching ${_label} release..."
	MIHOMO_JSON=$(github_get "$_api") || {
		warn "${_label} GitHub API request failed — install from Settings later"
		MIHOMO_STATUS="missing (API failed)"
		return 1
	}
	[ -n "$MIHOMO_JSON" ] || {
		warn "empty ${_label} API response — install from Settings later"
		MIHOMO_STATUS="missing (empty API)"
		return 1
	}
	MIHOMO_VER=$(printf '%s\n' "$MIHOMO_JSON" \
		| grep '"tag_name"' | head -n 1 \
		| sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
	if [ -z "$MIHOMO_VER" ]; then
		warn "could not parse ${_label} version — install from Settings later"
		MIHOMO_STATUS="missing (parse failed)"
		return 1
	fi
	_token=$(kernel_release_token "$KERNEL_TRACK" "$MIHOMO_VER" "$MIHOMO_JSON") || {
		warn "unexpected ${_label} release tag ${MIHOMO_VER} — install from Settings later"
		MIHOMO_STATUS="missing (parse failed)"
		return 1
	}
	info "${_label}: ${_token}"
	_have=""
	if [ -x "$CLASH_BIN" ]; then
		_have=$(kernel_token_from_text "$("$CLASH_BIN" -v 2>/dev/null || true)")
	fi
	if kernel_should_keep "$_have" "$_token" "$KERNEL_TRACK"; then
		info "${_label} ${_have} is already current for ${_token} — keeping it"
		MIHOMO_STATUS="kept (${_have})"
		return 1
	fi
	if [ -n "$_have" ]; then
		info "${_label} ${_have} differs from ${_token} — installing"
	fi
	MIHOMO_URL=""
	case "$KERNEL_TRACK" in
		mihomo-stable)
			MIHOMO_URL=$(kernel_gzip_url mihomo "$MIHOMO_VER" "$MIHOMO_ARCH" 1 0) || MIHOMO_URL=""
			;;
		prizrak-core)
			MIHOMO_URL=$(kernel_gzip_url prizrak-core "$MIHOMO_VER" "$MIHOMO_ARCH" 1 0) || MIHOMO_URL=""
			;;
		prizrak-kroha)
			MIHOMO_URL=$(kernel_gzip_url prizrak-kroha "$MIHOMO_VER" "$MIHOMO_ARCH" 0 1) || MIHOMO_URL=""
			;;
		mihomo-alpha)
			MIHOMO_URL=$(kernel_alpha_url "$MIHOMO_ARCH") || MIHOMO_URL=""
			;;
	esac
	if [ -z "$MIHOMO_URL" ]; then
		warn "${_label} asset for ${MIHOMO_ARCH} not found — install from Settings later"
		MIHOMO_STATUS="missing (no asset for ${MIHOMO_ARCH})"
		return 1
	fi
	return 0
}
# KERNEL-ASSET-END

# ---- 8. mihomo kernel (GitHub API) ------------------------------------------
install_mihomo() {
	select_kernel_track
	if [ "$KERNEL_TRACK" = "skip" ]; then
		warn "skipping kernel download (skip)"
		MIHOMO_STATUS="skipped (skip)"
		return 0
	fi
	if [ "$KERNEL_TRACK" = "keep" ]; then
		if [ -x "$CLASH_BIN" ] && "$CLASH_BIN" -v >/dev/null 2>&1; then
			_tok=$(kernel_token_from_text "$("$CLASH_BIN" -v 2>/dev/null || true)" || true)
			if [ -n "$_tok" ]; then
				MIHOMO_STATUS="kept (current: ${_tok})"
			else
				MIHOMO_STATUS="kept (current)"
			fi
			info "keeping current kernel (${_tok:-ok})"
		else
			warn "keep requested but no runnable kernel at $CLASH_BIN"
			MIHOMO_STATUS="missing (keep: no kernel)"
		fi
		return 0
	fi
	if [ -z "$MIHOMO_ARCH" ]; then
		warn "kernel architecture not determined — install manually from Settings"
		MIHOMO_STATUS="missing (unknown arch)"
		return 0
	fi

	fetch_kernel_asset || return 0
	info "url: ${MIHOMO_URL}"

	_tmp_gz="$(mktemp)"
	say "downloading ${KERNEL_TRACK} kernel..."
	if ! GITHUB_GET_MAX_TIME=300 github_get "$MIHOMO_URL" "$_tmp_gz"; then
		warn "Mihomo download failed — install from Settings later"
		rm -f "$_tmp_gz"
		MIHOMO_STATUS="missing (download failed)"
		return 0
	fi
	_mname=${MIHOMO_URL##*/}
	_mwant=$(asset_digest "$MIHOMO_JSON" "$_mname") || {
		warn "Mihomo release has no sha256 for ${_mname} — install from Settings later"
		rm -f "$_tmp_gz"
		MIHOMO_STATUS="missing (no sha256)"
		return 0
	}
	if ! check_sha256 "$_tmp_gz" "$_mwant"; then
		warn "Mihomo sha256 mismatch for ${_mname} — keeping existing kernel"
		rm -f "$_tmp_gz"
		MIHOMO_STATUS="missing (sha256 mismatch)"
		return 0
	fi

	# gzip -l reports the uncompressed size when this host's gzip supports it.
	# The archive is then streamed onto the install filesystem, so /tmp keeps
	# only the .gz. BusyBox gzip has no -l and still unpacks to a temp file.
	_gunzip='gunzip -c'
	_bytes=""
	_listing=$(gzip -l "$_tmp_gz" 2>/dev/null) || _listing=""
	if [ -n "$_listing" ]; then
		_bytes=$(printf '%s\n' "$_listing" | awk 'NR==2 { print $2; exit }')
	fi
	case "${_bytes:-}" in
		''|*[!0-9]*|0)
			_listing=$(gunzip -l "$_tmp_gz" 2>/dev/null) || _listing=""
			if [ -n "$_listing" ]; then
				_bytes=$(printf '%s\n' "$_listing" | awk 'NR==2 { print $2; exit }')
			fi
			;;
	esac
	case "${_bytes:-}" in
		''|*[!0-9]*|0) _bytes="" ;;
	esac

	if [ -z "$_bytes" ]; then
		_tmp_bin="$(mktemp)"
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
		if ! install_checked_bin "$_tmp_bin" "$CLASH_BIN" 755 "Mihomo" 1; then
			rm -f "$_tmp_bin"
			MIHOMO_STATUS="missing (install failed)"
			return 0
		fi
		rm -f "$_tmp_bin"
	else
		_dir=$(dirname "$CLASH_BIN")
		mkdir -p "$_dir" || {
			rm -f "$_tmp_gz"
			MIHOMO_STATUS="missing (install failed)"
			return 0
		}
		rm -f "$_dir"/.mihomo-new.*
		_free_kb=$(fs_avail_kb "$_dir")
		_free=$((${_free_kb:-0} * 1024))
		_old=0
		if [ -f "$CLASH_BIN" ]; then
			_old=$(wc -c < "$CLASH_BIN" | tr -d ' ')
		fi
		if [ "$_free" -ge $((_bytes + 1048576)) ]; then
			_stage="$_dir/.mihomo-new.$$"
			rm -f "$_stage"
			if ! $_gunzip "$_tmp_gz" > "$_stage"; then
				rm -f "$_stage" "$_tmp_gz"
				warn "Mihomo extraction failed — keeping existing kernel; install from Settings later"
				MIHOMO_STATUS="missing (extract failed)"
				return 0
			fi
			rm -f "$_tmp_gz"
			if ! chmod 755 "$_stage"; then
				rm -f "$_stage"
				MIHOMO_STATUS="missing (install failed)"
				return 0
			fi
			if ! "$_stage" -v >/dev/null 2>&1; then
				rm -f "$_stage"
				warn "Mihomo does not run on this host — keeping existing binary"
				MIHOMO_STATUS="missing (install failed)"
				return 0
			fi
			stop_ssclash_for_upgrade
			stop_bin_path "$CLASH_BIN"
			if ! mv -f "$_stage" "$CLASH_BIN"; then
				rm -f "$_stage"
				MIHOMO_STATUS="missing (install failed)"
				return 0
			fi
			chmod 755 "$CLASH_BIN"
		elif [ $((_free + _old)) -ge "$_bytes" ]; then
			warn "low space: replacing Mihomo in place (no second copy on flash)"
			stop_ssclash_for_upgrade
			stop_bin_path "$CLASH_BIN"
			rm -f "$CLASH_BIN"
			if ! $_gunzip "$_tmp_gz" > "$CLASH_BIN"; then
				rm -f "$CLASH_BIN" "$_tmp_gz"
				warn "Mihomo replace failed — binary missing until reinstall"
				MIHOMO_STATUS="missing (extract failed)"
				return 0
			fi
			rm -f "$_tmp_gz"
			if ! chmod 755 "$CLASH_BIN"; then
				rm -f "$CLASH_BIN"
				MIHOMO_STATUS="missing (install failed)"
				return 0
			fi
			if ! "$CLASH_BIN" -v >/dev/null 2>&1; then
				rm -f "$CLASH_BIN"
				warn "Mihomo does not run — removed the failed install"
				MIHOMO_STATUS="missing (install failed)"
				return 0
			fi
		else
			_need_mib=$(((_bytes + 1048575) / 1048576))
			_free_mib=$((_free / 1048576))
			warn "not enough free space for Mihomo (need about ${_need_mib} MiB, free ${_free_mib} MiB) — keeping existing binary"
			rm -f "$_tmp_gz"
			MIHOMO_STATUS="missing (install failed)"
			return 0
		fi
	fi
	rm -f "$ROOT/bin/meta-backup" 2>/dev/null || true

	MIHOMO_V=$("$CLASH_BIN" -v 2>/dev/null || true)
	say "Kernel installed (${KERNEL_TRACK}): ${MIHOMO_V:-ok}"
	MIHOMO_STATUS="installed (${MIHOMO_V:-$MIHOMO_VER})"
}

# ---- MAIN -------------------------------------------------------------------
parse_install_options "$@"
print_banner
if [ "$UI_PORT" != 9091 ]; then
	validate_ui_port
fi
apply_install_paths
[ "$(id -u)" = "0" ] || die "run as root"

_present=0
_healthy=0
if [ -e "$SSCLASH_BIN" ] || [ -e /etc/init.d/ssclash ]; then
	_present=1
fi
if [ -x "$SSCLASH_BIN" ] && [ -x /etc/init.d/ssclash ]; then
	_healthy=1
fi
prompt_install_action "$_present" "$_healthy"

if [ "$UPDATE" = 1 ]; then
	if [ -n "$UI_BIND$UI_ADDR$TLS_CERT$TLS_KEY" ] || [ "$TLS_SELF_SIGNED" = 1 ] || [ "$UI_PORT" != "9091" ] || [ "$ROOT_EXPLICIT" = 1 ]; then
		die "--update keeps address, TLS and install root; do not pass --port, --bind, --addr, --root or --tls-*"
	fi
	[ -x /etc/init.d/ssclash ] || die "--update: /etc/init.d/ssclash is missing; run a normal install"
	[ -x "$SSCLASH_BIN" ] || die "--update: $SSCLASH_BIN is missing; run a normal install"
fi

select_kernel_track

if [ "$UPDATE" != 1 ]; then
	prompt_ui_port
	prompt_tls_self_signed
	validate_ui_port
	finalize_ui_addr
	prepare_tls_certs
fi

detect_openwrt
ensure_fetcher
detect_arch

SSCLASH_WAS_ENABLED=0
if [ "$UPDATE" != 1 ] && [ -x /etc/init.d/ssclash ] && /etc/init.d/ssclash enabled 2>/dev/null; then
	SSCLASH_WAS_ENABLED=1
	info "service was enabled — will restore after upgrade"
fi
WAS_RUNNING=0
if pidof ssclash >/dev/null 2>&1; then
	WAS_RUNNING=1
fi

# Download release metadata and binaries while SSClash may still provide DNS/proxy.
# stop_ssclash_for_upgrade runs only inside install_bin / before kernel replace.
fetch_ssclash_release
if [ "$UPDATE" != 1 ]; then
	pkg_update
	install_deps
fi

install_ssclash
if [ "$UPDATE" != 1 ]; then
	install_service
	if [ "$SSCLASH_WAS_ENABLED" = "1" ]; then
		/etc/init.d/ssclash enable
	fi
fi

install_mihomo
assert_mihomo_ready

if [ "$UPDATE" = 1 ]; then
	_kept_addr=$(sed -n 's/^[[:space:]]*procd_set_param env SSCLASH_ADDR="\([^"]*\)".*/\1/p' /etc/init.d/ssclash | head -n 1)
	_kept_cert=$(sed -n 's/^[[:space:]]*procd_set_param env SSCLASH_TLS_CERT="\([^"]*\)".*/\1/p' /etc/init.d/ssclash | head -n 1)
	[ -n "$_kept_addr" ] && UI_ADDR="$_kept_addr"
	[ -n "$_kept_cert" ] && TLS_CERT="$_kept_cert"
	if [ "$WAS_RUNNING" = "1" ]; then
		/etc/init.d/ssclash start >/dev/null 2>&1 \
			|| warn "service start skipped — open the web UI and press Start"
	elif [ -f "$ROOT/.ssclash/enabled" ]; then
		# The daemon's own auto-start flag ($ROOT/.ssclash/enabled, written on
		# Start, cleared only by an explicit Stop): the proxy should be running,
		# so bring the service back even though it was down during the update.
		info "proxy auto-start flag present — starting service after update"
		/etc/init.d/ssclash start >/dev/null 2>&1 \
			|| warn "service start skipped — open the web UI and press Start"
	else
		say "service was not running — binary updated, service left stopped"
	fi
else
	/etc/init.d/ssclash enable
	/etc/init.d/ssclash start >/dev/null 2>&1 \
		|| warn "service start skipped — open the web UI and press Start"
fi

IP=$(openwrt_lan_ip)
print_install_summary "$IP"
