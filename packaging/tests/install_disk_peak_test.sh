#!/bin/sh
# Disk-peak contract for the installers' binary replace.
# Runs install_checked_bin from each installer. decide() is the same table
# the Mihomo stream path uses.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
FAILS=0
MARGIN=1048576
# Measured uncompressed size of mihomo-linux-arm64-v1.19.33.gz.
MIHOMO_BYTES=57475198

# Stream-to-dest keeps one uncompressed Mihomo on the install filesystem.
# Staging asks for free >= bytes + 1 MiB. In-place asks for free + old >= bytes.
# A second uncompressed copy (free >= 2 * bytes) is not required.
decide() {
	_free=$1
	_old=$2
	_bytes=$3
	if [ "$_free" -ge $((_bytes + MARGIN)) ]; then
		printf 'stage\n'
		return 0
	fi
	if [ $((_free + _old)) -ge "$_bytes" ]; then
		printf 'inplace\n'
		return 0
	fi
	printf 'fail\n'
}

note_ok() {
	printf 'ok: %s\n' "$1"
}

note_fail() {
	printf 'FAIL: %s\n' "$1" >&2
	FAILS=$((FAILS + 1))
}

assert_eq() {
	if [ "$1" = "$2" ]; then
		note_ok "$3"
	else
		note_fail "$3 (got [$1] want [$2])"
	fi
}

extract_fn() {
	awk '
		/^install_checked_bin\(\)/ { p = 1 }
		p { print }
		p && /^}/ { exit }
	' "$1"
}

write_fixture() {
	_path=$1
	cat > "$_path" <<'EOF'
#!/bin/sh
if [ "$1" = "-v" ]; then
	printf '%s\n' "$0" >> "${VERIFY_LOG:?}"
	if [ "${VERIFY_MODE:-}" = "reject" ]; then
		exit 1
	fi
	case "$0" in
		*/dl/*) exit 1 ;;
	esac
	exit 0
fi
exit 0
EOF
	chmod 755 "$_path"
}

run_checked() {
	_body=$1
	_free_kb=$2
	_noexec_rc=$3
	_src=$4
	_dst=$5
	_rc=0
	(
		set -eu
		FAKE_FREE_KB=$_free_kb
		PATH_NOEXEC_RC=$_noexec_rc
		export VERIFY_LOG VERIFY_MODE
		fs_avail_kb() { printf '%s\n' "$FAKE_FREE_KB"; }
		path_noexec() { return "$PATH_NOEXEC_RC"; }
		stop_ssclash_for_upgrade() { :; }
		stop_bin_path() { :; }
		warn() { printf 'warn: %s\n' "$*" >&2; }
		# The extracted installer function is the code under test.
		eval "$_body"
		install_checked_bin "$_src" "$_dst" 755 Mihomo 1
	) || _rc=$?
	printf '%s\n' "$_rc"
}

no_stage_left() {
	_dir=$1
	_hit=0
	for _f in "$_dir"/.mihomo-new.*; do
		if [ -e "$_f" ]; then
			_hit=1
		fi
	done
	[ "$_hit" = "0" ]
}

check_peak() {
	_twice=$((MIHOMO_BYTES * 2))
	_free58=$((58 * 1024 * 1024))
	assert_eq "$(decide "$MIHOMO_BYTES" 0 "$MIHOMO_BYTES")" inplace \
		"one uncompressed image fits in place and does not need 2 * bytes ($_twice)"
	assert_eq "$(decide $((MIHOMO_BYTES - 1)) 0 "$MIHOMO_BYTES")" fail \
		"one byte under the image does not fit when nothing can be removed"
	assert_eq "$(decide "$_free58" 0 "$MIHOMO_BYTES")" stage \
		"58 MiB free ($_free58) stages one $MIHOMO_BYTES-byte image"
	if [ "$_free58" -lt "$_twice" ]; then
		note_ok "58 MiB free is below 2 * uncompressed ($_twice)"
	else
		note_fail "58 MiB free is not below 2 * uncompressed"
	fi
	assert_eq "$(decide $((MIHOMO_BYTES + MARGIN - 1)) "$MIHOMO_BYTES" "$MIHOMO_BYTES")" inplace \
		"free + old covers the image inside the staging margin"
	assert_eq "$(decide $((MIHOMO_BYTES + MARGIN)) 0 "$MIHOMO_BYTES")" stage \
		"free at bytes + 1 MiB stages"
}

check_script() {
	_name=$1
	_path=$2
	_body=$(extract_fn "$_path")
	if ! printf '%s\n' "$_body" | grep -q '^install_checked_bin()'; then
		note_fail "$_name: could not extract install_checked_bin"
		return 0
	fi

	_case=$TMP/$_name
	rm -rf "$_case"
	mkdir -p "$_case/dl" "$_case/inst"
	write_fixture "$_case/dl/mihomo"
	_src=$_case/dl/mihomo
	_dst=$_case/inst/clash
	_bytes=$(wc -c < "$_src" | tr -d ' ')

	# Detected noexec, no old file. free covers the image and not the 1 MiB margin.
	_free_kb=$(( (_bytes + 1023) / 1024 ))
	_free=$((_free_kb * 1024))
	: > "$VERIFY_LOG"
	VERIFY_MODE=
	_rc=$(run_checked "$_body" "$_free_kb" 0 "$_src" "$_dst")
	assert_eq "$(decide "$_free" 0 "$_bytes")" inplace "$_name decide tight noexec"
	assert_eq "$_rc" 0 "$_name noexec tight install exits 0"
	if cmp -s "$_src" "$_dst"; then
		note_ok "$_name noexec tight dest matches source"
	else
		note_fail "$_name noexec tight dest mismatch"
	fi
	if grep -Fxq "$_dst" "$VERIFY_LOG"; then
		note_ok "$_name noexec tight verified on dest"
	else
		note_fail "$_name noexec tight did not verify on dest"
	fi
	if grep -Fxq "$_src" "$VERIFY_LOG"; then
		note_fail "$_name noexec tight ran -v in the download directory"
	else
		note_ok "$_name noexec tight skipped -v in the download directory"
	fi

	# Download directory cannot run -v. free + old covers bytes + 1 MiB, free does not.
	# The old early return rejected this before the in-place path.
	rm -f "$_dst"
	dd if=/dev/zero of="$_dst" bs="$((_bytes + MARGIN))" count=1 2>/dev/null
	_old=$(wc -c < "$_dst" | tr -d ' ')
	: > "$VERIFY_LOG"
	VERIFY_MODE=
	_rc=$(run_checked "$_body" 0 1 "$_src" "$_dst")
	assert_eq "$(decide 0 "$_old" "$_bytes")" inplace "$_name decide src-rejected in-place"
	assert_eq "$_rc" 0 "$_name src-rejected in-place exits 0"
	if cmp -s "$_src" "$_dst"; then
		note_ok "$_name src-rejected dest matches source"
	else
		note_fail "$_name src-rejected dest mismatch"
	fi
	if grep -Fxq "$_dst" "$VERIFY_LOG"; then
		note_ok "$_name src-rejected verified on dest"
	else
		note_fail "$_name src-rejected did not verify on dest"
	fi

	# Room for a second file: stage, verify, mv.
	rm -f "$_dst"
	printf 'old-kernel\n' > "$_dst"
	_free_kb=$(( (_bytes + MARGIN + 1023) / 1024 ))
	_free=$((_free_kb * 1024))
	_old=$(wc -c < "$_dst" | tr -d ' ')
	: > "$VERIFY_LOG"
	VERIFY_MODE=
	_rc=$(run_checked "$_body" "$_free_kb" 1 "$_src" "$_dst")
	assert_eq "$(decide "$_free" "$_old" "$_bytes")" stage "$_name decide stage"
	assert_eq "$_rc" 0 "$_name stage exits 0"
	if cmp -s "$_src" "$_dst"; then
		note_ok "$_name stage dest matches source"
	else
		note_fail "$_name stage dest mismatch"
	fi
	if no_stage_left "$_case/inst"; then
		note_ok "$_name stage left no .mihomo-new.*"
	else
		note_fail "$_name stage left .mihomo-new.*"
	fi

	# A bad new binary must not replace a working one when staging fits.
	printf 'keep-me\n' > "$_dst"
	cp "$_dst" "$_case/keep"
	: > "$VERIFY_LOG"
	VERIFY_MODE=reject
	_rc=$(run_checked "$_body" "$_free_kb" 1 "$_src" "$_dst")
	assert_eq "$_rc" 1 "$_name stage verify failure exits 1"
	if cmp -s "$_case/keep" "$_dst"; then
		note_ok "$_name stage verify failure kept the old binary"
	else
		note_fail "$_name stage verify failure lost the old binary"
	fi
	if no_stage_left "$_case/inst"; then
		note_ok "$_name stage verify failure left no .mihomo-new.*"
	else
		note_fail "$_name stage verify failure left .mihomo-new.*"
	fi

	# Not enough room even after removing the old file.
	rm -f "$_dst"
	if [ "$_bytes" -gt 1 ]; then
		dd if=/dev/zero of="$_dst" bs="$((_bytes - 1))" count=1 2>/dev/null
	else
		: > "$_dst"
	fi
	cp "$_dst" "$_case/keep"
	_old=$(wc -c < "$_dst" | tr -d ' ')
	: > "$VERIFY_LOG"
	VERIFY_MODE=
	_rc=$(run_checked "$_body" 0 1 "$_src" "$_dst")
	assert_eq "$(decide 0 "$_old" "$_bytes")" fail "$_name decide no space"
	if [ "$_rc" -ne 0 ]; then
		note_ok "$_name no space exits non-zero"
	else
		note_fail "$_name no space exited 0"
	fi
	if cmp -s "$_case/keep" "$_dst"; then
		note_ok "$_name no space kept the old binary"
	else
		note_fail "$_name no space changed the old binary"
	fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM
VERIFY_LOG=$TMP/verify.log
VERIFY_MODE=
export VERIFY_LOG VERIFY_MODE
: > "$VERIFY_LOG"

check_peak

_ow=$ROOT/packaging/openwrt/install-openwrt.sh
_ke=$ROOT/packaging/keenetic/install-keenetic.sh
_li=$ROOT/packaging/linux/install-linux.sh
_ow_fn=$TMP/openwrt.fn
_ke_fn=$TMP/keenetic.fn
_li_fn=$TMP/linux.fn
extract_fn "$_ow" > "$_ow_fn"
extract_fn "$_ke" > "$_ke_fn"
extract_fn "$_li" > "$_li_fn"
if cmp -s "$_ow_fn" "$_ke_fn" && cmp -s "$_ow_fn" "$_li_fn"; then
	note_ok "install_checked_bin matches across openwrt, keenetic, and linux"
else
	note_fail "install_checked_bin drifted across installers"
fi

check_script openwrt "$_ow"
check_script keenetic "$_ke"
check_script linux "$_li"

if [ "$FAILS" -ne 0 ]; then
	printf '%s failing checks\n' "$FAILS" >&2
	exit 1
fi
printf 'all checks passed\n'
