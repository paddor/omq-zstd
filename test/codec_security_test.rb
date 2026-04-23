# frozen_string_literal: true

require_relative "test_helper"
require "rzstd"

describe "Codec security" do
  # Shared frame codec for the tests that need to produce valid
  # frames on the fly. rzstd 0.4 removed module-level RZstd.compress.
  SEC_TEST_CODEC = RZstd::FrameCodec.new(level: -3)

  def codec(**opts)
    OMQ::Transport::ZstdTcp::Codec.new(level: -3, **opts)
  end

  def connection(codec)
    OMQ::Transport::ZstdTcp::ZstdConnection.new(FakeConn.new, codec)
  end


  class FakeConn
    attr_reader :sent

    def initialize
      @sent = []
    end

    def write_message(parts)
      @sent << parts
    end

    def receive_message
      @sent.shift
    end

    def flush; end
  end


  it "rejects a frame whose declared FCS exceeds budget" do
    c = codec(max_message_size: 1_000)
    conn = connection(c)
    payload = "A" * 100_000
    frame   = SEC_TEST_CODEC.compress(payload)
    assert_raises(OMQ::Transport::ZstdTcp::ProtocolError) do
      conn.send(:decode_parts, [frame])
    end
  end


  it "allows a frame that fits the budget" do
    c = codec(max_message_size: 10_000)
    conn = connection(c)
    payload = "A" * 8_000
    frame   = SEC_TEST_CODEC.compress(payload)
    decoded = conn.send(:decode_parts, [frame])
    assert_equal [payload], decoded
  end


  it "rejects a compressed frame without Frame_Content_Size" do
    c = codec
    conn = connection(c)
    raw_frame = [0x28, 0xB5, 0x2F, 0xFD, 0x00, 0x00, 0x01, 0x00, 0x00].pack("C*")
    assert_raises(OMQ::Transport::ZstdTcp::ProtocolError) do
      conn.send(:decode_parts, [raw_frame])
    end
  end


  it "rejects multipart message whose decompressed sum exceeds budget" do
    c = codec(max_message_size: 10_000)
    conn = connection(c)
    part_a = SEC_TEST_CODEC.compress("A" * 8_000)
    part_b = SEC_TEST_CODEC.compress("B" * 8_000)
    assert_raises(OMQ::Transport::ZstdTcp::ProtocolError) do
      conn.send(:decode_parts, [part_a, part_b])
    end
  end


  it "charges uncompressed sentinel against budget" do
    c = codec(max_message_size: 1_000)
    conn = connection(c)
    body = OMQ::Transport::ZstdTcp::Codec::NUL_PREAMBLE + ("x" * 20_000)
    assert_raises(OMQ::Transport::ZstdTcp::ProtocolError) do
      conn.send(:decode_parts, [body])
    end
  end


  it "allows dict overwrite" do
    c = codec
    conn = connection(c)
    samples = 400.times.map { |i| "user_#{i}|key=#{i}|val=#{i * 7}" }
    dict_bytes = RZstd::Dictionary.train(samples, capacity: 8 * 1024).bytes
    result1 = conn.send(:decode_parts, [dict_bytes])
    assert_nil result1
    result2 = conn.send(:decode_parts, [dict_bytes])
    assert_nil result2
  end


  it "rejects oversized dict" do
    c = codec
    conn = connection(c)
    samples = 400.times.map { |i| "user_#{i}|key=#{i}|val=#{i * 7}" }
    dict_bytes = RZstd::Dictionary.train(samples, capacity: 8 * 1024).bytes
    padded = dict_bytes + ("\x00" * (65 * 1024))
    assert_raises(OMQ::Transport::ZstdTcp::ProtocolError) do
      conn.send(:decode_parts, [padded])
    end
  end
end
