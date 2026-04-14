# frozen_string_literal: true

require "omq"
require_relative "connection"
require_relative "constants"

module OMQ
  module RFC
    module Zstd

      # Prepended onto OMQ::Engine to install a compression-aware
      # connection wrapper. The wrapper is installed unconditionally
      # at engine init time and inspects +options.compression+ on each
      # call -- the user typically sets +socket.compression =+ AFTER
      # the engine has been constructed, so the closure must look up
      # the compression object lazily.
      #
      module EngineExt
        def initialize(socket_type, options)
          super
          self.connection_wrapper = ->(conn) do
            compression = options.compression
            next conn unless compression
            next conn unless matched_profile(conn, compression)

            wrapper = CompressionConnection.new(
              conn,
              send_compression: compression,
              recv_compression: compression,
              max_message_size: options.max_message_size,
              engine: self,
            )
            wrapper.send_initial_dict!
            wrapper
          end
        end


        private


        def matched_profile(conn, compression)
          props = conn.peer_properties
          return nil unless props
          peer_value = props[PROPERTY_NAME]
          compression.match(peer_value)
        end

      end
    end
  end
end

OMQ::Engine.prepend(OMQ::RFC::Zstd::EngineExt)
