# omq-rfc-zstd

[![Gem Version](https://img.shields.io/gem/v/omq-rfc-zstd?color=e9573f)](https://rubygems.org/gems/omq-rfc-zstd)
[![License: ISC](https://img.shields.io/badge/License-ISC-blue.svg)](LICENSE)
[![Ruby](https://img.shields.io/badge/Ruby-%3E%3D%203.3-CC342D?logo=ruby&logoColor=white)](https://www.ruby-lang.org)

> **Status:** Draft. The wire format and API may change before the first tagged release.

Transparent, negotiated **Zstandard** compression for [OMQ](https://github.com/paddor/omq).
Sender and receiver advertise compression support via a ZMTP READY property
during the handshake. If both peers advertise it, message frame bodies are
compressed per-frame on the wire, optionally using a shared dictionary for
small messages.

See [RFC.md](RFC.md) for the full specification.

## Goals

- **Transparent**: existing OMQ code sees plaintext; compression happens under the socket.
- **Backwards compatible**: a peer that does not advertise compression is served plaintext. libzmq and other ZMTP 3.1 peers remain interoperable.
- **Small-message friendly**: an optional shared dictionary makes compression useful even for messages in the dozens-to-hundreds-of-bytes range. Without a dictionary, the sender skips compression for frames below 512 B.
- **Pay-per-frame**: the sender MAY skip compression on a per-frame basis. Short or incompressible frames are sent plaintext.
- **Zero-config option**: `dict:auto` trains a dictionary from the first 1000 messages (or 100 KiB, whichever hits first) and ships it via the `ZDICT` command frame.

## Non-goals

- A new socket type or a new ZMTP mechanism.
- Compression over `inproc://`. Zero-copy + compression is pure overhead.
- Compression over `ipc://`. Deferred for a future revision.
- Replacing CurveZMQ or any security layer. Compression and encryption interact in well-known dangerous ways (see RFC §Security Considerations).
- Locking the negotiation surface to Zstd. The READY property is `X-Compression`; profile strings carry an algorithm prefix (`zstd:none`, `zstd:dict:sha1:<hex>`, …) so future RFCs can add `lz4:`, `brotli:`, etc. without a new property.

## Usage (target API)

```ruby
require "omq"
require "omq/rfc/zstd"

# 1. No dictionary — opportunistic compression for frames ≥ 512 B
push = OMQ::PUSH.new
push.compression = OMQ::RFC::Zstd::Compression.none
push.connect("tcp://127.0.0.1:5555")

# 2. Caller-supplied dictionary, agreed out of band
dict = File.binread("schema.dict")
push.compression = OMQ::RFC::Zstd::Compression.with_dictionary(dict)

# 3. Caller-supplied dictionary, sent over the wire once via DICT command
push.compression = OMQ::RFC::Zstd::Compression.with_dictionary(dict, inline: true)

# 4. Auto-trained dictionary — zero config
push.compression = OMQ::RFC::Zstd::Compression.auto
```

The default level is **3**. Pass `level:` to override (negative levels enable
the fast strategy; see RFC §3.4).

## Status of the implementation

| Part | Status |
|------|--------|
| RFC  | Draft |
| Frame-format codec (encode/decode one part) | Implemented |
| `OMQ::Options` extension (`compression=`) | Implemented |
| Handshake property injection | Implemented |
| `Connection#receive_message` / send seam | Implemented |
| `DICT` command frame (`dict:inline`, `dict:auto`) | Implemented |
| Integration test (real OMQ socket pair) | Implemented |
| omq-cli integration (`-z` / `-Z` / `--compress=LEVEL`) | Implemented |

## Development

```sh
OMQ_DEV=1 bundle install
OMQ_DEV=1 bundle exec rake test
OMQ_DEV=1 bundle exec ruby --yjit bench/level_sweep.rb
```

## License

[ISC](LICENSE)
