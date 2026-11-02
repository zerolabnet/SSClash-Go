#!/bin/sh
# check_sha256 compares a file to a GitHub asset digest. asset_digest reads that field.
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
	awk -v fn="$2" '
		$0 ~ "^" fn "\\(\\)" { p = 1 }
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
UPPER=$(printf '%s' "$GOOD" | tr 'a-f' 'A-F')

JSON=$(printf '%s\n' \
	'{' \
	'  "assets": [' \
	'    {"name": "other.bin", "digest": "sha256:'"$BAD"'"},' \
	'    {' \
	'      "name": "'"$ASSET"'",' \
	'      "browser_download_url": "https://example/'"$ASSET"'",' \
	'      "digest": "sha256:'"$GOOD"'"' \
	'    }' \
	'  ]' \
	'}')
NO_DIGEST=$(printf '%s\n' \
	'{"assets":[{"name":"'"$ASSET"'","browser_download_url":"https://example/'"$ASSET"'"}]}')

run_hash() {
	_script=$1
	_want=$2
	_runner=$WORKDIR/runner.sh
	{
		printf '%s\n' '#!/bin/sh' 'set -eu'
		extract_fn "$_script" check_sha256
		printf '%s\n' 'check_sha256 "$1" "$2"'
	} > "$_runner"
	sh "$_runner" "$WORKDIR/$ASSET" "$_want"
}

run_digest() {
	_script=$1
	_json=$2
	_asset_name=$3
	_runner=$WORKDIR/digest.sh
	{
		printf '%s\n' '#!/bin/sh' 'set -eu'
		extract_fn "$_script" asset_digest
		printf '%s\n' 'asset_digest "$1" "$2"'
	} > "$_runner"
	sh "$_runner" "$_json" "$_asset_name"
}

for _script in \
	"$ROOT/packaging/linux/install-linux.sh" \
	"$ROOT/packaging/openwrt/install-openwrt.sh" \
	"$ROOT/packaging/keenetic/install-keenetic.sh"
do
	_name=${_script##*/}
	if run_hash "$_script" "$GOOD"; then
		note_ok "$_name accepted a good digest"
	else
		note_fail "$_name rejected a good digest"
	fi
	if run_hash "$_script" "$BAD"; then
		note_fail "$_name accepted a bad digest"
	else
		note_ok "$_name rejected a bad digest"
	fi
	if run_hash "$_script" "$UPPER"; then
		note_ok "$_name accepted uppercase hex"
	else
		note_fail "$_name rejected uppercase hex"
	fi
	_got=$(run_digest "$_script" "$JSON" "$ASSET" || true)
	if [ "$_got" = "$GOOD" ]; then
		note_ok "$_name read the asset digest"
	else
		note_fail "$_name digest was ${_got:-empty}"
	fi
	if run_digest "$_script" "$NO_DIGEST" "$ASSET" >/dev/null 2>&1; then
		note_fail "$_name accepted an asset with no digest"
	else
		note_ok "$_name rejected an asset with no digest"
	fi
done

[ "$FAILS" -eq 0 ]
