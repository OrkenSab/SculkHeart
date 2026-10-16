# Высокопроизводительный сервер Minecraft на Zig (1.21.11, Протокол 774)

Нативное, легковесное серверное ядро Minecraft Java Edition версии **1.21.11** (Protocol 774), написанное на языке **Zig** с мгновенным холодным запуском (< 1 мс), выделенным портом **3222** и генератором плоского мира (Flat World).

## Архитектура и особенности

- **Сверхбыстрый старт**: сокет инициализируется и готов принимать подключения за **< 0.1 мс** (измерено через `--benchmark-start`).
- **Сетевая оптимизация**: принудительный флаг `TCP_NODELAY` для отключения буферизации алгоритма Нейгла, что минимизирует задержки сетевых пакетов Minecraft.
- **Управление памятью**: использование `std.heap.ArenaAllocator` на соединение со сбросом после обработки каждого пакета — отсутствие фрагментации и утечек памяти.
- **Поддержка протокола 1.21.11 (Protocol 774)**:
  - **Handshaking**: маршрутизация в Status и Login.
  - **Status (Server List Ping)**: JSON MOTD с русскоязычным описанием сервера, счетчиком игроков и Ping/Pong.
  - **Login**: офлайн-авторизация, генерация v3 UUID, `Login Success` (ID `0x02`), `Login Acknowledged` (ID `0x03`).
  - **Configuration (1.20.2+)**: синхронизация датапаков (`Select Known Packs`), передача синхронизируемых реестров (`dimension_type`, `biome`, `damage_type`, `painting_variant`, `banner_pattern`), `Update Tags`, `Finish Configuration`.
  - **Play**: отправка `Login (play)` (ID `0x32`), `Game Event 13` (ожидание чанков), генерация плоского чанка (бедрок, 3 слоя земли, блок травы), спавн игрока в Creative (`X=0.5, Y=-59.0, Z=0.5`), Keep Alive таймер (раз в 10 секунд).

## Сборка и запуск

Сборка с использованием RAM-диска (`tmpfs`) для исключения нагрузки на HDD:

```bash
# Сборка ReleaseFast
zig build -Doptimize=ReleaseFast --cache-dir /tmp/zig-cache --global-cache-dir /tmp/zig-global-cache

# Бенчмарк холодного старта
./zig-out/bin/server --benchmark-start

# Обычный запуск сервера (порт 3222)
./zig-out/bin/server
```

## Тестирование

```bash
# Юнит-тесты протокола и генератора мира
zig test src/main.zig --cache-dir /tmp/zig-cache --global-cache-dir /tmp/zig-global-cache

# Интеграционный тест Server List Ping
python3 tests/test_ping.py

# Сквозной headless-клиент тест (Handshake -> Login -> Configuration -> Play -> KeepAlive)
python3 tests/test_e2e_client.py
```
