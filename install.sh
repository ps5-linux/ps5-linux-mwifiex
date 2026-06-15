#!/bin/sh
set -eu

REPO_URL=https://github.com/nxp-imx/mwifiex.git
REF=lf-6.18.2_1.0.0

KERNEL_RELEASE=$(uname -r)
KERNELDIR=/lib/modules/$KERNEL_RELEASE/build

script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd)
BUILD_DIR=$script_dir/build
DRIVER_DIR=$BUILD_DIR/mwifiex
PATCH_FILE=$script_dir/ps5-iw620.patch
RECOVER_PATCH=$script_dir/ps5-iw620-cmd-timeout-recover.patch
KERNEL71_PATCH=$script_dir/ps5-iw620-kernel71-compat.patch

MODULE_DIR=/lib/modules/$KERNEL_RELEASE/extra/ps5-iw620
MODPROBE_CONF=/etc/modprobe.d/ps5-iw620.conf
FW_NAME=nxp/pcieuartiw620_combo_v1.bin
FW_PATH=/lib/firmware/$FW_NAME

MOAL_OPTIONS="fw_name=$FW_NAME pcie_int_mode=1 drv_mode=1 cfg80211_wext=4 sta_name=mlan ext_scan=1 auto_fw_reload=0 wifi_reset_config=0 sched_scan=0 ps_mode=0 auto_ds=0 amsdu_disable=0"

usage() {
	cat <<EOF
Usage: $0 [uninstall]

Run without arguments to build, install, and load the driver.
Run with uninstall to remove the installed modules and modprobe config.
EOF
}

say() {
	printf '%s\n' "$*"
}

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

need_root() {
	[ "$(id -u)" -eq 0 ] || die "run install/uninstall as root"
}

git_driver() {
	git -c safe.directory="$DRIVER_DIR" -C "$DRIVER_DIR" "$@"
}

prepare_source() {
	[ -f "$PATCH_FILE" ] || die "patch file not found: $PATCH_FILE"
	[ -d "$KERNELDIR" ] || die "kernel build directory not found: $KERNELDIR"

	mkdir -p "$BUILD_DIR"

	if [ ! -d "$DRIVER_DIR/.git" ]; then
		[ ! -e "$DRIVER_DIR" ] || die "$DRIVER_DIR exists but is not a git checkout"
		say "Cloning driver source into $DRIVER_DIR"
		git clone "$REPO_URL" "$DRIVER_DIR"
	else
		say "Using existing driver source at $DRIVER_DIR"
	fi

	say "Updating driver source"
	if ! git_driver fetch --tags origin; then
		git_driver rev-parse --verify "$REF^{commit}" >/dev/null 2>&1 ||
			die "failed to fetch driver source and $REF is not available locally"
		say "Fetch failed; using local $REF"
	fi

	say "Checking out $REF"
	git_driver checkout "$REF"

	if git_driver apply --check "$PATCH_FILE" >/dev/null 2>&1; then
		say "Applying PS5 IW620 patch"
		git_driver apply "$PATCH_FILE"
	elif git_driver apply -R --check "$PATCH_FILE" >/dev/null 2>&1; then
		say "PS5 IW620 patch is already applied"
	else
		die "patch does not apply cleanly in $DRIVER_DIR"
	fi

	[ -f "$RECOVER_PATCH" ] || die "patch file not found: $RECOVER_PATCH"
	if git_driver apply --check "$RECOVER_PATCH" >/dev/null 2>&1; then
		say "Applying PS5 IW620 command-timeout recovery patch"
		git_driver apply "$RECOVER_PATCH"
	elif git_driver apply -R --check "$RECOVER_PATCH" >/dev/null 2>&1; then
		say "PS5 IW620 command-timeout recovery patch is already applied"
	else
		die "recovery patch does not apply cleanly in $DRIVER_DIR"
	fi

	KERNEL_MAJOR=$(uname -r | cut -d. -f1)
	if [ "$KERNEL_MAJOR" -ge 7 ]; then
		[ -f "$KERNEL71_PATCH" ] || die "patch file not found: $KERNEL71_PATCH"
		if git_driver apply --check "$KERNEL71_PATCH" >/dev/null 2>&1; then
			say "Applying kernel 7.1 cfg80211 API compatibility patch"
			git_driver apply "$KERNEL71_PATCH"
		elif git_driver apply -R --check "$KERNEL71_PATCH" >/dev/null 2>&1; then
			say "Kernel 7.1 cfg80211 API compatibility patch is already applied"
		else
			die "kernel71 compat patch does not apply cleanly in $DRIVER_DIR"
		fi
	fi
}

build_driver() {
	prepare_source

	say "Building modules for $KERNEL_RELEASE"
	make -C "$DRIVER_DIR" CONFIG_OBJTOOL= KERNELDIR="$KERNELDIR" ARCH=x86 -j"$(nproc)"

	[ -f "$DRIVER_DIR/mlan.ko" ] || die "missing built module: $DRIVER_DIR/mlan.ko"
	[ -f "$DRIVER_DIR/moal.ko" ] || die "missing built module: $DRIVER_DIR/moal.ko"
}

copy_boot_lib_payload() {
	fw_src=/boot/efi/lib/$FW_NAME

	if [ ! -f "$fw_src" ]; then
		say "Firmware not found at $fw_src; skipping firmware copy"
		return
	fi

	say "Installing firmware to $FW_PATH"
	install -d "$(dirname "$FW_PATH")"
	install -m 0644 "$fw_src" "$FW_PATH"
}

write_modprobe_config() {
	say "Writing modprobe config to $MODPROBE_CONF"
	install -d "$(dirname "$MODPROBE_CONF")"
	cat >"$MODPROBE_CONF" <<EOF
# PS5 IW620 mwifiex
softdep moal pre: cfg80211 mlan
options moal $MOAL_OPTIONS
EOF
}

install_driver() {
	need_root
	build_driver
	copy_boot_lib_payload

	say "Installing modules to $MODULE_DIR"
	install -d "$MODULE_DIR"
	install -m 0644 "$DRIVER_DIR/mlan.ko" "$MODULE_DIR/mlan.ko"
	install -m 0644 "$DRIVER_DIR/moal.ko" "$MODULE_DIR/moal.ko"

	write_modprobe_config

	say "Running depmod for $KERNEL_RELEASE"
	depmod "$KERNEL_RELEASE"

	say "Loading installed driver"
	if modprobe moal; then
		say "Driver loaded"
	else
		say "Install finished, but modprobe moal failed. Check dmesg for details."
	fi
}

uninstall_driver() {
	need_root

	say "Removing installed modules"
	rm -f "$MODULE_DIR/mlan.ko" "$MODULE_DIR/moal.ko"
	rmdir "$MODULE_DIR" 2>/dev/null || true

	say "Removing $MODPROBE_CONF"
	rm -f "$MODPROBE_CONF"

	say "Running depmod for $KERNEL_RELEASE"
	depmod "$KERNEL_RELEASE"
}

cmd=${1:-}

case "$cmd" in
	"") install_driver ;;
	uninstall) uninstall_driver ;;
	-h|--help|help) usage ;;
	*) usage >&2; exit 2 ;;
esac
