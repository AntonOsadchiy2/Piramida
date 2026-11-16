# Архитектура Windows-обоев

Godot 4.7.2 stable · GDScript · Compatibility. Точка входа — [wallpaper.tscn](../scenes/wallpaper.tscn) и [wallpaper.gd](../scripts/application/wallpaper.gd). Мир создаётся из [wallpaper_world.tscn](../scenes/wallpaper_world.tscn). [Правила продукта](GDD.md) · [План изменений](OPTIMIZATION.md)

## Поток исполнения

1. `wallpaper.gd` копирует [базовые данные](../data/balance.json) и задаёт профилю V-образный карьер, верхний трос и вместимость 8. Экспорт Windows подключает нативную DLL для привязки к Explorer и ограничивает кадровую частоту 30 FPS.
2. [SimulationRunner](../scripts/simulation/simulation_runner.gd) выдаёт каждому работнику 0,1 с в порядке ID. [WorkerState](../scripts/domain/worker_state.gd) проходит очередь ходьбы и работы, сохраняя прогресс. Остаток бюджета может перейти к уже поставленной фазе.
3. Завершения обновляют запасы и передачи через [GameState](../scripts/domain/game_state.gd). После этого выдаются новые задания мастерской и строителю, затем транспорту и каменотёсу, затем помощнику у подъёмника. Новая работа получает время со следующего тика.
4. [WorldPresenter](../scripts/presentation/world_presenter.gd) получает состояние и события, интерполирует положения между тиками, обновляет клетки пирамиды и контур карьера. Небо получает системный UTC. Погода и время показа готовой пирамиды используют локальные интервалы. Через пять секунд после укладки 900-го кирпича заменяется сцена стройки, а текущее время суток и погода продолжаются.
5. [SaveService](../scripts/application/save_service.gd) пишет снимок обоев схемы 10 в `user://wallpaper/save.json` с SHA-256 и резервом. Начисления и покупки удалены из симуляции. Поля валюты и прежних скоростей сохранены для чтения старых снимков. Владельцы и резервы восстанавливаются из запасов и заданий. При переходе со схемы 9 обновляются пешие маршруты строителя, а для более ранних схем также маршруты карьера. Время закрытия не засчитывается в стройку.

Материал проходит карьер → волокушу → сырьевой склад → мастерскую → основание подъёмника → площадку ряда → строителя → пирамиду. На заполненном карьере используется выносной склад. На первом ряду кирпич несут по земле, а строитель может забрать его в мастерской. Все передачи централизованы в модели.

## Куда заходить по задаче

| Задача | Код | Проверка Windows-обоев |
|---|---|---|
| Добыча, буферы и рейсы | [quarry_production.gd](../scripts/simulation/quarry_production.gd), `GameState`, `WorkerState` | Полный цикл и сценарии изолированной симуляции с профилем обоев |
| Форма воронки, маршруты, леса | [quarry_slopes.gd](../scripts/domain/quarry_slopes.gd), [world_geometry.gd](../scripts/domain/world_geometry.gd), профиль `wallpaper_balance()`, [construction_production.gd](../scripts/simulation/construction_production.gd), [отрисовка наклона](../scripts/presentation/world_presenter.gd) | Сценовый тест склонов карьера, наклона пирамиды, троса и привязки к клеткам |
| Сохранение, возврат к стройке, следующий цикл | `wallpaper.gd`, [save_service.gd](../scripts/application/save_service.gd), [snapshot_values.gd](../scripts/domain/snapshot_values.gd) | Изолированный снимок обоев, миграция маршрутов из схемы 9, продолжение активного рейса из основного и резервного файлов |
| Кадры, груз, камера и декорации | `WorldPresenter`, [worker_walk.gd](../scripts/presentation/worker_walk.gd), [site_camera.gd](../scripts/presentation/site_camera.gd), [site_overseer.gd](../scripts/presentation/site_overseer.gd) | [Тест сцены](../tests/wallpaper_cycles.gd) и просмотр кадров |
| Факелы и их местный свет | [site_torches.gd](../assets/wallpaper/torches/site_torches.gd), [torch.tscn](../assets/wallpaper/torches/torch.tscn), [wallpaper.gd](../scripts/application/wallpaper.gd) | [Тест сцены](../tests/wallpaper_cycles.gd) и кадры под OpenGL днём, в сумерках и ночью |
| Светила, палитра и погода | [wallpaper_sky.gd](../scripts/presentation/wallpaper_sky.gd), [giza_sky.gd](../scripts/presentation/giza_sky.gd), `WorldPresenter`, [cloud_layer.gd](../scripts/presentation/cloud_layer.gd), [wallpaper_weather.gd](../scripts/application/wallpaper_weather.gd) | [Сверка эфемерид](../tools/check-giza-sky.gd), тест сцены, сумеречные кадры |
| EXE, Explorer, трей | Профиль Windows Wallpaper в [export_presets.cfg](../export_presets.cfg), [build.ps1](../tools/windows-wallpaper/build.ps1), [DesktopExtension.cpp](../tools/windows-wallpaper/DesktopExtension.cpp), `wallpaper.gd::_attach_desktop` | Проверка EXE и [приёмка Windows](ACCEPTANCE.md#живые-обои-windows-x64) |

## Состав проекта

- Основная сцена проекта — Windows-обои. В экспорте остался один профиль Windows Wallpaper.
- Симуляция, геометрия и сохранения используются только обоями. Старые поля валюты и множителей скорости читаются ради совместимости снимков; покупок и начислений нет.
- Основная графика лежит в `assets/wallpaper`. В `assets/sprites` и `assets/placeholders` оставлены только зависимости обоев, включая динамически загружаемые кадры.
- `tools/windows-wallpaper/build.ps1` собирает актуальный EXE с нативным адаптером C++. Старые хосты и материалы подготовки удалены.
- `.godot`, каталоги IDE и `build` — локальные артефакты, исключённые из Git. Старый мобильный проект доступен в истории Git.
