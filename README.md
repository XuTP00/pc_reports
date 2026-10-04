# Навык: "Инфа о ПК"

## 📌 Описание навыка
Мини-сервис **PC Report** формирует автономный HTML-отчёт с полными характеристиками компьютера. Отчёт открывается в любом браузере, не требует интернета и внешних ресурсов.

Сервис состоит ровно из **двух файлов**:
| Файл | ОС | Способ запуска |
|---|---|---|
| `pc_report.sh` | Linux | `./pc_report.sh` (локально) или `user@host` (по SSH) |
| `pc_report.ps1` | Windows | `powershell -ExecutionPolicy Bypass -File .\pc_report.ps1` |

Каждый файл самодостаточен: сбор данных и генерация HTML встроены внутрь, никаких дополнительных скриптов не требуется.

---

## 🎯 Когда применять
1. **«Выполни навык „Инфа о ПК“ на текущем ПК»** → локальный запуск.
2. **«Вот доступы на ПК: ssh mike@192.168.1.154 password: 1234567»** → агент сам подключается по SSH, применяет навык на удалённой машине и возвращает готовый HTML-файл.
3. Любая просьба «узнать конфигурацию ПК / собрать инфо о железе / сделать отчёт о системе».

---

## 🔧 Пошаговый алгоритм агента

### Шаг 1. Определить цель
- **Локальный ПК** (текущая машина) → шаг 2.
- **Удалённый хост** (IP/hostname, пользователь, пароль или ключ) → шаг 3.

### Шаг 2. Определить ОС цели
- `uname -s` → `Linux` ⇒ использовать `pc_report.sh`.
- Windows (`Microsoft Windows`, PowerShell-сессия) ⇒ использовать `pc_report.ps1`.
- macOS ⇒ навык не поддерживается, сообщить пользователю.

### Шаг 3. Локальный запуск
**Linux:**
```bash
cd <папка_с_файлом>
chmod +x pc_report.sh
./pc_report.sh                      # создаст PC_Report_<хост>_<дата>.html
# рекомендуется для полных данных о RAM/плате:
sudo -E ./pc_report.sh
```

---

## 📦 Сборка EXE-файла из `pc_report.ps1` (Windows)

Скрипт можно упаковать в самостоятельный `pc_report.exe` — тогда отчёт будет генерироваться двойным кликом или запуском без PowerShell и без обхода политик выполнения. Нужен модуль **PS2EXE-GUI** (Ingo Karstein / Markus Scholtes).

### Пошагово (PowerShell от администратора)

**1. Разрешить выполнение локальных скриптов:**
```powershell
Set-ExecutionPolicy RemoteSigned
```

**2. Установить и импортировать модуль PS2EXE:**
```powershell
Install-Module -Name PS2EXE -Scope CurrentUser   # если модуль ещё не установлен
Import-Module -Name PS2EXE
```

**3. Перейти в папку со скриптом** и при необходимости положить туда же `.ico`-файл — красивую иконку будущего exe:
```powershell
cd C:\project\PC_INFO\pc_reports\pc-report
# скопируйте свой файл иконки, например:
# Copy-Item .\my_icon.ico .\icon.ico
```

**4. Скомпилировать exe (иконка — опционально):**
```powershell
Invoke-PS2EXE .\pc_report.ps1 .\pc_report.exe -iconFile .\icon.ico
# без иконки достаточно: Invoke-PS2EXE .\pc_report.ps1 .\pc_report.exe
```

### Ожидаемый вывод компиляции
```text
PS2EXE-GUI v0.5.0.34 by Ingo Karstein, reworked and GUI support by Markus Scholtes

PowerShell Desktop environment started...


Reading input file C:\project\1\pc_report.ps1
Compiling file...

Output file C:\project\1\pc_report.exe written
```

После этого `pc_report.exe` самодостаточен: переносите его на любой Windows-ПК (Win 10/11, x64), запускайте — HTML-отчёт создастся рядом с рабочей папкой.

> 💡 Советы:
> - Для скрытия окна консоли при запуске добавьте флаг `-noConsole` (тогда скрипт должен писать результат в файл, что `pc_report.ps1` и делает).
> - Если антивирус ругается на неподписанный exe — добавьте исключение для папки сборки или подпишите код сертификатом.
> - Обновляли `pc_report.ps1` → пересоберите exe шагом 4, старый exe удалите.