# moonfetch h3 server

A server over HTTP/1.1, HTTP/2 and HTTP/3 on one port number, for the live cases of
`moonfetch`. It is a separate module so that the library's own dependencies stay the ones a
reader needs.

```bash
moon run integration/h3-server --target native
MOONFETCH_H3=https://127.0.0.1:12000 moon test --target native
```

The certificate under `certs/` is written by `scripts/gen_certs.py` and signed by the root
`src/fixtures_test.mbt` holds, so a test trusts it by trusting the fixture root.
