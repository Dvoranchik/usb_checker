# USB Checker

A single-file bash tool that shows which USB devices are connected right now
and reconstructs when they were connected before. It only reads system data:
nothing is installed, nothing is modified.

```console
$ ./usb_checker.sh
...
1. USB STORAGE DEVICES (connected now): 1
------------------------------------------------------------------------------
 [1] /dev/sdb  Cruzer Blade
     Vendor      : SanDisk
     Serial      : 4C530001230101116
     USB         : 0781:5567  port 1-2
     Capacity    : 14.43 GiB   removable: yes
     Partitions  : sdb1 -> /media/user/USB Stick
     Seen since  : 2026-10-28 09:12:33 (udev database)
     First log   : 2026-10-27 21:00:01   sessions: 1
```

## Features

- USB storage devices: vendor, model, **serial number**, capacity, removable
  flag, partitions, filesystems and mount points.
- Every other USB device on the bus: hubs, cameras, keyboards, network cards
  (`/sys/bus/usb/devices`).
- Connection history: connect/disconnect sessions with timestamps, port,
  product and serial, rebuilt from the systemd journal or from syslog.
- Output: human readable report, CSV (RFC 4180), JSON, self-contained HTML
  with sorting, search and client-side export.
- No Python, no Perl, no jq: only bash and standard Unix utilities.
- Works without `udevadm`, without `lsblk`, without `lsusb`, without systemd.

## Supported systems

| Distribution | Status |
|---|---|
| Astra Linux SE 1.6 / 1.7 / 2.x | supported |
| ALT Linux 8 / 9 / 10 / p10 / SPT | supported |
| RED OS 7.x / 8.x | supported |
| Debian, Ubuntu, Mint, Kali | supported |
| RHEL, CentOS, Rocky, Alma, Fedora | supported |
| openSUSE, SLES | supported |
| Arch, Manjaro | supported |
| Alpine and other BusyBox systems | supported with the `bash` package |
| macOS, BSD, Windows | **not supported** (exit code 3 with an explanation) |

Requirements: Linux with `sysfs` (kernel 2.6.25 or newer) and `bash` 3.2 or
newer. Both are present by default in every distribution listed above.

## Requirements

Required: `bash`, `awk`, `sed`, `grep`, `sort`, `date`, `tr`, `uname`, read
access to `/sys` and `/proc`.

Optional, used automatically when present:

| Tool | Used for |
|---|---|
| `udevadm` | precise USB detection and serial numbers (recommended) |
| `journalctl` | best source of connection history |
| `gzip` / `bzip2` / `xz` | reading rotated log files |
| `lspci` | readable USB controller names |
| `lsusb` | extra descriptor dump in `--list-devices -v` |

`root` is only needed to read the full journal or `/var/log`; without it the
tool still shows currently connected devices.

## Usage

```bash
chmod +x usb_checker.sh

./usb_checker.sh                     # full report (default)
./usb_checker.sh --list-devices      # what is connected right now
./usb_checker.sh --history           # connection history only

./usb_checker.sh --export-csv  > usb.csv
./usb_checker.sh --export-json > usb.json
./usb_checker.sh --export-html -o usb.html
./usb_checker.sh --export-fusb            # ./FUSB_CSV_20261028130000/
./usb_checker.sh --export-fusb -o /tmp    # /tmp/FUSB_CSV_20261028130000/

sudo ./usb_checker.sh -s "30 days ago"   # limit the journal window
```

### Options

| Option | Description |
|---|---|
| `-r, --report` | full text report (default) |
| `-l, --list-devices` | compact list of devices connected now |
| `-y, --history` | connection history only |
| `-c, --export-csv` | inventory as CSV, every field quoted |
| `-j, --export-json` | inventory, history and bus tree as JSON |
| `-H, --export-html` | single-file HTML report |
| `-f, --export-fusb` | `FUSB_CSV_<timestamp>/` with `UsbDevices.csv` + `UsbStor.csv` |
| `-o, --output FILE` | write to FILE instead of stdout (for `--export-fusb`: parent directory) |
| `-s, --since TIME` | journal window, e.g. `"7 days ago"`, `2026-01-01` |
| `--no-color` | disable ANSI colors (auto when piped) |
| `-v, --verbose` | diagnostics on stderr, full `lsusb` dump |
| `-h, --help` | usage |
| `-V, --version` | version |

Exit codes: `0` success, `1` runtime error, `2` usage error, `3` unsupported
platform.

## How detection works

The script does not parse `lsblk` output (its layout differs between
util-linux versions and it is absent in minimal images). Instead it reads
sysfs and falls back in this order:

1. `udevadm info --query=property --name=/dev/sdX` → `ID_BUS=usb`
   (also gives `ID_SERIAL_SHORT`, `ID_VENDOR_ID`, `ID_MODEL_ID`);
2. the canonical sysfs path of the device contains a USB bus component
   (`/sys/devices/.../usb1/1-2/.../block/sdb`);
3. the device `uevent` node names a USB driver.

Serial numbers are taken from `ID_SERIAL_SHORT`, then from the USB device
node (`.../1-2/serial`), then from the block device attributes. If a device
does not report a serial in its firmware, the report says so instead of
inventing a value.

Mount points come from `/proc/mounts` (not `findmnt`), so partitions mounted
under a path with spaces are decoded correctly.

## How history works

Sources are tried in this order, and the first one that yields events is used,
so the same kernel message is never counted twice:

1. `journalctl --no-pager -o short-iso` (all boots, or `--since`);
2. `/var/log/kern.log*`, then `syslog*`, then `messages*` (rotated and
   compressed files are read too);
3. `dmesg` (timestamps are converted from uptime to wall clock; needs root).


## Output formats

- **Text** – report with five sections (storage, other USB devices, history,
  summary, system). No ANSI escapes when the output is piped.
- **CSV** – one row per device, connected or seen only in logs, all 14 fields
  quoted, embedded quotes doubled, UTF-8, CRLF-free.
- **JSON** – `tool`, `version`, `generated`, `host`, `sources`, `summary`,
  `devices[]`, `peripherals[]`, `history[]`. `<`, `>` and `&` are written as
  `\u003c`, `\u003e`, `\u0026`, so the payload can be inlined into HTML
  safely.
- **HTML** – a single file, no external requests. Data is embedded as JSON and
  rendered with `textContent`, so hostile device names cannot inject markup.
  Sorting, filtering, CSV and JSON download work offline.
