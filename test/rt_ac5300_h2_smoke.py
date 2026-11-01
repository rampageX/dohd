#!/usr/bin/env python3
"""Native CI smoke test for the RT-AC5300 HTTP/2 callback fix.

Run as root because the old dohd CLI hardcodes upstream DNS port 53.
No Internet DNS service is used: a local UDP stub returns example.com's A RR.
"""

import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import threading
import time


DNS_QUERY = bytes.fromhex("123401000001000000000000") + b"\x07example\x03com\x00\x00\x01\x00\x01"
DNS_ANSWER = bytes.fromhex("c00c000100010000003c00045db8d822")


def serve_dns(sock, stop):
    sock.settimeout(0.25)
    while not stop.is_set():
        try:
            request, peer = sock.recvfrom(2048)
        except socket.timeout:
            continue
        if len(request) < 12:
            continue
        reply = request[:2] + bytes.fromhex("8180") + request[4:6] + bytes.fromhex("000100000000")
        reply += request[12:] + DNS_ANSWER
        sock.sendto(reply, peer)


def main():
    if os.geteuid() != 0:
        raise SystemExit("Run as root to bind the local DNS stub to port 53")

    root = Path(__file__).resolve().parent.parent
    dns = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    dns.bind(("127.0.0.1", 53))
    stop = threading.Event()
    thread = threading.Thread(target=serve_dns, args=(dns, stop), daemon=True)
    thread.start()

    try:
        with tempfile.TemporaryDirectory(prefix="dohd-h2-smoke-") as temp:
            work = Path(temp)
            # dohd drops to nobody before loading its TLS key.
            work.chmod(0o755)
            cert, key = work / "server.crt", work / "server.key"
            subprocess.run(
                ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                 "-days", "1", "-subj", "/CN=localhost", "-keyout", str(key),
                 "-out", str(cert)],
                check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
            key.chmod(0o644)
            query_path, answer_path = work / "query.bin", work / "answer.bin"
            query_path.write_bytes(DNS_QUERY)
            log_path = work / "dohd.log"

            with log_path.open("w+") as log:
                server = subprocess.Popen(
                    [str(root / "src" / "dohd"), "-c", str(cert), "-k", str(key),
                     "-d", "127.0.0.1", "-p", "18553", "-u", "nobody", "-F"],
                    stdout=log, stderr=subprocess.STDOUT,
                )
                try:
                    time.sleep(1)
                    if server.poll() is not None:
                        raise AssertionError("dohd stopped during startup")
                    for attempt in range(5):
                        result = subprocess.run(
                            ["curl", "--http2", "-k", "-sS", "--max-time", "5",
                             "-H", "content-type: application/dns-message",
                             "--data-binary", "@" + str(query_path),
                             "-o", str(answer_path), "-w", "%{http_code} %{http_version}",
                             "https://127.0.0.1:18553/dns-query"],
                            capture_output=True, text=True,
                        )
                        assert result.returncode == 0, (attempt, result.stderr)
                        assert result.stdout.strip() == "200 2", result.stdout
                        answer = answer_path.read_bytes()
                        assert answer[:2] == DNS_QUERY[:2] and answer.endswith(DNS_ANSWER), answer.hex()
                    # A malformed stream can be torn down after its request
                    # slot has already been released. The old close callback
                    # returned -1 for that ordinary lifecycle transition.
                    subprocess.run(
                        ["curl", "--http2", "-k", "-sS", "--max-time", "2",
                         "https://127.0.0.1:18553/invalid-dns-request"],
                        capture_output=True, text=True,
                    )
                    time.sleep(0.25)
                    assert server.poll() is None, "dohd crashed during valid DoH requests"
                    print("PASS: 5 HTTPS/2 POST requests and malformed stream cleanup")
                finally:
                    server.send_signal(signal.SIGTERM)
                    try:
                        server.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        server.kill()
                        server.wait()
                log.flush()
                errors = log_path.read_text(errors="replace")
                if "NGHTTP2" in errors and ("callback function failed" in errors or "(-902)" in errors):
                    raise AssertionError("nghttp2 callback failure in server log:\n" + errors)
                print("PASS: no nghttp2 callback failures in server log")
    finally:
        stop.set()
        dns.close()
        thread.join(timeout=1)


if __name__ == "__main__":
    main()
