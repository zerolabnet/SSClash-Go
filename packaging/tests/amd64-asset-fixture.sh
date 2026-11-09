#!/bin/sh
# amd64_mihomo_names must not offer the unsuffixed v3 build to an older CPU.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
FAILS=0

note_ok() { printf 'ok: %s\n' "$1"; }
note_fail() { printf 'FAIL: %s\n' "$1" >&2; FAILS=$((FAILS + 1)); }

extract_fn() {
	awk -v fn="$2" '
		$0 ~ "^" fn "\\(\\)" { p = 1 }
		p { print }
		p && /^}/ { exit }
	' "$1"
}

V2="cx16 lahf_lm popcnt pni sse4_1 sse4_2 ssse3"
V3="$V2 avx avx2 bmi1 bmi2 f16c fma abm movbe osxsave"

for _script in \
	"$ROOT/packaging/linux/install-linux.sh" \
	"$ROOT/packaging/openwrt/install-openwrt.sh" \
	"$ROOT/packaging/keenetic/install-keenetic.sh"
do
	_name=${_script##*/}
	_runner=$(mktemp)
	{
		printf '%s\n' '#!/bin/sh' 'set -eu'
		extract_fn "$_script" has_cpu_flag
		extract_fn "$_script" amd64_mihomo_names
		printf '%s\n' 'amd64_mihomo_names "$1" "$2"'
	} > "$_runner"
	_base=$(sh "$_runner" v1.19.33 "fpu sse2")
	_v2=$(sh "$_runner" v1.19.33 "$V2")
	_v3=$(sh "$_runner" v1.19.33 "$V3")
	rm -f "$_runner"
	case "$_base" in
		mihomo-linux-amd64-v1-v1.19.33.gz*) note_ok "$_name baseline starts at v1" ;;
		*) note_fail "$_name baseline was ${_base}" ;;
	esac
	case " $_base " in
		*" mihomo-linux-amd64-v3-"*|*" mihomo-linux-amd64-v2-"*) note_fail "$_name baseline offered a newer level" ;;
		*) note_ok "$_name baseline skips v2 and v3" ;;
	esac
	case "$_v2" in
		mihomo-linux-amd64-v2-v1.19.33.gz*) note_ok "$_name v2 starts at v2" ;;
		*) note_fail "$_name v2 was ${_v2}" ;;
	esac
	case " $_v2 " in
		*" mihomo-linux-amd64-v3-"*) note_fail "$_name v2 offered v3" ;;
		*) note_ok "$_name v2 skips v3" ;;
	esac
	case "$_v3" in
		mihomo-linux-amd64-v3-v1.19.33.gz*) note_ok "$_name v3 starts at v3" ;;
		*) note_fail "$_name v3 was ${_v3}" ;;
	esac
done

[ "$FAILS" -eq 0 ]
