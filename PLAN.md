# MacBox — Архітектурний план та дорожня карта (Phase 0)

**Назва проєкту:** `MacBox` (CLI: `macbox`, гостьовий агент: `MacBoxAgent.app`)  
**Призначення:** Open-source віртуальний Mac на Apple Silicon для ШІ-агентів, яким можна керувати через MCP і переглядати/контролювати прямо з терміналу (Kitty graphics / iTerm2 inline images) без впливу на мишу, буфер обміну й вікна хоста.  

---

## 1. Середовище розробки (перевірено локально)

| Параметр | Значення | Статус |
|---|---|---|
| Хост ОС | macOS 26.5.2 (Build `25F84`) | [ПЕРЕВІРЕНО] |
| Архітектура | `arm64` (Apple Silicon) | [ПЕРЕВІРЕНО] |
| Swift / Xcode | Swift 6.2.1 (`swiftlang-6.2.1.4.8`), Xcode 26.1 (`17B55`) | [ПЕРЕВІРЕНО] |
| Мінімальна цільова ОС | macOS 14.0+ (Sonoma), Apple Silicon | Вимога |
| Вільне місце на `/` | **46 GiB** (з 228 GiB) | [ПЕРЕВІРЕНО — УВАГА!] |

> **Ризик дискового простору:** IPSW-образ macOS займає ~13–16 GiB, а встановлений sparse-диск гостьової macOS — ~18–25 GiB реальних блоків. Із 46 GiB вільного місця одночасне зберігання IPSW + встановленої VM + знімків стану (`.vzvmsave` ≈ розміру RAM VM) буде на межі. Рекомендовано або підключити зовнішній APFS-диск через `--data-dir`, або видаляти IPSW після інсталяції базового образу.

---

## 2. Огляд аналогів

| Проєкт | Інтерфейс | Транспорт / Керування | Сильні сторони | Чого бракує для нашої задачі |
|---|---|---|---|---|
| **Tart** (Cirrus Labs) | CLI | SSH / VNC, OCI-реєстри | Зрілий CLI, APFS-клонування (`clonefile`), CI/CD-орієнтований, Softnet | Немає вбудованого термінального viewer і MCP-керування GUI |
| **Lume** (TryCua) | CLI + HTTP API + MCP | Локальний HTTP / VNC | Швидкий старт, орієнтований на ШІ-агентів | Потребує мережевого/VNC-каналу, немає нативного термінального рендера |
| **UTM** | GUI + `utmctl` | SPICE / Apple VZ | Підтримка QEMU + Apple VZ, багато ОС | Важкий GUI-застосунок, не орієнтований на термінальний workflow та MCP |
| **VirtualBuddy** | Native GUI | Apple VZ GUI | Найкращий нативний UX для macOS VM, зручна робота з IPSW | Чисто GUI, без CLI/MCP/термінального viewer |

---

## 3. Перевірка Apple API (Перевірено vs Припущення)

Усі символи нижче звірені безпосередньо з заголовками `MacOSX.sdk` (Xcode 26.1) та офіційною документацією Apple Developer:

| API / Механізм | Статус | Деталі перевірки |
|---|---|---|
| `VZMacOSRestoreImage` (`latestSupported`, `image(from:)`) | **[ПЕРЕВІРЕНО]** | Наявний у `Virtualization.framework/Headers/VZMacOSRestoreImage.h` |
| `VZMacOSInstaller` (`install()`) | **[ПЕРЕВІРЕНО]** | Наявний у `VZMacOSInstaller.h` |
| `VZVirtualMachine.saveMachineStateTo(url:)` / `restoreMachineStateFrom(url:)` | **[ПЕРЕВІРЕНО]** | `API_AVAILABLE(macos(14.0))` у `VZVirtualMachine.h`. Обмеження з коментарів SDK: файл прив'язаний до того ж хоста і версії macOS; після оновлення ОС хоста може відхилятися з `VZErrorRestore` |
| `VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag` | **[ПЕРЕВІРЕНО]** | `API_AVAILABLE(macos(13.0))` у `VZVirtioFileSystemDeviceConfiguration.h`. Автомонтується у `/Volumes` в macOS-гості |
| `VZVirtioSocketDevice` + `<sys/vsock.h>` (`AF_VSOCK = 40`, `sockaddr_vm`, `VMADDR_CID_HOST = 2`) | **[ПЕРЕВІРЕНО на рівні SDK]** / **[ПРИПУЩЕННЯ для runtime macOS-гостя]** | Заголовок `<sys/vsock.h>` є в macOS SDK, `VZVirtioSocketDevice` є у `Virtualization.framework`. **Потребує live-перевірки у Фазі 2:** чи дозволяє XNU всередині macOS-гостя відкривати `socket(AF_VSOCK, SOCK_STREAM, 0)` без додаткових entitlements і яка реальна пропускна здатність/стабільність |
| `VZVirtioConsoleDevice` / `VZVirtioConsolePort` | **[ПЕРЕВІРЕНО на рівні SDK]** / **[ПРИПУЩЕННЯ для macOS-гостя]** | Заголовки є в SDK, але драйвер virtio-console у macOS-гості потрібно перевірити наживо у Фазі 2 |
| `VZGraphicsDisplay` | **[ПЕРЕВІРЕНО]** | Не має публічного API для читання пікселів framebuffer на хості — лише `sizeInPixels`, `reconfigure(...)` і `VZGraphicsDisplayObserver` |
| `VZVirtualMachineView` | **[ПЕРЕВІРЕНО]** | Має `virtualMachine`, `capturesSystemKeys`, `automaticallyReconfiguresDisplay` (macOS 14+). Не має публічного API для ін'єкції синтетичних подій без фокусу вікна |
| `SCStream` / `SCStreamConfiguration` (`minimumFrameInterval`, `capturesAudio`) | **[ПЕРЕВІРЕНО]** | Наявні у `ScreenCaptureKit` (macOS 14+) |
| `clonefile` (`<sys/clonefile.h>`) | **[ПЕРЕВІРЕНО]** | Наявний у macOS SDK для миттєвого Copy-on-Write клонування на APFS |
| Unattended `VZMacGuestProvisioningOptions` | **[СПРОСТОВАНО]** | У заголовках `Virtualization.framework` (MacOSX26.sdk) **відсутній** будь-який публічний API автоматичного проходження Setup Assistant. Setup Assistant на macOS-гості потребує або інтерактивного проходження, або зовнішньої автоматизації |
| Ліміт одночасних macOS VM (SLA) | **[ПЕРЕВІРЕНО]** | Apple macOS SLA та `Virtualization.framework` обмежують кількість одночасно запущених гостьових macOS до **2** на одному Mac |
| Kitty Graphics SHM (`t=s`) у Ghostty/Kitty та iTerm2 OSC 1337 | **[ПРИПУЩЕННЯ — потребує live-перевірки у Фазі 4]** | Специфікація відома, але поведінка ресайзу, очищення SHM і FPS потребують реальної перевірки в Ghostty/Kitty та iTerm2 |

---

## 4. Модульна структура (`MacBox`)

Усі модулі та назви власні (Swift 6, SwiftPM, мінімум залежностей — лише системні фреймворки Apple + за потреби `swift-argument-parser` або власний легкий CLI-парсер):

```text
macbox/
├── Package.swift
├── PLAN.md
├── DECISIONS.md
├── SECURITY.md
├── CHECKLIST.md
├── README.md
├── Sources/
│   ├── MacBoxCore/          # Ядро VM: конфіг, життєвий цикл, диск (sparse/APFS clone), snapshot/restore, file lock, метадані
│   ├── MacBoxProtocol/      # Версіонований протокол хост <-> гість (кадри, RPC, ліміти, auth-токен, TTL, координати)
│   ├── MacBoxTransport/     # Абстракція транспорту (прототипи vsock / virtio-fs / serial / NAT-TCP + фінальний драйвер)
│   ├── MacBoxTerminal/      # Рендерер терміналу (Kitty SHM + inline, iTerm2 OSC 1337, автодетект, пропорції, raw input, Ctrl+G палітра)
│   ├── MacBoxMCP/           # MCP-сервер поверх stdio (screenshot, click, drag, scroll, type, key, status, ax_tree)
│   ├── MacBoxCLI/           # Точка входу `macbox` (init/up, create, start, stop, pause, resume, clone, snapshot, doctor, view, mcp)
│   └── MacBoxGuestAgent/    # Окремий бандл `MacBoxAgent.app` для гостя (ScreenCaptureKit, CGEvent, AXUIElement, VirtualMac-перевірка)
├── Tests/
│   ├── MacBoxProtocolTests/
│   ├── MacBoxTerminalTests/
│   ├── MacBoxMCPTests/
│   └── MacBoxCoreTests/
├── skills/
│   └── macbox-agent/SKILL.md
└── scripts/
    └── sign-and-bundle.sh
```

---

## 5. Власні доповнення (понад базовий функціонал)

Обираємо **три** заплановані функції MacBox із чіткими критеріями приймання та вимірюваннями (реалізація у Фазі 7):

1. **Миттєве клонування VM через APFS `clonefile` (`macbox clone <src> <dst>`)**
   - *Навіщо:* дозволяє тримати чистий «золотий» образ macOS (після Setup Assistant і налаштування TCC) і миттєво створювати ізольовані копії для агентів без повторного встановлення ОС.
   - *Критерій приймання:* клон 64 GiB sparse-образу створюється з унікальним `VZMacMachineIdentifier`, коректно завантажується і не змінює диск оригіналу.
   - *Вимірювання:* час клонування (ціль `< 200 ms`) і додатковий обсяг на диску до першого запису (`≈ 0 MiB` CoW).

2. **Знімки та відновлення живого стану VM (`macbox snapshot save/restore/ls/rm`)**
   - *Навіщо:* швидкий відкат стану після експериментів ШІ-агента через нативний `VZVirtualMachine.saveMachineStateTo(url:)` + APFS `clonefile` диска в момент паузи.
   - *Критерій приймання:* збереження стану з відкритим вікном, внесення змін у гості, відновлення повертає і пам'ять, і стан диска.
   - *Вимірювання:* час `save`, час `restore`, розмір знімка на диску.

3. **Дерево доступності від гостьового агента (`ax_tree` в MCP і `macbox action ax-tree`)**
   - *Навіщо:* ШІ-агенту значно точніше й дешевше по токенах отримувати структурований JSON активного вікна через `AXUIElement` (ролі, заголовки, координати в системі скріншота), ніж вгадувати пікселі на кожному кроці.
   - *Критерій приймання:* повертає обмежений за глибиною та розміром JSON із координатами елементів активного вікна, узгодженими з `screenshot`; при збої/відсутності AX-дозволу повертає чітку структуровану помилку.
   - *Вимірювання:* латентність запиту `ax_tree` (ціль `< 50 ms`) та розмір payload порівняно зі скріншотом.

---

## 6. Дорожня карта (Фази 0–8)

- **Фаза 0 (поточна):** Дослідження, `PLAN.md`, `DECISIONS.md`, `SECURITY.md`, `CHECKLIST.md`.
- **Фаза 1 (Spike):** SwiftPM-проєкт компілюється, підписується з `com.apple.security.virtualization`, створює/завантажує macOS VM і показує робочий стіл у нативному `NSWindow` (`VZVirtualMachineView`).
- **Фаза 2 (Транспорт і кадри):** Прототипи кандидатів (`vsock`, `virtio-fs`, `NAT TCP`, перевірка `virtio-console`), бенчмарк латентності та пропускної здатності, заповнення таблиці вимірів у `DECISIONS.md`, фінальний вибір транспорту та формату кадрів.
- **Фаза 3 (Ввід без впливу на хост):** Гостьовий агент `MacBoxAgent.app` (`ScreenCaptureKit` + `CGEvent`), скрипт робить скріншот, клікає в Dock і друкує в TextEdit, поки користувач вільно рухає мишею на хості.
- **Фаза 4 (Термінальний Viewer):** Kitty Graphics (SHM + fallback) та iTerm2 inline images, автодетект, масштабування зі збереженням пропорцій, адаптивний FPS, коректний ресайз.
- **Фаза 5 (Інтерактивний режим):** Миша (кліки, дабл/тріпл, drag, scroll), клавіатура, палітра `Ctrl+G` для Mac-шорткатів, вихід `Ctrl+]` без зупинки VM.
- **Фаза 6 (MCP-сервер і Skill):** stdio MCP (`screenshot`, `click`, `drag`, `scroll`, `type`, `key`, `status`), юніт-тести схем і координат, `SKILL.md` («спостерігай → дій → перевір»), live-тест із Claude Code.
- **Фаза 7 (Власні доповнення з вимірами):** APFS `clone`, `snapshot save/restore`, `ax_tree` — реалізація, тести, таблиця вимірів.
- **Фаза 8 (Документація й пакування):** `README.md` (встановлення, підпис, SLA, troubleshooting, конфіги Claude Code / Cursor), інсталятор, фінальна перевірка чекліста.
