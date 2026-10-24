#!/bin/bash
# Build an SD-card or eMMC image for the BPI-R4 Pro 8X/4E or BPI-R4, configured with Kconfig (make menuconfig).
# Runs on x86_64 (arm64 rootfs via qemu binfmt) or natively on arm64.
# usage: ./build.sh [--config FILE] [--board r4pro|r4pro4e|r4] [--device sdmmc|emmc]
#                   [--kernel 6.18|7.2] [--ram 8|4] [--ports sfp|phy] [--clean] [distro]
#   The options come from a Kconfig config (make menuconfig, see the Makefile
#   and Kconfig's help texts): --config FILE, else configs/<board>_defconfig
#   for --board (r4pro-8x, r4pro-4e, r4), else .config, else
#   configs/r4pro-8x_defconfig. The other flags override it where Kconfig
#   allows (scripts/resolve-config).
#   --board   r4pro: BPI-R4 Pro 8X; r4pro4e: BPI-R4 Pro 4E; r4: BPI-R4 (standard, 2x SFP)
#   --device  sdmmc or emmc; emmc also writes <image>_bl2.img, the bl2 for the
#             eMMC boot0 partition (the image's bl2 partition is empty)
#   --kernel  frank-w kernel branch: 6.18 (LTS) or 7.2 (newest)
#   --ram     board RAM in GB; 8 writes u-boot's 8GB bl2 and fip
#   --ports   R4 Pro combo/WAN ports: sfp or phy (RJ45)
#   --clean   rebuild the cached rootfs (.cache/rootfs/<distro>_arm64.tar.gz)
#   distro    trixie, bookworm, noble or resolute
set -euo pipefail

usage() { sed -n 's/^# \{0,1\}//; 4,18p' "$0" >&2; exit 1; }
clean=
config=
board=
device=
kernel=
ram=
ports=
while [[ $# -gt 0 ]]; do
	case "$1" in
		--clean) clean=1; shift ;;
		--config) config=${2:-}; shift 2 || usage ;;
		--config=*) config=${1#*=}; shift ;;
		--board) board=${2:-}; shift 2 || usage ;;
		--board=*) board=${1#*=}; shift ;;
		--device) device=${2:-}; shift 2 || usage ;;
		--device=*) device=${1#*=}; shift ;;
		--kernel) kernel=${2:-}; shift 2 || usage ;;
		--kernel=*) kernel=${1#*=}; shift ;;
		--ram) ram=${2:-}; shift 2 || usage ;;
		--ram=*) ram=${1#*=}; shift ;;
		--ports) ports=${2:-}; shift 2 || usage ;;
		--ports=*) ports=${1#*=}; shift ;;
		-h|--help) usage ;;
		-*) echo "unknown option $1" >&2; usage ;;
		*) break ;;
	esac
done
distro=${1:-}
[[ $# -le 1 ]] || { echo "unexpected argument '$2'" >&2; usage; }

top=$(cd "$(dirname "$0")" && pwd)
cache=$top/.cache
host=$(uname -m)

# one build at a time: builds share .cache
mkdir -p "$cache"
exec 9>"$cache/build.lock"
flock -n 9 || { echo "another build is running" >&2; exit 1; }
# everything from here on is also logged, and kept as out/<image>.log
log=$cache/build.log
exec > >(tee "$log") 2>&1
sudo_keepalive=
on_exit() {
	local rc=$?
	[[ -z $sudo_keepalive ]] || kill "$sudo_keepalive" 2>/dev/null
	(( rc == 0 )) || echo "build failed (exit $rc), log in $log" >&2
}
trap on_exit EXIT

# everything the build host needs, checked up front for a single apt line
missing=()
need_cmd() { # <package> <command>
	PATH=$PATH:/usr/sbin:/sbin command -v "$2" >/dev/null || missing+=("$1")
}
need_py() { # <package> <module>
	python3 -c "import $2" 2>/dev/null || missing+=("$1")
}
need_py python3-kconfiglib kconfiglib
need_cmd pigz pigz
need_cmd debootstrap debootstrap
need_cmd mtools mcopy
need_cmd git git
case "$host" in
	# the arm64 chroot runs under qemu through binfmt; qemu-user-static
	# registers it
	x86_64) grep -q '^enabled' /proc/sys/fs/binfmt_misc/qemu-aarch64 2>/dev/null ||
		missing+=(qemu-user-static) ;;
	aarch64) ;;
	*) echo "unsupported build host $host" >&2; exit 1 ;;
esac
if (( ${#missing[@]} )); then
	echo "missing build prerequisites: sudo apt install ${missing[*]}" >&2
	exit 1
fi

# every image option as CONFIG_<name> (Kconfig), the flags applied on top
rc_args=(--write "$cache/build.config")
[[ -z $config ]] || rc_args+=(--config "$config")
for opt in board device kernel ram ports distro; do
	if [[ -n ${!opt} ]]; then rc_args+=("--$opt" "${!opt}"); fi
done
resolved=$("$top/scripts/resolve-config" "${rc_args[@]}")
eval "$resolved"
board=$CONFIG_BOARD
device=$CONFIG_DEVICE
kernel=$CONFIG_KERNEL
ram=$CONFIG_RAM
ports=$CONFIG_PORTS
distro=$CONFIG_DISTRO
# the access points' passphrase, the environment's or else the config's:
# checked here, as check-image resolves built images' configs without it
if [[ $CONFIG_WIFI == ap ]]; then
	pass=${WIFI_PASSPHRASE:-$CONFIG_WIFI_PASSPHRASE}
	if (( ${#pass} < 8 || ${#pass} > 63 )) || LC_ALL=C grep -q '[^ -~]' <<< "$pass"; then
		echo "WIFI_AP needs WIFI_PASSPHRASE: 8 to 63 ASCII characters, in the config or the environment" >&2
		exit 1
	fi
fi
# root's SSH keys: scripts/mkimage needs them at the end, so check now
keys=$CONFIG_AUTHORIZED_KEYS
[[ $keys == /* ]] || keys=$top/$keys
if ! grep -qsE '^(ssh-|ecdsa-|sk-)' "$keys"; then
	echo "no SSH public keys in $keys (root logs in with keys only; see the README's Quick start)" >&2
	exit 1
fi
# debootstrap checks the archive's signature with the host's keyring
case "$distro" in
	noble|resolute) keyring=ubuntu-keyring; keyfile=ubuntu-archive-keyring.gpg ;;
	*) keyring=debian-archive-keyring; keyfile=debian-archive-keyring.gpg ;;
esac
if [[ ! -e /usr/share/keyrings/$keyfile ]]; then
	echo "missing build prerequisite: sudo apt install $keyring" >&2
	exit 1
fi

# per board: u-boot's image variant and default release (empty: the
# latest), our image name, uEnv.txt settings,
# device tree overlays (the FIT's ov-* configs), rootfs overlays and the
# WAN's networkd [Match]: the R4 Pro's gmac1 by DT node (its name differs
# between kernels and --ports), the R4's DSA port by name
overlays=common
uboot_release=
wan_match="Property=OF_FULLNAME=/soc/ethernet@15100000/mac@1"
case "$board" in
	r4pro)
		variant=bpi-r4pro
		image_prefix=bpi-r4pro
		uenv="isr4pro=1"
		dt_overlays="ov-pro-cn14 ov-pro-cn15 ov-pro-8x-lan-$ports ov-pro-8x-wan-$ports"
		overlays+=" r4pro" ;;
	# the 4E shares the R4 Pro u-boot and image; isr4pro4e=1 selects its FIT
	# config (conf-base-r4pro-4e), which u-boot knows from the 2026.07 CI
	# build (the latest release is older). 2026.07's default env drops
	# console=ttyS0,115200n1 from $console, leaving the kernel on the DT's
	# stdout-path at 9600 baud
	r4pro4e)
		variant=bpi-r4pro
		uboot_release=CI-BUILD-2026-07-bpi-2026.07-2026-08-12_1320
		image_prefix=bpi-r4pro-4e
		uenv="isr4pro=1
isr4pro4e=1
console=console=ttyS0,115200n1 earlycon=uart8250,mmio32,0x11000000"
		dt_overlays="ov-pro-cn14 ov-pro-cn15 ov-pro-4e-wan-$ports"
		overlays+=" r4pro r4pro4e" ;;
	r4)
		variant=bpi-r4
		image_prefix=bpi-r4
		uenv=
		dt_overlays=
		wan_match="Name=wan" ;;
esac
dt_overlays+=${CONFIG_DT_OVERLAYS:+ $CONFIG_DT_OVERLAYS}
uboot_release=${CONFIG_UBOOT_RELEASE:-$uboot_release}
[[ -z $CONFIG_GPS_TIME ]] || overlays+=" gps"
[[ $CONFIG_ROLE != router ]] || overlays+=" router"
[[ -z $CONFIG_FIREWALL ]] || overlays+=" firewall"
[[ $CONFIG_WIFI != ap ]] || overlays+=" wifi-ap"
[[ -z $CONFIG_WIFI_GUEST ]] || overlays+=" wifi-guest"
[[ $CONFIG_MODEM != mm ]] || overlays+=" modem-mm"

pkgs="ssh chrony${PACKAGE_OPTIONS:+ $PACKAGE_OPTIONS}"
[[ -z $CONFIG_GPS_TIME ]] || pkgs+=" gpsd"
[[ $CONFIG_MODEM != mm ]] || pkgs+=" modemmanager libqmi-utils libmbim-utils"
[[ -z $CONFIG_USB_WAN ]] || pkgs+=" usbmuxd"
[[ -z ${CONFIG_KERNEL_APPARMOR:-} ]] || pkgs+=" apparmor"
[[ -z ${CONFIG_KERNEL_TRACING:-} ]] || pkgs+=" bpftrace bpfcc-tools"
pkgs+=${CONFIG_EXTRA_PACKAGES:+ $CONFIG_EXTRA_PACKAGES}

# what's being built, before the sudo prompt and the long part: a flag
# applied to an unexpected base config (a stray .config) shows here
echo "config:   $config_source"
echo "building: $board ($device, ${ram}GB), kernel $kernel${CONFIG_KERNEL_SOURCE:+ from source}$( [[ $board == r4pro* ]] && echo ", ports $ports"), $distro, $CONFIG_ROLE role, Wi-Fi $CONFIG_WIFI${CONFIG_IMAGE_TAG:+, tag $CONFIG_IMAGE_TAG}"

# the kernel toolchain, before the long part
[[ -z $CONFIG_KERNEL_SOURCE ]] || "$top/scripts/kernel" --config "$cache/build.config" check

# sudo once, before the long part: the build runs sudo on and off for ~10
# minutes and would otherwise stop at a password prompt partway through,
# once sudo's timeout has run out
sudo -v
while kill -0 $$ 2>/dev/null && sudo -n -v 2>/dev/null; do sleep 60; done >/dev/null 2>&1 9>&- &
sudo_keepalive=$!

mkdir -p "$cache/rootfs" "$cache/build" "$top/out"
rootfs=$cache/rootfs/${distro}_arm64.tar.gz
[[ -z $clean ]] || rm -f "$rootfs"
[[ -e $rootfs ]] || "$top/scripts/rootfs" "$distro" "$CONFIG_MIRROR" "$rootfs"

# u-boot, kernel (unless built from source), firmware and regdb,
# exported for scripts/mkimage
fetch_args=(--cache "$cache/dl" --variant "$variant" --device "$device" --ram "$ram"
	--kernel "$kernel" --uboot-release "$uboot_release" --kernel-release "$CONFIG_KERNEL_RELEASE")
[[ -z $CONFIG_KERNEL_SOURCE ]] || fetch_args+=(--no-kernel)
fetched=$("$top/scripts/fetch" "${fetch_args[@]}")
set -a
eval "$fetched"
if [[ -n $CONFIG_KERNEL_SOURCE ]]; then
	built=$("$top/scripts/kernel" --config "$cache/build.config" build)
	eval "$built"
fi
set +a

# scripts/mkimage takes the rest of the options straight from the config
export ROOTFS_TAR=$rootfs PACKAGES=$pkgs OVERLAYS=$overlays WAN_MATCH=$wan_match \
	UENV=$uenv DT_OVERLAYS=$dt_overlays "${!CONFIG_@}"
work=$cache/build
rm -f "$work/packages" "$work/uEnv.txt"
"$top/scripts/mkimage" "$work/image.img" "$work"

name=${image_prefix}_${distro}_${KERNEL_VERSION}_${device}${CONFIG_IMAGE_TAG:+-$CONFIG_IMAGE_TAG}.img.gz
echo "compressing $name..."
pigz -c "$work/image.img" > "$top/out/$name.part"
mv "$top/out/$name.part" "$top/out/$name"
rm "$work/image.img"
mv "$work/packages" "$top/out/$name.packages"
cp "$cache/build.config" "$top/out/$name.config"
bl2=
if [[ $device == emmc ]]; then
	bl2=${name%.img.gz}_bl2.img
	cp "$EMMC_BL2" "$top/out/$bl2"
fi

# what went into the image: the u-boot and kernel releases are the latest
# unless pinned, and firmware and packages are current, so record them
(
	cd "$top/out"
	echo "built:      $(date -u +%FT%TZ) on $(hostname) ($host)"
	echo "repo:       $(git -C "$top" describe --always --dirty)"
	echo "config:     $name.config, from $config_source"
	echo "board:      $board (u-boot $variant)"
	echo "device:     $device"
	echo "distro:     $distro (rootfs from $(date -u -r "$rootfs" +%F), $CONFIG_MIRROR)"
	echo "u-boot:     $UBOOT_RELEASE${uboot_release:+ (pinned)}"
	echo "kernel:     $KERNEL_RELEASE${CONFIG_KERNEL_RELEASE:+ (pinned)} $(sha256sum "$KERNEL_TAR" | cut -d' ' -f1)"
	echo "firmware:   linux-firmware $FIRMWARE_COMMIT"
	echo "ram:        ${ram}GB$( [[ $ram == 8 ]] && echo " (8GB bl2/fip)")"
	[[ $board == r4pro* ]] && echo "ports:      $ports"
	sed -n 's/^\([^#]\)/uEnv:       \1/p' "$work/uEnv.txt"
	echo "hostname:   $CONFIG_HOSTNAME"
	echo "role:       $CONFIG_ROLE$( [[ $CONFIG_ROLE == router ]] && echo " ${CONFIG_LAN_ADDRESS}${CONFIG_DHCP_SERVER:+ dhcp-server}${CONFIG_FIREWALL:+ firewall}${CONFIG_SSH_FROM_WAN:+ ssh-from-wan}")"
	echo "wifi:       $CONFIG_WIFI (regdom ${CONFIG_REGDOM:-world})$( [[ $CONFIG_WIFI == ap ]] && echo ", SSID ${CONFIG_WIFI_SSID:-$CONFIG_HOSTNAME},${CONFIG_WIFI_5G:+ 5g/$CONFIG_WIFI_CHANNEL_5G}${CONFIG_WIFI_6G:+ 6g/$CONFIG_WIFI_CHANNEL_6G}${CONFIG_WIFI_2G4:+ 2g4/$CONFIG_WIFI_CHANNEL_2G4}${CONFIG_WIFI_WPA3_ONLY:+ wpa3-only}, $( [[ -n $CONFIG_WIFI_NET_SUBNET ]] && echo "subnet $CONFIG_WIFI_ADDRESS${CONFIG_WIFI_GUEST:+ guest}" || echo lan)")"
	echo "modem:      $CONFIG_MODEM${CONFIG_MODEM_APN:+ (APN $CONFIG_MODEM_APN)}"
	echo "usb wan:    $( [[ -n $CONFIG_USB_WAN ]] && echo "phones and ECM modems" || echo no)${CONFIG_BACKUP_METRIC:+ (backup metric $CONFIG_BACKUP_METRIC)}"
	echo "locales:    ${CONFIG_LOCALES:-C.UTF-8 only}"
	echo "userpkgs:   $pkgs${CONFIG_PKG_DEVTOOLS:+ + install-devtools}"
	echo "image:      $name $(sha256sum "$name" | cut -d' ' -f1)"
	[[ -n $bl2 ]] && echo "boot0 bl2:  $bl2 $(sha256sum "$bl2" | cut -d' ' -f1)"
	echo "packages:   $name.packages"
	echo "log:        $name.log"
) > "$top/out/$name.manifest"
(cd "$top/out" && md5sum "$name" > "$name.md5")
cp "$log" "$top/out/$name.log"
cat "$top/out/$name.manifest"
