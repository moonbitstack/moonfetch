#!/usr/bin/env python3
"""An HTTP/3 server for the live cases of moonfetch, on aioquic.

A second implementation to run the client against, at a version pinned by the workflow. Its
replies are written as one DATA frame whatever their size, so a client that cannot take a frame
as it arrives cannot have the 8 MiB body.

    python3 server.py --cert certs/cert.pem --key certs/key.pem --port 4433

The routes are the ones the repository's own integration server serves:

    /       "hello over h3\\n"
    /away   302 to /
    /big    8 MiB of a repeating pattern
    /echo   {"method": ..., "path": ..., "size": ...}
"""

import argparse
import asyncio
import json
import ssl
from email.utils import formatdate
from typing import Dict

from aioquic.asyncio import serve
from aioquic.asyncio.protocol import QuicConnectionProtocol
from aioquic.h3.connection import H3_ALPN, H3Connection
from aioquic.h3.events import DataReceived, HeadersReceived, H3Event
from aioquic.quic.configuration import QuicConfiguration
from aioquic.quic.events import QuicEvent

BIG = 8 * 1024 * 1024
PATTERN = bytes(range(256)) * 4


class H3Server(QuicConnectionProtocol):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._http = H3Connection(self._quic)
        self._heads: Dict[int, list] = {}
        self._bodies: Dict[int, bytearray] = {}
        self._paths: Dict[int, str] = {}

    def quic_event_received(self, event: QuicEvent) -> None:
        for http_event in self._http.handle_event(event):
            self.http_event_received(http_event)

    def http_event_received(self, event: H3Event) -> None:
        if isinstance(event, HeadersReceived):
            self._heads[event.stream_id] = event.headers
            self._paths[event.stream_id] = dict(event.headers).get(b":path", b"/").decode()
            self._bodies[event.stream_id] = bytearray()
            if event.stream_ended:
                self._answer(event.stream_id)
        elif isinstance(event, DataReceived):
            self._bodies[event.stream_id].extend(event.data)
            if event.stream_ended:
                self._answer(event.stream_id)

    def _send(self, stream_id: int, status: int, headers: list, body: bytes) -> None:
        self._http.send_headers(
            stream_id=stream_id,
            headers=[
                (b":status", str(status).encode()),
                (b"content-length", str(len(body)).encode()),
                (b"date", formatdate(usegmt=True).encode()),
            ]
            + headers,
        )
        # The whole body in one call: aioquic splits what the window will not take yet and
        # sends the rest as MAX_STREAM_DATA arrives, which is what the test is about.
        self._http.send_data(stream_id=stream_id, data=body, end_stream=True)
        self.transmit()

    def _answer(self, stream_id: int) -> None:
        path = self._paths.get(stream_id, "/")
        method = dict(self._heads[stream_id]).get(b":method", b"GET").decode()
        if path == "/":
            self._send(stream_id, 200, [(b"content-type", b"text/plain")], b"hello over h3\n")
        elif path == "/away":
            self._http.send_headers(
                stream_id=stream_id,
                headers=[(b":status", b"302"), (b"location", b"/")],
            )
            self._http.send_data(stream_id=stream_id, data=b"", end_stream=True)
            self.transmit()
        elif path == "/big":
            body = (PATTERN * ((BIG // len(PATTERN)) + 1))[:BIG]
            self._send(
                stream_id, 200, [(b"content-type", b"application/octet-stream")], body
            )
        else:
            line = json.dumps(
                {"method": method, "path": path, "size": len(self._bodies[stream_id])}
            ).encode()
            self._send(stream_id, 200, [(b"content-type", b"application/json")], line)


async def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="::")
    parser.add_argument("--port", type=int, default=4433)
    parser.add_argument("--cert", required=True)
    parser.add_argument("--key", required=True)
    args = parser.parse_args()

    config = QuicConfiguration(is_client=False, alpn_protocols=H3_ALPN)
    config.load_cert_chain(args.cert, args.key)
    await serve(
        args.host,
        args.port,
        configuration=config,
        create_protocol=H3Server,
        stream_handler=None,
    )
    print(f"serving HTTP/3 on {args.host}:{args.port}", flush=True)
    await asyncio.Future()


if __name__ == "__main__":
    asyncio.run(main())
