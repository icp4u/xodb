"""Owned loopback peer for tests/network-evidence.py (runs under xodb).

Connects TCP to the harness, exchanges ping/pong, sends one datagram from a
connected UDP socket and reports its endpoints (before the capture starts);
when the go file appears it exchanges a second ping/pong and datagram on the
same sockets (inside the capture), then holds both sockets open until the
stop file appears. Loopback only; no other traffic.
"""
import json, os, socket, sys, time
tcp_port, udp_port, ready, go, stop = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5]
t = socket.create_connection(('127.0.0.1', tcp_port))
t.sendall(b'ping')
assert t.recv(4) == b'pong'
u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
u.connect(('127.0.0.1', udp_port))
u.send(b'datagram')
info = dict(pid=os.getpid(), tcp=t.getsockname()[1], udp=u.getsockname()[1])
with open(ready + '.tmp', 'w') as f: json.dump(info, f)
os.rename(ready + '.tmp', ready)
deadline = time.monotonic() + 60
while not os.path.exists(go) and time.monotonic() < deadline: time.sleep(.01)
t.sendall(b'ping')
assert t.recv(4) == b'pong'
u.send(b'datagram')
while not os.path.exists(stop) and time.monotonic() < deadline: time.sleep(.01)
t.close(); u.close()
