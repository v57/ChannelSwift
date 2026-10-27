#!/usr/bin/env python3
"""ChannelSwift's SocketWebSocketTests: a TCP forwarder for testing WebSocket clients: listen PORT, forward to UPSTREAM_PORT on 127.0.0.1.
--tls CERT KEY terminates TLS on the listening side; --bad-accept rewrites the server's Sec-WebSocket-Accept."""
import socket, ssl, sys, threading

args = sys.argv[1:]
port, upstream = int(args[0]), int(args[1])
tls = None
bad_accept = "--bad-accept" in args
if "--tls" in args:
    i = args.index("--tls")
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.load_cert_chain(args[i + 1], args[i + 2])

def pump(src, dst, rewrite=False):
    try:
        first = True
        while True:
            data = src.recv(65536)
            if not data:
                break
            index = data.lower().find(b"sec-websocket-accept:")
            if rewrite and first and index >= 0:
                head, rest = data[:index], data[index + len(b"sec-websocket-accept:"):]
                value, _, tail = rest.partition(b"\r\n")
                data = head + b"Sec-WebSocket-Accept: AAAAAAAAAAAAAAAAAAAAAAAAAAA=\r\n" + tail
                first = False
            dst.sendall(data)
    except OSError:
        pass
    finally:
        for s in (src, dst):
            try: s.shutdown(socket.SHUT_RDWR)
            except OSError: pass

def serve(client):
    try:
        if tls:
            client = tls.wrap_socket(client, server_side=True)
    except (ssl.SSLError, OSError) as error:
        print("tls handshake failed:", error, flush=True)
        client.close()
        return
    server = socket.create_connection(("127.0.0.1", upstream))
    threading.Thread(target=pump, args=(client, server), daemon=True).start()
    pump(server, client, rewrite=bad_accept)

listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
listener.bind(("127.0.0.1", port))
listener.listen(16)
print("listening", port, "->", upstream, "tls" if tls else "plain", "bad-accept" if bad_accept else "", flush=True)
while True:
    connection, _ = listener.accept()
    threading.Thread(target=serve, args=(connection,), daemon=True).start()
