# frozen_string_literal: true

require "omq"
require_relative "constants"

module OMQ
  module RFC
    module Zstd

      # Prepended onto OMQ::Options to add a +compression+ attribute.
      #
      # Setting +compression+ also publishes the profile string on the
      # mechanism's metadata so the ZMTP READY command advertises
      # +X-Compression+ to the peer during handshake.
      #
      module OptionsExt

        attr_reader :compression


        def initialize(**kwargs)
          super
          @compression = nil
        end


        def compression=(value)
          @compression = value
          return unless value

          mech = self.mechanism
          unless mech.respond_to?(:metadata)
            raise ArgumentError,
                  "mechanism #{mech.class} does not support metadata; " \
                  "ZMTP-Zstd requires NULL, PLAIN, or CURVE"
          end
          mech.metadata ||= {}
          mech.metadata[PROPERTY_NAME] = value.profile
        end

      end
    end
  end
end

OMQ::Options.prepend(OMQ::RFC::Zstd::OptionsExt)
