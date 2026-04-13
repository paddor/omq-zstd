# frozen_string_literal: true

require "delegate"
require "protocol/zmtp"
require_relative "codec"
require_relative "constants"

module OMQ
  module RFC
    module Zstd
      # Wraps a Protocol::ZMTP::Connection to transparently apply the
      # ZMTP-Zstd sender/receiver rules (RFC sections 6.4 and 6.5) at
      # the frame-body level.
      #
      # Each outgoing message part is run through {Codec.encode_part};
      # each incoming part through {Codec.decode_part}. The wrapper is
      # installed via +Engine#connection_wrapper+ once the handshake has
      # matched a profile -- if the peer didn't advertise a compatible
      # X-Compression value, no wrapper is installed and the connection
      # stays on the raw path.
      #
      # Fan-out byte-sharing is disabled on wrapped connections by
      # hiding +#write_wire+. Compression must run per-recipient under
      # the current API (each connection could in principle use a
      # different profile or dictionary), so the fan-out optimization
      # in +OMQ::Routing::FanOut+ falls back to per-connection
      # +write_message+.
      class CompressionConnection < SimpleDelegator
        # Mixed-in so +is_a?+ against Protocol::ZMTP::Connection still
        # matches the wrapped instance.
        module TransparentDelegator
          def is_a?(klass)
            super || __getobj__.is_a?(klass)
          end
          alias_method :kind_of?, :is_a?
        end

        include TransparentDelegator

        # @param conn [Protocol::ZMTP::Connection] underlying connection
        # @param send_compression [OMQ::RFC::Zstd::Compression, nil]
        #   compression object used on outgoing parts; nil = no-op
        # @param recv_compression [OMQ::RFC::Zstd::Compression, nil]
        #   compression object used on incoming parts; nil = no-op
        # @param max_message_size [Integer, nil]
        def initialize(conn, send_compression:, recv_compression:, max_message_size: nil, engine: nil)
          super(conn)
          @send_compression = send_compression
          @recv_compression = recv_compression
          @max_message_size = max_message_size
          @engine           = engine
          @dict_sent        = false
          @last_wire_size_out = nil
          @last_wire_size_in  = nil

          # Cached once: is the send side an auto-training compression
          # that still needs samples? Flipped false the moment training
          # completes, so #encode_parts drops the per-message branch.
          @auto_sampling = send_compression.is_a?(Compression) && send_compression.auto?
        end


        # Compressed byte size of the most recent outgoing message body
        # (sum over parts). Read by the engine's verbose monitor to
        # annotate +:message_sent+ traces with +wire=NB+.
        attr_reader :last_wire_size_out


        # Compressed byte size of the most recent incoming message body.
        attr_reader :last_wire_size_in


        # Disables fan-out byte-sharing. See class docs.
        def respond_to?(name, include_private = false)
          return false if name == :write_wire
          super
        end


        def send_message(parts)
          encoded = encode_parts(parts)
          ship_auto_dict_if_ready
          super(encoded)
        end


        def write_message(parts)
          encoded = encode_parts(parts)
          ship_auto_dict_if_ready
          super(encoded)
        end


        def write_messages(messages)
          encoded = messages.map { |parts| encode_parts(parts) }
          ship_auto_dict_if_ready
          super(encoded)
        end


        def receive_message
          parts = super do |frame|
            handle_command_frame(frame)
          end
          decode_parts(parts)
        end


        # Sends the DICT command frame if the send-side compression has
        # an inline dictionary to ship. Called by EngineExt right after
        # the wrapper is constructed, before the recv pump starts.
        def send_initial_dict!
          return if @dict_sent
          return unless @send_compression
          # RFC Sec. 6.4: a passive sender MUST NOT emit a ZDICT frame.
          return if @send_compression.respond_to?(:passive?) && @send_compression.passive?
          bytes = @send_compression.send_dict_bytes
          return unless bytes
          if bytes.bytesize > DICT_FRAME_MAX_SIZE
            raise Error, "ZMTP-Zstd: dictionary exceeds DICT_FRAME_MAX_SIZE (#{bytes.bytesize} > #{DICT_FRAME_MAX_SIZE})"
          end
          __getobj__.send_command(Protocol::ZMTP::Codec::Command.new("ZDICT", bytes))
          @dict_sent = true
          @engine&.emit_verbose_monitor_event(:zdict_sent, size: bytes.bytesize)
        end

        private


        def handle_command_frame(frame)
          cmd = Protocol::ZMTP::Codec::Command.from_body(frame.body)
          case cmd.name
          when "ZDICT"
            install_received_dict(cmd.data)
          end
        end


        def install_received_dict(bytes)
          return unless @recv_compression
          if bytes.bytesize > DICT_FRAME_MAX_SIZE
            raise Error, "ZMTP-Zstd: received DICT exceeds DICT_FRAME_MAX_SIZE"
          end
          @recv_compression.install_recv_dictionary(bytes)
          @engine&.emit_verbose_monitor_event(:zdict_received, size: bytes.bytesize)
        end


        def encode_parts(parts)
          return parts if @send_compression.nil?

          if @auto_sampling
            if @send_compression.trained?
              @auto_sampling = false
            else
              parts.each { |p| @send_compression.add_sample(p) }
            end
          end

          encoded = parts.map { |p| Codec.encode_part(p, @send_compression) }
          @last_wire_size_out = encoded.sum(&:bytesize)
          encoded
        end


        def ship_auto_dict_if_ready
          return if @dict_sent
          return unless @send_compression&.send_dict_bytes
          send_initial_dict!
        end


        def decode_parts(parts)
          return parts if @recv_compression.nil?
          @last_wire_size_in = parts.sum(&:bytesize)
          budget_remaining = @max_message_size
          parts.map do |p|
            plaintext = Codec.decode_part(p, @recv_compression, budget_remaining: budget_remaining)
            budget_remaining -= plaintext.bytesize if budget_remaining
            plaintext
          end
        end
      end
    end
  end
end
