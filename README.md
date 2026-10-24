# BPI-R4 / R4 Pro images

This repo builds Debian or Ubuntu SD-card and eMMC images for these boards:
- Banana Pi BPI-R4 Pro 8X
- BPI-R4 Pro 4E
- BPI-R4 (2x SFP)

The images use frank-w's [u-boot](https://github.com/frank-w/u-boot) and
[kernel](https://github.com/frank-w/BPI-Router-Linux) CI releases, a
debootstrapped root filesystem, and options picked with Kconfig
(`make menuconfig`). The build started as a layer over his
[BPI-Router-Images](https://github.com/frank-w/BPI-Router-Images) scripts and
now does the same job itself.

## Quick start

```sh
sudo apt install python3-kconfiglib pigz debootstrap mtools git qemu-user-static \
	gcc-aarch64-linux-gnu make bc bison flex libssl-dev libelf-dev u-boot-tools ccache
cat ~/.ssh/id_ed25519.pub > root_authorized_keys   # root's SSH keys (see below)
make r4pro-8x_defconfig    # or r4pro-4e, r4pro-8x-switch, r4
make menuconfig            # optional: change anything
make                       # build; the image lands in out/
```

The build host is Debian or Ubuntu on either x86_64 or arm64. On x86_64 the
arm64 rootfs's package scripts run under qemu (`qemu-user-static`) and the
kernel is cross-compiled (`gcc-aarch64-linux-gnu`). On arm64 both run
natively: install `gcc` instead of those two. The build also needs:
- **sudo**, for debootstrap, the root filesystem's loop mount and chroot. The
  build asks for the password once at the start and keeps sudo's timeout
  refreshed until it ends.
- **Network access**, to download packages, the kernel, u-boot and firmware.
  `GITHUB_TOKEN`, if set, lifts GitHub's limit of 60 API requests an hour; a
  build makes two.

`root_authorized_keys` (not in the repo) holds the SSH public keys allowed to
log in to the images as root, one per line: SSH takes keys only, so it needs
at least one. The AUTHORIZED_KEYS option points elsewhere.

The first build of a distribution bootstraps its rootfs and caches it in
`.cache/rootfs/`. Downloads are cached in `.cache/dl/`. Later builds reuse
both.

## Configuring

The options live in `Kconfig`, and each has a help text (`?` in menuconfig).

| make target | does |
|---|---|
| `make <name>_defconfig` | writes `.config` from `configs/<name>_defconfig` |
| `make menuconfig` | edits `.config` |
| `make savedefconfig` | writes a minimal `./defconfig` from `.config`, to copy into `configs/` |
| `make` / `make image` | `./build.sh --config .config`; `FLAGS="--clean ..."` adds flags |
| `make help` | lists the targets and the saved configs |

`./build.sh` also works without make. Its flags override single options:

```sh
./build.sh                                  # .config, else the 8X defaults
./build.sh --board r4pro4e                  # configs/r4pro-4e_defconfig
./build.sh --config configs/r4pro-8x-switch_defconfig --kernel 7.2 --ports phy
./build.sh --kernel 7.2 --ports phy bookworm
./build.sh --clean                          # rebuild the cached rootfs first
```

The base config is chosen in this order:
1. `--config FILE`.
2. `configs/<board>_defconfig`, for `--board`.
3. `.config`.
4. `configs/r4pro-8x_defconfig`.

The flags `--device`, `--kernel`, `--ram`, `--ports` and the distro then
override single options on top of it (`scripts/resolve-config`). A combination
Kconfig doesn't allow stops the build before it starts, for example
`--board r4pro4e --kernel 6.18`.

### Options

| Option | Default | |
|---|---|---|
| Board | R4 Pro 8X | 8X, 4E, or R4 (2x SFP) |
| Boot device | SD card | eMMC also writes `<image>_bl2.img` for the boot0 partition |
| RAM | 8 GB on the 8X, else 4 GB | 8 GB writes u-boot's 8 GB bl2 and fip |
| Kernel | 6.18, or 7.2 on the 4E | the branch; the 4E needs 7.2 |
| Kernel build | built from source, with WireGuard and exFAT | or frank-w's CI build, which has neither (see Custom kernels) |
| Distribution | Debian 13 trixie | Debian 12 bookworm, Ubuntu 24.04 noble, Ubuntu 26.04 resolute |
| Debian mirror, Ubuntu mirror | deb.debian.org, ports.ubuntu.com | the one for the distribution is used; e.g. an apt-cacher-ng proxy |
| **Releases** | | |
| u-boot release | latest, or 2026.07 on the 4E | a frank-w/u-boot release tag |
| Kernel release | the branch's latest CI build | a BPI-Router-Linux release tag of that branch |
| Extra device tree overlays | none | added to the board's ones in uEnv.txt's `addconf` |
| **Network** | | |
| Combo/WAN ports | SFP, or RJ45 on the 4E | R4 Pro only. On the 8X: lan6 and the WAN combo ports. On the 4E: the WAN |
| Role | Router | Router or Switch (see below) |
| LAN address | 192.168.1.1/24 | router only |
| DHCP server | yes | router only; leases host numbers .101 to .250 |
| NAT and firewall | yes | router only; nftables |
| SSH from the WAN | yes | with the firewall |
| Cellular modem | none | or ModemManager (see below) |
| APN | empty: the network's default | with ModemManager |
| Phones and ECM modems on USB | yes | backup uplinks: Android and iPhone tethering, ECM modems (see below) |
| Backup route metric | 2048 | of the modem and USB uplinks; above the WAN's 1024 |
| **Wi-Fi** | | |
| Wi-Fi mode | monitor-only | Choices: monitor-only MT7915/MT7916 (mt7915e); access point (see below); off |
| Regulatory domain | none: the kernel's world domain | also hostapd's country code with the access point, which needs one |
| SSID | the hostname | access point only, as are the rows below |
| Passphrase | none: one is needed | 8 to 63 characters |
| WPA3 only | no: WPA2 and WPA3 | on 2.4 and 5 GHz; 6 GHz is always WPA3 only |
| Bands and channels | 5 GHz on 36, 6 GHz on 37, 2.4 GHz on 1 | channel 0: automatic |
| Wi-Fi clients' network | the LAN | or (router) a subnet of their own, 192.168.20.1/24, optionally as a guest network |
| **Identity** | | |
| Hostname | endpoint | |
| Locales | `en_US.UTF-8` | generated; the first is `LANG` |
| Root password | scripts/mkimage's default | for the serial console only; SSH takes keys only |
| authorized_keys file | `root_authorized_keys` | yours, not in the repo; must hold at least one key |
| **Time** | | |
| GPS time | yes | gpsd, and a chrony refclock from it |
| GPS receiver, offset | `/dev/ttyACM0`, 0.067 s | the offset suits a u-blox 7 on USB |
| **Packages** | | |
| Package options | ethtool, iperf3, tcpdump, usbutils, pciutils, screen | 257 packages to choose from (see Packages) |
| Development tools | no | runs `install-devtools` in the image, about 590 MB |
| Extra packages | none | anything else, space-separated |
| Image name tag | empty | appended to the image name |

ssh, chrony, iw, xz-utils, wireguard-tools, exfatprogs, locales and
systemd-resolved are always installed, hostapd only with the access point, and
ModemManager with the cellular modem option. nftables is installed for the firewall (Debian's
base system has it anyway) and only enabled with it.

A root password or Wi-Fi passphrase set in the config is stored in plain text
in `.config` and `out/*.config`. Don't put one in `configs/`; set
`ROOT_PASSWORD=...` or `WIFI_PASSPHRASE=...` in the environment instead, which
overrides the config.

### Packages

The *Packages* menu has one option per package, in groups. Each option's
prompt starts with the package's name (`docker.io: Docker engine`), and
`resolve-config` reads the names from there, so adding an option takes
just one Kconfig entry. The selected packages are installed with their
recommends, like *Extra packages*.

| group | packages (default on in **bold**) |
|---|---|
| Network diagnostics | **ethtool**, mtr-tiny, traceroute, tcptraceroute, iputils-tracepath, bind9-dnsutils, ldnsutils, knot-dnsutils, dnstop, iputils-arping, fping, ndisc6, whois, ipcalc, sipcalc, conntrack, net-tools, bridge-utils, snmp, inetutils-telnet, wakeonlan, etherwake, httpie, speedtest-cli |
| Packet capture and scanning | **tcpdump**, tshark, termshark, ngrep, tcpflow, tcpreplay, netsniff-ng, python3-scapy, nmap, masscan, hping3, arp-scan, netdiscover, netcat-openbsd, socat |
| Monitoring | htop, btop, glances, atop, nmon, iotop-c, sysstat, lsof, strace, powertop, iftop, nload, bmon, nethogs, iptraf-ng, bwm-ng, ifstat, tcptrack, vnstat, darkstat, lnav |
| Metrics and logging | prometheus-node-exporter, prometheus-blackbox-exporter, collectd, munin-node, monit, zabbix-agent, snmpd, rsyslog, systemd-journal-remote |
| Benchmarks and testing | **iperf3**, iperf, stress-ng, memtester, fio, sysbench |
| Hardware | **usbutils**, **pciutils**, lshw, inxi, i2c-tools, spi-tools, gpiod, lm-sensors, mmc-utils, mtd-utils, u-boot-tools, libubootenv-tool, picocom, minicom, ser2net, usb-modeswitch, rfkill, nut, apcupsd, rtl-sdr |
| Storage and filesystems | nvme-cli, smartmontools, hdparm, parted, gdisk, dosfstools, mtools, f2fs-tools, squashfs-tools, btrfs-progs, cryptsetup, lvm2, mdadm, ntfs-3g, sshfs, autofs, testdisk, gddrescue, pv, bmap-tools, duf, systemd-zram-generator |
| Wi-Fi | wpasupplicant, wavemon, aircrack-ng, hcxdumptool, hcxtools, horst, mdk4 |
| DNS and DHCP | dnsmasq, unbound, bind9, nsd, pdns-recursor, stubby, dnscrypt-proxy, kea-dhcp4-server, radvd, ndppd, ddclient, avahi-daemon, avahi-utils, tftpd-hpa |
| Routing and firewall | frr, bird2, keepalived, conntrackd, ipvsadm, lldpd, miniupnpd, igmpproxy, smcroute, ppp, iptables, ipset, softflowd, freeradius |
| VPN and remote access | openvpn, strongswan, tinc, openconnect, ocserv, sshuttle, autossh, mosh, cockpit |
| Web servers and proxies | nginx, caddy, lighttpd, apache2, haproxy, squid, tinyproxy, privoxy, certbot |
| File sharing and media | samba, smbclient, nfs-kernel-server, nfs-common, cifs-utils, vsftpd, minidlna, transmission-daemon, syncthing |
| Messaging and data | mosquitto, mosquitto-clients, sqlite3, redis-server |
| Containers | docker.io, docker-compose, podman, buildah, skopeo, lxc, incus, systemd-container |
| Virtual machines | qemu-system-arm, qemu-utils, qemu-efi-aarch64, libvirt-daemon-system, libvirt-clients, virtinst |
| Shell and editors | **screen**, tmux, byobu, vim, neovim, micro, mc, zsh, fish, bash-completion, man-db, sudo |
| Command-line tools | curl, wget, aria2, lftp, git, rsync, jq, yq, fzf, ripgrep, fd-find, bat, moreutils, parallel, inotify-tools, ncdu, tree, file, zstd, unzip, psmisc, at, bc, pwgen, shellcheck, python3-pip, python3-venv, nodejs |
| Backup | borgbackup, restic, rclone, rsnapshot |
| Maintenance and security | unattended-upgrades, needrestart, apt-listchanges, apt-file, debsums, fail2ban, sshguard, crowdsec, knockd, lynis, gnupg, age, msmtp-mta |
| GPS and time | gpsd-clients, pps-tools, linuxptp |

- **Availability:** every package exists for arm64 in trixie, bookworm,
  noble and resolute, except six whose options are hidden where they're
  missing: aircrack-ng, mdk4 and zabbix-agent (not in noble), dnscrypt-proxy
  and incus (not in bookworm), docker-compose (not in resolute).
- **Conflicts:** apcupsd and nut can't be installed together (both are UPS
  monitors), so apcupsd's option is hidden while nut's is on. With that,
  every option at once installs on each distribution, checked with apt's
  solver.
- **Per-board secrets:** the TLS key that ssl-cert generates (pulled in by
  nginx, apache2, lighttpd, ocserv and others) is deleted in the build and
  made on first boot, like the SSH host keys. freeradius' test certificates
  and crowdsec's local API registration are made at install, so they're the
  same in every image; their option help says how to redo them.
- **Kernel support:** `kernel/features.config` has what the storage options
  need: the device mapper, dm-crypt with XTS, software RAID and Btrfs.

### Network roles

**Router**
- The WAN takes a DHCP lease.
- The LAN ports are bridged as `lanbr0` with the LAN address. The DHCP server
  is optional.
- IPv4 is forwarded between the WAN and the LAN.
- With the firewall, `/etc/nftables.conf`:
  - masquerades the LAN to the WAN;
  - drops input except LAN traffic, replies, ping, the DHCP client and
    (optionally) SSH, which is rate-limited;
  - logs (at most 10 a minute) and rejects the rest, except broadcasts and
    multicasts, which it drops without a log.
- The firewall counts `lanbr0` and `wlan*` (the Wi-Fi subnet's `wlanbr0`) as
  LAN and every other interface as WAN.
- For local rules, put `*.nft` files in `/etc/nftables/` on the board.

**Switch**
- Every port, WAN included, is in `lanbr0`.
- `lanbr0` takes a DHCP lease from the upstream network.
- There is no forwarding, NAT or firewall: the bridge passes traffic like a
  switch.

**Wi-Fi access point**
- At boot, `wifi-ap.service` gives each band a radio that can run it, in the
  order 5, 6, 2.4 GHz, and runs hostapd on it (`wifi-ap@wlan5g` and so on). An
  MT7915E card runs one band at a time, so one card gives 5 GHz and two give 5
  and 2.4 GHz. The BE14 runs all three.
- hostapd's configs are made from the cards' capabilities: Wi-Fi 6, 20 MHz
  wide on 2.4 GHz, 80 MHz on 5 and 6 GHz. Each access point has its card's MAC
  address, or one made from it.
- The settings are in `/etc/default/wifi-ap` (root only): change them and run
  `systemctl restart wifi-ap`. `wifi-ap plan` shows the radios and configs
  without changing anything. An `/etc/hostapd/wlan5g.conf` (and so on), if
  there is one, is used instead of the generated config.
- Wi-Fi clients are on the LAN (bridged into `lanbr0`), or with the router
  role on a subnet of their own: `wlanbr0`, with a DHCP server. As a guest
  network, the subnet reaches only the WAN, and the router only for DHCP and
  ping.

**Cellular modem and USB uplinks**

The kernel has the drivers for 4G/5G modems either way: `qmi_wwan`,
`cdc_mbim`, `option`, MHI and T7xx. It also has the USB tethering drivers:
`rndis_host`, `cdc_ncm` and `cdc_ether` for Android, `ipheth` for iPhones. The
options choose the userspace:
- **Cellular modem, ModemManager:** for QMI and MBIM modems, such as a Quectel
  RM520N in its default QMI mode.
  - The image gets ModemManager, `qmicli` and `mbimcli`.
  - `modem-connect.service` enables the modem and keeps a data connection up
    with the APN, waiting quietly without a SIM. A PIN-locked SIM needs
    `mmcli -i <sim> --pin=<PIN>`.
  - ModemManager's connection dispatcher puts the addresses, a default route
    with the backup metric, and the DNS servers on `wwan0`, which networkd
    leaves alone.
  - A udev rule keeps ModemManager from probing (sending AT commands to)
    Linux USB gadgets, such as another board's serial console, and u-blox GNSS
    receivers, which gpsd reads.
- **Phones and ECM modems on USB (on by default):** networkd takes a DHCP
  lease, with the backup metric, on the USB network interface of a tethering
  phone. It works for Android (RNDIS, NCM or ECM) and iPhone (`ipheth`, with
  `usbmuxd` for the *Trust this computer* pairing). It also covers a modem
  switched to ECM mode (Quectel: `AT+QCFG="usbnet",1`, with the APN set in the
  modem). Any `cdc_ether` or `cdc_ncm` device counts, USB Ethernet adapters in
  those modes included.

Their interfaces count as WAN to the firewall. With the default metric they're
backups: they take over when the WAN's route goes, through a lost link or
lease. An ISP that fails upstream while the WAN link stays up isn't detected;
that needs a health check (see ROADMAP.md).

**Ports**
- **8X:**
  - WAN: the 10G combo.
  - On kernel 7.2: `lan1`–`lan4` and `lan6` (the 10G combo) are on the MxL862xx switch, and `lan5` is on the MT7988 switch.
  - Kernel 6.18 names the MxL ports `lan0`–`lan4`.
- **4E:**
  - WAN: the 2.5G RJ45, or SFP2 with `--ports sfp`.
  - LAN: `lan1`–`lan4` and `sfp-lan` (SFP1) are on the MxL862xx switch, and `lan5`–`lan6` are on the MT7988 switch.
- **R4:**
  - WAN is `wan`.
  - The LAN bridge uses `lan0`–`lan3`.

## Custom kernels

By default the kernel is built from source rather than taken from frank-w's
CI build, because his defconfig has no WireGuard or exFAT. `scripts/kernel`
builds it the way his CI does:
his `mt7988a_bpi-r4_defconfig`, and the `bpi-r4.itb` FIT image from his
`bpi-r4.its`, with the board device trees and overlays. It packs the same
tarball layout. The *Kernel source* menu sets what to build:

| Option | Default | |
|---|---|---|
| Git repository | frank-w/BPI-Router-Linux | or a fork, or a local repository path |
| Branch, tag or commit | empty: `<branch>-main` | fetched shallowly |
| Patch directory | none | `*.patch` from `git format-patch`, applied in name order, e.g. `kernel/patches` |
| Local tree | none | a checkout built as it is, uncommitted changes included; replaces the three above |
| Base kernel config | the tree's defconfig | or a file from `make kernel-savedefconfig` |
| Config fragments | `kernel/features.config kernel/r4-only.config` | files of `CONFIG_` lines merged on top |
| Version suffix | `-custom` | in the image name and `uname -r`: `7.2.0-custom`, `7.2.0-bpi-r4-custom` |

```sh
make menuconfig                                     # Kernel source: repository, patches, fragments
make kernel-menuconfig FRAGMENT=kernel/my.config    # change options; writes the changes
make menuconfig                                     # Kernel source > Config fragments: kernel/my.config
make kernel                                         # just the kernel
make                                                # kernel and image
make kernel-install HOST=root@endpoint              # kernel onto a running board
```

- **Config fragments:** a fragment value that the kernel's Kconfig drops,
  through an unmet dependency or a misspelt symbol, stops the build. The repo
  has two:
  - `kernel/features.config` adds, as modules:
    - WireGuard and exFAT;
    - BBR with the fq qdisc;
    - `cdc_mbim` for USB 4G/5G modems;
    - FTDI, CP210x, CH341 and PL2303 USB serial drivers;
    - UAS;
    - the PPS clients (serial DCD, GPIO);
    - zram, for compressed swap;
    - KVM, with vhost-net and macvtap, for virtual machines (the CPUs start at
      EL2);
    - the EIP-197 crypto driver.
  - `kernel/r4-only.config` leaves out drivers for hardware the R4 family
    doesn't have: other MediaTek SoCs' clocks and pin controllers, EFI, the
    VT console, PS/2 and libata. This shrinks the kernel from 29.4 MB to
    26.1 MB.
- **Kernel extras:** two options under *Kernel source* add a fragment and
  its packages:
  - **AppArmor** (`kernel/apparmor.config`): the LSM, on at boot, plus the
    `apparmor` package. Docker, Podman, LXC and Incus confine their containers
    with it. Services that ship profiles, chrony and gpsd among them, run
    confined too, so check them on the board.
  - **BPF tracing** (`kernel/tracing.config`): kprobes, uprobes, BTF and the
    kernel headers, plus `bpftrace` and the bcc tools. BTF needs debug info and
    `pahole` (`dwarves`) on the build host, so kernel builds are slower.
    Modules are always installed stripped.
- **EIP-197:** MT7988's device tree has no node for the crypto engine.
  `kernel/patches-eip197` adds one, taken from the MT7987's identical block,
  but it hasn't been tested on hardware. Set the patch directory to it to
  try it.
- **Installing on a running board:** `make kernel-install HOST=root@<board>`
  builds the kernel and installs it over SSH:
  - the modules, under `/lib/modules/<release>`;
  - the FIT, as `/boot/bpi-r4-<version>.itb`;
  - a `fit=` line in `/boot/uEnv.txt` naming that file. `uEnv.txt` is saved
    first as `uEnv.txt.prev`, on the first install only.

  The image's `bpi-r4.itb` stays as the fallback. If the new kernel doesn't
  boot, pick *Enter kernel-name* in u-boot's boot menu on the serial console
  and type `bpi-r4.itb`. It refuses a host that isn't an R4 board, a full
  `/boot`, or a FIT missing an overlay that `uEnv.txt`'s `addconf` names. It
  doesn't reboot. Give each build its own Version suffix, so a fallback
  kernel of the same release keeps its modules.
- **Where it builds:** out of tree in `.cache/kernel/` and incrementally, so
  rebuilds are quick, and quicker still with ccache.
- **Output:** `.cache/kernel/out/bpi-r4_<version>.tar.gz`.
- **Records:** the manifest records the repository, ref, commit, patches and
  fragments.
- **Host:** an x86_64 host cross-compiles and needs
  `sudo apt install gcc-aarch64-linux-gnu make bc bison flex libssl-dev libelf-dev u-boot-tools`.
  An arm64 host builds natively and needs `gcc` in place of the cross
  compiler. `ccache` speeds up rebuilds, and `libncurses-dev` is needed for
  `make kernel-menuconfig`.

## Output

The images go to `out/`, named
`<board>_<distro>_<kernel>_<device>[-<tag>].img.gz`, for example
`bpi-r4pro_trixie_6.18.53-main_sdmmc.img.gz`. The board prefix is `bpi-r4pro`
for the 8X, `bpi-r4pro-4e` for the 4E and `bpi-r4` for the R4. Next to each
image are:

| file | |
|---|---|
| `.manifest` | what went in: repo commit, config source, u-boot and kernel releases, linux-firmware commit, uEnv.txt, settings, sha256s |
| `.config` | the resolved config: `./build.sh --config out/<image>.config` builds the same options again |
| `.packages` | the image's package list (`dpkg-query`) |
| `.log` | the build's output; a failed build leaves it in `.cache/build.log` |
| `.md5` | checksum of the image |
| `_bl2.img` | eMMC only: the bl2 for the eMMC's boot0 partition |

Unless they're pinned under Releases, the u-boot release and the kernel build
are the latest ones. Firmware and packages are always current. A rebuild from
the same config can therefore get newer versions; the manifest records which
ones went in.

### Checking an image

```sh
scripts/check-image out/<image>.img.gz
```

This checks a built image offline, without root, against the `.config`,
manifest and package list next to it:
- **u-boot:** the bl2 and fip against the release's files in `.cache/dl/`.
- **BPI-BOOT:** `uEnv.txt`'s settings, and that each overlay it names is in the
  kernel's FIT.
- **BPI-ROOT:**
  - kernel modules, fstab, hostname and apt sources;
  - the network role's files and the firewall, loading the ruleset with the
    host's nft where the host kernel allows;
  - enabled units and first-boot state;
  - root SSH keys and password;
  - Wi-Fi, firmware and GPS.
- **Packages:** what the config asks for.

It prints ok or FAIL for each check and exits with status 1 if any failed.

## Flashing

**SD card**

```sh
pigz -dc out/<image>.img.gz | sudo dd of=/dev/sdX bs=1M conv=fsync status=progress
```

**eMMC**

Write the image from a system running on the board, booted from SD or NAND.
First back up the eMMC (the factory OpenWrt keeps its calibration data there).
The eMMC also needs the separate bl2 in its boot0 partition:

```sh
B=root@<board>
pigz -dc out/<image>.img.gz | ssh $B 'dd of=/dev/mmcblk0 bs=1M conv=fsync'
ssh $B 'echo 0 > /sys/block/mmcblk0boot0/force_ro &&
	dd if=/dev/zero of=/dev/mmcblk0boot0 bs=512k count=1 &&
	dd of=/dev/mmcblk0boot0 conv=fsync &&
	echo 1 > /sys/block/mmcblk0boot0/force_ro' < out/<image>_bl2.img
ssh $B 'mmc extcsd read /dev/mmcblk0 | grep -A4 PARTITION_CONFIG'  # boots from boot0?
ssh $B 'mmc bootpart enable 1 1 /dev/mmcblk0'                      # only if not
```

`mmc` comes from mmc-utils. Then set the boot switch to eMMC.

## On the board

- **First boot:**
  - The root partition grows to fill the SD card or eMMC.
  - Each board generates its own SSH host keys and machine-id, and, when
    ssl-cert is installed, its own snakeoil TLS key.
- **Logging in:**
  - SSH as root works with the configured keys only.
  - The password works on the serial console, at 115200 baud.
- **Kernel:** the kernel is frank-w's, in `/boot`. apt pins the distribution's
  kernels out so they can't replace it.
- **Build tools:** `install-devtools` installs the tools for building Debian
  packages on the board, if the image didn't include them.

## How it works

1. **`scripts/resolve-config`** loads the base config with kconfiglib and
   applies the flags. It writes the result to `.cache/build.config` and prints
   every option as a `CONFIG_<NAME>=value` shell assignment. Bools come out as
   `y` or empty, and options the config doesn't use come out empty.
   It also rejects free-text values that would break a file or a command
   line, such as a bad hostname, mirror URL or LAN address.
2. **`build.sh`** evals those assignments. It then works out the board's
   u-boot variant, uEnv.txt settings, device tree overlays and rootfs
   overlays, and the package list.
3. **`scripts/rootfs`** debootstraps the distribution into a tmpfs and packs
   it as `.cache/rootfs/<distro>_arm64.tar.gz`, unless that already exists.
4. **`scripts/fetch`** downloads, into `.cache/dl/`:
   - the u-boot release's base image for the board and boot device (partition
     table, bl2, fip, and empty BPI-BOOT and BPI-ROOT filesystems);
   - the 8 GB and eMMC bl2/fip files;
   - the kernel CI build;
   - linux-firmware's `aeonsemi`, `airoha` and `mediatek` directories (a
     sparse clone from GitLab);
   - wireless-regdb.
   With *Built from source*, **`scripts/kernel`** builds the kernel tarball
   instead (see Custom kernels).
5. **`scripts/mkimage`** builds the image from all that and the config:
   - writes the 8 GB bl2/fip, the kernel and `uEnv.txt` at their partition
     offsets in the image file;
   - loop-mounts only the root filesystem;
   - unpacks the rootfs, modules and firmware;
   - installs the packages in a chroot;
   - copies the `overlays/` directories;
   - writes the network role files, Wi-Fi settings, hostname, root password
     and SSH keys;
   - enables the first-boot units;
   - installs the development tools, if selected.

   apt failures stop the build.
6. **`build.sh`** compresses the image into `out/` and writes the manifest and
   the log.

Before any of this, `build.sh` checks the host prerequisites and prints a
single `apt install` line for whatever is missing. It also takes a lock, so a
second build started meanwhile stops instead of overwriting the first one's
files.

`scripts/mkimage` copies these `overlays/<name>/` trees into the rootfs, in
this order:

| overlay | when | |
|---|---|---|
| `common` | always | kernel interface names, the switch conduit, the LAN bridge, apt kernel pin, keys-only root SSH, grow-rootfs, ssh-hostkeys, install-devtools |
| `r4pro` | 8X and 4E | persistent WAN MAC, LAN bridge ports |
| `r4pro4e` | 4E | re-probes the WAN PHY at boot |
| `gps` | GPS time | gpsd defaults, chrony refclock |
| `router` | router role | IPv4 forwarding |
| `firewall` | NAT and firewall | `/etc/nftables.conf`, and logging and rejecting what it doesn't accept |
| `wifi-ap` | access point | `wifi-ap` and its units |
| `wifi-guest` | guest Wi-Fi | a firewall table that keeps `wlanbr0` off the LAN and the router |

`scripts/mkimage` also generates some files from the config:
- `15-wan.network` and `25-lanbr.network`;
- `/etc/hostname` and `/etc/hosts`;
- the access points' `/etc/default/wifi-ap`, and the Wi-Fi subnet's `wlanbr0`
  files;
- the cfg80211 regulatory domain.

### Extending

- **A new option:** add a symbol with a help text to `Kconfig`, then use
  `$CONFIG_<NAME>` in `build.sh` or `scripts/mkimage`; every option is
  exported to both. If the value is free text that ends up in a file or a
  command line, add a format for it to `scripts/resolve-config`.
- **A new saved config:**
  ```sh
  make menuconfig
  make savedefconfig
  cp defconfig configs/<name>_defconfig
  ```
- **A new board:**
  - `Kconfig`: an entry in the Board choice, and a `BOARD` default.
  - `scripts/resolve-config`: the `board_defconfig` and `choices` maps.
  - `build.sh`: an entry in the board `case`.
  - `configs/<name>_defconfig`.

## Known issues

- **MxL862xx switch firmware:** both R4 Pro boards ship with firmware 1.0.70,
  which has no SerDes PCS support. The 4E's `sfp-lan` can't link, and the 8X's
  `lan6` probably can't either. Firmware 1.0.85 may fix this, but flashing it is
  one-way.

## License

MIT (see `LICENSE`), except the kernel patches in `kernel/patches-*`: they
change Linux source files, so they take those files' licenses. The EIP-197
patch changes `mt7988a.dtsi`, which is GPL-2.0-only OR MIT. The images the
build makes hold software under its own licenses: Linux (GPL-2.0), u-boot
(GPL-2.0+), the distribution's packages and linux-firmware's files.
