#!/usr/bin/env bash
# ============================================================
#  collect.sh — сбор сведений о ПК (Linux), вывод KEY<TAB>VALUE
#  Используется: pc_report.sh (локально) и навыком через SSH.
#  Только стандартные утилиты, без зависимостей.
#  Списки: элементы разделены ";", поля внутри элемента "|".
# ============================================================
set -u

emit() { printf '%s\t%s\n' "$1" "$2"; }

# ---------- ОС ----------
OS_NAME=""; OS_VER=""; OS_BUILD=""
if [ -r /etc/os-release ]; then
  . /etc/os-release
  OS_NAME="${PRETTY_NAME:-${NAME:-Linux}}"
  OS_VER="${VERSION:-${VERSION_ID:-unknown}}"
  OS_BUILD="${VERSION_CODENAME:-}"
fi
[ -n "$OS_NAME" ] || OS_NAME="$(uname -s)"
# если в имени уже есть кодовое имя в скобках — не дублировать его в версии
case "$OS_NAME" in *"$OS_BUILD)"*) OS_BUILD="" ;; esac
KERNEL=$(uname -r)
ARCH=$(uname -m)
case "$ARCH" in
  x86_64|aarch64|ppc64le|s390x|riscv64|ia64|alpha) BITS="64-bit" ;;
  i386|i486|i586|i686|armv7l|armv6l|mips)          BITS="32-bit" ;;
  *) BITS="unknown" ;;
esac
HOST=$(hostname -f 2>/dev/null || hostname)
USER_NOW=$(id -un)
HOME_DIR="${HOME:-/root}"
UPTIME_S=$(uptime -s 2>/dev/null || echo "н/д")
UPTIME_P=$(uptime -p 2>/dev/null | sed 's/^up //' || uptime | sed 's/.*up \([^,]*\).*/\1/')

ENV_TYPE="Физическая машина (bare metal)"
if [ -f /.dockerenv ] || grep -qsE 'docker|containerd|kubepods|lxc' /proc/1/cgroup 2>/dev/null; then
  ENV_TYPE="Контейнер (Docker/Kubernetes/LXC)"
elif command -v systemd-detect-virt >/dev/null 2>&1; then
  v=$(systemd-detect-virt 2>/dev/null || true)
  case "$v" in
    ""|none) : ;;
    docker|podman|lxc) ENV_TYPE="Контейнер ($v)" ;;
    *) ENV_TYPE="Виртуальная машина ($v)" ;;
  esac
fi
PN=""; SYS_MFR=""
for f in /sys/class/dmi/id/product_name /sys/devices/virtual/dmi/id/product_name; do
  if [ -r "$f" ]; then PN=$(tr -d '\0' < "$f" 2>/dev/null); [ -n "$PN" ] && break; fi
done
for f in /sys/class/dmi/id/sys_vendor /sys/devices/virtual/dmi/id/sys_vendor; do
  if [ -r "$f" ]; then SYS_MFR=$(tr -d '\0' < "$f" 2>/dev/null); [ -n "$SYS_MFR" ] && break; fi
done
case "$PN" in
  *VirtualBox*) ENV_TYPE="Виртуальная машина VirtualBox ($PN)";;
  *VMware*)     ENV_TYPE="Виртуальная машина VMware ($PN)";;
  *QEMU*|*KVM*) ENV_TYPE="Виртуальная машина QEMU/KVM ($PN)";;
  Amazon*)      ENV_TYPE="Облако AWS EC2";;
esac

emit OS_NAME   "$OS_NAME"
emit OS_VER    "$(echo "$OS_VER $OS_BUILD" | awk '{$1=$1};1')"
emit KERNEL    "Linux $KERNEL"
emit ARCH      "$ARCH"
emit BITS      "$BITS"
emit HOST      "$HOST"
emit USER_NOW  "$USER_NOW"
emit HOME_DIR  "$HOME_DIR"
emit ENV_TYPE  "$ENV_TYPE"
emit UPTIME    "$UPTIME_S, вверх $UPTIME_P"

# ---------- Процессор ----------
CPU_MODEL=$(lscpu 2>/dev/null | awk -F': +' '/^Model name/{print $2; exit}')
[ -n "$CPU_MODEL" ] || CPU_MODEL=$(awk -F': +' '/^model name/{print $2; exit}' /proc/cpuinfo)
[ -n "$CPU_MODEL" ] || CPU_MODEL="unknown"
CPU_VENDOR=$(lscpu 2>/dev/null | awk -F': +' '/^Vendor ID/{print $2; exit}')
CPU_CORES=$(lscpu 2>/dev/null | awk -F': +' '/^Core\(s\) per socket/{print $2; exit}')
CPU_SOCKETS=$(lscpu 2>/dev/null | awk -F': +' '/^Socket\(s\)/{print $2; exit}')
CPU_THREADS=$(lscpu 2>/dev/null | awk -F': +' '/^CPU\(s\):/{print $2; exit}')
[ -n "$CPU_THREADS" ] || CPU_THREADS=$(nproc)
[ -n "$CPU_CORES" ] || CPU_CORES=$CPU_THREADS
[ -n "$CPU_SOCKETS" ] || CPU_SOCKETS=1
CPU_MHZ=$(lscpu 2>/dev/null | awk -F': +' '/^CPU max MHz/{printf "%.0f",$2; exit}')
[ -n "$CPU_MHZ" ] || CPU_MHZ=$(awk -F': +' '/^cpu MHz/{printf "%.0f",$2; exit}' /proc/cpuinfo)
CPU_CACHE=$(lscpu 2>/dev/null | awk -F': +' '/^L3 cache/{print $2; exit}')
CPU_FLAGS=$(awk -F': +' '/^flags/{print $2; exit}' /proc/cpuinfo | tr ' ' '\n' | grep -E '^(sse|avx|fma|aes|x2apic|hle|bmi)' | head -14 | paste -sd' ' -)

emit CPU_MODEL   "$CPU_MODEL"
emit CPU_VENDOR  "${CPU_VENDOR:-unknown}"
emit CPU_CORES   "$CPU_CORES"
emit CPU_SOCKETS "$CPU_SOCKETS"
emit CPU_THREADS "$CPU_THREADS"
emit CPU_MHZ     "${CPU_MHZ:-н/д}"
emit CPU_L3      "${CPU_CACHE:-н/д}"
emit CPU_FLAGS   "${CPU_FLAGS:-n/a}"

# ---------- Материнская плата ----------
BB_MFR=""; BB_PROD=""; BB_VER=""; BIOS_V=""; BIOS_D=""
read_dmi_file() { # $1 = file suffix
  local f
  for f in "/sys/class/dmi/id/$1" "/sys/devices/virtual/dmi/id/$1"; do
    if [ -r "$f" ]; then tr -d '\0' < "$f"; return 0; fi
  done
  return 1
}
BB_MFR=$(read_dmi_file board_vendor || true)
BB_PROD=$(read_dmi_file board_name || true)
BB_VER=$(read_dmi_file board_version || true)
BIOS_V=$(read_dmi_file bios_version || true)
BIOS_D=$(read_dmi_file bios_date || true)
if [ -z "$BB_MFR" ] && [ -z "$BB_PROD" ] && command -v dmidecode >/dev/null 2>&1; then
  BB_MFR=$(dmidecode -s baseboard-manufacturer 2>/dev/null || true)
  BB_PROD=$(dmidecode -s baseboard-product-name 2>/dev/null || true)
  BB_VER=$(dmidecode -s baseboard-version 2>/dev/null || true)
  BIOS_V=$(dmidecode -s bios-version 2>/dev/null || true)
  BIOS_D=$(dmidecode -s bios-release-date 2>/dev/null || true)
fi
MB=$(echo "$BB_MFR $BB_PROD" | awk '{$1=$1};1')
[ -n "$MB" ] || MB="не определена (DMI недоступен в контейнере/виртуальной среде)"
[ -n "$BIOS_V" ] || BIOS_V="н/д"
[ -n "$BIOS_D" ] || BIOS_D="н/д"

emit MOTHERBOARD "$MB"
emit MB_VERSION  "${BB_VER:-н/д}"
emit SYS_VENDOR  "${SYS_MFR:-н/д}"
emit BIOS_VER    "$BIOS_V"
emit BIOS_DATE   "$BIOS_D"

# ---------- Память ----------
RAM_KB=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
RAM_GB=$(awk -v k="$RAM_KB" 'BEGIN{printf "%.1f", k/1048576}')
RAM_AVAIL=$(awk -v k="$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)" 'BEGIN{printf "%.1f GB", k/1048576}')
MODS=""
if command -v dmidecode >/dev/null 2>&1; then
  MODS=$(dmidecode -t memory -q 2>/dev/null | awk '
    BEGIN{RS="\n\n"}
    /^Handle .*Memory Device$/ && !/No Module Installed/ {
      m=""; p=""; sz=""; fr=""; ty=""
      if (match($0,/Manufacturer: [^\n]+/)) { m=substr($0,RSTART+13,RLENGTH-13); gsub(/ +$/,"",m)}
      if (match($0,/Part Number: [^\n]+/))  { p=substr($0,RSTART+12,RLENGTH-12); gsub(/ +$/,"",p)}
      if (match($0,/Size: [^\n]+/))         { sz=substr($0,RSTART+6,RLENGTH-6); gsub(/ +$/,"",sz)}
      if (match($0,/Type: DDR[0-9]/))       { ty=substr($0,RSTART+6,RLENGTH-6)}
      if (match($0,/Configured Clock Speed: [^\n]+/))   { fr=substr($0,RSTART+24,RLENGTH-24); gsub(/ +$/,"",fr)}
      else if (match($0,/Configured Memory Speed: [^\n]+/)) { fr=substr($0,RSTART+25,RLENGTH-25); gsub(/ +$/,"",fr)}
      if (sz ~ /[0-9]/) printf "%s|%s|%s|%s %s;", m, p, sz, ty, fr
    }')
fi
NMOD=0
[ -n "$MODS" ] && NMOD=$(echo "$MODS" | tr ';' '\n' | grep -c '|')
if [ "$NMOD" -eq 0 ]; then
  MODS="Модули недоступны для чтения (нет доступа к DMI)|virtual|${RAM_GB} GB|итого по /proc/meminfo;"
  NMOD=1
  RAM_SRC="/proc/meminfo (DMI недоступен)"
else
  RAM_SRC="DMI (dmidecode)"
fi
emit RAM_TOTAL "$RAM_GB GB"
emit RAM_AVAIL "$RAM_AVAIL"
emit RAM_MODULES "$MODS"
emit RAM_COUNT "$NMOD"
emit RAM_SRC "$RAM_SRC"

# ---------- Видеокарта ----------
GPU_NAME=""; GPU_BUS=""; GPU_DRV=""; GPU_VRAM=""
if command -v lspci >/dev/null 2>&1; then
  line=$(lspci 2>/dev/null | grep -iE 'VGA compatible controller|3D controller|Display controller' | head -1)
  if [ -n "$line" ]; then
    GPU_BUS=$(echo "$line" | awk '{print $1}')
    GPU_NAME=$(echo "$line" | sed -E 's/^[0-9a-f]+:[0-9a-f]+\.[0-9a-f] [^:]+: //')
    GPU_DRV=$(lspci -k -s "$GPU_BUS" 2>/dev/null | awk -F': ' '/Kernel driver in use/{print $2}')
  fi
elif command -v lshw >/dev/null 2>&1; then
  GPU_NAME=$(lshw -class display 2>/dev/null | awk -F': ' '/product:/{print $2; exit}')
fi
if [ -z "$GPU_NAME" ] && [ -d /sys/class/drm ]; then
  for c in /sys/class/drm/card[0-9]; do
    [ -e "$c/device/vendor" ] || continue
    v=$(cat "$c/device/vendor"); d=$(cat "$c/device/device" 2>/dev/null)
    GPU_NAME="DRM $(basename "$c") vendor=0x$v device=0x$d (полное имя недоступно без lspci)"
    break
  done
fi
[ -n "$GPU_NAME" ] || GPU_NAME="Графический адаптер не обнаружен (headless-окружение)"
[ -n "$GPU_DRV" ] || GPU_DRV="н/д"
if command -v nvidia-smi >/dev/null 2>&1; then
  nv=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader 2>/dev/null | head -1)
  [ -n "$nv" ] && GPU_VRAM="$nv"
fi
if [ -z "$GPU_VRAM" ]; then
  for d in /sys/class/drm/card*/device/mem_info_vram_total; do
    if [ -r "$d" ]; then GPU_VRAM=$(awk -v b="$(cat "$d")" 'BEGIN{printf "%.1f GB", b/1073741824}'); break; fi
  done
fi
[ -n "$GPU_VRAM" ] || GPU_VRAM="н/д (видеопамять не видима из текущего окружения)"

emit GPU_NAME "$GPU_NAME"
emit GPU_BUS  "${GPU_BUS:-н/д}"
emit GPU_DRV  "$GPU_DRV"
emit GPU_VRAM "$GPU_VRAM"

# ---------- Диски ----------
ROOT_SRC=$(findmnt -n -o SOURCE / 2>/dev/null || awk '$2=="/"{print $1; exit}' /proc/mounts)
ROOT_FS=$(findmnt -n -o FSTYPE / 2>/dev/null || awk '$2=="/"{print $3; exit}' /proc/mounts)
R_SIZE=$(df -hP / 2>/dev/null | awk 'NR==2{print $2}')
R_USED=$(df -hP / 2>/dev/null | awk 'NR==2{print $3}')
R_AVAIL=$(df -hP / 2>/dev/null | awk 'NR==2{print $4}')
R_PUSE=$(df -hP / 2>/dev/null | awk 'NR==2{print $5}')
DISKS=""
if command -v lsblk >/dev/null 2>&1; then
  # NAME SIZE ROTA MODEL TYPE -> "name|size|rota|model|type"; пустые поля (MODEL) заполняем из конца строки
  while IFS='|' read -r name size rota model type; do
    [ "$type" = "disk" ] || continue
    hum=$(numfmt --to=iec-i --suffix=B "${size:-0}" 2>/dev/null || echo "${size:-?} B")
    kind="HDD"; [ "$rota" = "0" ] && kind="SSD/NVMe"
    model=$(echo "${model:-}" | awk '{$1=$1};1'); [ -n "$model" ] || model="модель недоступна"
    DISKS+="/dev/$name|$model|$hum|$kind;"
  done < <(lsblk -b -dn -o NAME,SIZE,ROTA,MODEL,TYPE 2>/dev/null | awk '
      { t=$NF; n=$1; s=$2; r=$3; m="";
        for(i=4;i<NF-0;i++){ if($i!=""){m=m" "$i}}
        sub(/^ /,"",m); if(m=="")m=" ";
        print n"|"s"|"r"|"m"|"t }')
fi
[ -n "$DISKS" ] || DISKS="/dev/-|список дисков недоступен|$R_SIZE|—"

emit ROOT_DEV  "${ROOT_SRC:-/}"
emit ROOT_FS   "${ROOT_FS:-overlayfs/unknown}"
emit ROOT_SIZE "$R_SIZE"
emit ROOT_USED "$R_USED"
emit ROOT_FREE "$R_AVAIL"
emit ROOT_PUSE "$R_PUSE"
emit DISKS "$DISKS"

# ---------- Сеть ----------
IFACES=""
for ifpath in /sys/class/net/*; do
  ifn=$(basename "$ifpath")
  [ "$ifn" = "lo" ] && continue
  st=$(cat "$ifpath/operstate" 2>/dev/null || echo down)
  mac=$(cat "$ifpath/address" 2>/dev/null || echo н/д)
  ip4=$(ip -4 -o addr show dev "$ifn" 2>/dev/null | awk '{printf "%s ",$4}' | awk '{$1=$1};1')
  gw=$(ip route show default 2>/dev/null | awk -v d="$ifn" '$5==d{print $3; exit}')
  [ -n "$gw" ] || gw="-"
  mode="статическая/manual"
  if command -v nmcli >/dev/null 2>&1; then
    conn=$(nmcli -g GENERAL.CONNECTION device show "$ifn" 2>/dev/null)
    if [ -n "$conn" ]; then
      cm=$(nmcli -f ipv4.method con show "$conn" 2>/dev/null | awk '/ipv4.method/{print $2}')
      [ "$cm" = "auto" ] && mode="DHCP (автоматически)"
      [ "$cm" = "manual" ] && mode="статическая (NetworkManager manual)"
    fi
  elif command -v networkctl >/dev/null 2>&1; then
    networkctl status "$ifn" 2>/dev/null | grep -qi DHCP && mode="DHCP (systemd-networkd)"
  fi
  IFACES+="$ifn|$st|$mac|${ip4:-без IPv4}|$gw|$mode;"
done
[ -n "$IFACES" ] || IFACES="(активных интерфейсов не найдено)|—|—|—|—|—"
DNS=$(grep -E '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{printf "%s ",$2}' | awk '{$1=$1};1')
[ -n "$DNS" ] || DNS="н/д"
emit IFACES "$IFACES"
emit DNS "$DNS"

# ---------- Пользователи ----------
LOGIN_USERS=$(awk -F: '$3>=1000 && $3<=60000 && $1!="nobody"{printf "%s;",$1}' /etc/passwd)
[ -n "$LOGIN_USERS" ] || LOGIN_USERS="(нет пользователей с UID>=1000);"
ALL_N=$(wc -l < /etc/passwd)
ONLINE=$(who 2>/dev/null | awk '{printf "%s;",$1}' | sort -u | tr -d '\n')
[ -n "$ONLINE" ] || ONLINE="(нет активных интерактивных сессий)"
emit USERS_LOGIN "$LOGIN_USERS"
emit USERS_ALL_N "$ALL_N"
emit USERS_ONLINE "$ONLINE"
emit DATE_NOW "$(date '+%d.%m.%Y %H:%M:%S')"
exit 0
