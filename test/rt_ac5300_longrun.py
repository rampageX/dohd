#!/usr/bin/env python3
"""Offline DoH TLS1.3 / HTTP2 regression; run as root for local UDP :53."""
import argparse
import base64
import concurrent.futures
import os
from pathlib import Path
import socket
import ssl
import struct
import subprocess
import tempfile
import threading
import time

from h2.config import H2Configuration
from h2.connection import H2Connection
from h2.events import DataReceived, ResponseReceived, StreamEnded, StreamReset, ConnectionTerminated

ANSWER = bytes.fromhex("c00c000100010000003c00045db8d822")

def query(idx, drop=False):
    name = b"\x04drop\x07example\x03com\0" if drop else b"\x07example\x03com\0"
    return struct.pack("!6H", idx % 65536, 0x0100, 1, 0, 0, 0) + name + b"\0\x01\0\x01"

def dns_stub(sock, stop):
    sock.settimeout(0.2)
    while not stop.is_set():
        try:
            req, peer = sock.recvfrom(4096)
        except socket.timeout:
            continue
        except OSError:
            return
        if len(req) < 17 or req[12:17] == b"\x04drop":
            continue
        response = req[:2] + bytes.fromhex("81800001000100000000") + req[12:] + ANSWER
        sock.sendto(response, peer)

class Client:
    def __init__(self, ctx, port, session=None):
        sock = socket.create_connection(("127.0.0.1", port), timeout=15)
        self.tls = ctx.wrap_socket(sock, server_hostname="localhost", session=session)
        self.tls.settimeout(20)
        assert self.tls.version() == "TLSv1.3"
        assert self.tls.selected_alpn_protocol() == "h2"
        self.h2 = H2Connection(config=H2Configuration(client_side=True, header_encoding="utf-8"))
        self.h2.initiate_connection()
        self.tls.sendall(self.h2.data_to_send())

    def batch(self, requests):
        pending = {}
        for wire, is_get, drop in requests:
            sid = self.h2.get_next_available_stream_id()
            path = "/?dns=" + base64.urlsafe_b64encode(wire).rstrip(b"=").decode() if is_get else "/dns-query"
            headers = [(":method", "GET" if is_get else "POST"), (":scheme", "https"),
                       (":authority", "localhost"), (":path", path),
                       ("accept", "application/dns-message")]
            if not is_get:
                headers += [("content-type", "application/dns-message")]
            self.h2.send_headers(sid, headers, end_stream=is_get)
            if not is_get:
                self.h2.send_data(sid, wire, end_stream=True)
            pending[sid] = [wire, drop, None, bytearray()]
        self.tls.sendall(self.h2.data_to_send())
        while pending:
            data = self.tls.recv(65536)
            assert data, "TLS EOF with outstanding requests"
            for e in self.h2.receive_data(data):
                if isinstance(e, ResponseReceived):
                    pending[e.stream_id][2] = dict(e.headers)[":status"]
                elif isinstance(e, DataReceived):
                    pending[e.stream_id][3].extend(e.data)
                    self.h2.acknowledge_received_data(e.flow_controlled_length, e.stream_id)
                elif isinstance(e, StreamEnded):
                    wire, drop, status, body = pending.pop(e.stream_id)
                    if drop:
                        assert status == "504", (status, bytes(body).hex())
                    else:
                        assert status == "200", status
                        assert body[:2] == wire[:2] and body.endswith(ANSWER), bytes(body).hex()
                elif isinstance(e, (StreamReset, ConnectionTerminated)):
                    raise AssertionError(str(e))
            more = self.h2.data_to_send()
            if more:
                self.tls.sendall(more)

    def close(self):
        self.tls.close()

def run_mode(args, cert, key, log, disabled):
    env = os.environ.copy()
    env["DOHD_DISABLE_TLS_RESUMPTION"] = "1" if disabled else "0"
    cmd = (["qemu-arm", "-cpu", "arm926"] if args.arm else []) + [
        str(Path(args.binary).resolve()), "-F", "-c", str(cert), "-k", str(key),
        "-p", str(args.port), "-d", "127.0.0.1", "-u", "nobody"]
    ctx = ssl.create_default_context(cafile=str(cert))
    ctx.minimum_version = ctx.maximum_version = ssl.TLSVersion.TLSv1_3
    ctx.set_alpn_protocols(["h2"])
    with log.open("w") as output:
        proc = subprocess.Popen(cmd, stdout=output, stderr=subprocess.STDOUT, env=env)
        try:
            time.sleep(1.2)
            assert proc.poll() is None, "daemon failed to start"
            c = Client(ctx, args.port)
            try:
                c.batch([(query(i, i % 7 == 0), i % 2 == 0, i % 7 == 0)
                         for i in range(28)])
                c.batch([(query(123), True, False), (query(124), False, False)])
                session = c.tls.session
            finally:
                c.close()
            assert not disabled or not session.has_ticket, "disabled TLS still sent a ticket"
            if not disabled:
                assert session.has_ticket, "enabled TLS did not send a ticket"
            reused = 0
            for i in range(12 if args.arm else 48):
                c = Client(ctx, args.port, session if session.has_ticket else None)
                try:
                    reused += int(c.tls.session_reused)
                    c.batch([(query(200+i), i % 2 == 0, False)])
                    session = c.tls.session
                finally:
                    c.close()
            if disabled:
                assert reused == 0, reused
            else:
                assert reused > 0, "resumption enabled but never reused"
            def worker(i):
                c = Client(ctx, args.port)
                try:
                    c.batch([(query(1000+i*8+j), j % 2 == 0, False) for j in range(8)])
                finally:
                    c.close()
            with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
                list(pool.map(worker, range(8 if args.arm else 24)))
            assert proc.poll() is None
            print(f"PASS disabled={disabled}: mixed DNS timeouts, GET/POST, reconnect, reused={reused}, concurrent connections")
        finally:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
    print(log.read_text(errors="replace")[-6000:])

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("binary")
    parser.add_argument("--arm", action="store_true")
    parser.add_argument("--port", type=int, default=18553)
    args = parser.parse_args()
    assert os.geteuid() == 0, "run with sudo for DNS port 53"
    stop = threading.Event()
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as dns:
        dns.bind(("127.0.0.1", 53))
        thread = threading.Thread(target=dns_stub, args=(dns, stop), daemon=True)
        thread.start()
        try:
            with tempfile.TemporaryDirectory(prefix="dohd-longrun-") as temp:
                work = Path(temp)
                work.chmod(0o755)
                cert, key = work / "cert.pem", work / "key.pem"
                subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048",
                    "-nodes", "-days", "1", "-subj", "/CN=localhost",
                    "-addext", "subjectAltName=DNS:localhost",
                    "-keyout", str(key), "-out", str(cert)], check=True,
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                key.chmod(0o644)
                cert.chmod(0o644)
                for disabled in (False, True):
                    log = work / f"server-{int(disabled)}.log"
                    try:
                        run_mode(args, cert, key, log, disabled)
                    except BaseException:
                        if log.exists():
                            print(log.read_text(errors="replace")[-16000:])
                        raise
        finally:
            stop.set()
            thread.join(timeout=1)

if __name__ == "__main__":
    main()
