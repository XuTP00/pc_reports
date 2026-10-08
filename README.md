
#  "Инфа о ПК"

## 📌 Описание 
Мини-сервис **PC Report** формирует автономный HTML-отчёт с полными характеристиками компьютера. Отчёт открывается в любом браузере, не требует интернета и внешних ресурсов.

Сервис состоит ровно из **двух файлов**:
| Файл | ОС | Способ запуска |
|---|---|---|
| `pc_report.sh` | Linux | `./pc_report.sh` (локально) или `user@host` (по SSH) |
| `pc_report.ps1` | Windows | `powershell -ExecutionPolicy Bypass -File .\pc_report.ps1` |

Каждый файл самодостаточен: сбор данных и генерация HTML встроены внутрь, никаких дополнительных скриптов не требуется.

###  Локальный запуск 
**Linux:**
```bash
cd <папка_с_файлом>
chmod +x pc_report.sh
./pc_report.sh   # создаст PC_Report_<хост>_<дата>.html
sudo -E ./pc_report.sh   # рекомендуется для полных данных о RAM/плате
```
**Windows (PowerShell скрипт):**
```powershell
cd <папка_с_файлом>
powershell -ExecutionPolicy Bypass -File pc_report.ps1 # разрешит выполнение данного скрипта и создаст PC_Report_<хост>_<дата>.html
```
**Windows (PowerShell скрипт #2):**
```powershell
cd <папка_с_файлом>
Set-ExecutionPolicy RemoteSigned # разрешит выполнение **всех** сторонних скриптов 
.\pc_report.ps1 # создаст PC_Report_<хост>_<дата>.html 
```
**Windows (Исполняемый файл .exe):**
```powershell
cd <папка_с_файлом>
.\pc_report.exe # создаст PC_Report_<хост>_<дата>.html
# Так же возможно просто запустить .exe из GUI.
```

## 🌐 Удалённый режим по SSH (`-r`)

Один и тот же файл скрипта работает и локально, и как сетевой сборщик: вы запускаете его **на своём ПК**, он подключается по SSH к удалённым машинам (Linux или Windows с включённым OpenSSH-сервером), собирает данные и сохраняет HTML-отчёт. Поддерживается опрос одного хоста и массовый опрос по файлу-списку.

### Linux (`pc_report.sh`)

```bash
# Один хост, порт по умолчанию 22, пароль запрашивается интерактивно:
./pc_report.sh -r mike@192.168.1.161

# Один хост с нестандартным портом (двоеточие после адреса):
./pc_report.sh -r mike@192.168.1.161:2222

# Пароль без интерактива — только через переменную окружения (не сохраняется):
PC_PASS='пароль' ./pc_report.sh -r mike@192.168.1.161

# Массовый опрос по файлу-списку:
./pc_report.sh -r pc_clients.txt
```

### Windows (`pc_report.ps1` / `pc_report.exe`)
>[!info] ### Так же нужен запуск "стороннего" скрипта из 2х вариантов.
**1. Set-ExecutionPolicy RemoteSigned**
**2. powershell -ExecutionPolicy Bypass -File pc_report.ps1**


```powershell
cd <папка_с_файлом>
.\pc_report.ps1 -r mike@192.168.1.161
.\pc_report.ps1 -r mike@192.168.1.161:2222
.\pc_report.ps1 -r pc_clients.txt
# собранный exe — аналогично:
.\pc_report.exe -r mike@192.168.1.161
.\pc_report.exe -r pc_clients.txt
```

### Формат файла-списка (`ListFile`)

Текстовый файл, строки разделены `;`. Столбцы: `user ; ip/hostname ; password ; port`. Первые три обязательны, `port` — нет (по умолчанию 22). Пустые строки и строки, начинающиеся с `#`, игнорируются.

```text
# user        ; host           ; password   ; port
mike         ; 192.168.1.161  ; secret123  ; 22
admin        ; 10.0.0.5       ; pass456    ;
sergey       ; srv.local      ; topsecret  ; 2222
```

### Что происходит при запуске `-r`

1. Определяется ОС удалённого хоста (`uname -s`).
2. **Linux-хост** → на него передаётся встроенный bash-сборщик, данные возвращаются и рендерятся в HTML.
3. **Windows-хост** → по SSH удалённо исполняется встроенный PowerShell-сборщик (CIM/WMI), данные возвращаются и рендерятся в тот же шаблон отчёта.
4. Каждый хост даёт отдельный файл `PC_Report_<имя_ПК>_<дата>.html` в текущей папке; при опросе списка печатается итог `успешно/ошибка` по каждому адресу.
5. Временные файлы сборщика удаляются на обеих сторонах, пароли не пишутся ни в какие файлы и не попадают в HTML.

### Требования к целевым ПК

| Цель | Что должно быть |
|---|---|
| Linux | OpenSSH-сервер, стандартные утилиты (`lscpu`, `df`, `ip`); для RAM/материнской платы желателен доступ root |
| Windows 10/11 | Включённая функция «OpenSSH Server» + PowerShell 5.1 (CIM-сборщик работает под обычным пользователем) |

## 📦 Сборка EXE-файла из `pc_report.ps1` (Windows)
Скрипт можно упаковать в самостоятельный `pc_report.exe` — тогда отчёт будет генерироваться двойным кликом или запуском без PowerShell и без обхода политик выполнения.
### **1 Вариант** 
Запускаем файл `create-exe.cmd` в папке с `pc-report.ps1` и если все совместимости подходят то видим следующие:
```
PC Report - EXE helper v2
Creating console EXE in Windows PowerShell without profiles...
PS2EXE-GUI v0.5.0.34 by Ingo Karstein, reworked and GUI support by Markus Scholtes


Reading input file C:\project\pc-report.ps1
Compiling file...

Output file C:\project\pc-report-build-500099846981419190336624ecb2683d.exe written
SUCCESS: C:\project\pc-report.exe
The EXE is not digitally signed. Signing scripts remains a separate operation.
```

### **2 Вариант**
Скрипт запускаем из cmd или powershell (Права Администратора не нужны):
```
.\create-exe.cmd
PC Report - EXE helper v2
Creating console EXE in Windows PowerShell without profiles...
PS2EXE-GUI v0.5.0.34 by Ingo Karstein, reworked and GUI support by Markus Scholtes


Reading input file C:\project\pc-report.ps1
Compiling file...

Output file C:\project\pc-report-build-500099846981419190336624ecb2684d.exe written
SUCCESS: C:\project\pc-report.exe
The EXE is not digitally signed. Signing scripts remains a separate operation.
```
### Если в папке со скриптом будет лежать файл иконки с именем `1.ico` то он будет добавлен к исполняемому файлу `pc-report.exe`
