# ============================================================
#  pc_report.ps1 — мини-сервис: красивый HTML-отчёт о ПК (Windows)
#
#  Запуск:      powershell -ExecutionPolicy Bypass -File .\pc_report.ps1
#               (опционально: -Output C:\path\report.html)
#  Что делает:  собирает полные сведения об ОС/железе (WMI/CIM)
#               и создаёт автономный HTML-файл в едином стиле
#               с Linux-версией (тёмная тема, моноширинный шрифт).
#  Требования:  Windows 10/11, PowerShell 5.1+ (без внешних модулей).
# ============================================================
param([string]$Output = "")

$ErrorActionPreference = 'Continue'
function Say($m) { Write-Host "[pc_report] $m" -ForegroundColor Cyan }
function Esc($s) { if ($null -eq $s) { '' } else { ([string]$s).Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;').Replace('"','&quot;') } }
function GB($bytes) { if ($bytes -gt 0) { ('{0:N1} ГБ' -f ($bytes/1GB)) } else { '—' } }

Say "Сбор сведений о системе..."

# ---------- ОС ----------
$os    = Get-CimInstance Win32_OperatingSystem
$cs    = Get-CimInstance Win32_ComputerSystem
$biosC = Get-CimInstance Win32_BIOS
$OSName   = "$($os.Caption)".Trim()
$OSVer    = "$($os.Version) (сборка $($os.BuildNumber))"
$Arch     = if ($env:PROCESSOR_ARCHITECTURE) { $env:PROCESSOR_ARCHITECTURE } else { $os.OSArchitecture }
$Bits     = if ("$Arch" -match '64') { '64-битная' } elseif ("$Arch" -match '86|32') { '32-битная' } else { '—' }
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
$BiosDate    = if ($biosC.ReleaseDate) { $biosC.ReleaseDate.ToString('dd.MM.yyyy') } else { '—' }

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
  if ($vramGb -le 0) { $vramTxt = '— (разделяемая)' } else { $vramTxt = "$vramGb ГБ" }
  $spec = "$($g.VideoProcessor)"
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
$gpuMain = if ($gpus.Count -gt 0) { $gpus[0].Name } else { '—' }
$gpuMainVram = if ($gpus.Count -gt 0 -and $gpus[0].AdapterRAM -gt 0) { "$([math]::Round($gpus[0].AdapterRAM/1GB,1)) ГБ" } else { '—' }

# ---------- Логические тома (диски) ----------
$vols = @(Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3")
$volCards = @()
foreach ($v in $vols) {
  $usedP = if ($v.Size -gt 0) { [math]::Round((($v.Size - $v.FreeSpace) / $v.Size) * 100, 0) } else { 0 }
  $cls = if ($usedP -gt 85) { 'crit' } elseif ($usedP -gt 65) { 'warn' } else { 'ok' }
  $label = if ($v.VolumeName) { $v.VolumeName } else { '—' }
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
  $ityp = if ("$($d.InterfaceType)") { $d.InterfaceType } else { '—' }
  "<tr><td>$(Esc $d.DeviceID)</td><td>$(Esc ("$($d.Model)").Trim())</td><td>$(GB $d.Size)</td><td>$ityp</td></tr>"
}
if (-not $prows) { $prows = @('<tr><td colspan="4">—</td></tr>') }

# ---------- Сеть ----------
$nics = @(Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "IPEnabled=True")
$nicCards = @()
foreach ($n in $nics) {
  $mode = if ($n.DHCPEnabled) { '<span class="pill green">DHCP</span>' } else { '<span class="pill amber">STATIC</span>' }
  $ip   = if ($n.IPAddress) { $n.IPAddress -join ', ' } else { '—' }
  $mask = if ($n.IPSubnet)  { $n.IPSubnet -join ', ' } else { '—' }
  $gw   = if ($n.DefaultIPGateway) { $n.DefaultIPGateway -join ', ' } else { '—' }
  $dns  = if ($n.DNSServerSearchOrder) { $n.DNSServerSearchOrder -join ', ' } else { '—' }
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

# ---------- Имя файла ----------
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
<title>PC Report — $(Esc $HostName) — $DateNow</title>
<style>
$CSS
</style>
</head>
<body>
<header class="hero"><div class="wrap">
<h1>PC<span class="dot">▪</span>REPORT</h1>
<div class="sub">
 <span>КОМПЬЮТЕР: <b>$(Esc $HostName)</b></span>
 <span>ДАТА ОТЧЁТА: <b>$DateNow</b></span>
 <span>ПОЛЬЗОВАТЕЛЬ: <b>$(Esc $userNow)</b></span>
</div>
<div class="badges">
 <span class="badge">$(Esc $OSName)</span>
 <span class="badge">$(Esc $Arch) · $(Esc $Bits)</span>
 <span class="badge">$RamTotalGb ГБ RAM</span>
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
 <tr><th>Последняя загрузка</th><td>$($os.LastBootUpTime.ToString('dd.MM.yyyy HH:mm'))</td></tr>
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
 <tr><th>Базовая частота</th><td>$CpuMhz МГц</td></tr>
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
  <div class="big-num">$RamTotalGb ГБ</div>
  <div style="margin-top:10px;font-size:13px">
   <div><span class="dim">Модулей установлено:</span> $RamCount</div>
   <div><span class="dim">Свободно доступно:</span> $RamFreeGb ГБ</div>
   <div><span class="dim">Источник данных:</span> WMI Win32_PhysicalMemory</div>
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
 <div class="card"><h3>Физические диски <span class="tag">$($pdisks.Count) шт.</span></h3>
  <table><tr><th>Устройство</th><th>Модель</th><th>Объём</th><th>Интерфейс</th></tr>
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
 <div class="card"><h3>Локальные пользователи <span class="tag">всего аккаунтов: $($allUsers.Count)</span></h3>
 <div>$userPills</div>
 </div>
</div></div></section>

<section id="summary"><div class="wrap">
<div class="sec-title"><span class="ico">⌨️</span><span class="num">09</span> Сводка (терминальный вид)</div>
<pre class="term"><span class="p">&gt;</span> hostname      → $(Esc $HostName)
<span class="p">&gt;</span> os            → $(Esc $OSName) · $(Esc $OSVer) · $(Esc $Arch) $(Esc $Bits)
<span class="p">&gt;</span> cpu           → $(Esc $CpuModel) · $CpuCores cores / $CpuThreads threads
<span class="p">&gt;</span> motherboard   → $(Esc $Motherboard)
<span class="p">&gt;</span> ram           → ${RamTotalGb}GB · $RamCount module(s)
<span class="p">&gt;</span> gpu           → $(Esc $gpuMain) · VRAM: $(Esc $gpuMainVram)
<span class="p">&gt;</span> volumes       → $volCount local volume(s)
<span class="p">&gt;</span> user          → $(Esc $userNow) · accounts: $($allUsers.Count)
</pre></div></section>

<footer><div class="wrap">
<span>Отчёт сформирован скриптом pc_report.ps1 · $DateNow</span>
<span>Хост: $(Esc $HostName) · Автономный HTML, без внешних ресурсов</span>
</div></footer>
</body></html>
"@

Set-Content -Path $Output -Value $html -Encoding UTF8
Say "Отчёт создан: $Output"
