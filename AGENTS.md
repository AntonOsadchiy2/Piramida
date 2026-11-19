# Работа с проектом «Пирамида»

## Обязательные правила

Проект — только живые обои Windows x64 на Godot 4.7.2. Не восстанавливай Android-ветку, мобильную сцену, HUD, покупки, звук и офлайн-прогресс. Сохраняй чтение существующих сохранений обоев и используемые ими поля модели.

Размер и число блоков пирамиды не фиксированы: используй данные выбранного чертежа.

- Найди файлы задачи и ближайшую проверку. Группируй чтения и правки. Не повторяй чтение и успешные проверки без причины. Возвращай нужные строки логов, файлов и diff. Для визуальной проверки выбирай кадры нужной фазы и области.
- Веди один активный чат на воспроизводимый сбой. Не веди тяжёлые задачи над одной подсистемой или сборкой параллельно. Новые чаты — по запросу или необходимости. При передаче укажи контрольную точку, изменённые файлы и следующую проверку. Для сбоя добавь чертёж или снимок и первую ошибку либо место остановки.
- Перед массовым удалением или архивированием перечисли объекты. Завершённые чаты не считай бесполезными; при оценочном критерии уточни список до действий.

## Когда открывать документы

- Поведение: раздел [ГДД](docs/GDD.md) по задаче; при изменении обнови его и сценарий в `docs/TESTING.md`.
- Модель, симуляция, геометрия, представление, сохранения: [инварианты](PROJECT_RULES.md#инварианты-обоев).
- Неизвестная точка входа или несколько подсистем: [карта проекта](docs/map.md).
- Панель: [техническая инструкция](docs/ADMIN_PANEL.md); запуск или пользовательское поведение — [README панели](tools/local-panel/README.md).
- Trello: [правила карточек](docs/WORKFLOW.md#trello); меняй только карточку текущей задачи.
- Сборка EXE: [хранение сборок](docs/WORKFLOW.md#хранение-exe-сборок).

## Точки входа и проверки

Вход обоев: `project.godot` → `scenes/wallpaper.tscn` → `scripts/application/wallpaper.gd`.

| Задача | Код | Ближайшая проверка |
|---|---|---|
| Доставка, подъёмник, ряд | `scripts/simulation/`, `scripts/domain/game_state.gd` | `first-lift`, `row-end` |
| Сохранения | `scripts/application/save_service.gd` | `transfer-resume`, `tests/construction_save_resume.gd` |
| Чертёж, размеры блоков | `scripts/domain/blueprint.gd` | `tests/blueprint_large_blocks.gd`, `tests/blueprint_mixed_domain.gd` |
| Положение груза на волокуше | `scripts/presentation/world_presenter.gd`, `tests/sled_cargo.gd` | `tests/sled_cargo_layout.gd`: `--headless --path . --script res://tests/sled_cargo_layout.gd` |
| Панель, сброс, скорость стройки | `tools/local-panel/`, `scripts/application/panel_settings.gd`, вход обоев | `tests/panel_reload.gd` с `PIRAMIDA_PANEL_TEST=1`; сервер: `node --check tools/local-panel/server.cjs` |
| Трей, Explorer, экспорт | `tools/windows-wallpaper/DesktopExtension.cpp` и `build.ps1` рядом | `tools/windows-wallpaper/tray-probe.ps1`; ресурсы панели в EXE: `--headless -- --verify-panel-resources` |

Именованные сценарии запускай из корня: `pwsh -NoProfile -File .\tools\test-scenario.ps1 <имя> -Summary`. Леса, склады, небо и остальные проверки — [выбор проверки](docs/TESTING.md#выбор-проверки); команды — [запуск](docs/TESTING.md#запуск).

- Только документация: проверь ссылки и `git diff --check`; игровые прогоны не нужны.
- Завершение стройки: `completion`. Общая симуляция, сохранения или экспорт: адресные сценарии, затем `tests/wallpaper_cycles.gd`; свежий EXE: `--headless -- --verify-wallpaper-cycles`. Команды — [приёмка](docs/ACCEPTANCE.md#автоматические-проверки). Короткий финал не заменяет два полных цикла с паузами по 5 с.
- Тесты с записью запускай с отдельным `APPDATA` или изоляцией раннера; не затрагивай рабочий профиль. В отчёте укажи команду, фактический результат, таймауты и непроверенное.
- Перед запуском или передачей пользователю временного GDScript-скрипта проверь его из корня проекта: `& .\Godot_v4.7.2-stable_win64_console.exe --headless --path . --script $script --check-only`, где `$script` — путь к скрипту. Если Godot сообщает ошибки разбора или типизации, исправь их и повтори проверку. Успешная проверка подтверждает разбор скрипта. Для проверки поведения запусти его отдельно.
- Внешний вид проверяй в открытом Godot: `Godot_v4.7.2-stable_win64.exe` из корня с этим проектом. Видимые правки обоев, панели, трея проверяй также в актуальной запущенной сборке, если возможно. Headless и исходник не подтверждают внешний вид.
- Если MCP или раннер не нашли Godot, перед повтором проверь путь из [приёмки](docs/ACCEPTANCE.md#как-найти-godot). Для раннера укажи `-Godot` с полным путём к консольному EXE. При неудаче сообщи проверенные пути или точную ошибку. Windows-сцена — [приёмка](docs/ACCEPTANCE.md#живые-обои-windows-x64) по задаче.

## Графика или расчёт через обычный ChatGPT

Если пользователь выбрал этот маршрут для работы без доступа к проекту, подготовь ТЗ: графика — назначение, референс, размер, формат, прозрачность, опорная точка; расчёт — данные с единицами, ограничения, допущения. Продолжай независимую работу. Решения по коду, реализация, интеграция, импорт и настройка Godot остаются в репозитории. Сверь результат с ТЗ и кодом; числа подтверди воспроизводимым расчётом на данных проекта.

Блок ниже применяется при работе с Godot.

<!-- BEGIN:godot-mcp -->
## Godot (managed by godot-mcp; edit outside these markers)

- This is a Godot 4.7 project. Your training data may be older: use Godot 4 APIs and GDScript 2.0 syntax, never Godot 3.
- Use the `godot_*` MCP tools. Start with `godot_status`, then `godot_project_info` for the main scene, autoloads and input actions.
- Change scenes with the scene/node tools, not by hand-editing `.tscn` text. If the editor is open, edits there are undoable; save with `godot_scene_save`.
- Don't edit `.godot/` (generated cache). Keep `*.uid` and `*.import` files next to their resources when moving files.
- Check your work: `godot_run_start` (mode "process"), then `godot_run_output` with level "error".
- Лаунчер Godot лежит в корневой папке проекта.
<!-- END:godot-mcp -->
