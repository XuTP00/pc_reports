#!/usr/bin/env bash
# ============================================================
#  pc_report.sh — мини-сервис: красивый HTML-отчёт о ПК (Linux)
#
#  Запуск:      ./pc_report.sh [-o файл.html] [--layout A|B|both]
#  Что делает:  собирает полные сведения об ОС/железе и создаёт
#               автономный HTML-файл (тёмная тема, моноширинный
#               шрифт, без внешних ресурсов).
#  Требования:  bash + стандартные утилиты Linux.
# ============================================================
set -u

LAYOUT="both"
OUTPUT=""
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

while [ $# -gt 0 ]; do
  case "$1" in
    -o|--output) OUTPUT="$2"; shift 2 ;;
    --layout)    LAYOUT="$2"; shift 2 ;;
    -h|--help)   sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Неизвестный параметр: $1 (см. --help)" >&2; exit 1 ;;
  esac
done

say() { printf '\033[1;36m[pc_report]\033[0m %s\n' "$1" >&2; }
die() { printf '\033[1;31m[pc_report] ОШИБКА:\033[0m %s\n' "$1" >&2; exit 1; }

TS=$(date '+%Y%m%d_%H%M%S')
HOST_SHORT=$(hostname 2>/dev/null || echo PC)
[ -n "$OUTPUT" ] || OUTPUT="PC_Report_${HOST_SHORT}_${TS}.html"

DATA_FILE=$(mktemp /tmp/.pcreport.XXXXXX)
trap 'rm -f "$DATA_FILE"' EXIT

say "Сбор сведений о системе..."
bash "$HERE/collect.sh" > "$DATA_FILE" 2>/dev/null || die "collect.sh завершился с ошибкой"
[ -s "$DATA_FILE" ] || die "пустой набор данных"

esc() { local s="$1"; s="${s//&/&amp;}"; s="${s//</&lt;}"; s="${s//>/&gt;}"; s="${s//\"/&quot;}"; printf '%s' "$s"; }
get() { awk -F'\t' -v k="$1" '$1==k{sub(/^[^\t]+\t/,""); print; exit}' "$DATA_FILE"; }

# ---------- читаем данные ----------
OS_NAME=$(get OS_NAME);   OS_VER=$(get OS_VER);     KERNEL=$(get KERNEL)
ARCH=$(get ARCH);         BITS=$(get BITS);         HOST=$(get HOST)
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
 <div class="card"><h3>Корневое устройство <span class="tag">$(esc "$ROOT_DEV")</span></h3><table>
 <tr><th>Блочное устройство (root)</th><td>$(esc "$ROOT_DEV")</td></tr>
 <tr><th>Файловая система</th><td>$(esc "$ROOT_FS")</td></tr>
 <tr><th>Общий объём</th><td>$(esc "$ROOT_SIZE")</td></tr>
 <tr><th>Занято</th><td>$(esc "$ROOT_USED") ($(esc "$ROOT_PUSE"))</td></tr>
 <tr><th>Свободно</th><td>$(esc "$ROOT_FREE")</td></tr>
 </table>
 <div class="bar"><div class="$BARCLASS" style="width:${PU}%"></div></div>
 </div>
 <div class="card"><h3>Физические диски</h3>
  <table><tr><th>Устройство</th><th>Модель</th><th>Объём</th><th>Тип</th></tr>
$(echo "$DISKS" | tr ';' '\n' | awk -F'|' 'NF>=4{printf "<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>\n", $1, $2, $3, $4}')
  </table>
 </div>
</div></div></section>

<section id="net"><div class="wrap">
<div class="sec-title"><span class="ico">🌐</span><span class="num">07</span> Сетевые интерфейсы</div>
<div class="grid g2">
$(echo "$IFACES" | tr ';' '\n' | awk -F'|' 'NF>=6{n++
 st=(($2=="up")?"green":"gray")
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

build_file() { # $1=output $2=extra-css
cat > "$1" << HEAD
<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>PC Report — $(esc "$HOST") — $(date '+%d.%m.%Y %H:%M')</title>
<style>$CSS$2</style>
</head>
<body>
HEAD
gen_body >> "$1"
echo "</body></html>" >> "$1"
}

if [ "$LAYOUT" = "A" ] || [ "$LAYOUT" = "both" ]; then
  build_file "$OUTPUT" ""
  say "Вариант A (карточный): $OUTPUT"
fi
if [ "$LAYOUT" = "B" ] || [ "$LAYOUT" = "both" ]; then
  OUT_B="${OUTPUT%.html}_variantB.html"
  build_file "$OUT_B" '.card{border-radius:0}.g2{grid-template-columns:1fr}.sec-title{border-left:4px solid var(--blue);padding-left:12px}.card:hover{transform:none}'
  say "Вариант B (табличный): $OUT_B"
fi
say "Готово. Открыть в браузере: file://$(realpath "$OUTPUT" 2>/dev/null || echo "$OUTPUT")"
