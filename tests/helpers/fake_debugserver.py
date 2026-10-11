"""A loopback stub that replays a recorded debugserver session.

The transcript is a list of [request, [replies]]. Run-control requests must
arrive in recorded order; between two of them the target is stopped, so reads
are answered from that stretch in any order. Anything else is remembered in
`unexpected` and gets the protocol's empty "unsupported" reply. `mutate` lets a
test replace replies with hostile ones: text is framed, bytes are sent raw.
"""
import socket
import threading

from . import rsp


def run_control(request):
    return request == '\x03' or request.startswith(('vCont;', 'c', 's', 'C', 'S', 'D', 'k'))


class Fake(threading.Thread):
    def __init__(self, exchanges, mutate=None):
        super().__init__(daemon=True)
        self.exchanges, self.mutate = exchanges, mutate
        self.at, self.unexpected, self.requests, self.error = 0, [], [], None
        self.listener = socket.socket(); self.listener.bind(('127.0.0.1', 0)); self.listener.listen(1)
        self.endpoint = '127.0.0.1:%d' % self.listener.getsockname()[1]

    def lookup(self, request):
        ex, at = self.exchanges, self.at
        # Suppressing load commands changes the requested fields, not the
        # image snapshot. Older recordings can still answer the new query with
        # their recorded reduced fields; consumers explicitly handle absence.
        if request == 'jGetLoadedDynamicLibrariesInfos:{"fetch_all_solibs":true}':
            reduced = request[:-1] + ',"report_load_commands":false}'
            if any(q == reduced for q, _ in self.exchanges):
                request = reduced
        if at < len(ex) and ex[at][0] == request:
            self.at = at + 1; return ex[at][1]
        after = next((i for i in range(at, len(ex)) if run_control(ex[i][0])), len(ex))
        if run_control(request):
            if after < len(ex) and ex[after][0] == request:
                self.at = after + 1; return ex[after][1]
            return ['OK'] if request == 'D' else None  # a shortened session may detach early
        before = next((i + 1 for i in range(at - 1, -1, -1) if run_control(ex[i][0])), 0)
        later = [i for i in range(at, after) if ex[i][0] == request]
        if later:
            self.at = later[0] + 1; return ex[later[0]][1]
        earlier = [i for i in range(before, at) if ex[i][0] == request]
        if earlier: return ex[earlier[-1]][1]
        # Older launch recordings do not query images at every stop. For a
        # supplementary image read, replay the last recorded list, never a
        # future list. Dynamic-image tests supply each stop's own snapshot.
        if request.startswith('jGetLoadedDynamicLibrariesInfos:'):
            previous = [i for i in range(at) if ex[i][0] == request]
            if previous: return ex[previous[-1]][1]
        return None

    def run(self):
        try:
            self.listener.settimeout(30)
            connection, _ = self.listener.accept()
            connection.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            connection.settimeout(60)
            with connection:
                buffer, acks, sent = bytearray(), True, []
                while True:
                    data = connection.recv(65536)
                    if not data: return
                    buffer += data
                    for kind, payload in rsp.split(buffer):
                        if kind == 'nak':
                            for raw in sent: connection.sendall(raw)  # the same bytes again, as a stub would
                        if kind in ('ack', 'nak'): continue
                        request = '\x03' if kind == 'interrupt' else payload.decode('latin-1')
                        self.requests.append(request)
                        if kind == 'packet' and acks: connection.sendall(b'+')
                        replies = self.lookup(request)
                        if replies is None:
                            self.unexpected.append(request); replies = ['']
                        if self.mutate: replies = self.mutate(request, replies)
                        sent = [reply if isinstance(reply, bytes) else rsp.frame(reply.encode('latin-1')) for reply in replies]
                        for raw in sent: connection.sendall(raw)
                        if request == 'QStartNoAckMode': acks = False
        except OSError as error: self.error = error
        finally: self.listener.close()
