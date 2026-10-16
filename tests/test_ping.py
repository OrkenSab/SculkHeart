import socket
import struct
import json
import time

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
            raise EOFError("Socket closed")
        byte = b[0]
        val |= (byte & 0x7F) << shift
        if (byte & 0x80) == 0:
            break
        shift += 7
        if shift >= 35:
            raise ValueError("VarInt too big")
    return val

def send_packet(sock, packet_id, data=b""):
    payload = write_varint(packet_id) + data
    sock.sendall(write_varint(len(payload)) + payload)

def read_packet(sock):
    total_len = read_varint(sock)
    data = b""
    while len(data) < total_len:
        chunk = sock.recv(total_len - len(data))
        if not chunk:
            raise EOFError("Socket closed prematurely")
        data += chunk
    
    # parse packet id
    val = 0
    shift = 0
    idx = 0
    while True:
        byte = data[idx]
        idx += 1
        val |= (byte & 0x7F) << shift
        if (byte & 0x80) == 0:
            break
        shift += 7
    return val, data[idx:]

def test_server_list_ping():
    print("[ТЕСТ 1] Проверка Server List Ping (Handshake + Status + Ping/Pong)...")
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.connect(("127.0.0.1", 3222))

    # 1. Handshake: proto=774, host="localhost", port=3222, next_state=1 (Status)
    host_bytes = "localhost".encode("utf-8")
    handshake_payload = write_varint(774) + write_varint(len(host_bytes)) + host_bytes + struct.pack(">H", 3222) + write_varint(1)
    send_packet(s, 0x00, handshake_payload)

    # 2. Status Request (0x00)
    send_packet(s, 0x00, b"")

    # Читаем Status Response (0x00)
    pkt_id, payload = read_packet(s)
    assert pkt_id == 0x00, f"Ожидался Status Response (0x00), получен 0x{pkt_id:X}"

    # Парсим строку JSON
    json_len = 0
    shift = 0
    idx = 0
    while True:
        byte = payload[idx]
        idx += 1
        json_len |= (byte & 0x7F) << shift
        if (byte & 0x80) == 0:
            break
        shift += 7
    
    json_str = payload[idx:idx + json_len].decode("utf-8")
    status_data = json.loads(json_str)
    print(f"  [OK] Получен JSON статус: {json_str}")

    assert status_data["version"]["name"] == "1.21.11", f"Неверное имя версии: {status_data['version']['name']}"
    assert status_data["version"]["protocol"] == 774, f"Неверный номер протокола: {status_data['version']['protocol']}"
    assert "Плоский мир" in status_data["description"]["text"], "Не найдено русское описание сервера"

    # 3. Ping Request (0x01)
    timestamp = int(time.time() * 1000)
    send_packet(s, 0x01, struct.pack(">q", timestamp))

    # Читаем Pong Response (0x01)
    pkt_id, pong_payload = read_packet(s)
    assert pkt_id == 0x01, f"Ожидался Pong Response (0x01), получен 0x{pkt_id:X}"
    pong_ts = struct.unpack(">q", pong_payload)[0]
    assert pong_ts == timestamp, f"Timestamp не совпадает: {pong_ts} != {timestamp}"
    print(f"  [OK] Pong timestamp совпадает: {pong_ts}")

    s.close()
    print("[ТЕСТ 1 УСПЕШНО ЗАВЕРШЕН] Server List Ping работает безупречно.\n")

if __name__ == "__main__":
    test_server_list_ping()
