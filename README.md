<p align="center">
  <img src="assets/logo-heart.png" width="400" alt="SculkHeart logo">
</p>

<h1 align="center">SculkHeart</h1>

<p align="center">
  Minecraft Java server in Zig. 1.21.11, flat world, no JVM.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/zig-0.13-orange" alt="zig">
  <img src="https://img.shields.io/badge/minecraft-1.21.11-green" alt="minecraft">
  <img src="https://img.shields.io/badge/protocol-774-blue" alt="protocol">
  <img src="https://img.shields.io/badge/license-MIT-lightgrey" alt="license">
</p>

## What this is

SculkHeart is a from-scratch Minecraft Java Edition server written in Zig. No Java, single binary, plain TCP + thread per client.

Current state: you can ping it, log in (offline or Mojang auth), walk around a flat world and stay connected. That is it. No chat, no commands, no inventory, no mobs. See Roadmap below.

## Status

| Area | State |
|---|---|
| Status ping, MOTD | works |
| Login offline (UUID v3) | works |
| Login online (RSA-2048, AES-CFB8, Mojang session) | works |
| Configuration (known packs, 19 registries, tags, finish) | works |
| Play (login, chunks, teleport, keep-alive) | works, flat 13x13 only |
| Packet compression (zlib) | wired, off by default |
| Chat, commands | not started |
| Inventory, blocks, entities | not started |
| World save (Anvil) | not started |

Version gate is strict: only 1.21.11 (protocol 774) gets past handshake.

## Quick start

Requires Zig 0.13 and Python 3 (for integration tests only).

```bash
zig build -Doptimize=ReleaseFast
./zig-out/bin/server
```

The server listens on `0.0.0.0:3222`. First run creates `server.toml` with defaults.

Cold start check:

```bash
./zig-out/bin/server --benchmark-start
# Server started on 0.0.0.0:3222 in 0.21 ms
```

## Config

`server.toml` is created on first run. The fields:

```toml
[server]
port = 3222
host = "0.0.0.0"
online_mode = false
max_players = 20
motd = "SculkHeart 1.21.11"
view_distance = 8

[world]
spawn_x = 0.5
spawn_y = -59.0
spawn_z = 0.5
gamemode = "creative"
```

Invalid values fall back to defaults with a warning in the log. `online_mode = true` enables Mojang auth and generates `server_rsa.key` (0600) next to the binary. The key is gitignored, do not commit it.

## Tests

```bash
zig build test
python3 tests/test_ping.py
python3 tests/test_e2e_client.py
```

`test_ping.py` covers Server List Ping. `test_e2e_client.py` runs two full logins against a live server: offline on 3222 and online (mock Mojang) on 3225, through configuration into play including keep-alive.

## Layout

```
src/
  main.zig          accept loop, per-client threads
  net/server.zig    Client, connection state, send path
  protocol/         VarInt/String/UUID, PacketWriter, zlib
  handlers/         status, login, configuration, play
  world/chunk.zig   flat chunk builder, heightmaps
  nbt/              tag tree, parser, serializer, SNBT
  crypto/           RSA-2048, CFB8, Mojang hash
  config/           TOML subset parser, validation
tests/              ping + headless client
```

NBT exists as a general library but chunk building still writes most section data by hand. That is next to clean up.

## Roadmap

1. Chat + `/stop`, `/gamemode`, `/tp`
2. Block place/break + inventory basics
3. Health, hunger, respawn
4. Anvil save/load, `level.dat`
5. Real terrain (noise) behind a flag
6. Redstone, fluids
7. Plugin API (after the core stops changing)

## License

MIT, see `LICENSE`.
