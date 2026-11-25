#!/bin/bash
# ============================================================================
#  usb_checker.sh - USB device inventory and connection history
#
#  Version : 2.0.0
#  License : MIT
#  Requires: bash >= 3.2 (present in every supported distribution)
#
#  Works on any Linux that exposes sysfs (kernel >= 2.6.25), including:
#    * Astra Linux SE 1.6 / 1.7 / 2.x      (Debian based)
#    * ALT Linux 8 / 9 / 10 / SPT          (ALT based)
#    * RED OS 7.x / 8.x                    (RHEL based)
#    * Debian, Ubuntu, Mint, Kali
#    * RHEL, CentOS, Rocky, Alma, Fedora
#    * openSUSE / SLES, Arch / Manjaro
#    * Alpine and other BusyBox systems (bash package required)
#
#  Everything below is optional and only used when present:
#    udevadm    - precise USB identification (ID_BUS, serials)
#    journalctl - systemd journal, best source of connection history
#    gzip       - reading rotated /var/log/*.gz
#    lspci      - pretty USB controller names
#    lsusb      - extra descriptor dump for --list-devices
#
#  No Python, no Perl, no jq: only POSIX shell utilities and awk.
# ============================================================================

export LC_ALL=C
unset CDPATH 2>/dev/null || true

APP_NAME="usb_checker"
APP_VERSION="2.0.0"

# ---------------------------------------------------------------------------
# Defaults / environment overrides (overrides are also used by the test suite)
# ---------------------------------------------------------------------------
SYS_ROOT="${USB_CHECKER_SYS_ROOT:-/sys}"
PROC_ROOT="${USB_CHECKER_PROC_ROOT:-/proc}"
DEV_ROOT="${USB_CHECKER_DEV_ROOT:-/dev}"
RUN_ROOT="${USB_CHECKER_RUN_ROOT:-/run}"
LOG_ROOT="${USB_CHECKER_LOG_ROOT:-/var/log}"
UDEVADM="${USB_CHECKER_UDEVADM:-udevadm}"
OS_RELEASE="${USB_CHECKER_OS_RELEASE:-/etc/os-release}"

ACTION=""
OUT_FILE=""
SINCE=""
VERBOSE=0
COLOR=auto
NEED_HISTORY=1
HISTORY_SOURCE="none"
JOURNAL_OK=0
TMPD=""
TAB=$(printf '\t')

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

die() {
    printf 'error: %s\n' "$1" >&2
    exit "${2:-1}"
}

warn() {
    printf 'warning: %s\n' "$1" >&2
}

debug() {
    [ "$VERBOSE" = 1 ] && printf 'debug: %s\n' "$1" >&2
    return 0
}

now_human() {
    date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date
}

now_zone() {
    date '+%Y-%m-%d %H:%M:%S %z' 2>/dev/null || now_human
}

now_epoch() {
    date '+%s' 2>/dev/null || echo 0
}

# First line of a file, trimmed. Returns 1 when the file is missing/empty.
read_val() {
    [ -r "$1" ] || return 1
    local v
    v=$(head -n 1 "$1" 2>/dev/null | tr -d '\000\r')
    [ -n "$v" ] || return 1
    v=${v#"${v%%[![:space:]]*}"}
    v=${v%"${v##*[![:space:]]}"}
    [ -n "$v" ] || return 1
    printf '%s' "$v"
}

# Strip characters that would break our tab separated intermediate files.
sanitize() {
    printf '%s' "$1" | tr '\t\r\n' '   '
}

# Resolve symlinks without relying on GNU `readlink -f` (absent in some systems).
resolve_path() {
    local p=$1 t d i=0
    while [ -L "$p" ] && [ "$i" -lt 20 ]; do
        t=$(readlink "$p" 2>/dev/null) || break
        case $t in
            /*) p=$t ;;
            *)  d=$(dirname "$p")
                p="$d/$t" ;;
        esac
        i=$((i + 1))
    done
    d=$(cd "$(dirname "$p")" 2>/dev/null && pwd -P) || { printf '%s' "$p"; return 0; }
    printf '%s/%s' "$d" "$(basename "$p")"
}

# File modification time in epoch seconds (GNU stat, then BSD stat).
file_mtime() {
    stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || return 1
}

# First whitespace separated word of a file (used for /sys/.../dev "8:16").
read_major_minor() {
    local line maj min
    line=$(read_val "$1") || return 1
    maj=${line%%:*}
    min=${line#*:}
    case ${maj:-x} in ''|*[!0-9]*) return 1 ;; esac
    case ${min:-x} in ''|*[!0-9]*) return 1 ;; esac
    printf '%s %s' "$maj" "$min"
}

# Escape a value so it can be embedded in a JSON (and therefore JS) string.
# '<' and '>' are escaped with \u sequences so data can never terminate a
# <script> element when the JSON is inlined into the HTML report.
json_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' \
                            -e 's/"/\\"/g' \
                            -e 's/	/\\t/g' \
                            -e 's/\r//g' \
                            -e 's/</\\u003c/g' \
                            -e 's/>/\\u003e/g' \
                            -e 's/&/\\u0026/g' \
                            -e 's/[[:cntrl:]]//g'
}

# JSON string literal (with quotes).
json_str() {
    printf '"%s"' "$(json_escape "$1")"
}

html_escape() {
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' \
                            -e 's/</\&lt;/g' \
                            -e 's/>/\&gt;/g' \
                            -e 's/"/\&quot;/g'
}

# RFC 4180: every field quoted, embedded quotes doubled.
csv_q() {
    printf '"%s"' "$(printf '%s' "$1" | sed 's/"/""/g')"
}

# Decode octal escapes used by the kernel in /proc/mounts.
unescape_mount() {
    printf '%s' "$1" | sed -e 's/\\040/ /g' -e 's/\\011/\t/g' \
                            -e 's/\\012/\n/g' -e 's/\\134/\\/g'
}

# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------
setup_colors() {
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_BOLD=""; C_OFF=""
    case $COLOR in
        0|no|never|off) return 0 ;;
    esac
    [ -n "${NO_COLOR:-}" ] && return 0
    [ -t 1 ] || return 0
    [ -n "$OUT_FILE" ] && return 0
    case ${TERM:-dumb} in dumb|"") return 0 ;; esac
    C_RED=$(printf '\033[31m')
    C_GREEN=$(printf '\033[32m')
    C_YELLOW=$(printf '\033[33m')
    C_BLUE=$(printf '\033[34m')
    C_BOLD=$(printf '\033[1m')
    C_OFF=$(printf '\033[0m')
}

LINE="------------------------------------------------------------------------------"

section() {
    printf '\n%s%s%s\n' "$C_BOLD" "$1" "$C_OFF"
    printf '%s\n' "$LINE"
}

# ---------------------------------------------------------------------------
# udev / sysfs primitives
# ---------------------------------------------------------------------------
udev_props() {  # $1 = kernel name (sdb)
    local bin=$UDEVADM
    [ -n "$bin" ] || return 1
    if [ -x "$bin" ]; then
        "$bin" info --query=property --name="$DEV_ROOT/$1" 2>/dev/null
    elif have "$bin"; then
        "$bin" info --query=property --name="$DEV_ROOT/$1" 2>/dev/null
    else
        return 1
    fi
}

# Walk up from a block device until the USB device node (idVendor+idProduct).
usb_device_dir() {
    local d i=0
    d=$(resolve_path "$1")
    while [ -n "$d" ] && [ "$d" != "/" ] && [ "$i" -lt 12 ]; do
        if [ -r "$d/idVendor" ] && [ -r "$d/idProduct" ]; then
            printf '%s' "$d"
            return 0
        fi
        d=$(dirname "$d")
        i=$((i + 1))
    done
    return 1
}

usb_attr() {  # $1 = block dir, $2 = attribute name
    local d
    d=$(usb_device_dir "$1") || return 1
    read_val "$d/$2"
}

# Is this block device attached over USB?
is_usb_storage() {
    local dir=$1 name=${1##*/} props resolved

    props=$(udev_props "$name")
    case $props in
        *ID_BUS=usb*) return 0 ;;
    esac

    resolved=$(resolve_path "$dir")
    case "/$resolved/" in
        */usb[0-9]*/*) return 0 ;;
    esac

    if [ -r "$dir/device/uevent" ] && grep -q 'DRIVER=usb' "$dir/device/uevent" 2>/dev/null; then
        return 0
    fi
    return 1
}

device_serial() {
    local dir=$1 name=${1##*/} props s usbdir

    props=$(udev_props "$name")
    if [ -n "$props" ]; then
        s=$(printf '%s\n' "$props" | sed -n 's/^ID_SERIAL_SHORT=//p' | head -n 1)
        [ -n "$s" ] && { printf '%s' "$s"; return 0; }
        s=$(printf '%s\n' "$props" | sed -n 's/^ID_SERIAL=//p' | head -n 1)
        [ -n "$s" ] && { printf '%s' "$s"; return 0; }
    fi

    usbdir=$(usb_device_dir "$dir")
    if [ -n "$usbdir" ]; then
        s=$(read_val "$usbdir/serial")
        [ -n "$s" ] && { printf '%s' "$s"; return 0; }
    fi

    s=$(read_val "$dir/device/serial")
    [ -n "$s" ] && { printf '%s' "$s"; return 0; }

    s=$(read_val "$dir/serial")
    [ -n "$s" ] && { printf '%s' "$s"; return 0; }

    return 1
}

device_model() {
    local dir=$1 m
    m=$(read_val "$dir/device/model") || m=""
    [ -n "$m" ] || m=$(usb_attr "$dir" product) || m=""
    [ -n "$m" ] || m=$(usb_attr "$dir" manufacturer) || m=""
    [ -n "$m" ] || m="Unknown"
    printf '%s' "$m"
}

device_vendor() {
    local dir=$1 v
    v=$(read_val "$dir/device/vendor") || v=""
    [ -n "$v" ] || v=$(usb_attr "$dir" manufacturer) || v=""
    printf '%s' "$v"
}

block_size_bytes() {
    local sectors
    sectors=$(read_val "$1/size") || return 1
    case $sectors in
        ''|*[!0-9]*) return 1 ;;
    esac
    printf '%s' $((sectors * 512))
}

human_size() {
    awk -v b="${1:-0}" 'BEGIN {
        if (b >= 1099511627776)      printf "%.2f TiB", b / 1099511627776;
        else if (b >= 1073741824)    printf "%.2f GiB", b / 1073741824;
        else if (b >= 1048576)       printf "%.1f MiB", b / 1048576;
        else if (b >= 1024)          printf "%.0f KiB", b / 1024;
        else                         printf "%d B", b;
    }'
}

gib_value() {
    awk -v b="${1:-0}" 'BEGIN { printf "%.2f", b / 1073741824 }'
}

# "mountpoint|fstype" for a device from /proc/mounts, or nothing.
mount_info() {
    local want=$1 line mp fs
    [ -r "$PROC_ROOT/mounts" ] || return 1
    while IFS= read -r line; do
        set -- $line
        [ "$1" = "$want" ] || continue
        mp=$(unescape_mount "$2")
        fs=$3
        printf '%s|%s' "$mp" "$fs"
        return 0
    done < "$PROC_ROOT/mounts"
    return 1
}

partitions_of() {  # $1 = block dir, $2 = kernel name
    local p
    for p in "$1/$2"*; do
        [ -d "$p" ] || continue
        [ -r "$p/partition" ] || continue
        printf '%s\n' "${p##*/}"
    done
}

# /run/udev/data/bMAJ:MIN mtime ~ the moment the device appeared in this boot.
udev_seen_epoch() {
    local name=$1 maj min f
    set -- $(read_major_minor "$SYS_ROOT/block/$name/dev") || return 1
    maj=$1
    min=$2
    [ -n "${maj:-}" ] && [ -n "${min:-}" ] || return 1
    f="$RUN_ROOT/udev/data/b$maj:$min"
    [ -e "$f" ] || return 1
    file_mtime "$f"
}

# ---------------------------------------------------------------------------
# Collection: storage devices
# ---------------------------------------------------------------------------
collect_storage() {
    local d name
    for d in "$SYS_ROOT"/block/*; do
        [ -d "$d" ] || continue
        name=${d##*/}
        case $name in
            loop*|ram*|zram*|dm-*|md*|nbd*|rbd*|drbd*|ubiblock*|mmcblk*boot*|mmcblk*rpmb*)
                continue ;;
        esac
        is_usb_storage "$d" || continue
        debug "storage device detected: $name"
        add_storage "$d" "$name"
    done
}

add_storage() {
    local dir=$1 name=$2
    local model vendor serial size_b size_h port usb_id mount removable seen
    local usbdir part psize fs_info mp fs parts_list props

    usbdir=$(usb_device_dir "$dir") || usbdir=""
    port=""
    usb_id=""
    if [ -n "$usbdir" ]; then
        port=${usbdir##*/}
        usb_id="$(read_val "$usbdir/idVendor")"
        usb_id="${usb_id}:$(read_val "$usbdir/idProduct")"
    else
        # No USB node in sysfs (unusual): udev still knows the identifiers.
        props=$(udev_props "$name")
        if [ -n "$props" ]; then
            usb_id=$(printf '%s\n' "$props" | sed -n 's/^ID_VENDOR_ID=//p' | head -n 1)
            usb_id="$usb_id:$(printf '%s\n' "$props" | sed -n 's/^ID_MODEL_ID=//p' | head -n 1)"
        fi
    fi

    model=$(device_model "$dir")
    vendor=$(device_vendor "$dir")
    serial=$(device_serial "$dir") || serial=""
    size_b=$(block_size_bytes "$dir") || size_b=0
    size_h=$(human_size "$size_b")
    removable=$(read_val "$dir/removable") || removable="0"
    seen=$(udev_seen_epoch "$name") || seen=0

    parts_list=""
    for part in $(partitions_of "$dir" "$name"); do
        psize=$(block_size_bytes "$dir/$part") || psize=0
        if fs_info=$(mount_info "$DEV_ROOT/$part"); then
            mp=${fs_info%%|*}
            fs=${fs_info#*|}
        else
            mp="-"
            fs="-"
        fi
        printf '%s\t%s\t%s\t%s\t%s\n' \
            "$name" "$part" "$fs" "$(human_size "$psize")" "$mp" >> "$TMPD/parts.tsv"
        if [ "$mp" != "-" ]; then
            if [ -n "$parts_list" ]; then
                parts_list="$parts_list, $part -> $mp"
            else
                parts_list="$part -> $mp"
            fi
        else
            if [ -n "$parts_list" ]; then
                parts_list="$parts_list, $part"
            else
                parts_list="$part"
            fi
        fi
    done

    if [ -z "$parts_list" ]; then
        if fs_info=$(mount_info "$DEV_ROOT/$name"); then
            mp=${fs_info%%|*}
            fs=${fs_info#*|}
            parts_list="whole disk -> $mp ($fs)"
            printf '%s\t%s\t%s\t%s\t%s\n' \
                "$name" "$name" "$fs" "$size_h" "$mp" >> "$TMPD/parts.tsv"
        else
            parts_list="-"
        fi
    fi

    # Every field is written with a "-" placeholder when unknown: bash `read`
    # treats TAB as IFS whitespace and would collapse empty fields otherwise.
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$(sanitize "${name:--}")" \
        "$(sanitize "${model:--}")" \
        "$(sanitize "${vendor:--}")" \
        "$(sanitize "${serial:--}")" \
        "${size_b:-0}" \
        "$(sanitize "${size_h:--}")" \
        "$(sanitize "${port:--}")" \
        "$(sanitize "${usb_id:--}")" \
        "$(sanitize "${parts_list:--}")" \
        "$(sanitize "${removable:--}")" \
        "${seen:-0}" >> "$TMPD/devices.tsv"
}

# ---------------------------------------------------------------------------
# Collection: every USB device on the bus (keyboard, camera, hub, ...)
# ---------------------------------------------------------------------------
collect_peripherals() {
    local base="$SYS_ROOT/bus/usb/devices" d port vid pid product manuf serial cls
    [ -d "$base" ] || return 0
    for d in "$base"/*; do
        [ -r "$d/idVendor" ] || continue
        port=${d##*/}
        vid=$(read_val "$d/idVendor") || continue
        pid=$(read_val "$d/idProduct") || pid=""
        product=$(read_val "$d/product") || product=""
        manuf=$(read_val "$d/manufacturer") || manuf=""
        serial=$(read_val "$d/serial") || serial=""
        cls=$(read_val "$d/bDeviceClass") || cls=""
        case $cls in
            09) [ -z "$product" ] && product="USB hub" ;;
        esac
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$(sanitize "${port:--}")" \
            "$(sanitize "${vid:--}:${pid:--}")" \
            "$(sanitize "${product:--}")" \
            "$(sanitize "${manuf:--}")" \
            "$(sanitize "${serial:--}")" \
            "$(sanitize "${cls:--}")" >> "$TMPD/usb.tsv"
    done
    if [ -s "$TMPD/usb.tsv" ]; then
        sort -t "$TAB" -k1,1 "$TMPD/usb.tsv" -o "$TMPD/usb.tsv"
    fi
}

# ---------------------------------------------------------------------------
# Collection: connection history
# ---------------------------------------------------------------------------
# Portable awk calendar arithmetic (no strftime/gawk dependency).
AWK_TIME='
function pad2(n) { return (n < 10 ? "0" : "") n }
function dfc(y, m, d,   era, yoe, doy, doe) {
    y -= (m <= 2) ? 1 : 0
    era = int((y >= 0 ? y : y - 399) / 400)
    yoe = y - era * 400
    doy = int((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + d - 1
    doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
    return era * 146097 + doe - 719468
}
function cfd(z,   era, doe, yoe, y, doy, mp, d, m) {
    z += 719468
    era = int((z >= 0 ? z : z - 146096) / 146097)
    doe = z - era * 146097
    yoe = int((doe - int(doe / 1460) + int(doe / 36524) - int(doe / 146096)) / 365)
    y = yoe + era * 400
    doy = doe - (365 * yoe + int(yoe / 4) - int(yoe / 100))
    mp = int((5 * doy + 2) / 153)
    d = doy - int((153 * mp + 2) / 5) + 1
    m = mp + (mp < 10 ? 3 : -9)
    if (m <= 2) y++
    return sprintf("%04d-%02d-%02d", y, m, d)
}
function fmt_epoch(e,   days, secs, dd) {
    e = int(e)
    if (e <= 0) return "-"
    days = int(e / 86400)
    secs = e - days * 86400
    if (secs < 0) { secs += 86400; days-- }
    dd = cfd(days)
    return dd " " pad2(int(secs / 3600)) ":" pad2(int((secs % 3600) / 60)) ":" pad2(secs % 60)
}
function month_num(m) {
    return (m == "Jan") ? 1 : (m == "Feb") ? 2 : (m == "Mar") ? 3 : \
           (m == "Apr") ? 4 : (m == "May") ? 5 : (m == "Jun") ? 6 : \
           (m == "Jul") ? 7 : (m == "Aug") ? 8 : (m == "Sep") ? 9 : \
           (m == "Oct") ? 10 : (m == "Nov") ? 11 : (m == "Dec") ? 12 : 0
}
function ts_to_epoch(ts,   y, mo, d, hh, mi, ss, a, n, s) {
    if (ts ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/) {
        y = substr(ts, 1, 4) + 0; mo = substr(ts, 6, 2) + 0; d = substr(ts, 9, 2) + 0
        hh = substr(ts, 12, 2) + 0; mi = substr(ts, 15, 2) + 0; ss = substr(ts, 18, 2) + 0
        return dfc(y, mo, d) * 86400 + hh * 3600 + mi * 60 + ss
    }
    n = split(ts, a, / +/)
    if (n < 3) return ""
    mo = month_num(a[1])
    if (mo == 0) return ""
    d = a[2] + 0
    s = a[3]
    hh = substr(s, 1, 2) + 0; mi = substr(s, 4, 2) + 0; ss = substr(s, 7, 2) + 0
    if (mo > curmonth + 6) y = year - 1
    else if (mo < curmonth - 6) y = year + 1
    else y = year
    return dfc(y, mo, d) * 86400 + hh * 3600 + mi * 60 + ss
}
'

# Normalise any log line to "<epoch><TAB><message>"; keep only USB events.
normalize_log_stream() {
    awk -v year="$(date '+%Y')" -v curmonth="$(date '+%m' | sed 's/^0//')" \
        "$AWK_TIME"'
        {
            ts = ""; rest = ""
            if (match($0, /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]/)) {
                ts = substr($0, 1, 19)
                rest = substr($0, 20)
                sub(/^[^ ]* +/, "", rest)
            } else if (match($0, /^[A-Z][a-z][a-z] +[0-9][0-9]? +[0-9][0-9]:[0-9][0-9]:[0-9][0-9]/)) {
                ts = substr($0, RSTART, RLENGTH)
                rest = substr($0, RLENGTH + 1)
                sub(/^ +/, "", rest)
            } else {
                next
            }
            e = ts_to_epoch(ts)
            if (e == "") next
            gsub(/\t/, " ", rest)
            print e "\t" rest
        }'
}

usb_log_filter() {
    grep -a -i -E 'usb [0-9]+-[0-9]+(\.[0-9]+)*|usb disconnect|usb-storage|usb_storage' 2>/dev/null
}

journal_available() {
    have journalctl || return 1
    local probe
    probe=$(journalctl --no-pager -n 1 -o cat 2>/dev/null)
    case $probe in
        ""|"-- No entries --"|*"No journal files"*) return 1 ;;
    esac
    return 0
}

journal_dump() {
    if [ -n "$SINCE" ]; then
        journalctl --no-pager -o short-iso --since "$SINCE" 2>/dev/null
    else
        journalctl --no-pager -o short-iso 2>/dev/null
    fi
}

# Pick the most kernel-oriented log that exists: kern.log > syslog > messages.
syslog_base() {
    local base f
    for base in kern.log syslog messages; do
        for f in "$LOG_ROOT/$base" "$LOG_ROOT/$base".[0-9]*; do
            if [ -r "$f" ]; then
                printf '%s' "$base"
                return 0
            fi
        done
    done
    return 1
}

# Rotated files are included as well; the collected events are sorted by
# timestamp later, so the order in which files are read does not matter.
syslog_dump_base() {
    local base=$1 f
    for f in "$LOG_ROOT/$base" "$LOG_ROOT/$base".[0-9]*; do
        [ -r "$f" ] || continue
        cat_log_file "$f"
    done
}

cat_log_file() {
    case $1 in
        *.gz)  have gzip  && gzip -dc "$1" 2>/dev/null || true ;;
        *.bz2) have bzip2 && bzip2 -dc "$1" 2>/dev/null || true ;;
        *.xz)  have xz    && xz -dc "$1" 2>/dev/null || true ;;
        *)     cat "$1" 2>/dev/null || true ;;
    esac
}

# dmesg has no wall clock; convert monotonic seconds via boot time.
dmesg_dump() {
    have dmesg || return 1
    local boot upload
    upload=$(cut -d. -f1 "$PROC_ROOT/uptime" 2>/dev/null) || return 1
    case ${upload:-x} in ''|*[!0-9]*) return 1 ;; esac
    boot=$(( $(now_epoch) - upload ))
    dmesg 2>/dev/null | awk -v boot="$boot" '
        {
            if (match($0, /^\[ *[0-9]+(\.[0-9]+)?\]/)) {
                s = substr($0, RSTART + 1, RLENGTH - 2)
                sub(/^ +/, "", s)
                e = boot + int(s)
                rest = substr($0, RLENGTH + 1)
                sub(/^ +/, "", rest)
                print e "\t" rest
            }
        }'
}

collect_history_sessions() {
    : > "$TMPD/events.tsv"
    : > "$TMPD/history.tsv"
    : > "$TMPD/hist_storage.tsv"
    [ "$NEED_HISTORY" = 1 ] || return 0

    if journal_available; then
        JOURNAL_OK=1
        journal_dump | usb_log_filter | normalize_log_stream >> "$TMPD/events.tsv"
        if [ -s "$TMPD/events.tsv" ]; then
            HISTORY_SOURCE="journald"
        fi
    fi

    if [ ! -s "$TMPD/events.tsv" ]; then
        local base
        if base=$(syslog_base); then
            syslog_dump_base "$base" | usb_log_filter | normalize_log_stream >> "$TMPD/events.tsv"
            if [ -s "$TMPD/events.tsv" ]; then
                HISTORY_SOURCE="$base"
            fi
        fi
    fi

    if [ ! -s "$TMPD/events.tsv" ]; then
        dmesg_dump | usb_log_filter | normalize_log_stream >> "$TMPD/events.tsv"
        if [ -s "$TMPD/events.tsv" ]; then
            HISTORY_SOURCE="dmesg"
        fi
    fi

    [ -s "$TMPD/events.tsv" ] || return 0
    # Stable sort: kernel messages within the same second must keep their
    # original order, otherwise "Product:"/"SerialNumber:" can be seen before
    # "new USB device" and the session state machine loses the properties.
    sort -s -t "$TAB" -k1,1n "$TMPD/events.tsv" -o "$TMPD/events.tsv" 2>/dev/null \
        || sort -t "$TAB" -k1,1n "$TMPD/events.tsv" -o "$TMPD/events.tsv"

    awk -F'\t' -v storefile="$TMPD/hist_storage.tsv" '
        function flush(port, endv,   k) {
            if (!(port in start)) return
            k = (serial[port] != "") ? "s:" serial[port] : "p:" port
            dur = (endv > 0 && endv >= start[port]) ? int((endv - start[port]) / 60) : -1
            printf "%s\t%d\t%d\t%d\t%s\t%s\t%s\t%s\t%s\t%s\n",
                k, start[port], endv, dur, port,
                (serial[port] == "" ? "-" : serial[port]),
                (product[port] == "" ? "-" : product[port]),
                (manuf[port] == "" ? "-" : manuf[port]),
                (vid[port] == "" ? "-" : vid[port]),
                (pid[port] == "" ? "-" : pid[port])
            if (store[port] == 1) print k > storefile
            delete start[port]; delete serial[port]; delete product[port]
            delete manuf[port]; delete vid[port]; delete pid[port]; delete store[port]
        }
        {
            e = $1 + 0
            line = $2
            low = tolower(line)
            port = ""
            if (match(line, /usb [0-9]+-[0-9]+(\.[0-9]+)*/))
                port = substr(line, RSTART + 4, RLENGTH - 4)
            if (port == "") {
                # "usb-storage 1-2:1.0: USB Mass Storage device detected"
                if (match(line, /(usb-storage|uas)[^ \t]* [0-9]+-[0-9]+(\.[0-9]+)*/)) {
                    p = substr(line, RSTART, RLENGTH)
                    sub(/^[^ \t]+ +/, "", p)
                    sub(/:.*/, "", p)
                    if (p in start) store[p] = 1
                }
                next
            }

            if (low ~ /new (high|full|low)-speed usb device/ || low ~ /new superspeed/) {
                if (port in start) flush(port, e)
                start[port] = e; serial[port] = ""; product[port] = ""; manuf[port] = ""
                vid[port] = ""; pid[port] = ""
            } else if (low ~ /new usb device found/) {
                if (!(port in start)) { start[port] = e; serial[port] = ""; product[port] = ""; manuf[port] = "" }
                if (match(line, /idVendor=[0-9a-fA-F]+/))
                    vid[port] = substr(line, RSTART + 9, RLENGTH - 9)
                if (match(line, /idProduct=[0-9a-fA-F]+/))
                    pid[port] = substr(line, RSTART + 10, RLENGTH - 10)
            }

            if (!(port in start)) next

            if (match(line, /SerialNumber: /)) {
                serial[port] = substr(line, RSTART + 14)
            } else if (match(line, /Product: /)) {
                product[port] = substr(line, RSTART + 9)
            } else if (match(line, /Manufacturer: /)) {
                manuf[port] = substr(line, RSTART + 14)
            }

            if (low ~ /usb disconnect/) flush(port, e)
        }
        END { for (p in start) flush(p, 0) }
    ' "$TMPD/events.tsv" > "$TMPD/history.tsv"

    sort -s -t "$TAB" -k2,2n "$TMPD/history.tsv" -o "$TMPD/history.tsv" 2>/dev/null \
        || sort -t "$TAB" -k2,2n "$TMPD/history.tsv" -o "$TMPD/history.tsv"
}

# ---------------------------------------------------------------------------
# Inventory: current devices merged with history
# ---------------------------------------------------------------------------
build_inventory() {
    : > "$TMPD/inventory.tsv"
    # devices.tsv has 11 tab separated fields, history.tsv has 10 - the field
    # count is what tells the two record types apart.
    cat "$TMPD/devices.tsv" "$TMPD/history.tsv" | awk -F'\t' '
        NF == 11 {
            key = ($4 != "") ? "s:" $4 : (($7 != "") ? "p:" $7 : "n:" $1)
            dn[key] = $1; dm[key] = $2; dv[key] = $3; ds[key] = $4
            db[key] = $5; dh[key] = $6; dp[key] = $7; di[key] = $8
            dmo[key] = $9; dr[key] = $10; dse[key] = $11
            order[++nd] = key
            next
        }
        NF == 10 {
            key = $1
            if (!(key in hf)) { hf[key] = $2; hn[++nh] = key }
            hl[key] = $3
            hc[key] += 1
            hport[key] = $5; hser[key] = $6; hprod[key] = $7; hman[key] = $8
            next
        }
        END {
            for (i = 1; i <= nd; i++) {
                k = order[i]
                f = (k in hf) ? hf[k] : 0
                l = (k in hl) ? hl[k] : 0
                c = (k in hc) ? hc[k] : 0
                printf "%s\tconnected\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%d\t%d\t%d\n",
                    k, dn[k], dm[k], dv[k], ds[k], dp[k], di[k], db[k], dh[k], dmo[k], dr[k], dse[k], f, l, c
                seen[k] = 1
            }
            for (i = 1; i <= nh; i++) {
                k = hn[i]
                if (k in seen) continue
                printf "%s\tdetached\t-\t%s\t%s\t%s\t%s\t-\t0\t0\t-\t?\t0\t%d\t%d\t%d\n",
                    k, hprod[k], hman[k], hser[k], hport[k], hf[k], hl[k], hc[k]
            }
        }
    ' > "$TMPD/inventory.tsv"
}

# ---------------------------------------------------------------------------
# System facts
# ---------------------------------------------------------------------------
os_name() {
    local v
    if [ -r "$OS_RELEASE" ]; then
        v=$(grep -m1 '^PRETTY_NAME=' "$OS_RELEASE" 2>/dev/null | cut -d= -f2-)
        v=${v%\"}; v=${v#\"}
        [ -n "$v" ] && { printf '%s' "$v"; return 0; }
    fi
    if [ -r /etc/altlinux-release ]; then
        read_val /etc/altlinux-release && return 0
    fi
    if [ -r /etc/redos-release ]; then
        read_val /etc/redos-release && return 0
    fi
    if [ -r /etc/astra_version ]; then
        v=$(read_val /etc/astra_version)
        [ -n "$v" ] && { printf 'Astra Linux %s' "$v"; return 0; }
    fi
    printf '%s' "Unknown Linux"
}

uptime_human() {
    local up
    up=$(cut -d. -f1 "$PROC_ROOT/uptime" 2>/dev/null) || { printf '?'; return 0; }
    case ${up:-x} in ''|*[!0-9]*) printf '?'; return 0 ;; esac
    awk -v s="$up" 'BEGIN {
        d = int(s / 86400); s %= 86400
        h = int(s / 3600); s %= 3600
        m = int(s / 60)
        if (d > 0) printf "%dd %dh %dm", d, h, m
        else if (h > 0) printf "%dh %dm", h, m
        else printf "%dm", m
    }'
}

is_root() { [ "$(id -u 2>/dev/null)" = "0" ]; }

pci_usb_controllers() {
    local base="$SYS_ROOT/bus/pci/devices" d cls ven dev
    [ -d "$base" ] || return 1
    for d in "$base"/*; do
        [ -r "$d/class" ] || continue
        cls=$(read_val "$d/class") || continue
        case $cls in
            0x0c03*) ;;
            *) continue ;;
        esac
        ven=$(read_val "$d/vendor") || ven="?"
        dev=$(read_val "$d/device") || dev="?"
        printf '%s %s [%s]\n' "${ven#0x}" "${dev#0x}" "${d##*/}"
    done
}

usb_modules() {
    local f="$PROC_ROOT/modules" name
    [ -r "$f" ] || return 0
    while read -r name _; do
        case $name in
            *usb*|*hci*|uas|*storage*) printf '%s ' "$name" ;;
        esac
    done < "$f"
    printf '\n'
}

# ---------------------------------------------------------------------------
# Renderers
# ---------------------------------------------------------------------------
# epoch -> "YYYY-MM-DD HH:MM:SS" ( "" -> "-" )
fmt_epoch_str() {
    awk -v e="${1:-0}" "$AWK_TIME"' BEGIN { print fmt_epoch(e) }'
}

render_report() {
    local host os kernel arch gen counts now_connected hist_n periph_n
    local key status name model vendor serial port usb_id size_b size_h mount removable seen first last cnt idx=0 modules

    host=$(uname -n 2>/dev/null || echo "?")
    os=$(os_name)
    kernel=$(uname -r 2>/dev/null || echo "?")
    arch=$(uname -m 2>/dev/null || echo "?")
    gen=$(now_zone)

    counts=$(awk -F'\t' '{ if ($2 == "connected") c++; else d++ } END { printf "%d %d", c + 0, d + 0 }' "$TMPD/inventory.tsv")
    now_connected=${counts% *}
    hist_n=$(wc -l < "$TMPD/history.tsv" 2>/dev/null | tr -d ' ')
    periph_n=$(wc -l < "$TMPD/usb.tsv" 2>/dev/null | tr -d ' ')
    [ -n "$hist_n" ] || hist_n=0
    [ -n "$periph_n" ] || periph_n=0

    printf '\n'
    printf '%s=====================================================%s\n' "$C_BOLD" "$C_OFF"
    printf '%s  USB DEVICE REPORT%s\n' "$C_BOLD" "$C_OFF"
    printf '%s=====================================================%s\n' "$C_BOLD" "$C_OFF"
    printf ' Generated : %s\n' "$gen"
    printf ' Host      : %s (%s)\n' "$host" "$os"
    printf ' Kernel    : %s %s\n' "$kernel" "$arch"
    printf ' Privileges: %s\n' "$(is_root && echo root || echo "regular user (limited log access)")"
    printf ' Uptime    : %s\n' "$(uptime_human)"
    printf ' History   : %s (%s sessions)\n' "$HISTORY_SOURCE" "$hist_n"

    section "1. USB STORAGE DEVICES (connected now): $now_connected"
    if [ "$now_connected" = 0 ]; then
        printf ' No USB storage devices currently connected.\n'
    else
        while IFS=$'\t' read -r key status name model vendor serial port usb_id size_b size_h mount removable seen first last cnt; do
            [ "$status" = "connected" ] || continue
            idx=$((idx + 1))
            printf ' %s[%d] /dev/%s%s  %s\n' "$C_BOLD" "$idx" "$name" "$C_OFF" "$model"
            printf '     Vendor      : %s\n' "${vendor:--}"
            printf '     Serial      : %s%s%s\n' "$C_GREEN" "${serial:-not reported by device}" "$C_OFF"
            if [ -n "$port" ] && [ "$port" != "-" ]; then
                printf '     USB         : %s  port %s\n' "${usb_id:-?}" "$port"
            else
                printf '     USB         : %s\n' "${usb_id:-?}"
            fi
            printf '     Capacity    : %s   removable: %s\n' "$size_h" "$( [ "$removable" = "1" ] && echo yes || echo no )"
            printf '     Partitions  : %s\n' "${mount:--}"
            if [ "${seen:-0}" -gt 0 ]; then
                printf '     Seen since  : %s (udev database)\n' "$(fmt_epoch_str "$seen")"
            fi
            if [ "${first:-0}" -gt 0 ]; then
                printf '     First log   : %s   sessions: %s\n' "$(fmt_epoch_str "$first")" "$cnt"
            fi
            printf '\n'
        done < "$TMPD/inventory.tsv"
    fi

    section "2. OTHER USB DEVICES ON THE BUS: $periph_n"
    if [ "$periph_n" = 0 ]; then
        printf ' No USB devices found in %s/bus/usb/devices.\n' "$SYS_ROOT"
    else
        printf ' %-10s %-10s %-32s %-20s %s\n' "PORT" "ID" "PRODUCT" "MANUFACTURER" "SERIAL"
        awk -F'\t' '{
            printf " %-10s %-10s %-32s %-20s %s\n", $1, $2, ($3 == "" ? "-" : $3), ($4 == "" ? "-" : $4), ($5 == "" ? "-" : $5)
        }' "$TMPD/usb.tsv"
    fi

    section "3. CONNECTION HISTORY (source: $HISTORY_SOURCE)"
    if [ "$hist_n" = 0 ]; then
        printf ' No USB connection events found.\n'
        if [ "$HISTORY_SOURCE" = "none" ]; then
            printf ' Checked: journalctl, %s/{kern.log,syslog,messages}*, dmesg.\n' "$LOG_ROOT"
            printf ' Without a persistent journal try: sudo %s --history\n' "${APP_NAME}.sh"
        fi
    else
        printf ' %-19s %-19s %-9s %-28s %s\n' "CONNECTED" "DISCONNECTED" "DURATION" "PRODUCT" "SERIAL"
        awk -F'\t' "$AWK_TIME"'
            {
                printf " %-19s %-19s %-9s %-28s %s\n",
                    fmt_epoch($2),
                    ($3 > 0 ? fmt_epoch($3) : "-"),
                    ($4 >= 0 ? $4 " min" : "open"),
                    ($7 == "" ? "-" : $7),
                    ($6 == "" ? "-" : $6)
            }' "$TMPD/history.tsv"
    fi

    section "4. SUMMARY"
    printf ' USB storage connected : %s\n' "$now_connected"
    printf ' History sessions      : %s\n' "$hist_n"
    printf ' USB devices on bus    : %s\n' "$periph_n"

    section "5. SYSTEM"
    printf ' USB controllers:\n'
    if pci_usb_controllers 2>/dev/null | grep -q .; then
        pci_usb_controllers 2>/dev/null | sed 's/^/   /'
        have lspci && lspci 2>/dev/null | grep -i usb | sed 's/^/   /'
    elif have lspci; then
        lspci 2>/dev/null | grep -i usb | sed 's/^/   /' || echo '   (none reported)'
    else
        echo '   (not available)'
    fi
    modules=$(usb_modules | tr -d '\n' | sed 's/ *$//')
    if [ -n "$modules" ]; then
        printf ' Kernel USB modules: %s\n' "$modules"
    else
        printf ' Kernel USB modules: not listed in %s/modules\n' "$PROC_ROOT"
    fi
    printf '\n'
}

render_list() {
    local key status name model vendor serial port usb_id size_b size_h mount removable seen first last cnt
    local n=0

    printf '%sUSB STORAGE%s\n' "$C_BOLD" "$C_OFF"
    printf '%-8s %-22s %-26s %-10s %-8s %s\n' "DEVICE" "SERIAL" "MODEL" "SIZE" "PORT" "MOUNT"
    while IFS=$'\t' read -r key status name model vendor serial port usb_id size_b size_h mount removable seen first last cnt; do
        [ "$status" = "connected" ] || continue
        n=$((n + 1))
        printf '%-8s %-22s %-26s %-10s %-8s %s\n' \
            "/dev/$name" "${serial:--}" "$model" "$size_h" "${port:--}" "${mount:--}"
    done < "$TMPD/inventory.tsv"
    [ "$n" = 0 ] && printf '(none)\n'

    if [ -s "$TMPD/usb.tsv" ]; then
        printf '\n%sALL USB DEVICES ON THE BUS%s\n' "$C_BOLD" "$C_OFF"
        printf '%-10s %-10s %-32s %-20s %s\n' "PORT" "ID" "PRODUCT" "MANUFACTURER" "SERIAL"
        awk -F'\t' '{
            printf "%-10s %-10s %-32s %-20s %s\n", $1, $2, ($3 == "" ? "-" : $3), ($4 == "" ? "-" : $4), ($5 == "" ? "-" : $5)
        }' "$TMPD/usb.tsv"
    fi

    if have lsusb && [ "$VERBOSE" = 1 ]; then
        printf '\n%slsusb -v (requires root for full output)%s\n' "$C_BOLD" "$C_OFF"
        lsusb -v 2>/dev/null | sed -n 's/^ *\(idVendor\|idProduct\|iManufacturer\|iProduct\|iSerial\)/  \1/p' | head -n 60
    fi
}

render_history() {
    local n
    n=$(wc -l < "$TMPD/history.tsv" 2>/dev/null | tr -d ' ')
    [ -n "$n" ] || n=0
    printf '%sUSB CONNECTION HISTORY%s  (source: %s, sessions: %s)\n' "$C_BOLD" "$C_OFF" "$HISTORY_SOURCE" "$n"
    if [ "$n" = 0 ]; then
        printf 'No USB connection events found.\n'
        return 0
    fi
    printf '%-19s %-19s %-9s %-8s %-28s %s\n' "CONNECTED" "DISCONNECTED" "DURATION" "PORT" "PRODUCT" "SERIAL"
    awk -F'\t' "$AWK_TIME"'
        {
            printf "%-19s %-19s %-9s %-8s %-28s %s\n",
                fmt_epoch($2),
                ($3 > 0 ? fmt_epoch($3) : "-"),
                ($4 >= 0 ? $4 " min" : "open"),
                $5,
                ($7 == "" ? "-" : $7),
                ($6 == "" ? "-" : $6)
        }' "$TMPD/history.tsv"
}

render_csv() {
    local key status name model vendor serial port usb_id size_b size_h mount removable seen first last cnt
    local f l

    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$(csv_q "status")" "$(csv_q "device")" "$(csv_q "model")" "$(csv_q "vendor")" \
        "$(csv_q "serial")" "$(csv_q "usb_id")" "$(csv_q "port")" "$(csv_q "size_gib")" \
        "$(csv_q "size_human")" "$(csv_q "removable")" "$(csv_q "mount")" \
        "$(csv_q "first_seen")" "$(csv_q "last_seen")" "$(csv_q "sessions")"

    while IFS=$'\t' read -r key status name model vendor serial port usb_id size_b size_h mount removable seen first last cnt; do
        f=$(fmt_epoch_str "${first:-0}")
        l=$(fmt_epoch_str "${last:-0}")
        printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
            "$(csv_q "$status")" \
            "$(csv_q "$( [ "$name" = "-" ] && echo "-" || echo "/dev/$name" )")" \
            "$(csv_q "$model")" \
            "$(csv_q "$vendor")" \
            "$(csv_q "$serial")" \
            "$(csv_q "$usb_id")" \
            "$(csv_q "$port")" \
            "$(csv_q "$(gib_value "$size_b")")" \
            "$(csv_q "$size_h")" \
            "$(csv_q "$( [ "$removable" = "1" ] && echo yes || echo no )")" \
            "$(csv_q "$mount")" \
            "$(csv_q "$f")" \
            "$(csv_q "$l")" \
            "$(csv_q "$cnt")"
    done < "$TMPD/inventory.tsv"
}

render_json() {
    local key status name model vendor serial port usb_id size_b size_h mount removable seen first last cnt
    local first_dev=1 first_hist=1 first_per=1
    local connected detached sessions peripherals

    connected=$(awk -F'\t' '$2 == "connected"' "$TMPD/inventory.tsv" | wc -l | tr -d ' ')
    detached=$(awk -F'\t' '$2 != "connected"' "$TMPD/inventory.tsv" | wc -l | tr -d ' ')
    sessions=$(wc -l < "$TMPD/history.tsv" 2>/dev/null | tr -d ' ')
    peripherals=$(wc -l < "$TMPD/usb.tsv" 2>/dev/null | tr -d ' ')
    [ -n "$sessions" ] || sessions=0
    [ -n "$peripherals" ] || peripherals=0

    printf '{\n'
    printf '  "tool": %s,\n' "$(json_str "$APP_NAME")"
    printf '  "version": %s,\n' "$(json_str "$APP_VERSION")"
    printf '  "generated": %s,\n' "$(json_str "$(now_zone)")"
    printf '  "host": {\n'
    printf '    "hostname": %s,\n' "$(json_str "$(uname -n 2>/dev/null || echo '?')")"
    printf '    "os": %s,\n' "$(json_str "$(os_name)")"
    printf '    "kernel": %s,\n' "$(json_str "$(uname -r 2>/dev/null || echo '?')")"
    printf '    "arch": %s,\n' "$(json_str "$(uname -m 2>/dev/null || echo '?')")"
    printf '    "root": %s\n' "$(is_root && echo true || echo false)"
    printf '  },\n'
    printf '  "sources": {\n'
    printf '    "history": %s,\n' "$(json_str "$HISTORY_SOURCE")"
    printf '    "journald": %s\n' "$( [ "$JOURNAL_OK" = 1 ] && echo true || echo false )"
    printf '  },\n'
    printf '  "summary": {\n'
    printf '    "connected": %s,\n' "$connected"
    printf '    "historical": %s,\n' "$detached"
    printf '    "sessions": %s,\n' "$sessions"
    printf '    "peripherals": %s\n' "$peripherals"
    printf '  },\n'

    printf '  "devices": ['
    while IFS=$'\t' read -r key status name model vendor serial port usb_id size_b size_h mount removable seen first last cnt; do
        if [ "$first_dev" = 1 ]; then first_dev=0; printf '\n'; else printf ',\n'; fi
        printf '    {\n'
        printf '      "status": %s,\n' "$(json_str "$status")"
        printf '      "device": %s,\n' "$(json_str "$( [ "$name" = "-" ] && echo "-" || echo "/dev/$name" )")"
        printf '      "model": %s,\n' "$(json_str "$model")"
        printf '      "vendor": %s,\n' "$(json_str "$vendor")"
        printf '      "serial": %s,\n' "$(json_str "$serial")"
        printf '      "port": %s,\n' "$(json_str "$port")"
        printf '      "usb_id": %s,\n' "$(json_str "$usb_id")"
        printf '      "size_bytes": %s,\n' "${size_b:-0}"
        printf '      "size_gib": %s,\n' "$(gib_value "$size_b")"
        printf '      "size_human": %s,\n' "$(json_str "$size_h")"
        printf '      "mounts": %s,\n' "$(json_str "$mount")"
        printf '      "removable": %s,\n' "$( [ "$removable" = "1" ] && echo true || echo false )"
        printf '      "seen_since": %s,\n' "$(json_str "$(fmt_epoch_str "${seen:-0}")")"
        printf '      "first_seen": %s,\n' "$(json_str "$(fmt_epoch_str "${first:-0}")")"
        printf '      "last_seen": %s,\n' "$(json_str "$(fmt_epoch_str "${last:-0}")")"
        printf '      "sessions": %s\n' "${cnt:-0}"
        printf '    }'
    done < "$TMPD/inventory.tsv"
    [ "$first_dev" = 1 ] || printf '\n  '
    printf '],\n'

    printf '  "peripherals": ['
    if [ -s "$TMPD/usb.tsv" ]; then
        while IFS=$'\t' read -r port usb_id product manuf serial cls; do
            if [ "$first_per" = 1 ]; then first_per=0; printf '\n'; else printf ',\n'; fi
            printf '    {"port": %s, "id": %s, "product": %s, "manufacturer": %s, "serial": %s, "class": %s}' \
                "$(json_str "$port")" "$(json_str "$usb_id")" "$(json_str "$product")" \
                "$(json_str "$manuf")" "$(json_str "$serial")" "$(json_str "$cls")"
        done < "$TMPD/usb.tsv"
        printf '\n  '
    fi
    printf '],\n'

    printf '  "history": ['
    awk -F'\t' "$AWK_TIME"'
        function jesc(s) {
            gsub(/\\/, "\\\\", s)
            gsub(/"/, "\\\"", s)
            gsub(/\t/, " ", s)
            gsub(/</, "\\u003c", s)
            gsub(/>/, "\\u003e", s)
            gsub(/&/, "\\u0026", s)
            return s
        }
        {
            printf "%s    {\"port\": \"%s\", \"serial\": \"%s\", \"product\": \"%s\", \"manufacturer\": \"%s\", \"connected_at\": \"%s\", \"disconnected_at\": \"%s\", \"duration_min\": %s, \"active\": %s}",
                (NR > 1 ? ",\n" : "\n"),
                jesc($5), jesc($6), jesc($7), jesc($8),
                fmt_epoch($2),
                ($3 > 0 ? fmt_epoch($3) : "-"),
                ($4 >= 0 ? $4 : "null"),
                ($3 > 0 ? "false" : "true")
        }' "$TMPD/history.tsv"
    if [ -s "$TMPD/history.tsv" ]; then printf '\n  '; fi
    printf ']\n'
    printf '}\n'
}

render_html() {
    local json

    json=$(render_json)

    cat <<'HTML_HEAD'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>USB device report</title>
<style>
:root{
  --bg:#f4f6f8; --card:#fff; --text:#1f2933; --muted:#6b7785;
  --accent:#2563eb; --ok:#15803d; --warn:#b45309; --err:#b91c1c; --line:#dbe1e8;
}
@media (prefers-color-scheme: dark){
  :root{ --bg:#12161c; --card:#1b2129; --text:#e6edf3; --muted:#93a1b1;
         --accent:#60a5fa; --ok:#4ade80; --warn:#fbbf24; --err:#f87171; --line:#2b3441; }
}
*{box-sizing:border-box}
body{margin:0;padding:24px;background:var(--bg);color:var(--text);
     font:15px/1.5 "Segoe UI",Roboto,Ubuntu,"Helvetica Neue",Arial,sans-serif}
.wrap{max-width:1180px;margin:0 auto}
header{background:var(--card);border:1px solid var(--line);border-radius:14px;padding:22px 26px;margin-bottom:18px}
h1{font-size:1.5rem;margin:0 0 6px}
.sub{color:var(--muted);margin:0}
.meta{display:flex;flex-wrap:wrap;gap:8px 26px;margin-top:14px;font-size:.9rem;color:var(--muted)}
.meta b{color:var(--text);font-weight:600}
.stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));gap:14px;margin-bottom:18px}
.stat{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:16px 18px}
.stat .n{font-size:1.9rem;font-weight:700;line-height:1.1}
.stat .l{color:var(--muted);font-size:.8rem;text-transform:uppercase;letter-spacing:.06em}
.panel{background:var(--card);border:1px solid var(--line);border-radius:14px;margin-bottom:18px;overflow:hidden}
.panel h2{font-size:1rem;margin:0;padding:14px 18px;border-bottom:1px solid var(--line)}
.bar{display:flex;gap:10px;flex-wrap:wrap;padding:12px 18px;border-bottom:1px solid var(--line)}
input[type=search],button{font:inherit;color:inherit;background:var(--bg);border:1px solid var(--line);border-radius:9px;padding:8px 12px}
input[type=search]{flex:1;min-width:220px}
button{cursor:pointer;background:var(--accent);border-color:var(--accent);color:#fff;font-weight:600}
button:hover{filter:brightness(1.08)}
button.ghost{background:transparent;color:var(--text);border-color:var(--line)}
table{width:100%;border-collapse:collapse;font-size:.92rem}
th,td{padding:10px 14px;text-align:left;border-bottom:1px solid var(--line);vertical-align:top}
th{font-size:.78rem;text-transform:uppercase;letter-spacing:.05em;color:var(--muted);
   cursor:pointer;user-select:none;white-space:nowrap;background:var(--bg)}
th.nosort{cursor:default}
th.sorted-asc::after{content:" \25B2"}
th.sorted-desc::after{content:" \25BC"}
tbody tr:hover{background:rgba(37,99,235,.06)}
td.mono{font-family:ui-monospace,SFMono-Regular,Consolas,monospace;font-size:.86rem}
.badge{display:inline-block;padding:2px 9px;border-radius:999px;font-size:.76rem;font-weight:700}
.b-ok{background:rgba(21,128,61,.14);color:var(--ok)}
.b-warn{background:rgba(180,83,9,.14);color:var(--warn)}
.b-err{background:rgba(185,28,28,.14);color:var(--err)}
.empty{padding:22px 18px;color:var(--muted)}
footer{color:var(--muted);font-size:.82rem;text-align:center;margin-top:8px}
</style>
</head>
<body>
<div class="wrap">
<header>
  <h1>USB device report</h1>
  <p class="sub">Inventory, bus tree and connection history</p>
  <div class="meta" id="meta"></div>
</header>

<div class="stats" id="stats"></div>

<section class="panel">
  <h2>Storage devices (connected now and seen in logs)</h2>
  <div class="bar">
    <input type="search" id="q" placeholder="Filter by device, model, serial, port or mount point">
    <button id="csv">Download CSV</button>
    <button id="json" class="ghost">Download JSON</button>
  </div>
  <table id="t-devices">
    <thead><tr>
      <th data-sort="text" data-col="0">Device</th>
      <th data-sort="text" data-col="1">Model</th>
      <th data-sort="text" data-col="2">Serial</th>
      <th data-sort="text" data-col="3">Port</th>
      <th data-sort="num"  data-col="4">Size, GiB</th>
      <th data-sort="text" data-col="5">Mount</th>
      <th data-sort="text" data-col="6">Status</th>
      <th data-sort="text" data-col="7">First seen</th>
    </tr></thead>
    <tbody></tbody>
  </table>
</section>

<section class="panel">
  <h2>Connection history</h2>
  <table id="t-history">
    <thead><tr>
      <th data-sort="text" data-col="0">Connected</th>
      <th data-sort="text" data-col="1">Disconnected</th>
      <th data-sort="num"  data-col="2">Minutes</th>
      <th data-sort="text" data-col="3">Port</th>
      <th data-sort="text" data-col="4">Product</th>
      <th data-sort="text" data-col="5">Serial</th>
    </tr></thead>
    <tbody></tbody>
  </table>
</section>

<section class="panel">
  <h2>Other USB devices on the bus</h2>
  <table id="t-periph">
    <thead><tr>
      <th data-sort="text" data-col="0">Port</th>
      <th data-sort="text" data-col="1">Vendor:Product</th>
      <th data-sort="text" data-col="2">Product</th>
      <th data-sort="text" data-col="3">Manufacturer</th>
      <th data-sort="text" data-col="4">Serial</th>
    </tr></thead>
    <tbody></tbody>
  </table>
</section>

<footer id="foot"></footer>
<noscript><p class="empty">JavaScript is disabled: the tables and CSV export need it. Use <code>--export-json</code> for machine readable data.</p></noscript>
</div>
HTML_HEAD

    printf '<script id="usb-data" type="application/json">%s</script>\n' "$json"

    cat <<'HTML_JS'
<script>
(function () {
    'use strict';

    var data;
    try {
        data = JSON.parse(document.getElementById('usb-data').textContent);
    } catch (e) {
        document.getElementById('foot').textContent = 'Cannot parse embedded data: ' + e.message;
        return;
    }

    function el(tag, cls, text) {
        var n = document.createElement(tag);
        if (cls) { n.className = cls; }
        if (text !== undefined && text !== null && text !== '') { n.textContent = String(text); }
        return n;
    }
    function val(v) { return (v === undefined || v === null || v === '') ? '—' : v; }

    // Header metadata
    var meta = document.getElementById('meta');
    [
        ['Generated', data.generated],
        ['Host', data.host.hostname],
        ['OS', data.host.os],
        ['Kernel', data.host.kernel + ' ' + data.host.arch],
        ['History source', data.sources.history],
        ['Privileges', data.host.root ? 'root' : 'regular user']
    ].forEach(function (p) {
        var d = el('div');
        d.appendChild(el('b', null, p[0] + ': '));
        d.appendChild(document.createTextNode(val(p[1])));
        meta.appendChild(d);
    });

    // Stat cards
    var stats = document.getElementById('stats');
    [
        ['Connected storage', data.summary.connected],
        ['In history only', data.summary.historical],
        ['History sessions', data.summary.sessions],
        ['USB devices on bus', data.summary.peripherals]
    ].forEach(function (s) {
        var c = el('div', 'stat');
        c.appendChild(el('div', 'n', s[1]));
        c.appendChild(el('div', 'l', s[0]));
        stats.appendChild(c);
    });

    function statusBadge(status) {
        var s = el('span', 'badge');
        if (status === 'connected') { s.classList.add('b-ok'); s.textContent = 'connected'; }
        else { s.classList.add('b-warn'); s.textContent = 'disconnected'; }
        return s;
    }

    function renderDevices(filter) {
        var tbody = document.querySelector('#t-devices tbody');
        var rows = (data.devices || []).filter(function (d) {
            if (!filter) { return true; }
            var hay = [d.device, d.model, d.vendor, d.serial, d.port, d.mounts, d.status].join(' ').toLowerCase();
            return hay.indexOf(filter) !== -1;
        });
        while (tbody.firstChild) { tbody.removeChild(tbody.firstChild); }
        if (!rows.length) {
            var tr = el('tr');
            var td = el('td', 'empty', 'No matching devices.');
            td.colSpan = 8;
            tr.appendChild(td);
            tbody.appendChild(tr);
            return;
        }
        rows.forEach(function (d) {
            var tr = el('tr');
            tr.appendChild(el('td', 'mono', val(d.device) === '—' ? '—' : d.device));
            tr.appendChild(el('td', null, val(d.model)));
            tr.appendChild(el('td', 'mono', val(d.serial)));
            tr.appendChild(el('td', 'mono', val(d.port)));
            var sizeCell = el('td', null, d.size_gib ? d.size_gib.toFixed(2) : '0');
            sizeCell.setAttribute('data-value', d.size_gib || 0);
            tr.appendChild(sizeCell);
            tr.appendChild(el('td', 'mono', val(d.mounts)));
            var st = el('td');
            st.appendChild(statusBadge(d.status));
            tr.appendChild(st);
            tr.appendChild(el('td', null, val(d.first_seen)));
            tbody.appendChild(tr);
        });
    }

    function renderHistory() {
        var tbody = document.querySelector('#t-history tbody');
        while (tbody.firstChild) { tbody.removeChild(tbody.firstChild); }
        var rows = data.history || [];
        if (!rows.length) {
            var tr = el('tr');
            var td = el('td', 'empty', 'No USB connection events found in the available logs.');
            td.colSpan = 6;
            tr.appendChild(td);
            tbody.appendChild(tr);
            return;
        }
        rows.forEach(function (h) {
            var tr = el('tr');
            tr.appendChild(el('td', 'mono', val(h.connected_at)));
            tr.appendChild(el('td', 'mono', val(h.disconnected_at)));
            tr.appendChild(el('td', null, h.duration_min === null ? 'open' : h.duration_min));
            tr.appendChild(el('td', 'mono', val(h.port)));
            tr.appendChild(el('td', null, val(h.product)));
            tr.appendChild(el('td', 'mono', val(h.serial)));
            tbody.appendChild(tr);
        });
    }

    function renderPeripherals() {
        var tbody = document.querySelector('#t-periph tbody');
        while (tbody.firstChild) { tbody.removeChild(tbody.firstChild); }
        var rows = data.peripherals || [];
        if (!rows.length) {
            var tr = el('tr');
            var td = el('td', 'empty', 'No USB devices reported by the kernel.');
            td.colSpan = 5;
            tr.appendChild(td);
            tbody.appendChild(tr);
            return;
        }
        rows.forEach(function (p) {
            var tr = el('tr');
            tr.appendChild(el('td', 'mono', val(p.port)));
            tr.appendChild(el('td', 'mono', val(p.id)));
            tr.appendChild(el('td', null, val(p.product)));
            tr.appendChild(el('td', null, val(p.manufacturer)));
            tr.appendChild(el('td', 'mono', val(p.serial)));
            tbody.appendChild(tr);
        });
    }

    function sortTable(table, col, numeric, dir) {
        var tbody = table.tBodies[0];
        var rows = Array.prototype.slice.call(tbody.rows).filter(function (r) {
            return !r.querySelector('.empty');
        });
        rows.sort(function (a, b) {
            var x = (a.cells[col] ? a.cells[col].textContent : '').trim();
            var y = (b.cells[col] ? b.cells[col].textContent : '').trim();
            if (numeric) {
                x = parseFloat((a.cells[col] && a.cells[col].getAttribute('data-value')) || x) || 0;
                y = parseFloat((b.cells[col] && b.cells[col].getAttribute('data-value')) || y) || 0;
                return (x - y) * dir;
            }
            return x.localeCompare(y, undefined, {numeric: true, sensitivity: 'base'}) * dir;
        });
        rows.forEach(function (r) { tbody.appendChild(r); });
    }

    function makeSortable(table) {
        var state = {col: -1, dir: 1};
        var heads = table.tHead.rows[0].cells;
        Array.prototype.forEach.call(heads, function (th, idx) {
            if (!th.hasAttribute('data-sort')) { th.classList.add('nosort'); return; }
            th.addEventListener('click', function () {
                if (state.col === idx) { state.dir = -state.dir; } else { state.col = idx; state.dir = 1; }
                sortTable(table, idx, th.getAttribute('data-sort') === 'num', state.dir);
                Array.prototype.forEach.call(heads, function (h) {
                    h.classList.remove('sorted-asc', 'sorted-desc');
                });
                th.classList.add(state.dir === 1 ? 'sorted-asc' : 'sorted-desc');
            });
        });
    }

    function csvCell(v) {
        v = (v === undefined || v === null) ? '' : String(v);
        return '"' + v.replace(/"/g, '""') + '"';
    }

    function download(name, mime, text) {
        var blob = new Blob([text], {type: mime});
        var url = URL.createObjectURL(blob);
        var a = document.createElement('a');
        a.href = url;
        a.download = name;
        document.body.appendChild(a);
        a.click();
        document.body.removeChild(a);
        setTimeout(function () { URL.revokeObjectURL(url); }, 1000);
    }

    document.getElementById('q').addEventListener('input', function () {
        renderDevices(this.value.toLowerCase().trim());
    });

    document.getElementById('csv').addEventListener('click', function () {
        var head = ['status', 'device', 'model', 'vendor', 'serial', 'usb_id', 'port',
                    'size_gib', 'size_human', 'removable', 'mounts', 'first_seen', 'last_seen', 'sessions'];
        var lines = [head.map(csvCell).join(',')];
        (data.devices || []).forEach(function (d) {
            lines.push([
                d.status, d.device, d.model, d.vendor, d.serial, d.usb_id, d.port,
                d.size_gib, d.size_human, d.removable ? 'yes' : 'no',
                d.mounts, d.first_seen, d.last_seen, d.sessions
            ].map(csvCell).join(','));
        });
        download('usb_devices_' + new Date().toISOString().slice(0, 10) + '.csv',
                 'text/csv;charset=utf-8', lines.join('\r\n') + '\r\n');
    });

    document.getElementById('json').addEventListener('click', function () {
        download('usb_devices_' + new Date().toISOString().slice(0, 10) + '.json',
                 'application/json', JSON.stringify(data, null, 2));
    });

    renderDevices('');
    renderHistory();
    renderPeripherals();
    makeSortable(document.getElementById('t-devices'));
    makeSortable(document.getElementById('t-history'));
    makeSortable(document.getElementById('t-periph'));

    document.getElementById('foot').textContent =
        data.tool + ' ' + data.version + ' — all data collected locally, nothing is uploaded.';
}());
</script>
</body>
</html>
HTML_JS
}

# ---------------------------------------------------------------------------
# FUSB compatible export
# ---------------------------------------------------------------------------
# Reference layout (produced by the Windows USB audit tool):
#
#   FUSB_CSV_<YYYYMMDDHHMMSS>/UsbDevices.csv
#   FUSB_CSV_<YYYYMMDDHHMMSS>/UsbStor.csv
#
# Both files are Windows-1251 with CRLF line ends, use ';' as the separator,
# start with a bare title line and end every record with a trailing ';'.
# The structure is reproduced exactly; the values come from sysfs and the
# kernel log instead of the Windows registry.
FUSB_DEV_TITLE='Устройства'
FUSB_DEV_HEADER='Устройство;Серийный №;Путь к экземпляру устройства;Первое подключение;Последнее подключение;Производитель;Продукт;'
FUSB_STOR_TITLE='Накопители'
FUSB_STOR_HEADER='Продукт;Серийный №;Диск;Метка;Первое подключение;Последнее подключение;'

fusb_field() {  # one field: no separator, no line breaks, no padding
    printf '%s' "$1" | tr '\t\r\n' '   ' | sed 's/;/ /g; s/^  *//; s/  *$//'
}

fusb_val() {  # "-" is the internal placeholder for "unknown"
    case ${1:-} in ''|-) printf '' ;; *) fusb_field "$1" ;; esac
}

fusb_hex4() {  # normalise a USB id to four upper case hex digits
    local v
    v=$(printf '%s' "$1" | tr 'a-f' 'A-F' | sed 's/^0[xX]//')
    case $v in ''|*[!0-9A-F]*) return 0 ;; esac
    while [ ${#v} -lt 4 ]; do v="0$v"; done
    printf '%s' "$v"
}

fusb_instance() {  # vid, pid, serial -> USB\VID_xxxx&PID_yyyy[\serial]
    local v p s
    v=$(fusb_hex4 "$1")
    p=$(fusb_hex4 "$2")
    s=$3
    [ -n "$v" ] && [ -n "$p" ] || return 0
    case ${s:-} in
        ''|-) printf 'USB\\VID_%s&PID_%s' "$v" "$p" ;;
        *)    printf 'USB\\VID_%s&PID_%s\\%s' "$v" "$p" "$s" ;;
    esac
}

fusb_name() {  # class hex, product, is_storage -> Windows style friendly name
    if [ "${3:-0}" = 1 ]; then
        printf 'USB Mass Storage Device'
        return 0
    fi
    case ${1:-} in
        00)   printf 'USB Composite Device' ;;
        01)   printf 'USB Audio Device' ;;
        02)   printf 'USB Communications Device' ;;
        03)   printf 'USB Input Device' ;;
        05)   printf 'USB Physical Interface Device' ;;
        06)   printf 'USB Still Image Device' ;;
        07)   printf 'USB Printing Support' ;;
        08)   printf 'USB Mass Storage Device' ;;
        09)   printf 'USB Hub' ;;
        0a|0A) printf 'USB CDC Data' ;;
        0b|0B) printf 'Smart Card Reader' ;;
        0d|0D) printf 'Fingerprint Reader' ;;
        0e|0E) printf 'USB Video Device' ;;
        dc|DC) printf 'USB Diagnostic Device' ;;
        e0|E0) printf 'Bluetooth Radio' ;;
        ef|EF) printf 'USB Composite Device' ;;
        ff|FF|'') printf '%s' "${2:-USB Device}" ;;
        *)    printf '%s' "${2:-USB Device}" ;;
    esac
}

# Convert a UTF-8 file to the encoding of the reference export.
# The conversion is done in awk on purpose: iconv is not installed on every
# distribution (minimal ALT/Alpine images) and the reference format must not
# depend on a package that may be missing.
UTF8_TO_CP1251='
function ord(ch) { return ORD[ch] + 0 }
function tocp(cp) {
    if (cp >= 1040 && cp <= 1103) return 192 + (cp - 1040)   # А-я
    if (cp == 1025) return 168                                 # Ё
    if (cp == 1105) return 184                                 # ё
    if (cp == 8470) return 185                                 # №
    if (cp == 171) return 171
    if (cp == 187) return 187
    if (cp == 160) return 160
    if (cp == 167) return 167
    if (cp == 169) return 169
    if (cp == 174) return 174
    if (cp == 176) return 176
    if (cp == 177) return 177
    if (cp == 181) return 181
    if (cp == 182) return 182
    if (cp == 183) return 183
    if (cp == 8211) return 150                                 # –
    if (cp == 8212) return 151                                 # —
    if (cp == 8216) return 145
    if (cp == 8217) return 146
    if (cp == 8220) return 147
    if (cp == 8221) return 148
    if (cp == 8230) return 133                                 # …
    if (cp >= 32 && cp <= 126) return cp
    return 63                                                  # "?"
}
BEGIN { for (i = 1; i < 256; i++) ORD[sprintf("%c", i)] = i }
{
    s = $0; out = ""; n = length(s)
    for (i = 1; i <= n; i++) {
        c = ord(substr(s, i, 1))
        if (c < 128) { out = out sprintf("%c", c); continue }
        if (c >= 192 && c <= 223) {
            cp = (c - 192) * 64 + (ord(substr(s, i + 1, 1)) - 128); i++
        } else if (c >= 224 && c <= 239) {
            cp = (c - 224) * 4096 + (ord(substr(s, i + 1, 1)) - 128) * 64 + \
                 (ord(substr(s, i + 2, 1)) - 128)
            i += 2
        } else {
            out = out "?"; continue
        }
        out = out sprintf("%c", tocp(cp))
    }
    print out
}'

fusb_convert() {  # $1 source (LF, UTF-8), $2 target (CRLF, cp1251)
    FUSB_ENCODING="cp1251"
    # Encode first, then terminate the lines: some awk builds translate CRLF
    # on input/output, so the line ending is added last by sed on purpose.
    LC_ALL=C awk "$UTF8_TO_CP1251" "$1" 2>/dev/null | sed 's/$/\r/' > "$2"
    if [ ! -s "$2" ]; then
        cp "$1" "$2"
        FUSB_ENCODING="utf-8"
    fi
    return 0
}

render_fusb() {
    local parent=${OUT_FILE:-.}
    local ts dest src dev_body stor_body dev_utf stor_utf
    local key status name model vendor serial port usb_id size_b size_h mount removable seen first last cnt
    local pn pp pfs psz pmp vid pid inst disk label cls friendly fid fl
    local f

    if [ -e "$parent" ] && [ ! -d "$parent" ]; then
        die "not a directory: $parent"
    fi
    ts=$(date '+%Y%m%d%H%M%S')
    dest="$parent/FUSB_CSV_$ts"
    mkdir -p "$dest" || die "cannot create $dest"

    src="$TMPD/fusb_src.tsv"
    dev_body="$TMPD/fusb_dev.body"
    stor_body="$TMPD/fusb_stor.body"
    dev_utf="$TMPD/UsbDevices.utf8"
    stor_utf="$TMPD/UsbStor.utf8"
    : > "$src"
    FUSB_ENCODING="cp1251"

    # --- storage devices connected right now --------------------------------
    while IFS=$'\t' read -r key status name model vendor serial port usb_id size_b size_h mount removable seen first last cnt; do
        [ "$status" = "connected" ] || continue
        vid=${usb_id%%:*}
        pid=${usb_id#*:}
        inst=$(fusb_instance "$vid" "$pid" "$serial")
        disk=""; label=""
        while IFS=$'\t' read -r pn pp pfs psz pmp; do
            [ "$pn" = "$name" ] || continue
            if [ "$pmp" != "-" ] && [ -z "$label" ]; then
                disk=$pmp
                label=$(udev_props "$pp" | sed -n 's/^ID_FS_LABEL=//p' | head -n 1)
                break
            fi
            [ -n "$disk" ] || disk="/dev/$pp"
        done < "$TMPD/parts.tsv"
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t1\n' \
            "USB Mass Storage Device" "$(fusb_val "$serial")" "$(fusb_field "$inst")" \
            "${first:-0}" "${last:-0}" "$(fusb_val "$vendor")" "$(fusb_val "$model")" \
            "$(fusb_field "$disk")" "$(fusb_field "$label")" >> "$src"
    done < "$TMPD/inventory.tsv"

    # --- every other USB device on the bus ----------------------------------
    while IFS=$'\t' read -r port usb_id product manuf serial cls; do
        vid=${usb_id%%:*}
        pid=${usb_id#*:}
        inst=$(fusb_instance "$vid" "$pid" "$serial")
        friendly=$(fusb_name "$cls" "$product" 0)
        fid=0; fl=0
        if [ -s "$TMPD/history.tsv" ]; then
            set -- $(awk -F'\t' -v s="$serial" '
                $6 == s { if ($2 + 0 > 0 && (mn == "" || $2 + 0 < mn + 0)) mn = $2
                          if ($3 + 0 > 0 && (mx == "" || $3 + 0 > mx + 0)) mx = $3 }
                END { printf "%d %d", mn + 0, mx + 0 }' "$TMPD/history.tsv")
            fid=${1:-0}
            fl=${2:-0}
        fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t0\n' \
            "$(fusb_field "$friendly")" "$(fusb_val "$serial")" "$(fusb_field "$inst")" \
            "${fid:-0}" "${fl:-0}" "$(fusb_val "$manuf")" "$(fusb_val "$product")" "" "" >> "$src"
    done < "$TMPD/usb.tsv"

    # --- devices that exist only in the log ---------------------------------
    while IFS=$'\t' read -r key first last f port serial product manuf vid pid; do
        inst=$(fusb_instance "$vid" "$pid" "$serial")
        if grep -Fqx -- "$key" "$TMPD/hist_storage.tsv" 2>/dev/null; then
            friendly="USB Mass Storage Device"
            label="1"
        else
            friendly=$(fusb_name "" "$product" 0)
            label="0"
        fi
        [ "$friendly" = "-" ] && friendly=""
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$(fusb_field "$friendly")" "$(fusb_val "$serial")" "$(fusb_field "$inst")" \
            "$first" "$last" "$(fusb_val "$manuf")" "$(fusb_val "$product")" "" "" "$label" >> "$src"
    done < "$TMPD/history.tsv"

    awk -F'\t' -v devout="$dev_body" -v storout="$stor_body" "$AWK_TIME"'
        function fdt(e,   days, secs, dd) {
            e = e + 0
            if (e <= 0) return ""
            days = int(e / 86400)
            secs = e - days * 86400
            if (secs < 0) { secs += 86400; days-- }
            dd = cfd(days)
            return substr(dd, 9, 2) "." substr(dd, 6, 2) "." substr(dd, 1, 4) " " \
                   pad2(int(secs / 3600)) ":" pad2(int((secs % 3600) / 60))
        }
        {
            k = ($3 != "") ? $3 : (($2 != "") ? "S:" $2 : "P:" $7 "/" $1)
            if (!(k in seen)) {
                seen[k] = 1; keys[++n] = k
                fr[k] = $1; se[k] = $2; inst[k] = $3
                ma[k] = $6; pr[k] = $7; di[k] = $8; lb[k] = $9; st[k] = $10
            } else {
                if (fr[k] == "") fr[k] = $1
                if (se[k] == "") se[k] = $2
                if (ma[k] == "") ma[k] = $6
                if (pr[k] == "") pr[k] = $7
                if (di[k] == "") di[k] = $8
                if (lb[k] == "") lb[k] = $9
                if ($10 + 0 == 1) st[k] = 1
            }
            if ($4 + 0 > 0 && (fi[k] == "" || $4 + 0 < fi[k] + 0)) fi[k] = $4 + 0
            if ($5 + 0 > 0 && (lo[k] == "" || $5 + 0 > lo[k] + 0)) lo[k] = $5 + 0
        }
        END {
            for (i = 1; i <= n; i++) {
                k = keys[i]
                nm = fr[k]
                if (nm == "") nm = pr[k]
                if (nm == "") nm = "USB Device"
                printf "%s;%s;%s;%s;%s;%s;%s;\n", nm, se[k], inst[k], fdt(fi[k]), fdt(lo[k]), ma[k], pr[k] >> devout
                if (st[k] == 1)
                    printf "%s;%s;%s;%s;%s;%s;\n", pr[k], se[k], di[k], lb[k], fdt(fi[k]), fdt(lo[k]) >> storout
            }
            close(devout); close(storout)
        }' "$src"

    sort -t ';' -k1,1 -k2,2 "$dev_body" -o "$dev_body" 2>/dev/null || true
    sort -t ';' -k1,1 -k2,2 "$stor_body" -o "$stor_body" 2>/dev/null || true

    {
        printf '%s\n' "$FUSB_DEV_TITLE"
        printf '%s\n' "$FUSB_DEV_HEADER"
        cat "$dev_body"
    } > "$dev_utf"
    {
        printf '%s\n' "$FUSB_STOR_TITLE"
        printf '%s\n' "$FUSB_STOR_HEADER"
        cat "$stor_body"
    } > "$stor_utf"

    fusb_convert "$dev_utf" "$dest/UsbDevices.csv"
    fusb_convert "$stor_utf" "$dest/UsbStor.csv"

    printf '%s\n' "$dest"
    printf '  UsbDevices.csv  %s rows (%s)\n' "$(wc -l < "$dev_body" | tr -d ' ')" "$FUSB_ENCODING"
    printf '  UsbStor.csv     %s rows (%s)\n' "$(wc -l < "$stor_body" | tr -d ' ')" "$FUSB_ENCODING"
}

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
$APP_NAME $APP_VERSION - USB device inventory and connection history

Usage: $0 [option]

Actions (choose one, default: --report):
  -r, --report            full text report (default)
  -l, --list-devices      compact list of devices connected right now
  -y, --history           connection history only
  -c, --export-csv        inventory as CSV (RFC 4180)
  -j, --export-json       inventory + history as JSON
  -H, --export-html       self-contained HTML report
  -f, --export-fusb       FUSB_CSV_<timestamp>/UsbDevices.csv + UsbStor.csv
                          (Windows-1251, ';' separated, Windows audit layout)

Options:
  -o, --output FILE       write output to FILE instead of stdout
                          (with --export-fusb: parent directory for the folder)
  -s, --since TIME        history window for journalctl (e.g. "30 days ago",
                          "2026-01-01"); default: everything available
      --no-color          disable ANSI colors (auto-disabled when not a tty)
  -v, --verbose           extra diagnostics on stderr, full lsusb dump
  -h, --help              this help
  -V, --version           version

Examples:
  $0
  $0 --list-devices
  $0 --history --since "7 days ago"
  $0 --export-csv  > usb.csv
  $0 --export-json > usb.json
  $0 --export-html -o /tmp/usb.html
  $0 --export-fusb -o /tmp        # -> /tmp/FUSB_CSV_<timestamp>/
  sudo $0 --report          # full history, all log sources

Exit codes: 0 ok, 1 runtime error, 2 usage error, 3 unsupported platform.
EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
set_action() {
    if [ -z "$ACTION" ]; then
        ACTION=$1
    elif [ "$ACTION" != "$1" ]; then
        die "only one action per run (got '$ACTION' and '$1'); use --help" 2
    fi
}

parse_args() {
    while [ $# -gt 0 ]; do
        case $1 in
            -h|--help)    usage; exit 0 ;;
            -V|--version) printf '%s %s\n' "$APP_NAME" "$APP_VERSION"; exit 0 ;;
            -r|--report)  set_action report ;;
            -l|--list|--list-devices) set_action list ;;
            -y|--history) set_action history ;;
            -c|--csv|--export-csv) set_action csv ;;
            -j|--json|--export-json) set_action json ;;
            -H|--html|--export-html) set_action html ;;
            -f|--fusb|--export-fusb) set_action fusb ;;
            -o|--output)
                shift
                [ $# -gt 0 ] || die "option $1 requires a file name" 2
                OUT_FILE=$1 ;;
            --output=*) OUT_FILE=${1#*=} ;;
            -s|--since)
                shift
                [ $# -gt 0 ] || die "option $1 requires a time value" 2
                SINCE=$1 ;;
            --since=*) SINCE=${1#*=} ;;
            --no-color) COLOR=0 ;;
            --color) COLOR=auto ;;
            -v|--verbose) VERBOSE=1 ;;
            --) shift; break ;;
            -*) die "unknown option: $1 (see --help)" 2 ;;
            *) die "unexpected argument: $1 (see --help)" 2 ;;
        esac
        shift
    done
}

cleanup() {
    if [ "${USB_CHECKER_KEEP_TMP:-0}" = 1 ]; then
        printf 'temporary data kept in: %s\n' "$TMPD" >&2
        return 0
    fi
    if [ -n "$TMPD" ] && [ -d "$TMPD" ]; then
        rm -rf "$TMPD"
    fi
    return 0
}

main() {
    parse_args "$@"
    [ -n "$ACTION" ] || ACTION=report

    case $(uname -s 2>/dev/null) in
        Linux) ;;
        *)
            printf 'error: %s supports Linux only (sysfs + udev).\n' "$APP_NAME" >&2
            printf '       Detected platform: %s\n' "$(uname -s 2>/dev/null || echo unknown)" >&2
            printf '       Supported: Astra Linux, ALT Linux, RED OS, Debian/Ubuntu, RHEL, SUSE, Arch, Alpine.\n' >&2
            exit 3 ;;
    esac

    [ -n "$OUT_FILE" ] && COLOR=0
    setup_colors

    if [ -n "$OUT_FILE" ] && [ "$ACTION" != "fusb" ]; then
        : > "$OUT_FILE" 2>/dev/null || die "cannot write to $OUT_FILE"
        exec > "$OUT_FILE"
    fi

    TMPD=$(mktemp -d "${TMPDIR:-/tmp}/usb_checker.XXXXXX" 2>/dev/null) || TMPD="/tmp/usb_checker.$$"
    mkdir -p "$TMPD" || die "cannot create temporary directory"
    trap cleanup EXIT INT TERM HUP

    # Listing current devices does not need the (slow) log scan.
    if [ "$ACTION" = "list" ]; then
        NEED_HISTORY=0
    fi

    debug "sysfs=$SYS_ROOT proc=$PROC_ROOT dev=$DEV_ROOT log=$LOG_ROOT udevadm=$UDEVADM"
    debug "action=$ACTION need_history=$NEED_HISTORY"

    : > "$TMPD/devices.tsv"
    : > "$TMPD/parts.tsv"
    : > "$TMPD/usb.tsv"
    : > "$TMPD/events.tsv"
    : > "$TMPD/history.tsv"
    : > "$TMPD/hist_storage.tsv"
    : > "$TMPD/inventory.tsv"

    collect_storage
    collect_peripherals
    collect_history_sessions
    build_inventory

    case $ACTION in
        report)  render_report ;;
        list)    render_list ;;
        history) render_history ;;
        csv)     render_csv ;;
        json)    render_json ;;
        html)    render_html ;;
        fusb)    render_fusb ;;
        *)       die "internal error: unknown action '$ACTION'" 1 ;;
    esac

    exit 0
}

main "$@"