# moonfetch

An HTTP client: `requests` to write, `aiohttp` to run, one spelling for both.

> **Status: planned.** The repository is set up; nothing is
> implemented yet.

The same call, written once:

```moonbit
@moonfetch.get("https://example.test/users")          // synchronous
@moonfetch.get_async("https://example.test/users")    // the same parameters
```

| Decided | Why |
|:--|:--|
| Same names, same parameters | The async call differs by its suffix and nothing else |
| One `Body` type | `data=` and `json=` are one parameter, not two that contradict |
| No `verify=false` | Turning verification off is not a convenience; a caller who needs another trust root passes one |
| Browser and native | On js it is the host's `fetch`; on native it is a socket |

## Install

```bash
moon add moonbitstack/moonfetch
```

## Licence

Apache-2.0. See [LICENSE](LICENSE).
