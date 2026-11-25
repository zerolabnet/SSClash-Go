#!/bin/sh
# pick_lan_ipv4 must not prefer Docker 172.17.0.1 when a LAN address exists.
# Uses a fake ip(1) on PATH. Does not touch the network.
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

LINUX="$ROOT/packaging/linux/install-linux.sh"
OPENWRT="$ROOT/packaging/openwrt/install-openwrt.sh"
KEENETIC="$ROOT/packaging/keenetic/install-keenetic.sh"

for _fn in iface_skipped iface_lan ipv4_docker17 ipv4_rfc1918 pick_lan_ipv4; do
	_a=$(extract_fn "$LINUX" "$_fn")
	_b=$(extract_fn "$OPENWRT" "$_fn")
	_c=$(extract_fn "$KEENETIC" "$_fn")
	if [ -n "$_a" ] && [ "$_a" = "$_b" ] && [ "$_a" = "$_c" ]; then
		note_ok "$_fn matches"
	else
		note_fail "$_fn differs"
	fi
done

RUNNER=$(mktemp)
MOCK=$(mktemp -d)
{
	printf '%s\n' '#!/bin/sh' 'set -eu'
	extract_fn "$LINUX" iface_skipped
	extract_fn "$LINUX" iface_lan
	extract_fn "$LINUX" ipv4_docker17
	extract_fn "$LINUX" ipv4_rfc1918
	extract_fn "$LINUX" pick_lan_ipv4
} > "$RUNNER"

cat > "$MOCK/ip" <<'EOF'
#!/bin/sh
if [ "$1" = "-4" ] && [ "$2" = "route" ]; then
	if [ -n "${IP_ROUTE:-}" ]; then
		printf '%s\n' "$IP_ROUTE"
		exit 0
	fi
	exit 1
fi
if [ "$1" = "-4" ] && [ "$2" = "-o" ]; then
	printf '%s\n' "${IP_ADDR:-}"
	exit 0
fi
exit 1
EOF
chmod +x "$MOCK/ip" "$RUNNER"

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

pick() {
	IP_ROUTE=$1 IP_ADDR=$2 PATH="$MOCK:$PATH" sh -c '. "$1"; pick_lan_ipv4' sh "$RUNNER"
}

ADDR_DOCKER_ETH='3: docker0    inet 172.17.0.1/16 brd 172.17.255.255 scope global docker0
2: eth0    inet 192.168.1.10/24 brd 192.168.1.255 scope global eth0'
expect_eq "$(pick '1.1.1.1 via 192.168.1.1 dev eth0 src 192.168.1.10 uid 0' "$ADDR_DOCKER_ETH")" \
	"192.168.1.10" "route src beats docker0"

expect_eq "$(pick '' "$ADDR_DOCKER_ETH")" \
	"192.168.1.10" "addr list does not prefer 172.17.0.1"

ADDR_BRLAN='5: docker0    inet 172.17.0.1/16 scope global docker0
3: br-lan    inet 192.168.1.1/24 scope global br-lan
2: eth1    inet 203.0.113.5/24 scope global eth1'
expect_eq "$(pick '1.1.1.1 via 203.0.113.1 dev eth1 src 203.0.113.5' "$ADDR_BRLAN")" \
	"192.168.1.1" "LAN private address beats a public WAN src"
expect_eq "$(pick '1.1.1.1 dev docker0 src 172.17.0.1' "$ADDR_BRLAN")" \
	"192.168.1.1" "docker route src is ignored"

ADDR_TUN='4: tun0    inet 10.8.0.1/24 scope global tun0
2: eth0    inet 192.168.0.4/24 scope global eth0'
expect_eq "$(pick '1.1.1.1 dev tun0 src 10.8.0.1' "$ADDR_TUN")" \
	"192.168.0.4" "tunnel src is ignored"

expect_eq "$(pick '1.1.1.1 dev ens18 src 192.168.5.9' '3: docker0 inet 172.17.0.1/16 scope global docker0
2: ens18 inet 192.168.5.9/24 scope global ens18')" \
	"192.168.5.9" "private route src on ens18"

expect_eq "$(pick '1.1.1.1 dev eth0 src 203.0.113.5' '2: eth0 inet 203.0.113.5/24 scope global eth0')" \
	"203.0.113.5" "public route src when nothing private exists"

expect_eq "$(pick '' '3: docker0 inet 172.17.0.1/16 scope global docker0')" \
	"" "docker-only host has no LAN address"

rm -rf "$RUNNER" "$MOCK"
printf 'lan-ip-fixture: %s checks failed\n' "$FAILS"
[ "$FAILS" -eq 0 ]
