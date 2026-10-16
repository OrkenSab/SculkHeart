import socket
import struct
import time
import os
import subprocess
import threading
import http.server
import socketserver
import zlib

try:
    from cryptography.hazmat.decrepit.ciphers.modes import CFB8
except ImportError:
    from cryptography.hazmat.primitives.ciphers.modes import CFB8
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms
from cryptography.hazmat.primitives.asymmetric import padding
from cryptography.hazmat.primitives.serialization import load_der_public_key

def write_varint(val):
    out = bytearray()
    val = val & 0xFFFFFFFF
    while True:
        if (val & ~0x7F) == 0:
            out.append(val)
            break
        out.append((val & 0x7F) | 0x80)
        val >>= 7
    return bytes(out)

def read_varint(sock):
    val = 0
    shift = 0
    while True:
        b = sock.recv(1)
        if not b:
            raise ConnectionResetError("Соединение закрыто при чтении VarInt")
        byte = b[0]
        val |= (byte & 0x7F) << shift
        if (byte & 0x80) == 0:
            break
        shift += 7
        if shift >= 35:
            raise ValueError("VarInt too big")
    return val

def read_varint_from_bytes(b, idx=0):
    val = 0
    shift = 0
    while True:
        byte = b[idx]
        idx += 1
        val |= (byte & 0x7F) << shift
        if (byte & 0x80) == 0:
            break
        shift += 7
    return val, idx

def send_packet(sock, packet_id, data=b"", compression_threshold=-1):
    uncompressed = write_varint(packet_id) + data
    if compression_threshold >= 0:
        if len(uncompressed) >= compression_threshold:
            compressed = zlib.compress(uncompressed)
            data_len = write_varint(len(uncompressed))
            total_len = write_varint(len(data_len) + len(compressed))
            sock.sendall(total_len + data_len + compressed)
        else:
            data_len = write_varint(0)
            total_len = write_varint(len(data_len) + len(uncompressed))
            sock.sendall(total_len + data_len + uncompressed)
    else:
        total_len = write_varint(len(uncompressed))
        sock.sendall(total_len + uncompressed)

def read_packet(sock, compression_threshold=-1):
    total_len = read_varint(sock)
    data = b""
    while len(data) < total_len:
        chunk = sock.recv(total_len - len(data))
        if not chunk:
            raise ConnectionResetError("Соединение закрыто при чтении пакета")
        data += chunk

    if compression_threshold >= 0:
        data_len, idx = read_varint_from_bytes(data, 0)
        remaining = data[idx:]
        if data_len == 0:
            pkt_id, p_offset = read_varint_from_bytes(remaining, 0)
            return pkt_id, remaining[p_offset:]
        else:
            decompressed = zlib.decompress(remaining)
            pkt_id, p_offset = read_varint_from_bytes(decompressed, 0)
            return pkt_id, decompressed[p_offset:]
    else:
        pkt_id, idx = read_varint_from_bytes(data, 0)
        return pkt_id, data[idx:]

def read_string(data, idx=0):
    val = 0
    shift = 0
    while True:
        byte = data[idx]
        idx += 1
        val |= (byte & 0x7F) << shift
        if (byte & 0x80) == 0:
            break
        shift += 7
    s = data[idx:idx + val].decode("utf-8")
    return s, idx + val

class EncryptedSocket:
    """Обертка над сокетом с симметричным шифрованием AES-128-CFB8 в обе стороны."""
    def __init__(self, sock, shared_secret):
        self.sock = sock
        cipher_enc = Cipher(algorithms.AES(shared_secret), CFB8(shared_secret))
        self.encryptor = cipher_enc.encryptor()
        cipher_dec = Cipher(algorithms.AES(shared_secret), CFB8(shared_secret))
        self.decryptor = cipher_dec.decryptor()

    def sendall(self, data):
        encrypted = self.encryptor.update(data)
        self.sock.sendall(encrypted)

    def recv(self, bufsize):
        raw = self.sock.recv(bufsize)
        if not raw:
            return b""
        return self.decryptor.update(raw)

    def settimeout(self, t):
        self.sock.settimeout(t)

    def close(self):
        self.sock.close()

def run_common_configuration_and_play(sock_or_enc, player_name, compression_threshold=-1):
    # ==================== CONFIGURATION ====================
    pkt_id, payload = read_packet(sock_or_enc, compression_threshold)
    assert pkt_id == 0x0E, f"Ожидался Select Known Packs (0x0E), получен 0x{pkt_id:X}"
    print(f"  [OK] Получен Select Known Packs от сервера (размер: {len(payload)} байт)")

    print("  -> Отправка ответа Select Known Packs (0x07)...")
    core_pack_resp = write_varint(1) + write_varint(9) + b"minecraft" + write_varint(4) + b"core" + write_varint(7) + b"1.21.11"
    send_packet(sock_or_enc, 0x07, core_pack_resp, compression_threshold)

    finish_config_received = False
    registry_count = 0
    tags_received = False

    while not finish_config_received:
        pkt_id, payload = read_packet(sock_or_enc, compression_threshold)
        if pkt_id == 0x07:
            registry_count += 1
            reg_name, _ = read_string(payload, 0)
        elif pkt_id == 0x0D:
            tags_received = True
            print("    - Получены теги сервера (Update Tags)")
        elif pkt_id == 0x03:
            finish_config_received = True
            print(f"  [OK] Синхронизировано {registry_count} реестров, получен Finish Configuration (0x03)")
        else:
            pass

    assert registry_count >= 5, f"Ожидалось не менее 5 синхронизируемых реестров, получено {registry_count}"
    assert tags_received, "Не был получен пакет Update Tags"

    print("  -> Отправка Acknowledge Finish Configuration (0x03)...")
    send_packet(sock_or_enc, 0x03, b"", compression_threshold)

    # ==================== PLAY ====================
    print("  -> Ожидание пакетов входа в игру (Login Play, Game Event, Chunk Data, Player Position)...")
    login_play_received = False
    game_event_received = False
    chunk_data_received = False
    teleport_received = False

    while not (login_play_received and game_event_received and chunk_data_received and teleport_received):
        pkt_id, payload = read_packet(sock_or_enc, compression_threshold)
        if pkt_id == 0x30:
            login_play_received = True
            entity_id = struct.unpack(">i", payload[:4])[0]
            print(f"  [OK] Получен Login (play) 0x30: Entity ID={entity_id}")
            assert entity_id == 1
        elif pkt_id == 0x26:
            event_id = payload[0]
            val = struct.unpack(">f", payload[1:5])[0]
            if event_id == 13:
                game_event_received = True
                print(f"  [OK] Получен Game Event 13 (Start waiting for chunks, val={val})")
        elif pkt_id == 0x2C:
            chunk_data_received = True
        elif pkt_id == 0x46:
            teleport_received = True
            t_id = payload[0]
            x, y, z = struct.unpack(">ddd", payload[1:25])
            print(f"  [OK] Получены координаты спавна: Teleport ID={t_id}, X={x}, Y={y}, Z={z}")
            assert x == 0.5 and y == -59.0 and z == 0.5
            
            print("  -> Отправка Confirm Teleportation (0x00, teleport_id=1)...")
            send_packet(sock_or_enc, 0x00, write_varint(t_id), compression_threshold)
        elif pkt_id in (0x5D, 0x5C, 0x0C, 0x0B):
            pass

    print(f"  [OK] Все фазы входа пройдены, игрок '{player_name}' на блоке травы плоского мира.")

    # ==================== УДЕРЖАНИЕ СОЕДИНЕНИЯ И KEEP ALIVE ====================
    print("  -> Ожидание Keep Alive и проверка устойчивости соединения...")
    start_wait = time.time()
    keep_alive_handled = False

    while time.time() - start_wait < 12.0:
        try:
            sock_or_enc.settimeout(2.0)
            pkt_id, payload = read_packet(sock_or_enc, compression_threshold)
            if pkt_id == 0x2B:
                ka_id = struct.unpack(">q", payload)[0]
                print(f"  [OK] Получен Keep Alive (0x2B) с ID={ka_id}. Отправка ответа Keep Alive (0x1B)...")
                send_packet(sock_or_enc, 0x1B, struct.pack(">q", ka_id), compression_threshold)
                keep_alive_handled = True
                break
        except socket.timeout:
            pass

    assert keep_alive_handled, "Не был получен/обработан Keep Alive в фазе Play"
    print("  [OK] Keep Alive успешно обработан, соединение стабильно удерживается.")

def test_offline_mode():
    print("\n" + "=" * 60)
    print("[ТЕСТ 1] Режим Offline-Mode: Прямой вход без шифрования (порт 3222)")
    print("=" * 60)

    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(15.0)
    s.connect(("127.0.0.1", 3222))

    print("  -> Отправка Handshake (Protocol 774, State=2 Login)...")
    host_bytes = "localhost".encode("utf-8")
    handshake_payload = write_varint(774) + write_varint(len(host_bytes)) + host_bytes + struct.pack(">H", 3222) + write_varint(2)
    send_packet(s, 0x00, handshake_payload)

    print("  -> Отправка Login Start (Player: 'OfflinePlayer')...")
    player_name = "OfflinePlayer".encode("utf-8")
    login_start_payload = write_varint(len(player_name)) + player_name + (b"\x00" * 16)
    send_packet(s, 0x00, login_start_payload)

    pkt_id, payload = read_packet(s)
    assert pkt_id == 0x02, f"Ожидался Login Success (0x02), получен 0x{pkt_id:X}"
    uuid_bytes = payload[:16]
    name_str, _ = read_string(payload, 16)
    print(f"  [OK] Получен Login Success: Игрок={name_str}, UUID={uuid_bytes.hex()}")
    assert name_str == "OfflinePlayer"

    print("  -> Отправка Login Acknowledged (0x03)...")
    send_packet(s, 0x03, b"")

    run_common_configuration_and_play(s, "OfflinePlayer")
    s.close()
    print("[ТЕСТ 1 УСПЕШНО ЗАВЕРШЕН] Offline-Mode проверен на 100%.\n")

class MockMojangHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"id":"069a79f444e94726a5bef2a2fce1b293","name":"OnlinePlayer"}')

    def log_message(self, format, *args):
        pass

def test_online_encrypted_mode():
    print("\n" + "=" * 60)
    print("[ТЕСТ 2] Режим Online-Mode: RSA-2048 обмен ключами -> AES-128-CFB8 шифрование сокета")
    print("=" * 60)

    mock_port = 18889
    httpd = socketserver.TCPServer(("127.0.0.1", mock_port), MockMojangHandler)
    mock_thread = threading.Thread(target=httpd.serve_forever)
    mock_thread.daemon = True
    mock_thread.start()

    server_cwd = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
    server_bin = os.path.join(server_cwd, "zig-out", "bin", "server")
    online_cfg_path = os.path.join(server_cwd, "server_test_online.toml")
    online_toml = f"""[server]
port = 3225
host = "127.0.0.1"
online_mode = true
max_players = 20
motd = "Сервер на Zig 1.21.11 | Онлайн режим"
view_distance = 6
auth_url = "http://127.0.0.1:{mock_port}/hasJoined"

[world]
spawn_x = 0.5
spawn_y = -59.0
spawn_z = 0.5
gamemode = "creative"
"""
    with open(online_cfg_path, "w", encoding="utf-8") as f:
        f.write(online_toml)
    server_proc = subprocess.Popen(
        [server_bin, "--config", online_cfg_path],
        cwd=server_cwd,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    time.sleep(0.5)

    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(15.0)
        s.connect(("127.0.0.1", 3225))

        print("  -> Отправка Handshake (Protocol 774, State=2 Login)...")
        host_bytes = "localhost".encode("utf-8")
        handshake_payload = write_varint(774) + write_varint(len(host_bytes)) + host_bytes + struct.pack(">H", 3225) + write_varint(2)
        send_packet(s, 0x00, handshake_payload)

        print("  -> Отправка Login Start (Player: 'OnlinePlayer')...")
        player_name = "OnlinePlayer".encode("utf-8")
        login_start_payload = write_varint(len(player_name)) + player_name + (b"\x00" * 16)
        send_packet(s, 0x00, login_start_payload)

        pkt_id, payload = read_packet(s)
        assert pkt_id == 0x01, f"Ожидался Encryption Request (0x01), получен 0x{pkt_id:X}"
        print("  [OK] Получен Encryption Request (0x01) от сервера!")

        srv_id, offset = read_string(payload, 0)
        key_len, offset = read_varint_from_bytes(payload, offset)
        pub_key_der = payload[offset:offset + key_len]
        offset += key_len

        token_len, offset = read_varint_from_bytes(payload, offset)
        verify_token = payload[offset:offset + token_len]
        print(f"    - Размер публичного RSA ключа сервера: {len(pub_key_der)} байт")
        print(f"    - Токен верификации: {verify_token.hex()}")
        assert len(pub_key_der) == 294, "Ожидался 2048-битный RSA ключ (DER 294 байт)"

        shared_secret = os.urandom(16)
        public_key = load_der_public_key(pub_key_der)
        encrypted_secret = public_key.encrypt(shared_secret, padding.PKCS1v15())
        encrypted_token = public_key.encrypt(verify_token, padding.PKCS1v15())

        print("  -> Отправка Encryption Response (0x01)...")
        enc_resp_payload = (
            write_varint(len(encrypted_secret)) + encrypted_secret +
            write_varint(len(encrypted_token)) + encrypted_token
        )
        send_packet(s, 0x01, enc_resp_payload)

        print("  [ШИФРОВАНИЕ] Включение AES-128-CFB8 шифрования на сокете клиента...")
        enc_sock = EncryptedSocket(s, shared_secret)

        pkt_id, payload = read_packet(enc_sock)
        assert pkt_id == 0x02, f"Ожидался зашифрованный Login Success (0x02), получен 0x{pkt_id:X}"
        uuid_bytes = payload[:16]
        name_str, _ = read_string(payload, 16)
        print(f"  [OK] Успешно дешифрован Login Success (0x02): Игрок={name_str}, UUID={uuid_bytes.hex()}")
        assert name_str == "OnlinePlayer"
        assert uuid_bytes.hex() == "069a79f444e94726a5bef2a2fce1b293"

        print("  -> Отправка зашифрованного Login Acknowledged (0x03)...")
        send_packet(enc_sock, 0x03, b"")

        run_common_configuration_and_play(enc_sock, "OnlinePlayer")
        enc_sock.close()

        print("[ТЕСТ 2 УСПЕШНО ЗАВЕРШЕН] Online-Mode с шифрованием AES-128-CFB8 проверен на 100%.\n")
    finally:
        server_proc.kill()
        server_proc.wait()
        httpd.shutdown()
        if os.path.exists(online_cfg_path):
            os.remove(online_cfg_path)

def test_compression_mode():
    print("\n" + "=" * 60)
    print("[ТЕСТ 3] Режим компрессии пакетов: Set Compression (ID 0x03) -> Zlib сжатие (порог 256)")
    print("=" * 60)

    server_cwd = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
    server_bin = os.path.join(server_cwd, "zig-out", "bin", "server")
    comp_cfg_path = os.path.join(server_cwd, "server_test_compression.toml")
    comp_toml = """[server]
port = 3226
host = "127.0.0.1"
online_mode = false
max_players = 20
motd = "Сервер на Zig 1.21.11 | Компрессия пакетов"
view_distance = 4
compression_threshold = 256

[world]
spawn_x = 0.5
spawn_y = -59.0
spawn_z = 0.5
gamemode = "creative"
"""
    with open(comp_cfg_path, "w", encoding="utf-8") as f:
        f.write(comp_toml)
    server_proc = subprocess.Popen(
        [server_bin, "--config", comp_cfg_path],
        cwd=server_cwd,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    time.sleep(0.5)

    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(15.0)
        s.connect(("127.0.0.1", 3226))

        print("  -> Отправка Handshake (Protocol 774, State=2 Login)...")
        host_bytes = "localhost".encode("utf-8")
        handshake_payload = write_varint(774) + write_varint(len(host_bytes)) + host_bytes + struct.pack(">H", 3226) + write_varint(2)
        send_packet(s, 0x00, handshake_payload)

        print("  -> Отправка Login Start (Player: 'CompressCrafter')...")
        player_name = "CompressCrafter".encode("utf-8")
        login_start_payload = write_varint(len(player_name)) + player_name + (b"\x00" * 16)
        send_packet(s, 0x00, login_start_payload)

        # 1. Сначала сервер ОБЯЗАН прислать Set Compression (ID 0x03) БЕЗ сжатия
        pkt_id, payload = read_packet(s, -1)
        assert pkt_id == 0x03, f"Ожидался Set Compression (0x03), получен 0x{pkt_id:X}"
        threshold, _ = read_varint_from_bytes(payload, 0)
        print(f"  [OK] Получен пакет Set Compression (0x03) с порогом {threshold} байт!")
        assert threshold == 256

        # 2. Все последующие пакеты отправляются со сжатием
        pkt_id, payload = read_packet(s, threshold)
        assert pkt_id == 0x02, f"Ожидался сжатый Login Success (0x02), получен 0x{pkt_id:X}"
        name_str, _ = read_string(payload, 16)
        print(f"  [OK] Успешно распакован Login Success: Игрок={name_str}")

        print("  -> Отправка сжатого Login Acknowledged (0x03)...")
        send_packet(s, 0x03, b"", threshold)

        run_common_configuration_and_play(s, "CompressCrafter", threshold)
        s.close()
        print("[ТЕСТ 3 УСПЕШНО ЗАВЕРШЕН] Компрессия Zlib и Set Compression проверены на 100%.\n")
    finally:
        server_proc.kill()
        server_proc.wait()
        if os.path.exists(comp_cfg_path):
            os.remove(comp_cfg_path)

def test_version_gate():
    print("\n" + "=" * 60)
    print("[ТЕСТ 4] Версионный гейт: Отклонение несовместимого протокола 769")
    print("=" * 60)

    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(5.0)
    s.connect(("127.0.0.1", 3222))

    # Шлем несовместимый протокол 769 (Minecraft 1.21.0 вместо 774 / 1.21.11)
    print("  -> Отправка Handshake с протоколом 769...")
    host_bytes = "localhost".encode("utf-8")
    handshake_payload = write_varint(769) + write_varint(len(host_bytes)) + host_bytes + struct.pack(">H", 3222) + write_varint(2)
    send_packet(s, 0x00, handshake_payload)

    pkt_id, payload = read_packet(s, -1)
    assert pkt_id == 0x00, f"Ожидался Login Disconnect (0x00), получен 0x{pkt_id:X}"
    reason_json, _ = read_string(payload, 0)
    print(f"  [OK] Сервер отклонил несовместимого клиента с причиной: {reason_json}")
    assert "Несовместимая версия клиента" in reason_json
    s.close()
    print("[ТЕСТ 4 УСПЕШНО ЗАВЕРШЕН] Версионный гейт работает корректно.\n")

def test_username_validation():
    print("\n" + "=" * 60)
    print("[ТЕСТ 5] Валидация никнейма: отклонение пустых и некорректных имен")
    print("=" * 60)

    for invalid_name in ["", "Hi", "User@Name!", "Name With Spaces", "Toolongplayername1234"]:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(5.0)
        s.connect(("127.0.0.1", 3222))

        # Handshake
        host_bytes = "localhost".encode("utf-8")
        handshake_payload = write_varint(774) + write_varint(len(host_bytes)) + host_bytes + struct.pack(">H", 3222) + write_varint(2)
        send_packet(s, 0x00, handshake_payload)

        # Login Start with invalid name
        name_bytes = invalid_name.encode("utf-8")
        login_start_payload = write_varint(len(name_bytes)) + name_bytes + (b"\x00" * 16)
        send_packet(s, 0x00, login_start_payload)

        pkt_id, payload = read_packet(s, -1)
        assert pkt_id == 0x00, f"Имя '{invalid_name}' должно было отклониться 0x00 Disconnect, но получен 0x{pkt_id:X}"
        reason, _ = read_string(payload, 0)
        print(f"  [OK] Некорректное имя '{invalid_name}' успешно отклонено: {reason}")
        s.close()

    print("[ТЕСТ 5 УСПЕШНО ЗАВЕРШЕН] Валидация никнейма работает на 100%.\n")

if __name__ == "__main__":
    test_offline_mode()
    test_online_encrypted_mode()
    test_compression_mode()
    test_version_gate()
    test_username_validation()
