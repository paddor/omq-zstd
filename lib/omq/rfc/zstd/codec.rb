# frozen_string_literal: true

require "rzstd"
require_relative "constants"

module OMQ
  module RFC
    module Zstd
      # Pure-function frame-body codec. Implements the sender/receiver rules
      # from RFC sections 6.4 and 6.5. Stateless: all state (dictionary,
      # profile, max_message_size) is passed in explicitly. Has no dependency
      # on Protocol::ZMTP::Connection, so this module is unit-testable in
      # isolation.
      module Codec
        module_function

        # Sender rule (RFC 6.4). Returns the bytes to place in the ZMTP
        # message-frame body.
        #
        # @param plaintext [String] frame payload as supplied by the user
        # @param compression [OMQ::RFC::Zstd::Compression] the negotiated
        #   send-direction compression object, or nil if no profile is active
        # @return [String] frame body bytes (always binary)
        def encode_part(plaintext, compression)
          plaintext = plaintext.b unless plaintext.encoding == Encoding::BINARY

          return plaintext if compression.nil?

          size = plaintext.bytesize
          if size < compression.min_compress_bytes
            return SENTINEL_UNCOMPRESSED + plaintext
          end

          compressed = compression.compress(plaintext)
          if compressed.bytesize >= size - SENTINEL_SIZE
            SENTINEL_UNCOMPRESSED + plaintext
          else
            compressed
          end
        end


        # Receiver rule (RFC 6.5). Returns the plaintext bytes for the user,
        # or raises on protocol violation.
        #
        # The +budget_remaining+ argument, when non-nil, is the running
        # remainder of +max_message_size+ left for the current multipart
        # message. The RFC-mandated header checks (Frame_Content_Size
        # present; declared size ≤ budget) happen inside the Rust
        # extension in a single call that either returns the plaintext
        # or raises before any decoder allocation.
        #
        # @param body [String] wire frame body bytes
        # @param compression [OMQ::RFC::Zstd::Compression] the negotiated
        #   recv-direction compression object, or nil if no profile is active
        # @param budget_remaining [Integer, nil] remaining decompressed-byte
        #   budget for this multipart message; nil disables the cap
        # @return [String] plaintext bytes
        def decode_part(body, compression, budget_remaining: nil)
          return body if compression.nil?

          if body.bytesize < SENTINEL_SIZE
            raise ShortFrameError, "ZMTP-Zstd: short frame"
          end

          sentinel = body.byteslice(0, SENTINEL_SIZE)

          case sentinel
          when SENTINEL_UNCOMPRESSED
            plaintext = body.byteslice(SENTINEL_SIZE, body.bytesize - SENTINEL_SIZE)
            enforce_budget!(plaintext.bytesize, budget_remaining)
            plaintext
          when SENTINEL_ZSTD_FRAME
            begin
              compression.decompress(body, max_output_size: budget_remaining)
            rescue RZstd::MissingContentSizeError => e
              raise MissingContentSizeError, "ZMTP-Zstd: missing content size: #{e.message}"
            rescue RZstd::OutputSizeLimitError => e
              raise DecompressedSizeExceedsMaxError,
                    "ZMTP-Zstd: decompressed message size exceeds maximum: #{e.message}"
            end
          else
            raise UnknownSentinelError,
                  "ZMTP-Zstd: unknown sentinel #{sentinel.unpack1('H*')}"
          end
        end


        def enforce_budget!(size, budget_remaining)
          return if budget_remaining.nil?
          return if size <= budget_remaining
          raise DecompressedSizeExceedsMaxError,
                "ZMTP-Zstd: decompressed message size exceeds maximum"
        end
      end
    end
  end
end
