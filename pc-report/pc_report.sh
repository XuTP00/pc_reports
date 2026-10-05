#!/usr/bin/env bash
# ============================================================
#  pc_report.sh — мини-сервис «PC Report»: красивый HTML-отчёт о ПК
#
#  Единственный исполняемый файл для Linux (bash 4+).
#
#  Локальный запуск:   ./pc_report.sh [-o файл.html]
#  Удалённый запуск:   ./pc_report.sh -r user@ip[:порт] [-o файл.html]
#                      пароль вводится в интерактивном режиме,
#                      нигде не сохраняется (только RAM процесса)
#  Массовый опрос:     ./pc_report.sh -r список.txt
#                      формат строки: user ; ip/hostname ; password ; port
#                      (port необязателен — по умолчанию 22; # — комментарий)
#  Работает с удалёнными хостами Linux И Windows (OpenSSH + PowerShell).
#  HTML-отчёты создаются рядом со скриптом (в текущей папке запуска).
#
#  Что делает:  определяет ОС, собирает полные сведения об
#               ОС/железе/сети/пользователях и создаёт автономный
#               HTML-файл (тёмная тема, моноширинный шрифт).
#  Требования:  bash + стандартные утилиты Linux (без зависимостей).
# ============================================================
set -u

OUTPUT=""
TARGET=""
SSH_PORT="22"
PASS="${PC_PASS:-}"
RUN_MODE="local"

usage() { sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

REMOTE_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o|--output) OUTPUT="$2"; shift 2 ;;
    -p|--port)   SSH_PORT="$2"; shift 2 ;;
    -r|--remote) REMOTE_ARG="${2:-}"; RUN_MODE="remote"; shift 2 ;;
    -h|--help)   usage ;;
    *@*)         TARGET="$1"; RUN_MODE="remote"; shift ;;
    *) echo "Неизвестный параметр: $1 (см. --help)" >&2; exit 1 ;;
  esac
done
say() { printf '\033[1;36m[pc_report]\033[0m %s\n' "$1" >&2; }
die() { printf '\033[1;31m[pc_report] ОШИБКА:\033[0m %s\n' "$1" >&2; exit 1; }

[ "$RUN_MODE" = "remote" ] && [ -z "$REMOTE_ARG" ] && die "после -r укажите user@ip[:порт] или файл-список"

TS=$(date '+%Y%m%d_%H%M%S')
DATA_FILE=$(mktemp /tmp/.pcreport.XXXXXX)
COLLECT_SCRIPT=""
cleanup() { rm -f "$DATA_FILE" ${COLLECT_SCRIPT:+"$COLLECT_SCRIPT"}; }
trap cleanup EXIT INT TERM

# ############################################################
#  ## 1. ВСТРОЕННЫЙ СБОРЩИК ДАННЫХ (Linux, KEY<TAB>VALUE)     ##
#  ##  Списки: элементы ";", поля внутри элемента "|"         ##
#  ############################################################
COLLECT_SCRIPT=$(mktemp /tmp/.pcreport_collect.XXXXXX)
cat > "$COLLECT_SCRIPT" <<'COLLECT_EOF'
#!/usr/bin/env bash
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
COLLECT_EOF

# ############################################################
#  ## 1b. ВСТРОЕННЫЙ СБОРЩИК ДАННЫХ (Windows, PowerShell)    ##
#  ##  Отправляется по SSH на удалённый Windows-хост.        ##
#  ############################################################
WIN_PS1=$(mktemp /tmp/.pcreport_win.XXXXXX)
cat > "$WIN_PS1" <<'WINPS_EOF'
$ErrorActionPreference='Continue'
$OutputEncoding=[Console]::OutputEncoding=[Text.Encoding]::UTF8
function E($v){if($null -eq $v){''}else{([string]$v).Trim().Replace("`r"," ").Replace("`n"," ")}}
function emit($k,$v){Write-Host ("`t"+$k+"`t"+(E $v))}
function GB($b){if($b -gt 0){('{0:N1} ГБ' -f ($b/1GB))}else{'н/д'}}
$os=Get-CimInstance Win32_OperatingSystem
$cs=Get-CimInstance Win32_ComputerSystem
emit HOST $cs.Name
emit OS_NAME $os.Caption
emit OS_VER ("{0} (сборка {1})" -f $os.Version,$os.BuildNumber)
emit KERNEL $os.Version
$arch=E $env:PROCESSOR_ARCHITECTURE; if(-not $arch){$arch=E $os.OSArchitecture}
emit ARCH $arch
$bits=if("$arch" -match '64'){'64-битная'}elseif("$arch" -match '86|32'){'32-битная'}else{'н/д'}
emit BITS $bits
emit USER_NOW ("{0}\{1}" -f $env:USERDOMAIN,$env:USERNAME)
emit HOME_DIR $env:USERPROFILE
$virt='физическая машина'
try{$vm=Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
 if("$($vm.Manufacturer)" -match 'Microsoft|Google|Amazon|Xen|VMware|innotek'){
   if((Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue).SerialNumber -match 'VM-'){$virt='виртуальная машина (Hyper-V)'}else{$virt='возможно виртуальная (по производителю)'}}}catch{}
emit ENV_TYPE $virt
$up=((Get-Date)-$os.LastBootUpTime); emit UPTIME ('аптайм {0} дн. {1} ч. {2} мин.' -f $up.Days,$up.Hours,$up.Minutes)
$cpus=@(Get-CimInstance Win32_Processor); $cpu=$cpus[0]
emit CPU_MODEL $cpu.Name
emit CPU_VENDOR $cpu.Manufacturer
emit CPU_SOCKETS $cpus.Count
emit CPU_CORES (($cpus|Measure-Object -Property NumberOfCores -Sum).Sum)
emit CPU_THREADS (($cpus|Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum)
emit CPU_MHZ $cpu.CurrentClockSpeed
$L2=($cpus|Measure-Object -Property L2CacheSize -Sum).Sum
$L3=($cpus|Measure-Object -Property L3CacheSize -Sum).Sum
emit CPU_L3 "$(if($L3){[math]::Round($L3/1MB,1)}else{$L2}) МБ"
emit CPU_FLAGS (E $cpu.SecondLevelAddressTranslationExtensions)
$mb=Get-CimInstance Win32_BaseBoard
emit MOTHERBOARD ("{0} {1}" -f $mb.Manufacturer,$mb.Product)
emit MB_VERSION $mb.Version
emit SYS_VENDOR $cs.Manufacturer
$bios=Get-CimInstance Win32_BIOS
emit BIOS_VER $bios.SMBIOSBIOSVersion
emit BIOS_DATE $(try{$bios.ReleaseDate.ToString('dd.MM.yyyy')}catch{'н/д'})
$mods=@(Get-CimInstance Win32_PhysicalMemory)
$total=($mods|Measure-Object -Property Capacity -Sum).Sum
if(-not $total){$total=$cs.TotalPhysicalMemory}
emit RAM_TOTAL (GB $total)
emit RAM_AVAIL (GB ($os.FreePhysicalMemory*1KB))
$tm=@{20='DDR';21='DDR2';22='DDR3';24='DDR3';26='DDR4';34='DDR4';35='DDR5'}
$rs=''
foreach($m in $mods){
 $mt=[int]$m.SMBIOSMemoryType
 $tp=if($tm.ContainsKey($mt)){$tm[$mt]}else{E $m.MemoryType}
 $fq=if($m.ConfiguredClockSpeed -gt 0){"$($m.ConfiguredClockSpeed) МГц"}else{"$($m.Speed) МГц"}
 $rs+=("{0}|{1}|{2}|{3};" -f (E $m.Manufacturer),(GB $m.Capacity),$tp,$fq)}
emit RAM_MODULES $rs
emit RAM_COUNT $mods.Count
emit RAM_SRC 'WMI Win32_PhysicalMemory'
$gpus=@(Get-CimInstance Win32_VideoController)
$gn='';$gv='';$gd=''
foreach($g in $gpus){
 $vg=[math]::Round($g.AdapterRAM/1GB,2)
 $vt=if($vg -gt 0){"$vg ГБ"}else{'н/д (разделяемая)'}
 $gn+=(E $g.Name)+" | "; $gv+=$vt+" | "; $gd+=(E $g.DriverVersion)+", "}
emit GPU_NAME $(E ($gn.TrimEnd(' ','|')))
emit GPU_VRAM $(E ($gv.TrimEnd(' ','|')))
emit GPU_DRV $(E ($gd.TrimEnd(' ',',')))
emit GPU_BUS (E $gpus[0].InterfaceType)
$vols=@(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3')
$ds=''
foreach($v in $vols){
 $uP=if($v.Size -gt 0){[math]::Round((($v.Size-$v.FreeSpace)/$v.Size)*100)}else{0}
 $nm=if($v.VolumeName){E $v.VolumeName}else{'без имени'}
 $ds+=("{0}|{1}|{2}|{3}|{4}%|{5}|" -f $v.DeviceID,(E $v.FileSystem),(GB $v.Size),(GB ($v.Size-$v.FreeSpace)),$uP,$nm)}
emit DISKS $ds
$rootVol=$vols|Where-Object{$_.DeviceID -eq ((E $env:SystemDrive)+'\\')}|Select-Object -First 1
if(-not $rootVol -and $vols.Count){$rootVol=$vols[0]}
if($rootVol){
 $ruP=[math]::Round((($rootVol.Size-$rootVol.FreeSpace)/$rootVol.Size)*100)
 emit ROOT_DEV $rootVol.DeviceID
 emit ROOT_FS $rootVol.FileSystem
 emit ROOT_SIZE (GB $rootVol.Size)
 emit ROOT_USED (GB ($rootVol.Size-$rootVol.FreeSpace))
 emit ROOT_FREE (GB $rootVol.FreeSpace)
 emit ROOT_PUSE "$ruP%"
}
$prows=@()
foreach($d in @(Get-CimInstance Win32_DiskDrive)){
 $prows+=("{0}|{1}|{2}|{3};" -f $d.DeviceID,(E $d.Model),(GB $d.Size),(E $d.InterfaceType))}
emit PHYSICAL_DISKS (-join $prows)
$nics=@(Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True')
$ifc=''
foreach($n in $nics){
 $ipx=if($n.IPAddress){E ($n.IPAddress -join ' ')}else{'нет IPv4'}
 $gwv=if($n.DefaultIPGateway){E ($n.DefaultIPGateway -join ' ')}else{'—'}
 $md=if($n.DHCPEnabled){'DHCP (авто)'}else{'STATIC (ручная)'}
 $ifc+=("{0}|{1}|{2}|{3}|{4};" -f (E $n.Description),(E $n.MACAddress),$ipx,$gwv,$md)}
emit IFACES $ifc
$dnss=@()
foreach($n in $nics){if($n.DNSServerSearchOrder){$dnss+=$n.DNSServerSearchOrder}}
emit DNS $(if($dnss){E ($dnss|Select-Object -Unique|Sort-Object -Unique)}else{'н/д'})
$users=@(Get-CimInstance Win32_UserAccount -Filter 'LocalAccount=True'|Where-Object{$_.SIDType -eq 1})
$ul=''
foreach($u in $users){$ul+=(E $u.Name)+';'}
emit USERS_LOGIN $ul
emit USERS_ALL_N $users.Count
$sess=@(Get-CimInstance Win32_LogonSession -Filter 'LogonType=2 OR LogonType=10' -ErrorAction SilentlyContinue)
emit USERS_ONLINE ("активных интерактивных сессий: $($sess.Count)")
emit DATE_NOW (Get-Date -Format 'dd.MM.yyyy HH:mm:ss')
WINPS_EOF

# ############################################################
#  ## 2. ИСПОЛНЕНИЕ СБОРА: локально или по SSH               ##
#  ############################################################
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o LogLevel=ERROR -o ConnectTimeout=10)
RUN_USER=""
CUR_PASS=""
OUTDIR="$(pwd)"

# Пароль живёт только в памяти процесса; временный askpass-файл
# существует лишь на время одной команды ssh и удаляется сразу.
ssh_pass_run() { # $1..n = команда; пароль — из PCR_PW (или CUR_PASS)
  local ap rc pwv="${PCR_PW:-$CUR_PASS}"
  ap=$(mktemp /tmp/.pcr_ap.XXXXXX) || die "не удалось создать временный файл"
  chmod 700 "$ap"
  printf '#!/bin/sh\ncase $1 in\n *[Pp]assword*) printf "%%s\\n" "$PCR_PW" ;;\n *) printf "yes\\n" ;;\nesac\n' > "$ap"
  if [ -t 0 ]; then
    PCR_PW="$pwv" SSH_ASKPASS="$ap" SSH_ASKPASS_REQUIRE=force \
      setsid -w ssh "${SSH_OPTS[@]}" -o UserKnownHostsFile=/dev/null -p "$SSH_PORT" "$RUN_USER" "$@" 2>/dev/null
    rc=$?
  else
    # stdin занят (pipe/файл с данными сборщика) — просим ssh читать его,
    # а диалог авторизации отводим в /dev/null
    PCR_PW="$pwv" SSH_ASKPASS="$ap" SSH_ASKPASS_REQUIRE=force \
      setsid -w ssh "${SSH_OPTS[@]}" -o UserKnownHostsFile=/dev/null \
          -o NumberOfPasswordPrompts=1 -p "$SSH_PORT" "$RUN_USER" "$@" <&0 2>/dev/null
    rc=$?
  fi
  rm -f "$ap"
  return $rc
}

ssh_key_run() { # проба без пароля (ключи из стандартных мест ~/.ssh/id_*)
  ssh -o BatchMode=yes "${SSH_OPTS[@]}" -p "$SSH_PORT" "$RUN_USER" "$@" 2>/dev/null
}

# выполнение удалённой команды с учётом способа авторизации
run_ssh() { # $@ = команда (stdin/stdout как у вызывающего)
  if [ "${AUTH_MODE:-}" = "key" ]; then ssh_key_run "$@"; else ssh_pass_run "$@"; fi
}

# авторизация: сначала ключ, затем пароль (из списка/PC_PASS/интерактивно)
authorize() { # $1=пароль или пусто
  AUTH_MODE=""
  if ssh_key_run true </dev/null >/dev/null 2>&1; then AUTH_MODE="key"; return 0; fi
  local p="${1:-${PC_PASS:-}}"
  if [ -z "$p" ] && [ -n "$CUR_PASS" ]; then p="$CUR_PASS"; fi
  if [ -z "$p" ]; then
    say "Ключ SSH не подошёл — запрошу пароль (он нигде не сохраняется)."
    printf 'Пароль пользователя %s: ' "${RUN_USER%%@*}"
    read -rs p; echo
  fi
  [ -n "$p" ] || { say "ПРОПУСК: нет пароля для $RUN_USER"; return 1; }
  export PCR_PW="$p"
  if ssh_pass_run true </dev/null >/dev/null 2>&1; then AUTH_MODE="pass"; return 0; fi
  say "ПРОПУСК: вход на $RUN_USER не выполнен"
  unset PCR_PW; return 1
}

run_remote_host() { # $1=user@host  $2=порт  $3=пароль(может быть пуст)
  RUN_USER="$1"; SSH_PORT="$2"; CUR_PASS="$3"
  command -v ssh >/dev/null || die "не найден клиент ssh — удалённый режим недоступен"
  say "Подключение к $RUN_USER (порт $SSH_PORT)..."
  authorize "$3" || return 1

  local osline hostdisp hshort b64
  osline="$(run_ssh uname -s </dev/null 2>/dev/null || echo '?')"
  hostdisp="${RUN_USER##*@}"; hshort="${hostdisp%%.*}"
  TS=$(date '+%Y%m%d_%H%M%S')

  case "$osline" in
    Linux)
      say "Удалённая ОС: Linux. Сбор сведений..."
      run_ssh 'cat > /tmp/pcr_collect_$$.sh && bash /tmp/pcr_collect_$$.sh; rc=$?; rm -f /tmp/pcr_collect_$$.sh; exit $rc' \
        < "$COLLECT_SCRIPT" > "$DATA_FILE" 2>/dev/null
      [ -s "$DATA_FILE" ] || { say "ПРОПУСК: ошибка удалённого сбора на $hostdisp"; return 1; }
      TARGET_OS="Linux"
      ;;
    MINGW*|MSYS*|CYGWIN*)
      say "Удалённая ОС: Windows (OpenSSH). Сбор через PowerShell..."
      # скрипт-сборщик передаётся base64-строкой внутри команды (без stdin),
      # выполняется powershell.exe, временный файл удаляется сразу после
      b64=$(base64 < "$WIN_PS1" | tr -d '\n\r ')
      run_ssh "powershell.exe -NoProfile -ExecutionPolicy Bypass -Command \"\$f=Join-Path \$env:TEMP 'pcr_win.ps1'; [IO.File]::WriteAllBytes(\$f,[Convert]::FromBase64String('$b64')); \& \$f; Remove-Item \$f -Force\"" \
        </dev/null > "$DATA_FILE" 2>/dev/null
      [ -s "$DATA_FILE" ] || { say "ПРОПУСК: сбор через PowerShell на $hostdisp не дал данных"; return 1; }
      TARGET_OS="Windows"
      ;;
    *)
      say "ПРОПУСК: нераспознанная удалённая ОС '$osline'"; return 1 ;;
  esac

  TARGET="$RUN_USER"
  gen_and_save "$hshort" "$TS"
  say "Готово по хосту $hostdisp."
  return 0
}

parse_target() { # разбирает user@host[:порт] → глобальные P_USER/P_HOST/P_PORT
  local spec="$1" port="" host user=""
  case "$spec" in
    *@*) user="${spec%%@*}"; host="${spec#*@}" ;;
    *)   host="$spec" ;;
  esac
  if [[ "$host" == *:* ]]; then port="${host##*:}"; host="${host%:*}"; fi
  P_USER="$user"; P_HOST="$host"; P_PORT="${port:-22}"
}

build_spec() { # $1=user $2=host $3=port → user@host[:port если не 22]
  if [ "${3:-22}" = "22" ]; then printf '%s@%s' "$1" "$2"; else printf '%s@%s:%s' "$1" "$2" "$3"; fi
}

# ############################################################
#  ## 3. ГЕНЕРАЦИЯ И СОХРАНЕНИЕ ОТЧЁТА                       ##
#  ############################################################
gen_and_save() { # $1=имя хоста для файла  $2=таймстемп
  local name out
  if [ -n "$OUTPUT" ]; then
    out="$OUTPUT"
  else
    name=$(echo "${HOST:-$1}" | tr -c 'A-Za-z0-9._-' '_')
    out="${OUTDIR}/PC_Report_${name}_${2}.html"
  fi
  build_file "$out"
  say "Отчёт сохранён локально: $out"
}

esc() { local s="$1"; s="${s//&/&amp;}"; s="${s//</&lt;}"; s="${s//>/&gt;}"; s="${s//\"/&quot;}"; printf '%s' "$s"; }
get() { awk -F'\t' -v k="$1" '$1==k{sub(/^[^\t]+\t/,""); print; exit}' "$DATA_FILE"; }

# ---------- читаем данные ----------
HOST=$(get HOST)
OS_NAME=$(get OS_NAME);   OS_VER=$(get OS_VER);     KERNEL=$(get KERNEL)
ARCH=$(get ARCH);         BITS=$(get BITS)
USER_NOW=$(get USER_NOW); HOME_DIR=$(get HOME_DIR); ENV_TYPE=$(get ENV_TYPE)
UPTIME=$(get UPTIME)
CPU_MODEL=$(get CPU_MODEL); CPU_VENDOR=$(get CPU_VENDOR); CPU_CORES=$(get CPU_CORES)
CPU_SOCKETS=$(get CPU_SOCKETS); CPU_THREADS=$(get CPU_THREADS); CPU_MHZ=$(get CPU_MHZ)
CPU_L3=$(get CPU_L3); CPU_FLAGS=$(get CPU_FLAGS)
MOTHERBOARD=$(get MOTHERBOARD); MB_VERSION=$(get MB_VERSION); SYS_VENDOR=$(get SYS_VENDOR)
BIOS_VER=$(get BIOS_VER); BIOS_DATE=$(get BIOS_DATE)
RAM_TOTAL=$(get RAM_TOTAL); RAM_AVAIL=$(get RAM_AVAIL); RAM_MODULES=$(get RAM_MODULES)
RAM_COUNT=$(get RAM_COUNT); RAM_SRC=$(get RAM_SRC)
GPU_NAME=$(get GPU_NAME); GPU_BUS=$(get GPU_BUS); GPU_DRV=$(get GPU_DRV); GPU_VRAM=$(get GPU_VRAM)
ROOT_DEV=$(get ROOT_DEV); ROOT_FS=$(get ROOT_FS); ROOT_SIZE=$(get ROOT_SIZE)
ROOT_USED=$(get ROOT_USED); ROOT_FREE=$(get ROOT_FREE); ROOT_PUSE=$(get ROOT_PUSE); DISKS=$(get DISKS)
PHYS_DISKS=$(get PHYSICAL_DISKS)
IFACES=$(get IFACES); DNS=$(get DNS)
USERS_LOGIN=$(get USERS_LOGIN); USERS_ALL_N=$(get USERS_ALL_N); USERS_ONLINE=$(get USERS_ONLINE)
DATE_NOW=$(get DATE_NOW)

PU=${ROOT_PUSE%\%}; case "$PU" in (*[!0-9]*|"") PU=0;; esac
BARCLASS=ok; [ "$PU" -gt 65 ] && BARCLASS=warn; [ "$PU" -gt 85 ] && BARCLASS=crit

CSS='
:root{--bg:#0d1117;--panel:#161b22;--panel2:#1c2330;--border:#30363d;--text:#c9d1d9;--dim:#8b949e;
--blue:#388bfd;--accent:#58a6ff;--green:#3fb950;--amber:#d29922;--red:#f85149;
--mono:"JetBrains Mono","Cascadia Code","Fira Code",Consolas,"Courier New",monospace}
*{box-sizing:border-box;margin:0;padding:0}
body{background:var(--bg);color:var(--text);font-family:var(--mono);font-size:14px;line-height:1.55;padding-bottom:60px}
.wrap{max-width:1180px;margin:0 auto;padding:0 24px}
header.hero{background:linear-gradient(135deg,#0d1117 0%,#10243f 60%,#0f2f52 100%);border-bottom:2px solid var(--blue);padding:34px 0 26px}
h1{font-size:44px;letter-spacing:4px;color:#fff;text-transform:uppercase}
h1 .dot{color:var(--accent)}
.sub{display:flex;gap:26px;flex-wrap:wrap;margin-top:12px;color:var(--dim);font-size:13px}
.sub b{color:var(--accent);font-weight:600}
.badges{margin-top:14px;display:flex;gap:10px;flex-wrap:wrap}
.badge{background:#1f6feb22;border:1px solid var(--blue);color:var(--accent);padding:3px 12px;border-radius:20px;font-size:12px}
nav.toc{position:sticky;top:0;z-index:50;background:#0d1117ee;backdrop-filter:blur(6px);border-bottom:1px solid var(--border);padding:10px 0}
nav.toc .wrap{display:flex;gap:6px;flex-wrap:wrap}
nav.toc a{color:var(--dim);text-decoration:none;font-size:12px;padding:5px 12px;border-radius:6px;border:1px solid transparent}
nav.toc a:hover{color:var(--accent);border-color:var(--border);background:var(--panel)}
section{margin-top:34px}
.sec-title{display:flex;align-items:center;gap:12px;font-size:20px;color:#fff;letter-spacing:1px;margin-bottom:16px}
.sec-title .ico{width:34px;height:34px;display:flex;align-items:center;justify-content:center;background:var(--panel2);border:1px solid var(--border);border-radius:8px;font-size:17px}
.sec-title .num{color:var(--blue);font-size:14px}
.grid{display:grid;gap:16px}
.g2{grid-template-columns:repeat(auto-fit,minmax(340px,1fr))}
.card{background:var(--panel);border:1px solid var(--border);border-radius:10px;padding:18px 20px;transition:border-color .2s,transform .2s}
.card:hover{border-color:var(--blue);transform:translateY(-2px)}
.card h3{font-size:15px;color:var(--accent);margin-bottom:12px;display:flex;justify-content:space-between;align-items:center;gap:8px;flex-wrap:wrap}
.card h3 .tag{font-size:11px;color:var(--dim);font-weight:400}
table{width:100%;border-collapse:collapse;font-size:13px}
th,td{text-align:left;padding:7px 10px;border-bottom:1px solid var(--border);vertical-align:top}
th{color:var(--dim);font-weight:500;width:38%;white-space:nowrap}
tr:last-child th,tr:last-child td{border-bottom:none}
.bar{height:10px;background:#21262d;border-radius:5px;overflow:hidden;margin-top:8px}
.bar>div{height:100%;border-radius:5px}
.bar .ok{background:linear-gradient(90deg,#238636,#3fb950)}
.bar .warn{background:linear-gradient(90deg,#bb8009,#d29922)}
.bar .crit{background:linear-gradient(90deg,#da3633,#f85149)}
.pill{display:inline-block;padding:2px 10px;border-radius:12px;font-size:11px;margin:2px 4px 2px 0}
.pill.green{background:#23863622;color:var(--green);border:1px solid #238636}
.pill.blue{background:#1f6feb22;color:var(--accent);border:1px solid var(--blue)}
.pill.gray{background:#21262d;color:var(--dim);border:1px solid var(--border)}
.pill.amber{background:#9e6a0322;color:var(--amber);border:1px solid #9e6a03}
.big-num{font-size:26px;color:#fff;font-weight:700}
.dim{color:var(--dim)}
pre.term{background:#010409;border:1px solid var(--border);border-radius:8px;padding:14px 16px;font-size:12px;overflow-x:auto;color:#7ee787}
pre.term .p{color:var(--accent)}
footer{margin-top:50px;border-top:1px solid var(--border);padding-top:18px;color:var(--dim);font-size:12px}
footer .wrap{display:flex;justify-content:space-between;flex-wrap:wrap;gap:8px}
@media print{body{background:#fff;color:#111}.card{border-color:#bbb;background:#fafafa}}
'

# ---------- генерация секций ----------
gen_body() {
cat << EOF
<header class="hero"><div class="wrap">
<h1>PC<span class="dot">▪</span>REPORT</h1>
<div class="sub">
 <span>КОМПЬЮТЕР: <b>$(esc "$HOST")</b></span>
 <span>ДАТА ОТЧЁТА: <b>$DATE_NOW</b></span>
 <span>ПОЛЬЗОВАТЕЛЬ: <b>$(esc "$USER_NOW")</b></span>
$([ "$RUN_MODE" = "remote" ] && printf ' <span>РЕЖИМ: <b>удалённый сбор по SSH %s (%s)</b></span>' "$(esc "${TARGET:-}")" "$(esc "${TARGET_OS:-Linux}")")
</div>
<div class="badges">
 <span class="badge">$(esc "$OS_NAME")</span>
 <span class="badge">$(esc "$ARCH") · $(esc "$BITS")</span>
 <span class="badge">Kernel $(esc "$KERNEL")</span>
 <span class="badge">$RAM_TOTAL RAM</span>
 <span class="badge">$CPU_CORES ядер</span>
</div>
</div></header>
<nav class="toc"><div class="wrap">
<a href="#os">ОС</a><a href="#cpu">Процессор</a><a href="#mb">Плата</a><a href="#ram">Память</a>
<a href="#gpu">Видеокарта</a><a href="#disk">Диски</a><a href="#net">Сеть</a><a href="#users">Пользователи</a><a href="#summary">Сводка</a>
</div></nav>

<section id="os"><div class="wrap">
<div class="sec-title"><span class="ico">🖥</span><span class="num">01</span> Операционная система</div>
<div class="grid g2">
 <div class="card"><h3>Система</h3><table>
 <tr><th>Полное наименование</th><td>$(esc "$OS_NAME")</td></tr>
 <tr><th>Версия</th><td>$(esc "$OS_VER")</td></tr>
 <tr><th>Ядро</th><td>$(esc "$KERNEL")</td></tr>
 <tr><th>Архитектура</th><td>$(esc "$ARCH")</td></tr>
 <tr><th>Разрядность</th><td>$(esc "$BITS")</td></tr>
 </table></div>
 <div class="card"><h3>Платформа</h3><table>
 <tr><th>Тип окружения</th><td>$(esc "$ENV_TYPE")</td></tr>
 <tr><th>Имя компьютера</th><td>$(esc "$HOST")</td></tr>
 <tr><th>Загрузка</th><td>$(esc "$UPTIME")</td></tr>
 </table></div>
</div></div></section>

<section id="cpu"><div class="wrap">
<div class="sec-title"><span class="ico">🧠</span><span class="num">02</span> Процессор</div>
<div class="grid g2">
 <div class="card"><h3>$(esc "$CPU_MODEL") <span class="tag">$CPU_CORES ядер / $CPU_THREADS потоков</span></h3><table>
 <tr><th>Производитель</th><td>$(esc "$CPU_VENDOR")</td></tr>
 <tr><th>Сокетов</th><td>$CPU_SOCKETS</td></tr>
 <tr><th>Физических ядер</th><td>$CPU_CORES</td></tr>
 <tr><th>Логических процессоров</th><td>$CPU_THREADS</td></tr>
 <tr><th>Частота</th><td>$(esc "$CPU_MHZ") МГц</td></tr>
 <tr><th>Кэш L3</th><td>$(esc "$CPU_L3")</td></tr>
 </table></div>
 <div class="card"><h3>Набор инструкций (выдержка)</h3>
 <div>$(printf '%s' "$CPU_FLAGS" | tr ' ' '\n' | grep -v '^$' | head -18 | awk '{printf "<span class=\"pill gray\">%s</span>", $1}')</div>
 <p class="dim" style="margin-top:10px;font-size:12px">Полный список: lscpu · /proc/cpuinfo</p>
 </div>
</div></div></section>

<section id="mb"><div class="wrap">
<div class="sec-title"><span class="ico">🔲</span><span class="num">03</span> Материнская плата</div>
<div class="grid g2">
 <div class="card"><h3>Плата</h3><table>
 <tr><th>Полное наименование</th><td>$(esc "$MOTHERBOARD")</td></tr>
 <tr><th>Версия платы</th><td>$(esc "$MB_VERSION")</td></tr>
 <tr><th>Производитель платформы</th><td>$(esc "$SYS_VENDOR")</td></tr>
 </table></div>
 <div class="card"><h3>BIOS / UEFI</h3><table>
 <tr><th>Версия BIOS</th><td>$(esc "$BIOS_VER")</td></tr>
 <tr><th>Дата BIOS</th><td>$(esc "$BIOS_DATE")</td></tr>
 </table></div>
</div></div></section>

<section id="ram"><div class="wrap">
<div class="sec-title"><span class="ico">📊</span><span class="num">04</span> Оперативная память</div>
<div class="grid g2">
 <div class="card"><h3>Итог</h3>
  <div class="big-num">$RAM_TOTAL</div>
  <div style="margin-top:10px;font-size:13px">
   <div><span class="dim">Модулей установлено:</span> $RAM_COUNT</div>
   <div><span class="dim">Свободно доступно:</span> $RAM_AVAIL</div>
   <div><span class="dim">Источник данных:</span> $(esc "$RAM_SRC")</div>
  </div>
 </div>
 <div class="card"><h3>Модули памяти</h3>
  <table><tr><th>№</th><th>Производитель</th><th>Part Number</th><th>Объём</th><th>Тип/частота</th></tr>
$(echo "$RAM_MODULES" | tr ';' '\n' | awk -F'|' 'NF>=4{n++; printf "<tr><td>#%d</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>\n", n, $1, $2, $3, $4}')
  </table>
 </div>
</div></div></section>

<section id="gpu"><div class="wrap">
<div class="sec-title"><span class="ico">🎮</span><span class="num">05</span> Видеокарта</div>
<div class="grid g2">
 <div class="card"><h3>Адаптер</h3><table>
 <tr><th>Полное наименование</th><td>$(esc "$GPU_NAME")</td></tr>
 <tr><th>Шина (PCI)</th><td>$(esc "$GPU_BUS")</td></tr>
 <tr><th>Драйвер</th><td>$(esc "$GPU_DRV")</td></tr>
 </table></div>
 <div class="card"><h3>Характеристики</h3><table>
 <tr><th>Видеопамять</th><td>$(esc "$GPU_VRAM")</td></tr>
 </table></div>
</div></div></section>

<section id="disk"><div class="wrap">
<div class="sec-title"><span class="ico">💾</span><span class="num">06</span> Дисковое пространство</div>
<div class="grid g2">
$(if [ "${TARGET_OS:-Linux}" = "Windows" ]; then
  # Windows: карточка на каждый логический том (DISKS: DeviceID|FS|Size|Used|Use%|Label)
  echo "$DISKS" | tr ';' '\n' | grep -v '^$' | awk -F'|' 'NF>=5{
    p=$5; sub(/%/,"",p); cls=(p+0>85)?"crit":((p+0>65)?"warn":"ok")
    lbl=(NF>=6 && $6!="")?$6:"без имени"
    printf " <div class=\"card\"><h3>%s <span class=\"tag\">%s · %s</span></h3><table>\n", $1, $2, lbl
    printf "<tr><th>Общий объём</th><td>%s</td></tr>\n<tr><th>Занято</th><td>%s (%s)</td></tr>\n", $3, $4, $5
    printf "</table>\n <div class=\"bar\"><div class=\"%s\" style=\"width:%s%%\"></div></div>\n </div>\n", cls, p+0 }'
else
  # Linux: корневое устройство + физдиски
  printf ' <div class="card"><h3>Корневое устройство <span class="tag">%s</span></h3><table>\n' "$(esc "$ROOT_DEV")"
  printf ' <tr><th>Блочное устройство (root)</th><td>%s</td></tr>\n' "$(esc "$ROOT_DEV")"
  printf ' <tr><th>Файловая система</th><td>%s</td></tr>\n' "$(esc "$ROOT_FS")"
  printf ' <tr><th>Общий объём</th><td>%s</td></tr>\n' "$(esc "$ROOT_SIZE")"
  printf ' <tr><th>Занято</th><td>%s (%s)</td></tr>\n' "$(esc "$ROOT_USED")" "$(esc "$ROOT_PUSE")"
  printf ' <tr><th>Свободно</th><td>%s</td></tr>\n' "$(esc "$ROOT_FREE")"
  printf ' </table>\n <div class="bar"><div class="%s" style="width:%s%%"></div></div>\n </div>\n' "$BARCLASS" "$PU"
fi)
 <div class="card"><h3>Физические диски</h3>
  <table><tr><th>Устройство</th><th>Модель</th><th>Объём</th><th>Тип/Интерфейс</th></tr>
$( { [ -n "$PHYS_DISKS" ] && printf '%s\n' "$PHYS_DISKS"; } | tr ';' '\n' | awk -F'|' 'NF>=4{printf "<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>\n", $1, $2, $3, $4}')
  </table>
 </div>
</div></div></section>

<section id="net"><div class="wrap">
<div class="sec-title"><span class="ico">🌐</span><span class="num">07</span> Сетевые интерфейсы</div>
<div class="grid g2">
$(echo "$IFACES" | tr ';' '\n' | awk -F'|' 'NF>=6{n++
 st=(($2~/up/)?((index($6,"DHCP")>0)?"green":"blue"):"gray")
 printf "<div class=\"card\"><h3>%s <span class=\"pill %s\">%s</span></h3><table>\n", $1, st, $2
 printf "<tr><th>MAC-адрес</th><td>%s</td></tr>\n", $3
 printf "<tr><th>IPv4</th><td>%s</td></tr>\n", $4
 printf "<tr><th>Шлюз по умолчанию</th><td>%s</td></tr>\n", $5
 printf "<tr><th>Режим настройки</th><td><span class=\"pill blue\">%s</span></td></tr>\n", $6
 printf "</table></div>\n"}')
 <div class="card"><h3>DNS</h3><table><tr><th>Серверы DNS</th><td>$(esc "$DNS")</td></tr></table></div>
</div></div></section>

<section id="users"><div class="wrap">
<div class="sec-title"><span class="ico">👤</span><span class="num">08</span> Пользователи</div>
<div class="grid g2">
 <div class="card"><h3>Текущая сессия</h3><table>
 <tr><th>Запущено от имени</th><td>$(esc "$USER_NOW")</td></tr>
 <tr><th>Домашний каталог</th><td>$(esc "$HOME_DIR")</td></tr>
 <tr><th>Активные сессии</th><td>$(esc "$USERS_ONLINE")</td></tr>
 </table></div>
 <div class="card"><h3>Пользователи системы <span class="tag">всего аккаунтов: $USERS_ALL_N</span></h3>
 <div>$(echo "$USERS_LOGIN" | tr ';' '\n' | grep -v '^$' | awk '{printf "<span class=\"pill blue\">%s</span>", $1}')</div>
 <p class="dim" style="margin-top:10px;font-size:12px">Показаны пользователи с UID ≥ 1000 (реальные учётные записи)</p>
 </div>
</div></div></section>

<section id="summary"><div class="wrap">
<div class="sec-title"><span class="ico">⌨️</span><span class="num">09</span> Сводка (терминальный вид)</div>
<pre class="term"><span class="p">$</span> hostname      → $(esc "$HOST")
<span class="p">$</span> os            → $(esc "$OS_NAME") · $(esc "$OS_VER") · $(esc "$ARCH") $(esc "$BITS")
<span class="p">$</span> cpu           → $(esc "$CPU_MODEL") · $CPU_CORES cores / $CPU_THREADS threads
<span class="p">$</span> motherboard   → $(esc "$MOTHERBOARD")
<span class="p">$</span> ram           → $RAM_TOTAL · $RAM_COUNT module(s)
<span class="p">$</span> gpu           → $(esc "$GPU_NAME") · VRAM: $(esc "$GPU_VRAM")
<span class="p">$</span> root disk     → $(esc "$ROOT_DEV") · $(esc "$ROOT_SIZE") total · $(esc "$ROOT_USED") used ($(esc "$ROOT_PUSE"))
<span class="p">$</span> user          → $(esc "$USER_NOW") · all: $(esc "$USERS_LOGIN")
</pre></div></section>

<footer><div class="wrap">
<span>Отчёт сформирован скриптом pc_report.sh · $DATE_NOW</span>
<span>Хост: $(esc "$HOST") · Автономный HTML, без внешних ресурсов</span>
</div></footer>
EOF
}

build_file() { # $1=output
cat > "$1" << HEAD
<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>PC Report — $(esc "$HOST") — $(date '+%d.%m.%Y %H:%M')</title>
<style>$CSS</style>
</head>
<body>
HEAD
gen_body >> "$1"
echo "</body></html>" >> "$1"
}

# ############################################################
#  ## 4. ГЛАВНЫЙ ЗАПУСК                                      ##
#  ############################################################
if [ "$RUN_MODE" = "local" ]; then
  say "Сбор сведений о системе (локально, Linux)..."
  bash "$COLLECT_SCRIPT" > "$DATA_FILE" 2>/dev/null || die "Сборщик данных завершился с ошибкой"
  [ -s "$DATA_FILE" ] || die "пустой набор данных"
  TARGET_OS="Linux"
  gen_and_save "$(hostname)" "$TS"
else
  OKC=0; FAILC=0
  if [ -f "$REMOTE_ARG" ]; then
    # ----- файл-список: user ; ip/hostname ; password ; port -----
    say "Массовый опрос по списку: $REMOTE_ARG"
    LINENO_=0
    while IFS= read -r line || [ -n "$line" ]; do
      LINENO_=$((LINENO_+1))
      line=$(printf '%s' "$line" | tr -d '\r')
      case "$line" in ''|\#*) continue ;; esac
      u=$(printf '%s' "$line"  | awk -F';' '{gsub(/^[ \t]+|[ \t]+$/,"",$1); print $1}')
      h=$(printf '%s' "$line"  | awk -F';' '{gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2}')
      p=$(printf '%s' "$line"  | awk -F';' '{gsub(/^[ \t]+|[ \t]+$/,"",$3); print $3}')
      pt=$(printf '%s' "$line" | awk -F';' '{gsub(/^[ \t]+|[ \t]+$/,"",$4); print $4}')
      [ -z "$u" ] || [ -z "$h" ] && { say "Строка $LINENO_: пропуск (нужны user и ip/hostname)"; FAILC=$((FAILC+1)); continue; }
      [ -z "$pt" ] && pt=22
      echo "───────────── [$LINENO_] $u@$h:$pt"
      if run_remote_host "$u@$h" "$pt" "$p"; then OKC=$((OKC+1)); else FAILC=$((FAILC+1)); fi
    done < "$REMOTE_ARG"
    unset PCR_PW
    say "Итог: успешно $OKC, с ошибками $FAILC."
    [ "$OKC" -gt 0 ] || exit 2
  else
    parse_target "$REMOTE_ARG"
    [ -n "$P_USER" ] || P_USER="$(id -un)"
    run_remote_host "$(build_spec "$P_USER" "$P_HOST" "$P_PORT")" "$P_PORT" "${PC_PASS:-}" || exit 2
    unset PCR_PW
  fi
fi

exit 0
