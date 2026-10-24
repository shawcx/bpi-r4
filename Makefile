# Image configuration with kconfiglib (sudo apt install python3-kconfiglib):
#   make <name>_defconfig   .config from configs/<name>_defconfig
#   make menuconfig         edit .config
#   make savedefconfig      minimal ./defconfig from .config (for configs/)
#   make [image]            build.sh --config .config [FLAGS="--clean ..."]
#   make kernel             build the kernel from source (Kernel build: source)
#   make kernel-menuconfig [FRAGMENT=kernel/x.config]   change its config
#   make kernel-savedefconfig OUT=kernel/x_defconfig    save it whole
#   make kernel-install HOST=root@endpoint   build it, install on a board
PYTHON ?= python3
KCONFIG := Kconfig
export KCONFIG_CONFIG ?= .config

.PHONY: image menuconfig olddefconfig savedefconfig help kernel kernel-menuconfig kernel-savedefconfig kernel-install

image: olddefconfig
	./build.sh --config $(KCONFIG_CONFIG) $(FLAGS)

menuconfig:
	$(PYTHON) -m menuconfig $(KCONFIG)

olddefconfig: $(KCONFIG_CONFIG)
	$(PYTHON) -m olddefconfig $(KCONFIG)

savedefconfig: $(KCONFIG_CONFIG)
	$(PYTHON) -m savedefconfig --kconfig $(KCONFIG) --out defconfig

kernel: olddefconfig
	scripts/kernel --config $(KCONFIG_CONFIG) build

kernel-menuconfig: olddefconfig
	scripts/kernel --config $(KCONFIG_CONFIG) menuconfig $(FRAGMENT)

kernel-savedefconfig: olddefconfig
	@test -n "$(OUT)" || { echo "usage: make kernel-savedefconfig OUT=kernel/<name>_defconfig" >&2; exit 1; }
	scripts/kernel --config $(KCONFIG_CONFIG) savedefconfig $(OUT)

kernel-install: olddefconfig
	@test -n "$(HOST)" || { echo "usage: make kernel-install HOST=root@<board>" >&2; exit 1; }
	scripts/kernel --config $(KCONFIG_CONFIG) install $(HOST)

%_defconfig: configs/%_defconfig
	$(PYTHON) -m defconfig --kconfig $(KCONFIG) $<

$(KCONFIG_CONFIG):
	@echo "no $@: run make <name>_defconfig or make menuconfig" >&2; exit 1

help:
	@sed -n 's/^# \{0,1\}//; 1,9p' Makefile
	@echo "defconfigs:"; ls configs | sed -n 's/^/  /; s/_defconfig$$//p'
