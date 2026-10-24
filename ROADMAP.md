# Roadmap

## R4 Pro SerDes port 13 on kernel 7.2

MxL862xx port 13 can't link with the switch firmware the boards ship with
(1.0.70). That port is `sfp-lan` (SFP1) on the 4E and `lan6` (the 10G combo)
on the 8X. Both boards log "SerDes PCS unsupported on old firmware" at boot.

### What's broken

The block is in frank-w's 7.2 `mxl862xx` driver, not missing firmware
capability (`drivers/net/dsa/mxl862xx/mxl862xx-phylink.c`):
- **The `if`:** below firmware 1.0.84, `mxl862xx_phylink_mac_select_pcs`
  returns NULL for every SerDes port (9–16). The intent is to leave the SerDes
  in the mode set in the switch's flash and keep the CPU port, port 9 (the 10G
  link to the MT7988), working.
- **The casualty:** port 13 gets no PCS, so phylink never reads its link state
  or sets its mode for the module, and reports link down.
- **The unused fix:** the driver already has a legacy PCS for old firmware,
  `mxl862xx_legacy_pcs_ops`. It sets the SerDes mode through the firmware's
  `SYS_MISC_SFP_SET` call (SGMII, 1000BASE-X, 2500BASE-X, 10GBASE-R, USXGMII)
  and reads link, speed and duplex back. It's set up on old firmware, then
  never selected.

### Options

- **A. Kernel patch (most feasible; days).** Return the legacy PCS for port 13
  only, and keep NULL for port 9.
  - It's about 5 lines in `kernel/patches/`, tested with `make kernel-install`
    on the 4E with a module in `sfp-lan`. The image's kernel stays the
    fallback.
  - The risk is low: software only, port 13 only, and a reboot undoes it.
  - Unknown: why the author disabled the legacy path. It may be caution about
    port 9, or `SYS_MISC_SFP_SET` on 1.0.70 may misbehave, or its link status
    may not track the SerDes.
- **B. Reverse-engineer the firmware to understand it (days to weeks).**
  - The firmware runs under MCUboot. The 1.0.85 upgrade file has a header
    declaring two image parts.
  - If the payload isn't encrypted (likely ARM Cortex-M code), Ghidra can show
    the command set, the XPCS API added in 1.0.84, and what
    `SYS_MISC_SFP_SET` does.
  - There's no 1.0.70 file to compare: it lives only in the switch's flash,
    and the driver can't read it back.
  - Useful as a diagnostic if A fails.
- **C. Modify the firmware (not feasible).**
  - The images are signed, and MCUboot checks the signature at boot against a
    built-in key. A modified image needs MaxLinear's private key, or getting
    around the bootloader by programming the flash chip directly.
  - A bad image takes down every MxL port, including the CPU link.
  - The SerDes registers are undocumented.
  - It would only reimplement what 1.0.85 already has.
  - Reverse-engineering for interoperability is generally allowed for
    personal use; redistributing modified MaxLinear firmware isn't.
- **D. Make the 1.0.85 upgrade reversible.** The driver says the switch boots
  from its own flash, so there's likely a dedicated SPI chip next to the
  MxL862xx.
  - If BPI's schematics show a clip-accessible chip, dump it before flashing
    1.0.85; flashing is then undoable.
  - 1.0.85: `mxl862xxc_1030_1085_1085_0069_signed_upgrade_xfi_v2.bin`,
    SHA-256 `68a510b7…4e672bf9b90`, via
    `devlink dev flash mdio_bus/mdio-bus:10`.
  - frank-w lost the switch PHYs after flashing it on a 7.2 tree (Aug 2026),
    so check the current driver first.

### Plan

1. A: write the port-13 patch, build it, and test it on the 4E's `sfp-lan`
   with the UF-RJ45-10G (or on the 8X's `lan6` with a 10G copper link). If it
   works, send it upstream.
2. If A fails: D, starting with the schematics, with B as a diagnostic.
3. Not C.

## Boot from NAND with the root filesystem on NVMe

u-boot goes in SPI-NAND, and the system runs from an M.2 NVMe drive. The SD
slot stays free for recovery, and the root filesystem gets much faster.

### Already there

- **frank-w's u-boot:** the boot menu has *Boot kernel from NVME*
  (`bootnvme`). It runs `pci enum` and `nvme scan`, loads `uEnv.txt` and
  `bpi-r4.itb` from NVMe partition 1, and boots with `root=/dev/nvme0n1p2`.
  There's also *Boot kernel from UBI* (`bootubi`).
- **u-boot releases:** they include SPI-NAND bl2 and fip (raw and UBI).
- **Kernel:** the PCIe controller (`PCIE_MEDIATEK_GEN3`) and its PHYs, NVMe,
  SPI-NAND, UBI and UBIFS are all built in, so no initramfs is needed.

### Layouts

- **A, only u-boot in NAND (preferred).**
  - NAND holds bl2, fip and u-boot's environment.
  - The NVMe drive gets two partitions: p1, a vfat boot partition with
    `bpi-r4.itb` and `uEnv.txt`; p2, the ext4 root.
  - It's frank-w's `bootnvme` layout as is: set `bootmenu_default=3` and run
    `saveenv` once.
  - `/boot` is still a vfat partition with `uEnv.txt`, so `make
    kernel-install`, `check-image` and the overlay checks keep working.
- **B, the kernel in a NAND UBI volume, the root on NVMe.**
  - Boots through `bootubi`, with `root=/dev/nvme0n1p2` in a `uEnv.txt` on
    the UBIFS volume.
  - Every kernel update writes UBIFS on NAND, which is slower and wears the
    flash, and `kernel-install` would need a separate path.
  - Its only gain is a kernel that boots without the drive, which needs a
    rescue initramfs to be useful.

### Work for A

- A third boot device, `nvme`, beside `sdmmc` and `emmc`.
- `scripts/mkimage` writes a plain two-partition GPT disk image instead of
  starting from u-boot's.
- `fstab` and `grow-rootfs` use `nvme0n1p1` and `p2` (or PARTUUIDs).
- A NAND image or flashing procedure for frank-w's SPI-NAND u-boot, writing
  only the bl2 and fip areas.

### Unknowns and risks

- **The M.2 slot must be in PCIe mode.** On the R4 Pro that's the
  `ov-pro-cn*` overlays: the slot's overlay must be in `addconf`, and u-boot
  must bring up that PCIe port. Test u-boot finding the drive in each slot.
- **NAND may hold factory data** (Wi-Fi calibration, MAC addresses). Back up
  all of NAND first, as was done on the 4E, and touch only bl2 and fip.
- **Untested:** the boot-menu default surviving `saveenv` on NAND.
- **Recovery:** the boot switch still selects SD, so a bad NAND u-boot isn't a
  brick.

**Effort:** a day or two of build-system work, plus a board test.

### u-boot defaults, and u-boot from source

A u-boot in NAND can't read a `uEnv.txt` until it knows which device to boot
from. So making NVMe the default needs `saveenv` by hand, a pre-filled
environment, or different built-in defaults. In order of need:

1. **A pre-filled environment (first, cheap).** The image's GPT has a
   `u-boot-env` partition. `mkenvimage` (u-boot-tools) can fill it at build
   time, for example with the boot-menu default and the boot delay, and
   `fw_setenv` can change it on a running board. First check how frank-w's
   u-boot stores its environment: which partition or UBI volume, at what
   offset and size, and whether it reads a saved one at all.
2. **u-boot from source (only when a u-boot patch or fix is needed).** A
   *u-boot: frank-w release | built from source* option, like the kernel's.
   - **What it builds:** bl2 and fip come from MediaTek's Arm Trusted Firmware
     fork (BL2 with the DRAM setup, and BL31) combined with frank-w's u-boot,
     packed with `fiptool`.
   - **Variants:** 4 GB and 8 GB DRAM, SD, eMMC and NAND, three boards.
   - **Partition layout:** the GPT would be ours, built with `sgdisk`, rather
     than the release's base image. That also serves the NVMe layout and
     rootless builds.
   - **Effort:** about two or three days, mostly testing each combination on
     a board.
   - **Risk:** a bad bl2 shows nothing, so it needs a working serial console.
     The boot switch always allows recovery from SD.
   - **Gain:** patches, and newer code than his releases: his latest release,
     2026.04, is older than the 2026.07 CI build the 4E already needs.

Until one of these is needed, prebuilt releases plus `uEnv.txt` cover
everything: the FIT file, overlays, console and board flags.

## Other open items

- **Boot-test the 8X** with `out/elroy/bpi-r4pro_trixie_7.2.0-custom_sdmmc.img.gz`:
  - router role: WAN lease, LAN DHCP and NAT, the ruleset loaded, chrony with
    GPS;
  - first boot: the root filesystem grown, new host keys;
  - the new kernel features: a WireGuard interface, an exFAT mount, the USB
    serial drivers and `cdc_mbim`.
- **`make kernel-install` on a real board:** u-boot booting `fit=`, and the
  boot-menu fallback to `bpi-r4.itb`.
- **EIP-197:** try `kernel/patches-eip197` on hardware. Check that
  `crypto_safexcel` probes, that it shows in `/proc/crypto`, and run
  `cryptsetup benchmark`. If it works, make the patch a default.
- **WAN failover health check:** route metrics fail over to the cellular modem
  or a USB uplink (a tethering phone, an ECM modem) only when the WAN's route
  goes. A service should ping out through the WAN, raise its route metric
  above the backups' while that fails, and restore it once pings succeed.
- **Cellular modem with a SIM:** test `modem-connect` and ModemManager's
  connection dispatcher (addresses, backup route, DNS on `wwan0`) on the 8X's
  RM520N. Without a SIM, only the waiting path has been tested.
- **USB tethering on hardware:** an Android phone (RNDIS or NCM) and an iPhone
  (`ipheth` after *Trust this computer*): check the DHCP lease and that the
  backup route takes over when the WAN cable is pulled.
- **Wi-Fi access point on hardware:** on the 8X's two MT7915E cards, where
  `wifi-ap plan` puts 5 GHz on `phy0` and 2.4 GHz on `phy1`: clients joining
  both bands with WPA2 and WPA3, DFS channels, the Wi-Fi subnet and the guest
  firewall. With a BE14: three access points on one radio, and 6 GHz.
- **Untested on hardware:** the switch role, Wi-Fi off,
  preinstalled devtools, bookworm, noble and resolute.
- **Ubuntu images:** consider leaving out `ubuntu-minimal` (rsyslog,
  ubuntu-pro-client, netplan, Rust coreutils, sudo-rs).
- **Rootless builds:** mmdebstrap in unshare mode, filesystems made from
  directories (`mkfs.ext4 -d`, mtools), no loop devices.
- **Tooling:** `scripts/check-board` for repeatable boot tests, and `make check`
  (defconfig round trips, `resolve-config` checks, script syntax).
