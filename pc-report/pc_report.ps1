# ============================================================

#  pc_report.ps1 — мини-сервис «PC Report»: HTML-отчёт о ПК (Windows)

#

#  Единственный исполняемый файл для Windows.

#

#  Запуск:      powershell -ExecutionPolicy Bypass -File .\pc_report.ps1

#               (опционально: -Output C:\path\report.html)

#  Что делает:  собирает полные сведения об ОС/железе (WMI/CIM)

#               и создаёт автономный HTML-файл в едином стиле

#               с Linux-версией (тёмная тема, моноширинный шрифт).

#  Требования:  Windows 10/11, PowerShell 5.1+ (без внешних модулей).

#  Удалённый режим (-r): подключение по SSH к удалённому ПК

#               (Linux или Windows), сбор данных на нём, а итоговый HTML-

#               отчёт сохраняется ЗДЕСЬ — в папке запуска этого скрипта.

#  Запуск:

#               .\pc_report.ps1                       (локально)

#               .\pc_report.ps1 -r user@ip[:порт]     (один хост)

#               .\pc_report.ps1 -r список.txt         (user ; ip ; password ; port)

#  Для -r нужен клиент OpenSSH (ssh.exe, входит в Windows 10+). Пароль

#               нигде не сохраняется: временный askpass удаляется сразу.

# ============================================================

param(

  [string]$Output = "",

  [Parameter(Position=0)][Alias("r")][string]$Remote = ""

)



$DASH = [string][char]0x2014

$ErrorActionPreference = 'Continue'

# Кодировка консоли UTF-8 — иначе вывод ssh.exe и сообщения на кириллице
# превращаются в кракозябры (особенно в exe-сборке PS2EXE).
try { [Console]::OutputEncoding=[Text.Encoding]::UTF8; $OutputEncoding=[Text.Encoding]::UTF8 } catch {}

function Say($m) { Write-Host "[pc_report] $m" -ForegroundColor Cyan }

function Esc($s) { if ($null -eq $s) { '' } else { ([string]$s).Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;').Replace('"','&quot;') } }

function GB($bytes) { if ($bytes -gt 0) { ('{0:N1} ГБ' -f ($bytes/1GB)) } else { $DASH } }

# ============================================================

#  Удалённый режим (-r): SSH-сбор с Linux/Windows хостов

# ============================================================

$script:RemoteTarget = ""

$script:RemotePort   = 22

$script:RemotePass   = ""

$script:AuthMode     = ""

function New-AskPass {

  # SSH_ASKPASS-ответчик: печатает пароль из PCR_PW; на вопросы о host key /
  # fingerprint отвечает 'yes'. .cmd — потому что OpenSSH для Windows запускает
  # askpass через cmd-оболочку.
  $f = Join-Path $env:TEMP ("pcr_ap_" + [guid]::NewGuid().ToString('N').Substring(0,8) + ".cmd")

  $bat = '@echo off' + "`r`n" + 'echo %PCR_PW%' + "`r`n"

  Set-Content -Path $f -Value $bat -Encoding ASCII

  return $f

}

# Диагностика сетевой доступности хоста (до попытки авторизации).
function Test-PortOpen([string]$H,[int]$P,[int]$T=6000) {
  try {
    $c = New-Object Net.Sockets.TcpClient
    $ar = $c.BeginConnect($H,$P,$null,$null)
    if ($ar.AsyncWaitHandle.WaitOne($T) -and $c.Connected) { $c.EndConnect($ar); $c.Close(); return $true }
    $c.Close(); return $false
  } catch { return $false }
}

# Расшифровка ошибки ssh в краткое человеческое сообщение.
function Get-SshErrorText([string]$Raw,[bool]$AuthFailed) {
  $r = $Raw.ToLower()
  if ($r -match 'connection refused')   { return "нет доступа к конечному хосту $($script:RemoteTarget): порт $($script:RemotePort) закрыт (SSH-сервер не запущен)" }
  if ($r -match 'timed out|timeout')    { return "нет доступа к $($script:RemoteTarget): таймаут порта $($script:RemotePort) (ПК выключен или блокирует брандмауэр)" }
  if ($r -match 'no route to host|host is down') { return "нет маршрута до хоста $($script:RemoteTarget) (ПК выключен или недоступен в сети)" }
  if ($r -match 'could not resolve|not known')   { return "не удалось разрешить имя хоста из '$($script:RemoteTarget)' (проверьте ip/hostname)" }
  if ($r -match 'network is unreachable')        { return "сеть недоступна с этого ПК (хост $($script:RemoteTarget))" }
  if ($r -match 'host key verification failed|identification has changed') { return "ключ хоста $($script:RemoteTarget) изменился или не подтверждён (проверьте, что на целевом ПК OpenSSH-сервер переустановлен)" }
  if ($AuthFailed)                                { return "неправильный логин или пароль от $($script:RemoteTarget)" }
  $m=$Raw.Trim(); if(-not $m){$m='неизвестная причина'}
  return "ошибка подключения к $($script:RemoteTarget): $m"
}

function Invoke-SshKey([string]$Cmd) {

  $a = @('-o','BatchMode=yes','-o','StrictHostKeyChecking=accept-new','-o','LogLevel=ERROR',

         '-o','ConnectTimeout=10','-p',"$($script:RemotePort)","$($script:RemoteTarget)",$Cmd)

  $prevEAP=$ErrorActionPreference; $ErrorActionPreference='SilentlyContinue'

  $out = & ssh.exe @a 2>&1

  $ErrorActionPreference=$prevEAP

  $script:SshErr = (($out | Where-Object { $_ -is [Management.Automation.ErrorRecord] }) | ForEach-Object { $_.ToString() }) -join ' '

  $out | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] }

}

function Invoke-SshPass([string]$Cmd) {

  $ap = New-AskPass

  $env:SSH_ASKPASS = $ap

  $env:SSH_ASKPASS_REQUIRE = 'force'

  $env:PCR_PW = $script:RemotePass

  # Временный known_hosts: Windows OpenSSH сервер при первом подключении меняет
  # host key — постоянный known_hosts даёт "REMOTE HOST IDENTIFICATION HAS CHANGED"
  # и вход ошибочно выглядит как неверный пароль.
  $kh = Join-Path $env:TEMP ("pcr_kh_" + [guid]::NewGuid().ToString('N').Substring(0,8))

  try {

    $a = @('-o','StrictHostKeyChecking=accept-new',"-o",'UserKnownHostsFile='+$kh,'-o','LogLevel=ERROR',

           '-o','ConnectTimeout=10','-p',"$($script:RemotePort)","$($script:RemoteTarget)",$Cmd)

    $prevEAP=$ErrorActionPreference; $ErrorActionPreference='SilentlyContinue'

    $out = & ssh.exe @a 2>&1

    $ErrorActionPreference=$prevEAP

    $script:SshErr = (($out | Where-Object { $_ -is [Management.Automation.ErrorRecord] }) | ForEach-Object { $_.ToString() }) -join ' '

    $out | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] }

  } finally {

    Remove-Item $ap -Force -ErrorAction SilentlyContinue

    Remove-Item Env:\SSH_ASKPASS -ErrorAction SilentlyContinue

    Remove-Item Env:\SSH_ASKPASS_REQUIRE -ErrorAction SilentlyContinue

    Remove-Item Env:\PCR_PW -ErrorAction SilentlyContinue

    Remove-Item $kh -Force -ErrorAction SilentlyContinue

  }

}

function Invoke-Ssh([string]$Cmd) {

  if ($script:AuthMode -eq 'key') { Invoke-SshKey $Cmd } else { Invoke-SshPass $Cmd }

}

function Test-RemoteAuth([string]$Password) {

  $script:AuthMode = ''

  $script:SshErr = ''

  # Сетевая диагностика до попыток входа

  $rt = "$($script:RemoteTarget)"
  $rh = $rt.Substring($rt.LastIndexOf('@')+1)

  if (-not (Test-PortOpen $rh ([int]$script:RemotePort))) {

    Say "ПРОПУСК: нет доступа к конечному хосту $rh (порт $($script:RemotePort) закрыт или не отвечает — ПК выключен, SSH-сервер не запущен или брандмауэр)"

    return $false

  }

  # Windows-логин с кириллицей/пробелами (например "МТСNETWORK1\Администратор")
  # в bash-совместимых шеллах (Git Bash/Cygwin на OpenSSH-сервере) ломает разбор
  # user@host — ключевой режим там сразу даёт синтаксическую ошибку. Пробуем его
  # только если логин ASCII и без спецсимволов; иначе — сразу парольный режим.
  $rt2 = "$($script:RemoteTarget)"
  $u = $rt2.Substring(0,$rt2.LastIndexOf('@'))
  if ($u -match '^[\x21-\x7E]+$' -and $u -notmatch '[!"#$%&()*+,:;<=>?@\[\]^`{|}~ ]') {
    if (((Invoke-SshKey 'echo OK') | Out-String).Trim() -eq 'OK') { $script:AuthMode='key'; return $true }
  }

  $p = $Password

  if (-not $p) { $p = $env:PC_PASS }

  if (-not $p) {

    $secure = Read-Host "Пароль пользователя $($script:RemoteTarget)" -AsSecureString

    $p = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))

  }

  if (-not $p) { Say "ПРОПУСК: нет пароля для $script:RemoteTarget"; return $false }

  # Интерактивно даём 3 попытки ввода пароля; для режимов с PC_PASS/файлом — 1.
  $tries = if ($Password -or $env:PC_PASS) { 1 } else { 3 }
  for ($t=1; $t -le $tries; $t++) {
    $script:RemotePass = $p
    if (((Invoke-SshPass 'echo OK') | Out-String).Trim() -eq 'OK') { $script:AuthMode='pass'; return $true }
    if ($t -lt $tries) {
      Write-Host '[pc_report] неверный пароль, осталось попыток: $($tries-$t)' -ForegroundColor Yellow
      $secure = Read-Host "Пароль пользователя $($script:RemoteTarget) (повторно)" -AsSecureString
      $p = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
      if (-not $p) { break }
    }
  }
  Say ("ПРОПУСК: " + (Get-SshErrorText ([string]$script:SshErr) $true))
  $script:RemotePass = ''
  return $false

}

function ConvertFrom-KvTsv([string[]]$Lines) {

  $h = @{}

  foreach ($l in $Lines) {

    if ($l.Contains("`t")) { $p = $l.Split("`t", 2); if (-not $h.ContainsKey($p[0])) { $h[$p[0]] = $p[1].Trim() } }

  }

  return $h

}

function Get-LinuxCollectorSh {

  return @'

#!/usr/bin/env bash

emit(){ printf '\t%s\t%s\n' "$1" "${2:-}"; }

OS_NAME=$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || echo Linux)

emit HOST "$(hostname)"

emit OS_NAME "$OS_NAME"

emit OS_VER "$(uname -r)"

emit KERNEL "$(uname -r)"

emit ARCH "$(uname -m)"

B=64-bit; [[ "$(uname -m)" =~ i[3-6]86 ]] && B=32-bit

emit BITS "$B"

emit USER_NOW "$(id -un)"

emit HOME_DIR "$HOME"

V=bare-metal

grep -qa docker /proc/1/cgroup 2>/dev/null && V=Docker

command -v systemd-detect-virt >/dev/null && { x=$(systemd-detect-virt 2>/dev/null||true); [ -n "$x" ] && [ "$x" != none ] && V="$x"; }

emit ENV_TYPE "$V"

emit UPTIME "$(awk '{printf "uptime %.0f h", $1/3600}' /proc/uptime)"

CM=$(lscpu 2>/dev/null | awk -F: '/Model name/{gsub(/^ +/,"",$2);print $2;exit}')

[[ -z "$CM" ]] && CM=$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ //')

emit CPU_MODEL "$CM"

emit CPU_VENDOR "$(lscpu 2>/dev/null | awk -F: '/Vendor ID/{gsub(/^ +/,"",$2);print $2;exit}')"

NS=$(lscpu 2>/dev/null | awk -F: '/^Socket\(s\)/{gsub(/ /,"",$2);print $2}'); NC=$(lscpu 2>/dev/null | awk -F: '/^Core\(s\) per socket/{gsub(/ /,"",$2);print $2}')

emit CPU_SOCKETS "${NS:-1}"

emit CPU_CORES "$(awk -v c="${NC:-1}" -v s="${NS:-1}" 'BEGIN{print c*s}')"

emit CPU_THREADS "$(nproc)"

emit CPU_MHZ "$(awk -F: '/cpu MHz/{printf "%.0f",$2;exit}' /proc/cpuinfo)"

emit CPU_L3 "$(lscpu 2>/dev/null | awk -F: '/L3 cache/{gsub(/^ +/,"",$2);print $2;exit}')"

emit CPU_FLAGS "$(grep -m1 flags /proc/cpuinfo | cut -d: -f2 | tr -s ' ' | cut -d' ' -f2-12)"

MV=$(cat /sys/class/dmi/id/board_vendor 2>/dev/null); MP=$(cat /sys/class/dmi/id/board_name 2>/dev/null)

emit MOTHERBOARD "$MV $MP"

emit MB_VERSION "$(cat /sys/class/dmi/id/board_version 2>/dev/null)"

emit SYS_VENDOR "$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null)"

emit BIOS_VER "$(cat /sys/class/dmi/id/bios_version 2>/dev/null)"

emit BIOS_DATE "$(cat /sys/class/dmi/id/bios_date 2>/dev/null)"

TK=$(awk '/MemTotal/{print $2}' /proc/meminfo); AK=$(awk '/MemAvailable/{print $2}' /proc/meminfo)

emit RAM_TOTAL "$(awk -v k=$TK 'BEGIN{printf "%.0f GB", k/1048576}')"

emit RAM_AVAIL "$(awk -v k=$AK 'BEGIN{printf "%.1f GB", k/1048576}')"

RM=""; RC=0

if command -v dmidecode >/dev/null 2>&1; then

  RM=$(dmidecode -t memory 2>/dev/null | awk 'BEGIN{RS="\n\n+";OFS="|"} /Memory Device/ && !/No Module Installed/ {m="?";s="?";t="?";f="?";p="?"; n=split($0,L,"\n"); for(i=1;i<=n;i++){ if(L[i]~/^Manufacturer:/){sub(/^Manufacturer: */,"",L[i]);m=L[i]} if(L[i]~/^Size:/){sub(/^Size: */,"",L[i]);s=L[i]} if(L[i]~/^Type:/){sub(/^Type: */,"",L[i]);t=L[i]} if(L[i]~/Clock Speed:/&&f=="?"){sub(/.*: */,"",L[i]);f=L[i]} if(L[i]~/^Part Number:/){sub(/^Part Number: */,"",L[i]);p=L[i]} } if(s~/[0-9]+ [KMGT]?B/) print m,s,t,f,p }' | paste -sd';')

fi

[ -n "$RM" ] && RC=$(tr ';' '\n' <<<"$RM" | grep -c .)

emit RAM_MODULES "$RM"

emit RAM_COUNT "$RC"

emit RAM_SRC "dmidecode/DMI"

GN=$(lspci 2>/dev/null | grep -Ei 'VGA|3D controller|Display' | head -1 | sed -E 's/^[0-9a-f:.]+ [^:]+: //; s/ \(rev[^)]*\)//I')

emit GPU_NAME "${GN:-n/a}"

emit GPU_BUS "$(lspci 2>/dev/null | grep -Ei 'VGA|3D controller|Display' | head -1 | awk '{print $1}')"

DV="(unknown)"; BUS=$(lspci 2>/dev/null | grep -Ei 'VGA|3D controller|Display' | head -1 | awk '{print $1}')

[ -n "$BUS" ] && [ -L "/sys/bus/pci/devices/0000:$BUS/driver" ] && DV=$(basename "$(readlink -f /sys/bus/pci/devices/0000:$BUS/driver)")

emit GPU_DRV "$DV"

VR="-"

if command -v nvidia-smi >/dev/null 2>&1; then nv=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader 2>/dev/null|head -1); [ -n "$nv" ] && VR="$nv"; fi

emit GPU_VRAM "$VR"

DS=""

while IFS= read -r line; do

  src=$(awk '{print $1}' <<<"$line"); fs=$(awk '{print $2}' <<<"$line"); sz=$(awk '{print $3}' <<<"$line")

  us=$(awk '{print $4}' <<<"$line"); fr=$(awk '{print $5}' <<<"$line"); pc=$(awk '{print $6}' <<<"$line"); mt=$(awk '{print $7}' <<<"$line")

  DS+="$src|$fs|$sz|$us|$fr|$pc|$mt;"

done < <(df -hT -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null | tail -n +2)

emit DISKS "${DS%;}"

RS=$(findmnt -n -o SOURCE / 2>/dev/null || df / | awk 'NR==2{print $1}')

emit ROOT_DEV "$RS"

emit ROOT_FS "$(df -T / 2>/dev/null | awk 'NR==2{print $2}')"

emit ROOT_SIZE "$(df -h / | awk 'NR==2{print $2}')"

emit ROOT_USED "$(df -h / | awk 'NR==2{print $3}')"

emit ROOT_FREE "$(df -h / | awk 'NR==2{print $4}')"

emit ROOT_PUSE "$(df / | awk 'NR==2{print $5}')"

PD=$(lsblk -d -o NAME,SIZE,MODEL,ROTA 2>/dev/null | awk '$1!="NAME"{printf "%s (%s, %s%s); ",$1,$2,$3,(($4==1)?" HDD":" SSD/NVMe")}')

emit PHYSICAL_DISKS "${PD%; }"

IS=""

for d in /sys/class/net/*; do

  n=$(basename "$d"); [ "$n" = lo ] && continue

  mac=$(cat "$d/address" 2>/dev/null); st=$(cat "$d/operstate" 2>/dev/null)

  ips=$(ip -o -4 addr show dev "$n" 2>/dev/null | awk '{split($4,a,"/");printf "%s, ",a[1]}')

  gw=$(ip route show default dev "$n" 2>/dev/null | awk '{print $3;exit}')

  IS+="$n|${st^^}|${ips%, }|$mac|${gw:--}|DHCP?|-;"

done

emit IFACES "${IS%;}"

emit DNS "$(awk '/^nameserver/{printf "%s, ",$2}' /etc/resolv.conf 2>/dev/null | sed 's/, $//')"

emit USERS_LOGIN "$(awk -F: '$3>=1000&&$3<65534{printf "%s, ",$1}' /etc/passwd | sed 's/, $//')"

emit USERS_ALL_N "$(awk -F: '$3>=1000&&$3<65534' /etc/passwd | wc -l)"

emit USERS_ONLINE "$(who 2>/dev/null | awk '{print $1}' | sort -u | wc -l)"

emit DATE_NOW "$(date '+%d.%m.%Y %H:%M')"

'@

}

function Get-WinCollectorScript {

  return @'

$ErrorActionPreference='Continue'

$OutputEncoding=[Console]::OutputEncoding=[Text.Encoding]::UTF8

function E($v){if($null -eq $v){''}else{([string]$v).Trim().Replace("`r"," ").Replace("`n"," ")}}

function emit($k,$v){Write-Host ("`t"+$k+"`t"+(E $v))}

function GB($b){if($b -gt 0){('{0:N1} GB' -f ($b/1GB))}else{'n/a'}}

$os=Get-CimInstance Win32_OperatingSystem

$cs=Get-CimInstance Win32_ComputerSystem

emit HOST $cs.Name

emit OS_NAME $os.Caption

emit OS_VER ("{0} (build {1})" -f $os.Version,$os.BuildNumber)

emit KERNEL $os.Version

$arch=E $env:PROCESSOR_ARCHITECTURE; if(-not $arch){$arch=E $os.OSArchitecture}

emit ARCH $arch

emit BITS (if("$arch" -match '64'){'64-bit'}elseif("$arch" -match '86|32'){'32-bit'}else{'n/a'})

emit USER_NOW ("{0}\{1}" -f $env:USERDOMAIN,$env:USERNAME)

emit HOME_DIR $env:USERPROFILE

emit ENV_TYPE 'physical/virtual (see manufacturer)'

$up=((Get-Date)-$os.LastBootUpTime); emit UPTIME ('uptime {0} d {1} h {2} min' -f $up.Days,$up.Hours,$up.Minutes)

$cpus=@(Get-CimInstance Win32_Processor); $cpu=$cpus[0]

emit CPU_MODEL $cpu.Name

emit CPU_VENDOR $cpu.Manufacturer

emit CPU_SOCKETS $cpus.Count

emit CPU_CORES (($cpus|Measure-Object -Property NumberOfCores -Sum).Sum)

emit CPU_THREADS (($cpus|Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum)

emit CPU_MHZ $cpu.CurrentClockSpeed

$L2=($cpus|Measure-Object -Property L2CacheSize -Sum).Sum

$L3=($cpus|Measure-Object -Property L3CacheSize -Sum).Sum

emit CPU_L3 "$(if($L3){[math]::Round($L3/1MB,1)}elseif($L2){[math]::Round($L2/1MB,1)}else{0}) MB"

emit CPU_FLAGS (E $cpu.SecondLevelAddressTranslationExtensions)

$mb=Get-CimInstance Win32_BaseBoard

emit MOTHERBOARD ("{0} {1}" -f $mb.Manufacturer,$mb.Product)

emit MB_VERSION $mb.Version

emit SYS_VENDOR $cs.Manufacturer

$bios=Get-CimInstance Win32_BIOS

emit BIOS_VER $bios.SMBIOSBIOSVersion

emit BIOS_DATE $(try{$bios.ReleaseDate.ToString('dd.MM.yyyy')}catch{'n/a'})

$mods=@(Get-CimInstance Win32_PhysicalMemory)

$total=($mods|Measure-Object -Property Capacity -Sum).Sum

if(-not $total){$total=$cs.TotalPhysicalMemory}

emit RAM_TOTAL (GB $total)

emit RAM_AVAIL (GB ($os.FreePhysicalMemory*1KB))

$rs=''

foreach($m in $mods){

 $rs+=("{0}|{1}|{2}|{3}|{4};" -f (E $m.Manufacturer),(GB $m.Capacity),(E $m.SMBIOSMemoryType),"$($m.Speed) MHz",(E $m.PartNumber))

}

emit RAM_MODULES ($rs.TrimEnd(';'))

emit RAM_COUNT (@($mods).Count)

emit RAM_SRC 'WMI Win32_PhysicalMemory'

$g=@(Get-CimInstance Win32_VideoController)

if($g.Count -gt 0){

 $vg=[math]::Round($g[0].AdapterRAM/1GB,2)

 emit GPU_NAME $g[0].Name

 emit GPU_BUS (E $g[0].PNPDeviceID)

 emit GPU_DRV $g[0].DriverVersion

 emit GPU_VRAM $(if($vg -gt 0){"$vg GB"}else{'shared'})

}else{emit GPU_NAME 'n/a';emit GPU_BUS '';emit GPU_DRV '';emit GPU_VRAM 'n/a'}

$d=@(Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3")

$ds=''

foreach($v in $d){

 $u=if($v.Size -gt 0){[math]::Round((($v.Size-$v.FreeSpace)/$v.Size)*100)}else{0}

 $ds+=("{0}|{1}|{2}|{3}|{4}|{5}%|{6} ({7});" -f $v.DeviceID,$v.FileSystem,(GB $v.Size),(GB ($v.Size-$v.FreeSpace)),(GB $v.FreeSpace),$u,$v.DeviceID,(E $v.VolumeName))

}

emit DISKS ($ds.TrimEnd(';'))

$sysdrive=($env:SystemRoot).Substring(0,2)+'\'

$root=$d | Where-Object {$_.DeviceID -eq $sysdrive} | Select-Object -First 1

if($root){

 emit ROOT_DEV $root.DeviceID; emit ROOT_FS $root.FileSystem

 emit ROOT_SIZE (GB $root.Size); emit ROOT_USED (GB ($root.Size-$root.FreeSpace))

 emit ROOT_FREE (GB $root.FreeSpace)

 emit ROOT_PUSE "$([math]::Round((($root.Size-$root.FreeSpace)/$root.Size)*100))%"

}else{emit ROOT_DEV 'n/a';emit ROOT_FS '';emit ROOT_SIZE '';emit ROOT_USED '';emit ROOT_FREE '';emit ROOT_PUSE '0%'}

$pd=@(Get-CimInstance Win32_DiskDrive)

$ps=''

foreach($x in $pd){$ps+=("{0} ({1}, {2}, {3});" -f (E $x.Model),(GB $x.Size),(E $x.InterfaceType),(E $x.MediaType))}

emit PHYSICAL_DISKS ($ps.TrimEnd(';'))

$ni=@(Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "IPEnabled=True")

$is=''

foreach($n in $ni){

 $mode=if($n.DHCPEnabled){'DHCP'}else{'STATIC'}

 $ip=if($n.IPAddress){(($n.IPAddress | Where-Object {$_ -match '^\d+\.'}) -join ',')}else{''}

 $gw=if($n.DefaultIPGateway){$n.DefaultIPGateway[0]}else{''}

 $dn=if($n.DNSServerSearchOrder){$n.DNSServerSearchOrder -join ','}else{''}

 $is+=("{0}|UP|{1}|{2}|{3}|{4}|{5};" -f (E $n.Description),$ip,(E $n.MACAddress),$gw,$mode,$dn)

}

emit IFACES ($is.TrimEnd(';'))

$dnall=if($ni -and $ni[0].DNSServerSearchOrder){$ni[0].DNSServerSearchOrder -join ', '}else{'n/a'}

emit DNS $dnall

$lu=@(Get-CimInstance Win32_UserAccount -Filter "LocalAccount=True" | Where-Object {$_.SIDType -eq 1 -and $_.Name -notmatch '^(Guest|DefaultAccount|WDAGUtilityAccount)$'})

emit USERS_LOGIN (($lu | ForEach-Object {$_.Name}) -join ', ')

emit USERS_ALL_N $lu.Count

emit USERS_ONLINE (@(Get-CimInstance Win32_LogonSession -ErrorAction SilentlyContinue | Where-Object {$_.LogonType -eq 2 -or $_.LogonType -eq 10}).Count)

emit DATE_NOW (Get-Date -Format 'dd.MM.yyyy HH:mm')

'@

}

function Run-RemoteHost([string]$Spec, [string]$Port, [string]$Password) {

  $user=''; $host_=$Spec

  if ($Spec.Contains('@')) { $user=$Spec.Substring(0,$Spec.LastIndexOf('@')); $host_=$Spec.Substring($Spec.LastIndexOf('@')+1) }

  $pt=22

  if ($Port) { $pt=[int]$Port }

  elseif ($host_.Contains(':')) { $pt=[int]$host_.Split(':')[1]; $host_=$host_.Split(':')[0] }

  if (-not $user) { $user = [Environment]::UserName }

  $script:RemoteTarget = "$user@$host_"

  $script:RemotePort = $pt

  Say "Подключение к $script:RemoteTarget (порт $pt)..."

  if (-not (Test-RemoteAuth $Password)) { return $null }

  # Определение удалённой ОС. На OpenSSH-сервере Windows команда 'uname -s'
  # не существует в cmd.exe, поэтому выводимый текст может быть на локальной
  # кодировке (кириллица) — сравниваем только ASCII-маркеры.
  $raw = (((Invoke-Ssh 'uname -s 2>/dev/null || ver') | Out-String) -replace '[^A-Za-z0-9.\- ]','').Trim()
  $low = $raw.ToLower()
  $isLinux = ($low -match '^linux') -or ($low.Contains(' linux'))
  $isWin   = $low.StartsWith('microsoft windows') -or ($low -match 'mingw|msys|cygwin') -or ($raw -match '\d+\.\d{3,}\.\d+')
  $kv = $null

  if ($isLinux) {

    Say "ОШИБКА: конечный ПК $script:RemoteTarget использует Linux-дистрибутив."

    Say "Для сбора с Linux используйте скрипт pc_report.sh — он работает и с Linux, и с Windows хостами:"

    Say "  ./pc_report.sh -r \"$user\"@$($script:RemoteTarget.Substring($script:RemoteTarget.LastIndexOf('@')+1)):$pt"

    return $null

  } elseif ($isWin) {

    Say "Удалённая ОС: Windows (OpenSSH). Сбор через PowerShell..."

    $ps = Get-WinCollectorScript

    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($ps))

    # Распаковка сборщика на хосте через -EncodedCommand (UTF-16LE base64):
    # без вложенных кавычек — одинаково надёжно для cmd.exe и PowerShell шелла.
    $inner = "[IO.File]::WriteAllBytes((Join-Path `$env:TEMP 'pcr_win.ps1'),[Convert]::FromBase64String('" + $b64 + "'))"
    $enc   = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($inner))
    $null  = Invoke-Ssh "powershell.exe -NonInteractive -NoProfile -ExecutionPolicy Bypass -EncodedCommand $enc"
    $cmd2 = "powershell.exe -NonInteractive -NoProfile -ExecutionPolicy Bypass -File %TEMP%\\pcr_win.ps1"

    $out = Invoke-Ssh $cmd2

    # Если PowerShell-коллектор не дал KV-строк — вероятно, удалённый шелл это
    # cmd.exe и powershell.exe не запустился напрямую. Пробуем резервный путь:
    # явный запуск через cmd /c (часто помогает при нестандартном default shell).
    $kv = ConvertFrom-KvTsv ((($out | Out-String) -split "`r?`n"))

    if (-not $kv -or -not $kv.ContainsKey('HOST')) {

      Say "Прямой запуск collect.ps1 не дал данных — пробую через cmd /c..."

      $out2 = Invoke-Ssh "cmd /c powershell.exe -NoProfile -ExecutionPolicy Bypass -File %TEMP%\pcr_win.ps1"

      $kv2 = ConvertFrom-KvTsv ((($out2 | Out-String) -split "`r?`n"))

      if ($kv2 -and $kv2.ContainsKey('HOST')) { $kv = $kv2 }

    }

  } else {

    Say "ПРОПУСК: нераспознанная удалённая ОС '$raw' на $script:RemoteTarget (ожидался Windows-хост с OpenSSH)"; return $null

  }

  Invoke-Ssh "del %TEMP%\pcr_win.ps1 2>nul" | Out-Null

  if (-not $kv -or -not $kv.ContainsKey('HOST')) { Say "ПРОПУСК: удалённый сбор на $($script:RemoteTarget) не дал данных (проверьте, что powershell.exe доступен для входа по SSH)"; return $null }

  $kv['__SPEC'] = "$user@$($script:RemoteTarget.Substring($script:RemoteTarget.LastIndexOf('@')+1)):$pt"

  return $kv

}



# ---------- выбор режима: локальный или удалённый (-r) ----------

$RemoteSpec = if ($Remote) { $Remote } else { "" }

if ($RemoteSpec) {

  Say "Удалённый режим (-r). Отчёты сохраняются в папке запуска: $(Get-Location)"

  $KvsList = @()

  if (Test-Path $RemoteSpec -PathType Leaf) {

    # ----- файл-список: user ; ip/hostname ; password ; port -----

    Say "Массовый опрос по списку: $RemoteSpec"

    $ln = 0

    foreach ($line in (Get-Content $RemoteSpec -Encoding UTF8)) {

      $ln++

      $t = "$line".Trim()

      if (-not $t -or $t.StartsWith('#')) { continue }

      $c = $t -split ';'

      $cu = ("{0}" -f $c[0]).Trim(); $ch = ("{0}" -f $c[1]).Trim()

      $cp = if ($c.Count -gt 2) { ("{0}" -f $c[2]).Trim() } else { "" }

      $cpt = if ($c.Count -gt 3 -and ("{0}" -f $c[3]).Trim()) { ("{0}" -f $c[3]).Trim() } else { "22" }

      if (-not $cu -or -not $ch) { Say "Строка ${ln}: пропуск (нужны user и ip/hostname)"; continue }

      Say "───────── [$ln] $cu@$ch`:$cpt"

      $kv = Run-RemoteHost "$cu@$ch" $cpt $cp

      if ($kv) { $KvsList += ,$kv }

    }

  } else {

    # одиночный хост: user@ip[:порт]; пароль — из PC_PASS или интерактивно

    $kv = Run-RemoteHost $RemoteSpec "" ""

    if ($kv) { $KvsList += ,$kv } else { exit 2 }

  }

  if ($KvsList.Count -eq 0) { Say "Отчёты не созданы: ни один хост не доступен."; exit 2 }

  function Get-K([hashtable]$h, [string]$k) { if ($h.ContainsKey($k)) { "$($h[$k])" } else { '' } }

  $okN = 0

  foreach ($h in $KvsList) {

    $HostName   = Get-K $h 'HOST'

    $OSName     = Get-K $h 'OS_NAME'

    $OSVer      = Get-K $h 'OS_VER'

    $Arch       = Get-K $h 'ARCH'

    $Bits       = Get-K $h 'BITS'

    $userNow    = Get-K $h 'USER_NOW'

    $DateNow    = Get-K $h 'DATE_NOW'

    $Uptime     = Get-K $h 'UPTIME'

    $SysVendor  = Get-K $h 'SYS_VENDOR'

    $Virt       = Get-K $h 'ENV_TYPE'

    $CpuModel   = Get-K $h 'CPU_MODEL';  $CpuVendor = Get-K $h 'CPU_VENDOR'

    $CpuCores   = Get-K $h 'CPU_CORES';  $CpuThreads = Get-K $h 'CPU_THREADS'

    $CpuMhz     = Get-K $h 'CPU_MHZ';    $SockCount = Get-K $h 'CPU_SOCKETS'

    $CpuCache   = Get-K $h 'CPU_L3'

    $Motherboard= Get-K $h 'MOTHERBOARD'; $MbVersion = Get-K $h 'MB_VERSION'

    $BiosVer    = Get-K $h 'BIOS_VER';   $BiosDate = Get-K $h 'BIOS_DATE'

    $RamTotal   = Get-K $h 'RAM_TOTAL';  $RamAvail = Get-K $h 'RAM_AVAIL'

    $RamCount   = Get-K $h 'RAM_COUNT';  $RamSrc   = Get-K $h 'RAM_SRC'

    $GpuName    = Get-K $h 'GPU_NAME';   $GpuBus   = Get-K $h 'GPU_BUS'

    $GpuDrv     = Get-K $h 'GPU_DRV';    $GpuVram  = Get-K $h 'GPU_VRAM'

    $RootDev    = Get-K $h 'ROOT_DEV';   $RootFs   = Get-K $h 'ROOT_FS'

    $RootSize   = Get-K $h 'ROOT_SIZE';  $RootUsed = Get-K $h 'ROOT_USED'

    $RootFree   = Get-K $h 'ROOT_FREE';  $RootPuse = Get-K $h 'ROOT_PUSE'

    $DisksStr   = Get-K $h 'DISKS'

    $PhysDisks  = Get-K $h 'PHYSICAL_DISKS'

    $IfacesStr  = Get-K $h 'IFACES';     $DnsStr   = Get-K $h 'DNS'

    $UsersLogin = Get-K $h 'USERS_LOGIN'; $UsersN  = Get-K $h 'USERS_ALL_N'

    $OnlineN    = Get-K $h 'USERS_ONLINE'

    $RemoteTag  = "удалённый сбор по SSH · $(Get-K $h '__SPEC')"

    # ---- модули RAM: mfr|size|type|freq|part ----

    $ramRows = @(); $i = 0

    foreach ($m in (Get-K $h 'RAM_MODULES') -split ';') {

      if (-not "$m".Trim()) { continue }

      $i++; $p = $m -split '\|'

      $ramRows += "<tr><td>#$i</td><td>$(Esc ("{0}" -f $p[0]))</td><td>$(Esc ("{0}" -f $p[4]))</td><td>$(Esc ("{0}" -f $p[1]))</td><td>$(Esc ("{0}" -f $p[2])) · $(Esc ("{0}" -f $p[3]))</td></tr>"

    }

    if ($ramRows.Count -eq 0) { $ramRows = @('<tr><td colspan="5">Данные о модулях недоступны (нет SMBIOS-информации)</td></tr>') }

    # ---- видеокарта ----

    $gpuCards = @( @"

 <div class="card"><h3>$(Esc $GpuName) <span class="tag">$DASH</span></h3><table>

 <tr><th>Полное наименование</th><td>$(Esc $GpuName)</td></tr>

 <tr><th>Идентификатор шины</th><td>$(Esc $GpuBus)</td></tr>

 <tr><th>Драйвер</th><td>$(Esc $GpuDrv)</td></tr>

 <tr><th>Видеопамять</th><td>$(Esc $GpuVram)</td></tr>

 </table></div>

"@ )

    $gpuMain = $GpuName; $gpuMainVram = $GpuVram

    # ---- тома: dev|fs|size|used|free|pct|mount ----

    $volCards = @(); $volCount = 0

    foreach ($d in $DisksStr -split ';') {

      if (-not "$d".Trim()) { continue }

      $volCount++; $p = $d -split '\|'

      $upRaw = "{0}" -f $p[5]; $upNum = 0

      if ($upRaw -match '\d+') { $upNum = [int]$Matches[0] }

      $cls = if ($upNum -gt 85) { 'crit' } elseif ($upNum -gt 65) { 'warn' } else { 'ok' }

      $volCards += @"

 <div class="card"><h3>$(Esc ("{0}" -f $p[6])) <span class="tag">$(Esc ("{0}" -f $p[0])) · $(Esc ("{0}" -f $p[1]))</span></h3><table>

 <tr><th>Общий объём</th><td>$(Esc ("{0}" -f $p[2]))</td></tr>

 <tr><th>Занято</th><td>$(Esc ("{0}" -f $p[3])) ($upNum%)</td></tr>

 <tr><th>Свободно</th><td>$(Esc ("{0}" -f $p[4]))</td></tr>

 </table><div class="bar"><div class="$cls" style="width:${upNum}%"></div></div></div>

"@

    }

    if ($volCards.Count -eq 0) { $volCards = @('<div class="card"><h3>Тома</h3><p class="dim">Локальные тома не обнаружены</p></div>') }

    # ---- физические диски ----

    $prows = @()

    foreach ($x in $PhysDisks -split ';') {

      if (-not "$x".Trim()) { continue }

      $prows += "<tr><td>$(Esc ("$x".Trim()))</td></tr>"

    }

    # ---- сеть: name|status|ips|mac|gw|mode|dns ----

    $nicCards = @()

    foreach ($n in $IfacesStr -split ';') {

      if (-not "$n".Trim()) { continue }

      $p = $n -split '\|'

      $st = "{0}" -f $p[1]

      $sc = if ("$st".ToUpper() -match 'UP') { 'green' } else { 'gray' }

      $md = "{0}" -f $p[5]

      $mc = if ("$md".ToUpper() -eq 'DHCP') { 'green' } else { 'amber' }

      $nicCards += @"

 <div class="card"><h3>$(Esc ("{0}" -f $p[0])) <span class="pill $sc">$(Esc $st)</span> <span class="pill $mc">$(Esc $md)</span></h3><table>

 <tr><th>MAC-адрес</th><td>$(Esc ("{0}" -f $p[3]))</td></tr>

 <tr><th>IPv4</th><td>$(Esc ("{0}" -f $p[2]))</td></tr>

 <tr><th>Шлюз по умолчанию</th><td>$(Esc ("{0}" -f $p[4]))</td></tr>

 <tr><th>DNS</th><td>$(Esc ("{0}" -f $p[6]))</td></tr>

 </table></div>

"@

    }

    if ($nicCards.Count -eq 0) { $nicCards = @('<div class="card"><h3>Сеть</h3><p class="dim">Активные интерфейсы не обнаружены</p></div>') }

    # ---- пользователи ----

    $userPills = @()

    foreach ($u in ($UsersLogin -split ',\s*')) { if ("$u".Trim()) { $userPills += '<span class="pill blue">' + (Esc "$u".Trim()) + '</span>' } }

    $allUsers = ($userPills -join '')

    $RamTotalGb = $RamTotal

    $RamFreeGb  = $RamAvail

    $ts = Get-Date -Format 'yyyyMMdd_HHmmss'

    $safeHost = ($HostName -replace '[^\w\-]','_')

    $OutputFile = if ($Output -and $KvsList.Count -eq 1) { $Output } else { "PC_Report_${safeHost}_${ts}.html" }

    $ModeLine = " <span>РЕЖИМ: <b>$RemoteTag</b></span>"

    $os = @{ LastBootUpTime = (Get-Date).AddSeconds(-1 * ([double](("{0}" -f $Uptime) -replace '[^\d.]','0' + '0'))) }

    $html = $LocalTemplate

    Set-Content -Path $OutputFile -Value $html -Encoding UTF8

    $okN++

    Say "✅ Отчёт создан: $OutputFile"

  }

  Say "Итог: отчётов создано — $okN из $($KvsList.Count)."

  exit 0

}

Say "Сбор сведений о системе..."



# ---------- ОС ----------

$os    = Get-CimInstance Win32_OperatingSystem

$cs    = Get-CimInstance Win32_ComputerSystem

$biosC = Get-CimInstance Win32_BIOS

$OSName   = "$($os.Caption)".Trim()

$OSVer    = "$($os.Version) (сборка $($os.BuildNumber))"

$Arch     = if ($env:PROCESSOR_ARCHITECTURE) { $env:PROCESSOR_ARCHITECTURE } else { $os.OSArchitecture }

$Bits     = if ("$Arch" -match '64') { '64-битная' } elseif ("$Arch" -match '86|32') { '32-битная' } else { $DASH }

$HostName = $cs.Name

$DateNow  = Get-Date -Format 'dd.MM.yyyy HH:mm'

$UpSec    = [math]::Floor(((Get-Date) - $os.LastBootUpTime).TotalSeconds)

$Uptime   = "{0} дн. {1} ч. {2} мин." -f [math]::Floor($UpSec/86400), [math]::Floor(($UpSec%86400)/3600), [math]::Floor(($UpSec%3600)/60)



# ---------- Процессор ----------

$cpus  = @(Get-CimInstance Win32_Processor)

$cpu   = $cpus[0]

$CpuModel   = "$($cpu.Name)".Trim()

$CpuVendor  = $cpu.Manufacturer

$CpuCores   = ($cpus | Measure-Object -Property NumberOfCores -Sum).Sum

$CpuThreads = ($cpus | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum

$CpuMhz     = $cpu.CurrentClockSpeed

$SockCount  = $cpus.Count



# ---------- Материнская плата / BIOS ----------

$mb = Get-CimInstance Win32_BaseBoard

$Motherboard = "$($mb.Manufacturer) $($mb.Product)".Trim()

$MbVersion   = $mb.Version

$SysVendor   = $cs.Manufacturer

$BiosVer     = $biosC.SMBIOSBIOSVersion

$BiosDate    = if ($biosC.ReleaseDate) { $biosC.ReleaseDate.ToString('dd.MM.yyyy') } else { $DASH }



# ---------- Оперативная память: каждый модуль ----------

$ramMods = @(Get-CimInstance Win32_PhysicalMemory)

$RamTotalGb = [math]::Round(($ramMods | Measure-Object -Property Capacity -Sum).Sum / 1GB, 0)

if ($RamTotalGb -eq 0) { $RamTotalGb = [math]::Round($cs.TotalPhysicalMemory / 1GB, 0) }

$RamFreeGb  = [math]::Round($os.FreePhysicalMemory / 1MB, 1)

$RamCount   = $ramMods.Count

$ramRows = @(); $i = 0

foreach ($m in $ramMods) {

  $i++

  $typeMap = @{20='DDR';21='DDR2';22='DDR3';24='DDR3';26='DDR4';34='DDR4';35='DDR5'}

  $mt = [int]$m.SMBIOSMemoryType

  $typeName = if ($typeMap.ContainsKey($mt)) { $typeMap[$mt] } else { "$($m.MemoryType)" }

  $freq = if ($m.ConfiguredClockSpeed -gt 0) { "$($m.ConfiguredClockSpeed) МГц" } else { "$($m.Speed) МГц" }

  $ramRows += "<tr><td>#$i</td><td>$(Esc $m.Manufacturer)</td><td>$(Esc ("$($m.PartNumber)").Trim())</td><td>$(GB $m.Capacity)</td><td>$typeName · $freq</td></tr>"

}

if ($ramRows.Count -eq 0) { $ramRows = @('<tr><td colspan="5">Данные о модулях недоступны (нет SMBIOS-информации)</td></tr>') }



# ---------- Видеокарты ----------

$gpus = @(Get-CimInstance Win32_VideoController)

$gpuCards = @()

foreach ($g in $gpus) {

  $vramGb = [math]::Round(($g.AdapterRAM / 1GB), 2)

  if ($vramGb -le 0) { $vramTxt = "$DASH (разделяемая)" } else { $vramTxt = "$vramGb ГБ" }

  $gpuCards += @"

 <div class="card"><h3>$(Esc $g.Name) <span class="tag">$vramTxt</span></h3><table>

 <tr><th>Полное наименование</th><td>$(Esc $g.Name)</td></tr>

 <tr><th>Видеопамять</th><td>$vramTxt</td></tr>

 <tr><th>Графический процессор</th><td>$(Esc $g.VideoProcessor)</td></tr>

 <tr><th>Драйвер</th><td>$(Esc $g.DriverVersion)</td></tr>

 <tr><th>Разрешение (текущее)</th><td>$(Esc "$($g.CurrentHorizontalResolution)x$($g.CurrentVerticalResolution)") @ $($g.CurrentRefreshRate) Гц</td></tr>

 <tr><th>Интерфейс</th><td>$(Esc $g.InterfaceType)</td></tr>

 <tr><th>Статус</th><td><span class="pill $(if($g.Status -eq 'OK'){'green'}else{'amber'})">$(Esc $g.Status)</span></td></tr>

 </table></div>

"@

}

if ($gpuCards.Count -eq 0) { $gpuCards = @('<div class="card"><h3>Видеоадаптер</h3><p class="dim">Не обнаружен</p></div>') }

$gpuMain = if ($gpus.Count -gt 0) { $gpus[0].Name } else { $DASH }

$gpuMainVram = if ($gpus.Count -gt 0 -and $gpus[0].AdapterRAM -gt 0) { "$([math]::Round($gpus[0].AdapterRAM/1GB,1)) ГБ" } else { $DASH }



# ---------- Логические тома (диски) ----------

$vols = @(Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3")

$volCards = @()

foreach ($v in $vols) {

  $usedP = if ($v.Size -gt 0) { [math]::Round((($v.Size - $v.FreeSpace) / $v.Size) * 100, 0) } else { 0 }

  $cls = if ($usedP -gt 85) { 'crit' } elseif ($usedP -gt 65) { 'warn' } else { 'ok' }

  $label = if ($v.VolumeName) { $v.VolumeName } else { $DASH }

  $volCards += @"

 <div class="card"><h3>$($v.DeviceID) <span class="tag">$(Esc $v.FileSystem)</span></h3><table>

 <tr><th>Название тома</th><td>$(Esc $label)</td></tr>

 <tr><th>Общий объём</th><td>$(GB $v.Size)</td></tr>

 <tr><th>Занято</th><td>$(GB ($v.Size - $v.FreeSpace)) ($usedP%)</td></tr>

 <tr><th>Свободно</th><td>$(GB $v.FreeSpace)</td></tr>

 </table><div class="bar"><div class="$cls" style="width:${usedP}%"></div></div></div>

"@

}

if ($volCards.Count -eq 0) { $volCards = @('<div class="card"><h3>Тома</h3><p class="dim">Локальные тома не обнаружены</p></div>') }



# Физические диски

$pdisks = @(Get-CimInstance Win32_DiskDrive)

$prows = foreach ($d in $pdisks) {

  $ityp = if ("$($d.InterfaceType)") { $d.InterfaceType } else { $DASH }

  "<tr><td>$(Esc $d.DeviceID)</td><td>$(Esc ("$($d.Model)").Trim())</td><td>$(GB $d.Size)</td><td>$ityp</td></tr>"

}

if (-not $prows) { $prows = @('<tr><td colspan="4">`u{2014}</td></tr>') }



# ---------- Сеть ----------

$nics = @(Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "IPEnabled=True")

$nicCards = @()

foreach ($n in $nics) {

  $mode = if ($n.DHCPEnabled) { '<span class="pill green">DHCP</span>' } else { '<span class="pill amber">STATIC</span>' }

  $ip   = if ($n.IPAddress) { $n.IPAddress -join ', ' } else { $DASH }

  $mask = if ($n.IPSubnet)  { $n.IPSubnet -join ', ' } else { $DASH }

  $gw   = if ($n.DefaultIPGateway) { $n.DefaultIPGateway -join ', ' } else { $DASH }

  $dns  = if ($n.DNSServerSearchOrder) { $n.DNSServerSearchOrder -join ', ' } else { $DASH }

  $mac  = $n.MACAddress

  $desc = $n.Description

  $nicCards += @"

 <div class="card"><h3>$(Esc $desc) $mode</h3><table>

 <tr><th>MAC-адрес</th><td>$(Esc $mac)</td></tr>

 <tr><th>IPv4</th><td>$(Esc $ip)</td></tr>

 <tr><th>Маска подсети</th><td>$(Esc $mask)</td></tr>

 <tr><th>Шлюз по умолчанию</th><td>$(Esc $gw)</td></tr>

 <tr><th>DNS</th><td>$(Esc $dns)</td></tr>

 </table></div>

"@

}

if ($nicCards.Count -eq 0) { $nicCards = @('<div class="card"><h3>Сеть</h3><p class="dim">Активные интерфейсы не обнаружены</p></div>') }



# ---------- Пользователи ----------

$userNow  = "$env:USERDOMAIN\$env:USERNAME" -replace '^\\',''

$allUsers = @(Get-CimInstance Win32_UserAccount -Filter "LocalAccount=True" | Where-Object { $_.SIDType -eq 1 })

$userPills = ($allUsers | ForEach-Object { '<span class="pill blue">' + (Esc $_.Name) + '</span>' }) -join ''

$online = @(Get-CimInstance Win32_LogonSession -Filter 'LogonType=2 OR LogonType=10' -ErrorAction SilentlyContinue)

$OnlineN = $online.Count



# ---------- CSS (идентичен Linux-версии) ----------

$CSS = @'

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

'@

if (-not $Output) {

  $ts = Get-Date -Format 'yyyyMMdd_HHmmss'

  $safeHost = ($HostName -replace '[^\w\-]','_')

  $Output = "PC_Report_${safeHost}_${ts}.html"

}



$volCount = $vols.Count


$html = @"

<!DOCTYPE html>

<html lang="ru">

<head>

<meta charset="UTF-8">

<meta name="viewport" content="width=device-width, initial-scale=1.0">

<title>PC Report - $(Esc $HostName) - $DateNow</title>

<style>

$CSS

</style>

</head>

<body>

<header class="hero"><div class="wrap">

<h1>PC<span class="dot">&bull;</span>REPORT</h1>

<div class="sub">

 <span>КОМПЬЮТЕР: <b>$(Esc $HostName)</b></span>

 <span>ДАТА ОТЧЁТА: <b>$DateNow</b></span>

 <span>ПОЛЬЗОВАТЕЛЬ: <b>$(Esc $userNow)</b></span>

 $ModeLine

</div>

<div class="badges">

 <span class="badge">$(Esc $OSName)</span>

 <span class="badge">$(Esc $Arch) · $(Esc $Bits)</span>

 <span class="badge">$(Esc $RamTotalGb) RAM</span>

 <span class="badge">$CpuCores ядер</span>

 <span class="badge">$(Esc $gpuMain)</span>

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

 <tr><th>Полное наименование</th><td>$(Esc $OSName)</td></tr>

 <tr><th>Версия</th><td>$(Esc $OSVer)</td></tr>

 <tr><th>Архитектура</th><td>$(Esc $Arch)</td></tr>

 <tr><th>Разрядность</th><td>$(Esc $Bits)</td></tr>

 </table></div>

 <div class="card"><h3>Платформа</h3><table>

 <tr><th>Изготовитель</th><td>$(Esc $SysVendor)</td></tr>

 <tr><th>Имя компьютера</th><td>$(Esc $HostName)</td></tr>

 <tr><th>Аптайм</th><td>$Uptime</td></tr>

 <tr><th>Тип системы</th><td>$(Esc $Virt)</td></tr>

 </table></div>

</div></div></section>



<section id="cpu"><div class="wrap">

<div class="sec-title"><span class="ico">🧠</span><span class="num">02</span> Процессор</div>

<div class="grid g2">

 <div class="card"><h3>$(Esc $CpuModel) <span class="tag">$CpuCores ядер / $CpuThreads потоков</span></h3><table>

 <tr><th>Производитель</th><td>$(Esc $CpuVendor)</td></tr>

 <tr><th>Физических процессоров</th><td>$SockCount</td></tr>

 <tr><th>Физических ядер</th><td>$CpuCores</td></tr>

 <tr><th>Логических процессоров</th><td>$CpuThreads</td></tr>

 <tr><th>Частота</th><td>$CpuMhz МГц</td></tr>

 <tr><th>Кэш L3</th><td>$(Esc $CpuCache)</td></tr>

 </table></div>

</div></div></section>



<section id="mb"><div class="wrap">

<div class="sec-title"><span class="ico">🔲</span><span class="num">03</span> Материнская плата</div>

<div class="grid g2">

 <div class="card"><h3>Плата</h3><table>

 <tr><th>Полное наименование</th><td>$(Esc $Motherboard)</td></tr>

 <tr><th>Версия платы</th><td>$(Esc $MbVersion)</td></tr>

 <tr><th>Производитель платформы</th><td>$(Esc $SysVendor)</td></tr>

 </table></div>

 <div class="card"><h3>BIOS / UEFI</h3><table>

 <tr><th>Версия BIOS</th><td>$(Esc $BiosVer)</td></tr>

 <tr><th>Дата BIOS</th><td>$(Esc $BiosDate)</td></tr>

 </table></div>

</div></div></section>



<section id="ram"><div class="wrap">

<div class="sec-title"><span class="ico">📊</span><span class="num">04</span> Оперативная память</div>

<div class="grid g2">

 <div class="card"><h3>Итог</h3>

  <div class="big-num">$(Esc $RamTotalGb)</div>

  <div style="margin-top:10px;font-size:13px">

   <div><span class="dim">Модулей установлено:</span> $RamCount</div>

   <div><span class="dim">Свободно сейчас:</span> $(Esc $RamFreeGb)</div>

   <div><span class="dim">Источник данных:</span> $(Esc $RamSrc)</div>

  </div>

 </div>

 <div class="card"><h3>Модули памяти</h3>

  <table><tr><th>№</th><th>Производитель</th><th>Part Number</th><th>Объём</th><th>Тип/частота</th></tr>

$(($ramRows) -join "`n")

  </table>

 </div>

</div></div></section>



<section id="gpu"><div class="wrap">

<div class="sec-title"><span class="ico">🎮</span><span class="num">05</span> Видеокарта</div>

<div class="grid g2">

$(($gpuCards) -join "`n")

</div></div></section>



<section id="disk"><div class="wrap">

<div class="sec-title"><span class="ico">💾</span><span class="num">06</span> Дисковое пространство</div>

<div class="grid g2">

$(($volCards) -join "`n")

 <div class="card"><h3>Физические диски</h3>

  <table><tr><th>Модель / объём / интерфейс</th></tr>

$(($prows) -join "`n")

  </table>

 </div>

</div></div></section>



<section id="net"><div class="wrap">

<div class="sec-title"><span class="ico">🌐</span><span class="num">07</span> Сетевые интерфейсы</div>

<div class="grid g2">

$(($nicCards) -join "`n")

</div></div></section>



<section id="users"><div class="wrap">

<div class="sec-title"><span class="ico">👤</span><span class="num">08</span> Пользователи</div>

<div class="grid g2">

 <div class="card"><h3>Текущая сессия</h3><table>

 <tr><th>Запущено от имени</th><td>$(Esc $userNow)</td></tr>

 <tr><th>Активных интерактивных сессий</th><td>$OnlineN</td></tr>

 </table></div>

 <div class="card"><h3>Пользователи ПК <span class="tag">всего аккаунтов: $UsersN</span></h3>

 <div>$allUsers</div>

 </div>

</div></div></section>



<section id="summary"><div class="wrap">

<div class="sec-title"><span class="ico">⌨️</span><span class="num">09</span> Сводка (терминальный вид)</div>

<pre class="term"><span class="p">&gt;</span> hostname      → $(Esc $HostName)

<span class="p">&gt;</span> os            → $(Esc $OSName) · $(Esc $OSVer) · $(Esc $Arch) $(Esc $Bits)

<span class="p">&gt;</span> cpu           → $(Esc $CpuModel) · $CpuCores cores / $CpuThreads threads

<span class="p">&gt;</span> motherboard   → $(Esc $Motherboard)

<span class="p">&gt;</span> ram           → $(Esc $RamTotalGb) · $RamCount module(s)

<span class="p">&gt;</span> gpu           → $(Esc $gpuMain) · VRAM: $(Esc $gpuMainVram)

<span class="p">&gt;</span> volumes       → $volCount volume(s), root: $(Esc $RootDev) ($(Esc $RootFs), $(Esc $RootPuse) занято)

<span class="p">&gt;</span> user          → $(Esc $userNow) · accounts: $UsersN

</pre></div></section>



<footer><div class="wrap">

<span>Отчёт сформирован скриптом pc_report.ps1 · $DateNow</span>

<span>Хост: $(Esc $HostName) · Автономный HTML, без внешних ресурсов</span>

</div></footer>

</body></html>

"@

# ---- сохранить шаблон для удалённого режима ----

$LocalTemplate = $html

Set-Content -Path $Output -Value $html -Encoding UTF8

Say "Отчёт создан: $Output"