#!/bin/sh
# Kernel track selection: canonical ids, quiet default, flags, keep rule, asset names.
# Does not contact GitHub.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
FAILS=0

note_ok() { printf 'ok: %s\n' "$1"; }
note_fail() { printf 'FAIL: %s\n' "$1" >&2; FAILS=$((FAILS + 1)); }

extract_region() {
	awk -v a="$2" -v b="$3" '
		$0 == a { p = 1 }
		p { print }
		$0 == b { exit }
	' "$1"
}

extract_fn() {
	awk -v fn="$2" '
		$0 ~ "^" fn "\\(\\)" { p = 1 }
		p { print }
		p && /^}/ { exit }
	' "$1"
}

SCRIPTS="
$ROOT/packaging/linux/install-linux.sh
$ROOT/packaging/openwrt/install-openwrt.sh
$ROOT/packaging/keenetic/install-keenetic.sh
"

_first=""
for _script in $SCRIPTS; do
	_sel=$(extract_region "$_script" "# KERNEL-SELECT-BEGIN" "# KERNEL-SELECT-END")
	_asset=$(extract_region "$_script" "# KERNEL-ASSET-BEGIN" "# KERNEL-ASSET-END")
	if [ -z "$_first" ]; then
		_first_sel="$_sel"
		_first_asset="$_asset"
		_first=1
	else
		if [ "$_sel" = "$_first_sel" ]; then
			note_ok "${_script##*/} select block matches"
		else
			note_fail "${_script##*/} select block differs"
		fi
		if [ "$_asset" = "$_first_asset" ]; then
			note_ok "${_script##*/} asset block matches"
		else
			note_fail "${_script##*/} asset block differs"
		fi
	fi
done

LINUX="$ROOT/packaging/linux/install-linux.sh"
RUNNER=$(mktemp)
{
	printf '%s\n' '#!/bin/sh' 'set -eu'
	printf '%s\n' 'err() { printf "ERR %s\n" "$*" >&2; exit 1; }'
	printf '%s\n' 'die() { err "$@"; }'
	printf '%s\n' 'warn() { printf "WARN %s\n" "$*" >&2; }'
	printf '%s\n' 'info() { printf "INFO %s\n" "$*"; }'
	extract_fn "$LINUX" version_gt
	extract_region "$LINUX" "# KERNEL-SELECT-BEGIN" "# KERNEL-SELECT-END"
	extract_fn "$LINUX" has_cpu_flag
	extract_fn "$LINUX" amd64_mihomo_names
	extract_region "$LINUX" "# KERNEL-ASSET-BEGIN" "# KERNEL-ASSET-END"
	extract_fn "$LINUX" tty_ok
	extract_fn "$LINUX" prompt_tls_self_signed
} > "$RUNNER"
chmod +x "$RUNNER"

expect_eq() {
	_got=$1
	_want=$2
	_name=$3
	if [ "$_got" = "$_want" ]; then
		note_ok "$_name"
	else
		note_fail "$_name got [${_got}] want [${_want}]"
	fi
}

run_norm() {
	sh -c '. "$1"; normalize_kernel_track "$2"' sh "$RUNNER" "$1"
}

check_norm() {
	_in=$1
	_want=$2
	_got=$(run_norm "$_in") || { note_fail "normalize $_in failed"; return; }
	expect_eq "$_got" "$_want" "normalize [$_in]"
}

check_norm mihomo-stable mihomo-stable
check_norm mihomo-alpha mihomo-alpha
check_norm prizrak-core prizrak-core
check_norm prizrak-kroha prizrak-kroha
check_norm skip skip
check_norm keep keep
reject_norm() {
	_in=$1
	if sh -c '. "$1"; normalize_kernel_track "$2"' sh "$RUNNER" "$_in" >/dev/null 2>&1; then
		note_fail "normalize [$_in] should fail"
	else
		note_ok "normalize [$_in] rejected"
	fi
}
reject_norm stable
reject_norm alpha
reject_norm mihomo
reject_norm prizrak
reject_norm kroha
reject_norm none
reject_norm off
reject_norm MIHOMO-STABLE
reject_norm prizrak_core
reject_norm ' skip '
reject_norm latest

# Preset track skips the menu. No controlling terminal defaults by UPDATE.
_out=$(sh -c '. "$1"; KERNEL_TRACK=prizrak-core; select_kernel_track; printf "%s\n" "$KERNEL_TRACK"' sh "$RUNNER" </dev/null)
expect_eq "$_out" "prizrak-core" "preset track skips menu"
_out=$(python3 - "$RUNNER" <<'PY'
import subprocess, sys
r = subprocess.run(
    ["sh", "-c", '. "$1"; KERNEL_TRACK=; UPDATE=0; select_kernel_track; printf "%s\\n" "$KERNEL_TRACK"', "sh", sys.argv[1]],
    stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    start_new_session=True, timeout=3,
)
sys.stdout.write(r.stdout.decode())
PY
)
expect_eq "$_out" "mihomo-stable" "no TTY fresh defaults to mihomo-stable"
case "$_out" in
	*Choose\ a\ kernel*) note_fail "no TTY printed the kernel menu" ;;
	*) note_ok "no TTY skips the kernel menu" ;;
esac
_out=$(python3 - "$RUNNER" <<'PY'
import subprocess, sys
r = subprocess.run(
    ["sh", "-c", '. "$1"; KERNEL_TRACK=; UPDATE=1; select_kernel_track; printf "%s\\n" "$KERNEL_TRACK"', "sh", sys.argv[1]],
    stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    start_new_session=True, timeout=3,
)
sys.stdout.write(r.stdout.decode())
PY
)
expect_eq "$_out" "keep" "no TTY update defaults to keep"

# Tokens and keep rule.
_tok=$(sh -c '. "$1"; kernel_token_from_text "$2"' sh "$RUNNER" 'Mihomo Meta v1.19.21 linux')
expect_eq "$_tok" "v1.19.21" "plain token"
_tok=$(sh -c '. "$1"; kernel_token_from_text "$2"' sh "$RUNNER" 'Prizrak v1.19.34-r4 linux')
expect_eq "$_tok" "v1.19.34-r4" "prizrak token"
_tok=$(sh -c '. "$1"; kernel_token_from_text "$2"' sh "$RUNNER" 'Prizrak v1.19.34-r4-kroha linux')
expect_eq "$_tok" "v1.19.34-r4-kroha" "kroha token"
_tok=$(sh -c '. "$1"; kernel_token_from_text "$2"' sh "$RUNNER" 'Mihomo Meta alpha-abcdef1')
expect_eq "$_tok" "alpha-abcdef1" "alpha token"

keep_rc() {
	# 0 keep, 1 install
	if sh -c '. "$1"; kernel_should_keep "$2" "$3" "$4"' sh "$RUNNER" "$1" "$2" "$3"; then
		printf keep
	else
		printf install
	fi
}
expect_eq "$(keep_rc v1.19.21 v1.19.21 mihomo-stable)" keep "stable same token kept"
expect_eq "$(keep_rc v1.19.20 v1.19.21 mihomo-stable)" install "stable older installs"
expect_eq "$(keep_rc v1.19.22 v1.19.21 mihomo-stable)" keep "stable newer kept"
expect_eq "$(keep_rc v1.19.21 v1.19.21-r4 prizrak-core)" install "stable binary vs prizrak installs"
expect_eq "$(keep_rc v1.19.34-r4 v1.19.34-r4 prizrak-core)" keep "prizrak same revision kept"
expect_eq "$(keep_rc v1.19.34-r3 v1.19.34-r4 prizrak-core)" install "prizrak other revision installs"
expect_eq "$(keep_rc v1.19.34-r4 v1.19.34-r4-kroha prizrak-kroha)" install "full prizrak vs kroha installs"
expect_eq "$(keep_rc v1.19.34-r4-kroha v1.19.34-r4-kroha prizrak-kroha)" keep "kroha same token kept"
expect_eq "$(keep_rc alpha-aaaaaaa alpha-bbbbbbb mihomo-alpha)" install "alpha hash change installs"
expect_eq "$(keep_rc '' v1.19.21 mihomo-stable)" install "missing binary installs"

_rel=$(sh -c '. "$1"; kernel_release_token prizrak-kroha v1.19.34-r4 ""' sh "$RUNNER")
expect_eq "$_rel" "v1.19.34-r4-kroha" "kroha release token"
if sh -c '. "$1"; kernel_release_token prizrak-core v1.19.34 ""' sh "$RUNNER" >/dev/null 2>&1; then
	note_fail "plain tag accepted as prizrak-core"
else
	note_ok "plain tag rejected for prizrak-core"
fi
_rel=$(sh -c '. "$1"; kernel_release_token mihomo-alpha Prerelease-Alpha "$2"' sh "$RUNNER" 'mihomo-linux-arm64-alpha-abcDEF0.gz')
expect_eq "$_rel" "alpha-abcdef0" "alpha release token"

# Asset pick from a fixture JSON. arm64 avoids the host CPU ladder.
JSON=$(cat <<'EOF'
{
  "tag_name": "v1.19.34-r4",
  "assets": [
    {"name": "mihomo-linux-arm64-v1.19.21.gz", "browser_download_url": "https://example/mihomo-linux-arm64-v1.19.21.gz"},
    {"name": "prizrak-core-linux-loong64-abi1-v1.19.34-r4.gz", "browser_download_url": "https://example/prizrak-core-linux-loong64-abi1-v1.19.34-r4.gz"},
    {"name": "prizrak-core-linux-loong64-abi2-v1.19.34-r4.gz", "browser_download_url": "https://example/prizrak-core-linux-loong64-abi2-v1.19.34-r4.gz"},
    {"name": "prizrak-kroha-linux-arm64-compressed-v1.19.34-r4.gz", "browser_download_url": "https://example/prizrak-kroha-linux-arm64-compressed-v1.19.34-r4.gz"},
    {"name": "prizrak-kroha-linux-amd64-v1-v1.19.34-r4.gz", "browser_download_url": "https://example/prizrak-kroha-linux-amd64-v1-v1.19.34-r4.gz"},
    {"name": "mihomo-linux-arm64-alpha-zz.gz", "browser_download_url": "https://example/mihomo-linux-arm64-alpha-zz.gz"},
    {"name": "mihomo-linux-arm64-alpha-abcdef0.gz", "browser_download_url": "https://example/mihomo-linux-arm64-alpha-abcdef0.gz"}
  ]
}
EOF
)

pick() {
	sh -c '. "$1"; MIHOMO_JSON=$2; kernel_gzip_url "$3" "$4" "$5" "$6" "$7"' \
		sh "$RUNNER" "$JSON" "$1" "$2" "$3" "$4" "$5"
}
_url=$(pick mihomo v1.19.21 arm64 1 0)
expect_eq "$_url" "https://example/mihomo-linux-arm64-v1.19.21.gz" "stable arm64 url"
_url=$(pick prizrak-core v1.19.34-r4 loong64 1 0)
expect_eq "$_url" "https://example/prizrak-core-linux-loong64-abi2-v1.19.34-r4.gz" "prizrak loong abi2 before abi1"
_url=$(pick prizrak-kroha v1.19.34-r4 arm64 0 1)
expect_eq "$_url" "https://example/prizrak-kroha-linux-arm64-compressed-v1.19.34-r4.gz" "kroha plain missing uses compressed"
if pick prizrak-kroha v1.19.34-r4 amd64 0 1 >/dev/null 2>&1; then
	note_fail "kroha amd64 picked a leveled asset"
else
	note_ok "kroha amd64 ignores the v1 ladder"
fi
_url=$(sh -c '. "$1"; MIHOMO_JSON=$2; kernel_alpha_url arm64' sh "$RUNNER" "$JSON")
expect_eq "$_url" "https://example/mihomo-linux-arm64-alpha-abcdef0.gz" "alpha arm64 hash url"

# Flag parse from each installer. Invalid dies. Accepted values set KERNEL_TRACK.
parse_flags() {
	_script=$1
	shift
	_body=$(mktemp)
	{
		printf '%s\n' '#!/bin/sh' 'set -eu' 'KERNEL_TRACK='
		printf '%s\n' 'err() { printf "ERR %s\n" "$*" >&2; exit 1; }' 'die() { err "$@"; }'
		extract_region "$LINUX" "# KERNEL-SELECT-BEGIN" "# KERNEL-SELECT-END"
		case "$_script" in
			*openwrt*)
				extract_fn "$_script" parse_install_options
				printf '%s\n' 'parse_install_options "$@"'
				;;
			*)
				awk '
					/while \[ \$# -gt 0 \]/ { p = 1 }
					p { print }
					p && /^done$/ { exit }
				' "$_script"
				;;
		esac
		printf '%s\n' 'printf "%s\n" "$KERNEL_TRACK"'
	} > "$_body"
	sh "$_body" "$@"
	_rc=$?
	rm -f "$_body"
	return $_rc
}

expect_eq "$(parse_flags "$LINUX" --kernel=prizrak-kroha)" "prizrak-kroha" "linux --kernel=prizrak-kroha"
expect_eq "$(parse_flags "$LINUX" --kernel mihomo-alpha)" "mihomo-alpha" "linux --kernel mihomo-alpha"
expect_eq "$(parse_flags "$LINUX" --kernel=mihomo-stable)" "mihomo-stable" "linux --kernel=mihomo-stable"
expect_eq "$(parse_flags "$LINUX" --kernel=prizrak-core)" "prizrak-core" "linux --kernel=prizrak-core"
expect_eq "$(parse_flags "$LINUX" --kernel=skip)" "skip" "linux --kernel=skip"
expect_eq "$(parse_flags "$LINUX" --kernel=keep)" "keep" "linux --kernel=keep"
reject_flags() {
	_script=$1
	shift
	if parse_flags "$_script" "$@" >/dev/null 2>&1; then
		note_fail "$_script accepted $*"
	else
		note_ok "$_script rejects $*"
	fi
}
reject_flags "$LINUX" --kernel=nope
reject_flags "$LINUX" --kernel=stable
reject_flags "$LINUX" --kernel=kroha
reject_flags "$LINUX" --kernel=none
reject_flags "$LINUX" --no-mihomo
expect_eq "$(parse_flags "$ROOT/packaging/openwrt/install-openwrt.sh" --kernel=mihomo-stable)" "mihomo-stable" "openwrt --kernel=mihomo-stable"
reject_flags "$ROOT/packaging/openwrt/install-openwrt.sh" --kernel=kroha
reject_flags "$ROOT/packaging/openwrt/install-openwrt.sh" --no-mihomo
expect_eq "$(parse_flags "$ROOT/packaging/keenetic/install-keenetic.sh" --kernel=skip)" "skip" "keenetic --kernel=skip"
reject_flags "$ROOT/packaging/keenetic/install-keenetic.sh" --kernel=none

# Real argv on the two installers that parse before any root check.
for _script in "$LINUX" "$ROOT/packaging/keenetic/install-keenetic.sh"; do
	_name=${_script##*/}
	if sh "$_script" --kernel=prizrak-kroha >/tmp/ssclash-kernel-ok.out 2>/tmp/ssclash-kernel-ok.err; then
		note_fail "$_name --kernel=prizrak-kroha exited 0"
	else
		if grep -q 'unknown --kernel' /tmp/ssclash-kernel-ok.err; then
			note_fail "$_name rejected prizrak-kroha"
		else
			note_ok "$_name accepts --kernel=prizrak-kroha"
		fi
	fi
	if sh "$_script" --kernel=nope >/dev/null 2>/tmp/ssclash-kernel-bad.err; then
		note_fail "$_name --kernel=nope exited 0"
	elif grep -q 'unknown --kernel: nope' /tmp/ssclash-kernel-bad.err; then
		note_ok "$_name --kernel=nope dies clearly"
	else
		note_fail "$_name --kernel=nope error was $(cat /tmp/ssclash-kernel-bad.err)"
	fi
	if sh "$_script" --kernel=stable >/dev/null 2>/tmp/ssclash-kernel-bad.err; then
		note_fail "$_name --kernel=stable exited 0"
	elif grep -q 'unknown --kernel: stable' /tmp/ssclash-kernel-bad.err; then
		note_ok "$_name --kernel=stable dies clearly"
	else
		note_fail "$_name --kernel=stable error was $(cat /tmp/ssclash-kernel-bad.err)"
	fi
	if sh "$_script" --no-mihomo >/dev/null 2>/tmp/ssclash-kernel-bad.err; then
		note_fail "$_name --no-mihomo exited 0"
	elif grep -q 'Unknown option: --no-mihomo' /tmp/ssclash-kernel-bad.err; then
		note_ok "$_name --no-mihomo is an unknown option"
	else
		note_fail "$_name --no-mihomo error was $(cat /tmp/ssclash-kernel-bad.err)"
	fi
	_help=$(sh "$_script" --help 2>/dev/null || true)
	if printf '%s\n' "$_help" | grep -q -- '--kernel'; then
		note_ok "$_name --help lists --kernel"
	else
		note_fail "$_name --help missing --kernel"
	fi
	if printf '%s\n' "$_help" | grep -q 'mihomo-stable'; then
		note_ok "$_name --help lists mihomo-stable"
	else
		note_fail "$_name --help missing mihomo-stable"
	fi
	if printf '%s\n' "$_help" | grep -q -- '--no-mihomo'; then
		note_fail "$_name --help still lists --no-mihomo"
	else
		note_ok "$_name --help omits --no-mihomo"
	fi
done

_b=$(mktemp)
{
	printf '%s\n' '#!/bin/sh' 'set -eu'
	extract_fn "$LINUX" print_banner
} > "$_b"
_banner=$(sh -c '. "$1"; print_banner' sh "$_b")
rm -f "$_b"
_flat=$(printf '%s' "$_banner" | tr '\n' ' ')
case "$_flat" in
	*'SSClash-Go'*'by ZeroChaos'*'https://zerolab.net'*) note_ok "banner names the product" ;;
	*) note_fail "banner was [$_flat]" ;;
esac
case "$_flat" in
	*[Gg]it[Hh]ub*|zerolabnet*) note_fail "banner mentions a forge or zerolabnet" ;;
	*) note_ok "banner omits the forge" ;;
esac

# TTY menu. Fresh empty is mihomo-stable. Update empty is keep.
if command -v python3 >/dev/null 2>&1; then
	_menu=$(python3 - "$RUNNER" <<'PY'
import os, pty, select, sys
runner = sys.argv[1]
def drive(cmd, payload):
    pid, fd = pty.fork()
    if pid == 0:
        os.execv("/bin/sh", ["sh", "-c", cmd, "sh", runner])
    buf = b""
    if payload:
        os.write(fd, payload)
    while True:
        r, _, _ = select.select([fd], [], [], 3)
        if not r:
            break
        chunk = os.read(fd, 4096)
        if not chunk:
            break
        buf += chunk
    os.waitpid(pid, 0)
    os.close(fd)
    return buf.decode("utf-8", "replace")
fresh = '. "$1"; KERNEL_TRACK=; UPDATE=0; select_kernel_track; printf "TRACK=%s\\n" "$KERNEL_TRACK"'
upd = '. "$1"; KERNEL_TRACK=; UPDATE=1; select_kernel_track; printf "TRACK=%s\\n" "$KERNEL_TRACK"'
empty = drive(fresh, b"\n")
invalid = drive(fresh, b"9\n4\n")
upd_empty = drive(upd, b"\n")
upd_stable = drive(upd, b"2\n")
preset = drive('. "$1"; KERNEL_TRACK=mihomo-alpha; UPDATE=0; select_kernel_track; printf "TRACK=%s\\n" "$KERNEL_TRACK"', b"")
tls = drive(
    '. "$1"; UPDATE=0; TLS_SELF_SIGNED=0; TLS_CERT=; TLS_KEY=; prompt_tls_self_signed; printf "TLS=%s\\n" "$TLS_SELF_SIGNED"',
    b"2\n",
)
sys.stdout.write(empty.split("TRACK=")[-1].strip() + "\n")
sys.stdout.write(("menu" if "1) mihomo-stable" in empty else "no-menu") + "\n")
sys.stdout.write(("reprompt" if "Invalid choice" in invalid else "no-reprompt") + "\n")
sys.stdout.write(invalid.split("TRACK=")[-1].strip() + "\n")
sys.stdout.write(upd_empty.split("TRACK=")[-1].strip() + "\n")
sys.stdout.write(("upd-menu" if "1) keep current" in upd_empty else "no-upd-menu") + "\n")
sys.stdout.write(upd_stable.split("TRACK=")[-1].strip() + "\n")
sys.stdout.write(preset.split("TRACK=")[-1].strip() + "\n")
sys.stdout.write(("preset-menu" if "Choose a kernel:" in preset else "preset-quiet") + "\n")
sys.stdout.write(("forge" if ("github" in empty.lower() or "zerolabnet" in empty.lower()) else "clean") + "\n")
sys.stdout.write(tls.split("TLS=")[-1].strip() + "\n")
PY
)
	_empty=$(printf '%s\n' "$_menu" | sed -n '1p')
	_banner=$(printf '%s\n' "$_menu" | sed -n '2p')
	_re=$(printf '%s\n' "$_menu" | sed -n '3p')
	_kroha=$(printf '%s\n' "$_menu" | sed -n '4p')
	_upd=$(printf '%s\n' "$_menu" | sed -n '5p')
	_upd_menu=$(printf '%s\n' "$_menu" | sed -n '6p')
	_upd_stable=$(printf '%s\n' "$_menu" | sed -n '7p')
	_preset=$(printf '%s\n' "$_menu" | sed -n '8p')
	_quiet=$(printf '%s\n' "$_menu" | sed -n '9p')
	_clean=$(printf '%s\n' "$_menu" | sed -n '10p')
	_tls=$(printf '%s\n' "$_menu" | sed -n '11p')
	expect_eq "$_empty" "mihomo-stable" "tty fresh empty is mihomo-stable"
	expect_eq "$_banner" "menu" "tty prints the kernel menu"
	expect_eq "$_re" "reprompt" "tty invalid choice re-prompts"
	expect_eq "$_kroha" "prizrak-kroha" "tty fresh choice 4 is prizrak-kroha"
	expect_eq "$_upd" "keep" "tty update empty is keep"
	expect_eq "$_upd_menu" "upd-menu" "tty update menu offers keep current"
	expect_eq "$_upd_stable" "mihomo-stable" "tty update choice 2 is mihomo-stable"
	expect_eq "$_preset" "mihomo-alpha" "tty preset stays mihomo-alpha"
	expect_eq "$_quiet" "preset-quiet" "tty preset skips the kernel menu"
	expect_eq "$_clean" "clean" "tty menu omits the forge"
	expect_eq "$_tls" "1" "tty TLS yes sets TLS_SELF_SIGNED"
else
	note_fail "python3 missing, tty menu not exercised"
fi

rm -f "$RUNNER" /tmp/ssclash-kernel-ok.out /tmp/ssclash-kernel-ok.err /tmp/ssclash-kernel-bad.err
printf 'kernel-track-fixture: %s checks failed\n' "$FAILS"
[ "$FAILS" -eq 0 ]
