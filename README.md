# PS5 IW620 mwifiex port

Single-patch PS5 IW620 port for NXP mwifiex.

## Install

Run from this package root:

```sh
sudo ./install.sh
```
If no boot `lib/` payload exists, the installer logs that and continues; this
keeps kernel module upgrades independent from firmware delivery.

To remove the installed driver files:

```sh
sudo ./install.sh uninstall
```

## Fresh Build

Run from this package root:

```sh
git clone https://github.com/nxp-imx/mwifiex.git && cd mwifiex
git checkout lf-6.18.20_2.0.0
git apply ../ps5-iw620.patch
make CONFIG_OBJTOOL=
```

## Load

Run from the built driver root:

```sh
sudo DRIVER_DIR="$PWD" ../test-iw620.sh load
```

Equivalent manual load:

```sh
sudo modprobe cfg80211
sudo insmod ./mlan.ko
sudo insmod ./moal.ko fw_name=nxp/pcieuartiw620_combo_v1.bin pcie_int_mode=1 drv_mode=1 cfg80211_wext=4 sta_name=mlan ext_scan=1 auto_fw_reload=0 wifi_reset_config=0 sched_scan=0 ps_mode=2 auto_ds=2 amsdu_disable=1
```

## Test

Run from the built driver root:

```sh
sudo DRIVER_DIR="$PWD" ../test-iw620.sh capture
```
