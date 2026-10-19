# PS5 IW620 mwifiex port

PS5 IW620 port for NXP mwifiex, as patches over `nxp-imx/mwifiex` at
`lf-6.18.2_1.0.0`.

## Patches

Applied in this order by `install.sh` — the order matters, later patches are
generated against the tree the earlier ones produce:

| Patch | What it does |
| --- | --- |
| `ps5-iw620.patch` | The PS5 port itself, including the fake-complete connected-state scan stability workaround. |
| `ps5-iw620-cmd-timeout-recover.patch` | Command-timeout handling: always release the timed-out command and wake its ioctl waiter, then decide whether to carry on or declare a hang. |
| `ps5-iw620-kernel71-compat.patch` | cfg80211 API changes for kernel >= 7 (applied conditionally). |
| `ps5-iw620-kernel72-compat.patch` | Kernel 7.2 string and cfg80211 API compatibility. |
| `ps5-iw620-rtnl-bounded-wait.patch` | Bounds the firmware round-trips in `woal_cfg80211_dump_station_info()` so a dead firmware cannot strand RTNL. |
| `ps5-iw620-he.patch` | Corrects the IW620 5 GHz HE profile across firmware configuration, association and cfg80211; requests TX BA timeout zero. |
| `ps5-iw620-tx-min128.patch` | Pads short IW620 data DMA transfers to 128 bytes while preserving real packet lengths and DMA ownership. |
| `ps5-iw620-tx-priority.patch` | Maps IW620 STA TX TIDs 1→2, 3→0 and 5→4 within their access categories before queue selection and BA bookkeeping to avoid priority-triggered stalls. |

### IW620 HE and aggregation

The observed HE capability advertises PPE thresholds without supplying the bytes.
The HE patch recognizes that exact capability, supplies the corrected 5 GHz
profile and keeps its firmware/association/cfg80211 copies consistent. On
2.4 GHz it clears the unsupported PPE flag. Unknown capability inputs are
left alone. The default STA TX block-ack window changes from 32 to 64 frames
by removing the timeout patch's override, and IW620 STA requests use a zero
TX BA inactivity timeout. These changes target the burst failure reported in
[#3](https://github.com/ps5-linux/ps5-linux-mwifiex/issues/3).

The IW620 register table specifies a 128-byte TX descriptor minimum, but the
normal TX path did not apply it. The TX patch uses a zero-tailed 128-byte
buffer for short transfers, retained until completion or teardown with
matching map/unmap lengths. The interface header, TxPD and Ethernet lengths
stay intact. Larger packets keep their existing mapping, ring size and
interrupt policy.

An instrumented development build passed 180- and 900-second concurrent TLS
bursts on one PS5 CFI-1108A boot at 5 GHz/80 MHz, with HE TX and TX/RX BA
active and zero driver timeouts. The longer run completed 13,815 requests
and padded 316,222 short transfers. The original
launcher workload also survived (user-reported). This cleaned patch stack is
build/offline-tested; independent fresh-boot and exact PR-build hardware
confirmation remain outstanding. Short-buffer copying and kernel differences
have not been isolated from padding as the cause of the improvement.

The TX minimum applies to IW620 ADMA transfers regardless of firmware version.
Hardware validation covers one console/firmware combination. AP mode, roaming
and suspend/resume are outside the recorded validation.

### Timeout handling

A firmware lockup used to freeze the **entire machine**, not just wifi.
`woal_cfg80211_dump_station_info()` runs while cfg80211 holds the wiphy mutex and
`nl80211_pre_doit()` holds RTNL. `MOAL_IOCTL_WAIT` has no timeout, so once the
command queue wedged, NetworkManager blocked there forever, RTNL was stranded,
and every network-touching syscall on the box blocked in D state — no desktop
icons, nothing responsive, hard power-off the only way out.

Two independent causes, hence two patches:

1. **The queue wedged.** On a command timeout the driver left `curr_cmd` set and
   `cmd_sent` MTRUE unless the command was on a small whitelist, so every later
   ioctl queued behind a command that would never be sent. Releasing the command
   and completing its ioctl now happens on *every* timeout; the whitelist only
   decides whether to carry on or escalate to a hang.

   Note `num_cmd_timeout` must be cleared after a recovery —
   `wlan_process_cmdresp()` drops **all** command responses while it is non-zero.
   The soft-recovery cap therefore uses its own `soft_cmd_timeout` counter.

2. **The wait was unbounded.** The four firmware round-trips in
   `woal_cfg80211_dump_station_info()` (signal, stats, bss_info, dtim_period) now
   use `MOAL_IOCTL_WAIT_TIMEOUT`, capping each at 20s. That function backs both
   `.get_station` and `.dump_station`.

### Firmware auto-reset (off by default)

`woal_request_fw_reload()` rejects every mode with `-EINVAL` unless the low byte
of `indrstcfg` is 1 or 2, and the module default is `0xffffffff`. So
`auto_fw_reload` on its own does nothing — both options are needed together:

```sh
sudo FW_RESET_OPTIONS="indrstcfg=2 auto_fw_reload=3" ./install.sh
```

Untested on PS5 hardware, and each attempt costs a cold power cycle. Change one
variable at a time.

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

Run from this package root. Apply compatibility patches using the same
running-kernel check as `install.sh`:

```sh
git clone https://github.com/nxp-imx/mwifiex.git && cd mwifiex
git checkout lf-6.18.2_1.0.0
git apply ../ps5-iw620.patch || exit 1
git apply ../ps5-iw620-cmd-timeout-recover.patch || exit 1
if [ "$(uname -r | cut -d. -f1)" -ge 7 ]; then
    git apply ../ps5-iw620-kernel71-compat.patch || exit 1
    git apply ../ps5-iw620-kernel72-compat.patch || exit 1
fi
for patch in ps5-iw620-rtnl-bounded-wait.patch ps5-iw620-he.patch \
    ps5-iw620-tx-min128.patch ps5-iw620-tx-priority.patch; do
    git apply "../$patch" || exit 1
done
make
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
