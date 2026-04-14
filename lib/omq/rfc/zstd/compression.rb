# frozen_string_literal: true

require "digest"
require "rzstd"
require_relative "constants"

require "thread"

module OMQ
  module RFC
    module Zstd
      # User-facing configuration object. Assigned to an OMQ socket via
      # `socket.compression = OMQ::RFC::Zstd::Compression.new(...)`.
      # Encapsulates the negotiated profile, the dictionaries (per
      # direction), the compression level, and the cached SHA-1 hash
      # used in the READY property.
      #
      # Per RFC §7.3, dictionaries are per-direction: each direction
      # uses its sender's dictionary. This object holds two independent
      # dictionary slots — one for outgoing compression and one for
      # incoming decompression — that are populated independently
      # depending on the negotiated profile.
      #
      # Profiles:
      #
      #   :none         no dictionary; per-frame opportunistic compression
      #                 above MIN_COMPRESS_BYTES_NO_DICT.
      #   :dict_static  caller-supplied dictionary, agreed out of band.
      #                 Loaded into both send and recv slots (symmetric).
      #                 Profile string `zstd:dict:sha1:<hex>`.
      #   :dict_inline  caller-supplied dictionary loaded into the send
      #                 slot only and shipped to the peer via ZDICT once;
      #                 the recv slot is populated when the peer's ZDICT
      #                 arrives.
      #   :dict_auto    no dictionary at connect time; the sender trains
      #                 one socket-wide from the first AUTO_DICT_SAMPLE_COUNT
      #                 messages OR AUTO_DICT_SAMPLE_BYTES of plaintext
      #                 (whichever comes first), installs it into the send
      #                 slot, and ships it via ZDICT. The recv slot is
      #                 populated when the peer's ZDICT arrives.
      class Compression
        attr_reader :sentinel, :profile, :level, :mode, :send_dict_bytes


        def self.none(level: DEFAULT_LEVEL, passive: false)
          new mode: :none, dictionary: nil, level: level, passive: passive
        end


        def self.with_dictionary(bytes, inline: false, level: DEFAULT_LEVEL, passive: false)
          new mode: inline ? :dict_inline : :dict_static,
            dictionary: bytes,
            level:      level,
            passive:    passive
        end


        def self.auto(level: DEFAULT_LEVEL, passive: false)
          new mode: :dict_auto, dictionary: nil, level: level, passive: passive
        end


        # When +passive: true+, the socket advertises the profile and
        # decodes incoming compressed frames, but never compresses
        # outgoing messages -- #min_compress_bytes reports infinity, so
        # every outgoing part falls through to the SENTINEL_UNCOMPRESSED
        # path. Used by omq-cli to decompress-by-default without
        # forcing compression on senders that didn't opt in.
        def initialize(mode:, dictionary:, level: DEFAULT_LEVEL, passive: false)
          @mode             = mode
          @passive          = passive
          @level            = Integer(level)
          @sentinel         = SENTINEL_ZSTD_FRAME
          @send_dictionary  = nil
          @recv_dictionary  = nil
          @send_dict_bytes  = nil

          case mode
          when :none
            @profile = PROFILE_NONE
          when :dict_static
            bytes            = dictionary.b
            dict             = RZstd::Dictionary.new(bytes, level: @level)
            @send_dictionary = dict
            @recv_dictionary = dict
            @profile         = "#{PROFILE_DICT_PREFIX}#{Digest::SHA1.hexdigest(bytes)}"
          when :dict_inline
            bytes            = dictionary.b
            @send_dictionary = RZstd::Dictionary.new(bytes, level: @level)
            @send_dict_bytes = bytes
            @profile         = PROFILE_DICT_INLINE
          when :dict_auto
            @profile        = PROFILE_DICT_AUTO
            @samples        = []
            @samples_bytes  = 0
            @samples_count  = 0
            @training_done  = false
            @training_mutex = Mutex.new
          else
            raise ArgumentError, "unknown mode: #{mode.inspect}"
          end
        end


        def has_send_dictionary?
          !@send_dictionary.nil?
        end


        def has_recv_dictionary?
          !@recv_dictionary.nil?
        end


        # True if this side was configured as a passive sender
        # (RFC Sec. 6.4 "Passive senders"): advertise the profile and
        # decompress incoming frames, but never compress outgoing
        # frames. Implemented by making #min_compress_bytes return
        # infinity so every outgoing part falls through to the
        # SENTINEL_UNCOMPRESSED path in Codec.encode_part.
        def passive?
          @passive == true
        end


        def min_compress_bytes
          return Float::INFINITY if passive?
          has_send_dictionary? ? MIN_COMPRESS_BYTES_DICT : MIN_COMPRESS_BYTES_NO_DICT
        end


        def compress(plaintext)
          if @send_dictionary
            @send_dictionary.compress(plaintext)
          else
            RZstd.compress(plaintext, level: @level)
          end
        end


        # Bounded single-shot decompression. The `max_output_size:` cap is
        # enforced inside the Rust extension: the frame's Frame_Content_Size
        # header is read first, and MissingContentSizeError /
        # OutputSizeLimitError are raised before allocating the output
        # buffer or invoking the decoder.
        def decompress(compressed, max_output_size: nil)
          if @recv_dictionary
            @recv_dictionary.decompress(compressed, max_output_size: max_output_size)
          else
            RZstd.decompress(compressed, max_output_size: max_output_size)
          end
        end


        # Match this compression's advertised profile against a peer's
        # X-Compression property value (comma-separated profile list).
        # Returns the matched profile string, or nil for no match.
        def match(peer_property_value)
          return nil if peer_property_value.nil? || peer_property_value.empty?
          peer_profiles = peer_property_value.split(",").map(&:strip)
          peer_profiles.include?(@profile) ? @profile : nil
        end


        # Install a dictionary into the send slot. Used internally by
        # auto-mode after training: the trained dict is installed here
        # and the bytes stashed for shipping via ZDICT.
        def install_send_dictionary(bytes)
          @send_dict_bytes = bytes.b
          @send_dictionary = RZstd::Dictionary.new(@send_dict_bytes, level: @level)
        end


        # Install a dictionary into the recv slot. Called by the
        # CompressionConnection wrapper when a ZDICT command frame
        # arrives from the peer.
        def install_recv_dictionary(bytes)
          @recv_dictionary = RZstd::Dictionary.new(bytes.b, level: @level)
        end


        # @return [Boolean] true for :dict_auto mode
        def auto?
          @mode == :dict_auto
        end


        # @return [Boolean] true once auto-training has completed (success
        #   or give-up). After this point #add_sample is a no-op.
        def trained?
          @training_done == true
        end


        # Feeds a plaintext sample into the auto-training buffer. No-op
        # for non-auto modes, after training has finished, or for parts
        # >= AUTO_DICT_MAX_SAMPLE_LEN (large frames dilute the dict and
        # blow the sample budget on a handful of messages). Triggers
        # training synchronously when the sample-count or sample-bytes
        # threshold is reached.
        #
        # Thread-safe: multiple connections sharing this socket-wide
        # Compression may call this concurrently.
        #
        # @param plaintext [String]
        # @return [void]
        def add_sample(plaintext)
          return unless @mode == :dict_auto
          return if @passive
          return if @training_done
          return if plaintext.bytesize >= AUTO_DICT_MAX_SAMPLE_LEN

          # OMQ's Writable mixin already hands us frozen binary Strings
          # (frozen_binary + parts.freeze), so in the common case we
          # can stash the caller's reference without a `.b` copy. Only
          # coerce when the encoding/frozen invariants don't hold.
          sample = plaintext.frozen? && plaintext.encoding == Encoding::BINARY ? plaintext : plaintext.b

          @training_mutex.synchronize do
            return if @training_done
            @samples << sample
            @samples_bytes += plaintext.bytesize
            @samples_count += 1
            maybe_train!
          end
        end


        private


        def maybe_train!
          return unless @samples_count >= AUTO_DICT_SAMPLE_COUNT ||
                        @samples_bytes >= AUTO_DICT_SAMPLE_BYTES

          begin
            trained = RZstd::Dictionary.train(@samples, capacity: DICT_FRAME_MAX_SIZE)
            install_send_dictionary(trained)
          rescue StandardError
            # Insufficient variation in the sample corpus. Stop trying;
            # auto stays in no-dict opportunistic mode for the lifetime
            # of this socket.
          ensure
            @training_done = true
            @samples       = nil
          end
        end

      end
    end
  end
end
