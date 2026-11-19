# Карта (пути от корня)

## Вход и код

`project.godot` → `scenes/wallpaper.tscn` → `scripts/application/wallpaper.gd` → `scenes/wallpaper_world.tscn`.

- `scripts/application/wallpaper.gd`: `wallpaper_balance`, `_start_cycle`, `_save_progress`, `_attach_desktop`; пауза перед автоматическим сбросом — `COMPLETED_DISPLAY_MSEC` и `_process`.
- `scripts/application/save_service.gd`: миграции, `load_game/save_game`; `user://wallpaper/save.json` + `.bak`.
- `scripts/simulation/simulation_runner.gd::step_simulation`: события → завершения → назначения.
- `scripts/simulation/quarry_production.gd`: добыча/носильщик.
- `scripts/simulation/construction_production.gd`: мастерская/подъёмник/помощники/строитель.
- `scripts/domain/game_state.gd`: запасы/резервы, `reserve_transfer/pick_up/deliver/cancel_transfer`, `validate`.
- `scripts/domain/worker_state.gd`: фазы/путь/работа.
- `scripts/domain/world_geometry.gd`: маршруты/клетки; `scripts/domain/quarry_slopes.gd`: склоны.
- `scripts/domain/snapshot_values.gd`: чтение снимка.
- `scripts/presentation/world_presenter.gd`: `setup/sync_state/capture_tick/render_frame/play_production`; положение груза — `_create_worker` (исходные места на волокуше) и `_sync_sled_cargo` (раскладка по размеру). Обычный груз сохраняет исходную раскладку, крупный раскладывается по ширине настила.
- `scripts/presentation/worker_walk.gd`: позы; `scripts/presentation/site_camera.gd`: кадр.
- `scripts/presentation/site_overseer.gd`: обход → `assets/wallpaper/torches/site_torches.gd::attach_to_patrol` → `assets/wallpaper/torches/torch.tscn`.
- `scripts/presentation/wallpaper_sky.gd`: переходы → `scripts/presentation/giza_sky.gd`: астрономия.
- `scripts/application/wallpaper_weather.gd`: погода → `scripts/presentation/cloud_layer.gd`: облака.

## Неочевидные связи

- `data/balance.json` переопределяется в `wallpaper_balance()`; флаги геометрии выбирают схему снимка (обои: 10).
- `world_presenter.gd::transfer_facing_snapshot` → `wallpaperTransferFacing` в снимке → `setup`: сторона волокуши при возобновлении передачи.
- `_start_cycle` заменяет мир/камеру; `_sky/_weather/_torches` живут в `wallpaper.gd`; `wallpaper_sky_area_changed` → `_reproject_sky`.
- `giza_sky.gd`: по умолчанию Гиза (звёзды); `wallpaper_sky.gd` передаёт Томск для Солнца/Луны. Каталог: `assets/wallpaper/sky/bright-stars.txt`.
- `world_presenter.gd::setup` загружает графику динамически: `assets/sprites/`, `assets/placeholders/`, `assets/wallpaper/`.
- `tools/windows-wallpaper/build.ps1` + `export_presets.cfg` → `build/Piramida.exe`; `tools/windows-wallpaper/DesktopExtension.cpp`: Explorer/трей/автозапуск. Временный `assets/wallpaper/desktop-extension.txt` встраивает DLL; `_attach_desktop` извлекает её в `user://desktop/<hash>/`.
- Локальная панель: [техническая инструкция](ADMIN_PANEL.md), [запуск и поведение](../tools/local-panel/README.md), `tools/local-panel/server.cjs` + `index.html` → JSON в `user://wallpaper/`; интеграция — `wallpaper.gd`, `panel_settings.gd`, `blueprint.gd`, команды трея — `DesktopExtension.cpp`.

## Проверки и детали

- Пауза и автоматический новый цикл: `tests/scaffold_quick_completion.gd` — малый финал; `completion` — финал стандартной стройки. Сброс текущего профиля через панель — отдельный путь: `tests/panel_reload.gd`. Команды — [выбор проверки](TESTING.md#выбор-проверки) и [запуск](TESTING.md#запуск).
- Положение груза: `tests/blueprint_scene.tscn` запускает `tests/sled_cargo.gd`; `transfer-resume` проверяет восстановление передачи. Команды — [выбор проверки](TESTING.md#выбор-проверки).
- `tests/wallpaper_cycles.gd`: сцена/снимки/миграции/небо; `-- --verify-transfer-resume`: ручная передача.
- EXE: `-- --verify-wallpaper-cycles`; оба входа изолируют снимки до `_ready`.
- `tools/check-giza-sky.gd`: эфемериды.
- `docs/ACCEPTANCE.md`: команды/APPDATA/Godot/Explorer; `docs/GDD.md`: поведение; `docs/ARCHITECTURE.md`: архитектура; `docs/OPTIMIZATION.md`: план; `docs/DECISIONS.md`: причины.
