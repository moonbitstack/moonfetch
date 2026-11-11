# aioquic, for the live cases

The HTTP/3 server the workflow `http3-aioquic` runs: a second implementation of the protocol for
the client to meet, at the version the workflow pins.

    python3 -m venv /tmp/aioquic
    /tmp/aioquic/bin/pip install aioquic==1.3.0
    /tmp/aioquic/bin/python integration/aioquic/server.py \
      --cert integration/h3-server/certs/cert.pem \
      --key integration/h3-server/certs/key.pem

It answers on `::`, port 4433, under the fixture certificate, so the cases run against it are
the ones the other servers answer. It is not part of the library and no module imports it.
