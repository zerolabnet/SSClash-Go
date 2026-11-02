#!/bin/sh
# check_sha256sum accepts a matching sha256sums.txt line and rejects a mismatch.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
FAILS=0
ASSET=ssclash-linux-amd64

note_ok() {
	printf 'ok: %s\n' "$1"
}

note_fail() {
	printf 'FAIL: %s\n' "$1" >&2
	FAILS=$((FAILS + 1))
}

extract_fn() {
	awk '
		/^check_sha256sum\(\)/ { p = 1 }
		p { print }
		p && /^}/ { exit }
	' "$1"
}

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT INT TERM

printf 'ssclash fixture\n' > "$WORKDIR/$ASSET"
command -v openssl >/dev/null 2>&1 || {
	printf 'FAIL: openssl is required to build the fixture digest\n' >&2
	exit 1
}
GOOD=$(openssl dgst -sha256 "$WORKDIR/$ASSET" | awk 'NR==1 { print tolower($NF); exit }')
_glen=$(printf '%s' "$GOOD" | wc -c | tr -d ' ')
[ "${_glen:-0}" -eq 64 ] || {
	printf 'FAIL: openssl digest length %s\n' "${_glen:-0}" >&2
	exit 1
}
case "$GOOD" in
	*[!0-9a-f]*)
		printf 'FAIL: openssl digest is not hex\n' >&2
		exit 1
		;;
esac

_lead=$(printf '%s' "$GOOD" | cut -c1)
if [ "$_lead" = "0" ]; then
	_lead=1
else
	_lead=0
fi
BAD="${_lead}$(printf '%s' "$GOOD" | cut -c2-)"

{
	printf '%s  ssclash-linux-arm64\n' "$BAD"
	printf '%s  %s\n' "$GOOD" "$ASSET"
	printf '%s  ssclash-linux-386\n' "$BAD"
} > "$WORKDIR/good.txt"

{
	printf '%s  ssclash-linux-arm64\n' "$GOOD"
	printf '%s  %s\n' "$BAD" "$ASSET"
	printf '%s  ssclash-linux-386\n' "$GOOD"
} > "$WORKDIR/bad.txt"

printf '%s *%s\n' "$GOOD" "$ASSET" > "$WORKDIR/star.txt"
printf '%s  %s\n' "$(printf '%s' "$GOOD" | tr 'a-f' 'A-F')" "$ASSET" > "$WORKDIR/upper.txt"

if command -v shasum >/dev/null 2>&1; then
	(
		cd "$WORKDIR"
		shasum -a 256 "$ASSET" > shasum.txt
	)
fi

run_check() {
	_script=$1
	_sums=$2
	_runner=$WORKDIR/runner.sh
	{
		printf '%s\n' '#!/bin/sh' 'set -eu'
		extract_fn "$_script"
		printf '%s\n' 'check_sha256sum "$1" "$2" "$3"'
	} > "$_runner"
	sh "$_runner" "$WORKDIR/$ASSET" "$ASSET" "$_sums"
}

for _script in \
	"$ROOT/packaging/linux/install-linux.sh" \
	"$ROOT/packaging/openwrt/install-openwrt.sh" \
	"$ROOT/packaging/keenetic/install-keenetic.sh"
do
	_name=${_script##*/}
	if run_check "$_script" "$WORKDIR/good.txt"; then
		note_ok "$_name accepted a good sum"
	else
		note_fail "$_name rejected a good sum"
	fi
	if run_check "$_script" "$WORKDIR/bad.txt"; then
		note_fail "$_name accepted a bad sum"
	else
		note_ok "$_name rejected a bad sum"
	fi
	if run_check "$_script" "$WORKDIR/star.txt"; then
		note_ok "$_name accepted *name"
	else
		note_fail "$_name rejected *name"
	fi
	if run_check "$_script" "$WORKDIR/upper.txt"; then
		note_ok "$_name accepted uppercase hex"
	else
		note_fail "$_name rejected uppercase hex"
	fi
	if [ -f "$WORKDIR/shasum.txt" ]; then
		if run_check "$_script" "$WORKDIR/shasum.txt"; then
			note_ok "$_name accepted shasum -a 256 output"
		else
			note_fail "$_name rejected shasum -a 256 output"
		fi
	fi
done

[ "$FAILS" -eq 0 ]
