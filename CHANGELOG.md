# Changelog

## v0.1.1

- New version tag

## v0.1.0

Initial release.

- RFC draft for `X-Compression` READY property and `ZDICT` command frame.
- `OMQ::RFC::Zstd::Compression` with `.none`, `.with_dictionary`, `.auto`.
- Transparent `CompressionConnection` wrapper installed after handshake.
- Per-direction compression negotiation (RFC §7.3).
- Auto-trained dictionaries shipped over a single `ZDICT` command frame.
- Integration tests against a real OMQ socket pair.
- RFC §6.5 byte-bomb prevention: on the recv path, the decoder is handed
  the remaining `max_message_size` budget and rejects a compressed frame
  whose declared `Frame_Content_Size` exceeds the cap before any output
  allocation. Frames omitting `Frame_Content_Size` are rejected outright
  (`MissingContentSizeError`). The budget is tracked per multipart
  running total across parts. Both violations drop the connection (they
  inherit from `Protocol::ZMTP::Error`). Requires rzstd >= 0.2.0.
- `Compression#decompress` now accepts `max_output_size:`; the bound
  check and decode happen in a single Rust call via rzstd's bounded
  decompression API.
- `:dict_auto` mode caps training samples at 1 KiB each
  (`AUTO_DICT_MAX_SAMPLE_LEN`): large frames dilute the trained
  dictionary and blow the sample budget on a handful of messages.
- **Passive sender mode (RFC Sec. 6.4).** All Compression factory
  methods (`.none`, `.with_dictionary`, `.auto`) now take a
  `passive:` keyword. A passive sender advertises its profile and
  decompresses incoming frames normally, but emits every outgoing
  frame with the uncompressed sentinel and never invokes the
  encoder. `#min_compress_bytes` returns `Float::INFINITY` in this
  mode, so `Codec.encode_part` falls through to the
  SENTINEL_UNCOMPRESSED path for every outgoing part. Passive
  senders also suppress auto-dict sample collection and ZDICT
  emission. Used by omq-cli to decompress-by-default on
  receive-capable sockets without forcing compression on peers that
  didn't opt in.
