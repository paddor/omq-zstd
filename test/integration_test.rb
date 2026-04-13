# frozen_string_literal: true

require_relative "test_helper"

class IntegrationTest < Minitest::Test
  def test_push_pull_round_trip_with_zstd_none
    Sync do
      push = OMQ::PUSH.new
      pull = OMQ::PULL.new
      push.compression = OMQ::RFC::Zstd::Compression.none
      pull.compression = OMQ::RFC::Zstd::Compression.none

      pull.bind("tcp://127.0.0.1:0")
      push.connect(pull.last_endpoint)

      payload = "a" * 4096
      push << [payload]

      assert_equal [payload], pull.receive
    ensure
      push&.close
      pull&.close
    end
  end


  def test_round_trip_small_payload_below_threshold
    Sync do
      push = OMQ::PUSH.new
      pull = OMQ::PULL.new
      push.compression = OMQ::RFC::Zstd::Compression.none
      pull.compression = OMQ::RFC::Zstd::Compression.none

      pull.bind("tcp://127.0.0.1:0")
      push.connect(pull.last_endpoint)

      push << ["hi"]
      assert_equal ["hi"], pull.receive
    ensure
      push&.close
      pull&.close
    end
  end


  def test_no_compression_when_peer_does_not_advertise
    Sync do
      push = OMQ::PUSH.new
      pull = OMQ::PULL.new
      push.compression = OMQ::RFC::Zstd::Compression.none
      # pull has no compression -- peer will not advertise X-Compression

      pull.bind("tcp://127.0.0.1:0")
      push.connect(pull.last_endpoint)

      payload = "b" * 4096
      push << [payload]
      assert_equal [payload], pull.receive
    ensure
      push&.close
      pull&.close
    end
  end


  def test_round_trip_with_inline_dictionary
    dict = ("the quick brown fox jumps over " * 20).b
    Sync do
      push = OMQ::PUSH.new
      pull = OMQ::PULL.new
      push.compression = OMQ::RFC::Zstd::Compression.with_dictionary(dict, inline: true)
      pull.compression = OMQ::RFC::Zstd::Compression.with_dictionary(dict, inline: true)

      pull.bind("tcp://127.0.0.1:0")
      push.connect(pull.last_endpoint)

      msg = ("the quick brown fox " * 50).b
      push << [msg]
      assert_equal [msg], pull.receive
    ensure
      push&.close
      pull&.close
    end
  end


  def test_auto_dict_trains_and_ships_dict_to_receiver
    Sync do
      push = OMQ::PUSH.new
      pull = OMQ::PULL.new
      push.compression = OMQ::RFC::Zstd::Compression.auto
      pull.compression = OMQ::RFC::Zstd::Compression.auto

      pull.bind("tcp://127.0.0.1:0")
      push.connect(pull.last_endpoint)

      # 200 unique-but-templated samples crossing AUTO_DICT_SAMPLE_BYTES
      # (100 KiB) so training fires.
      template = "user=%s|status=active|tier=gold|region=eu-west-%d|payload=" + ("x" * 600)
      sent = 200.times.map { |i| format(template, "user_#{i}@example.com", i % 4) }
      sent.each { |m| push << [m] }

      received = sent.size.times.map { pull.receive.first }
      assert_equal sent, received

      assert push.compression.trained?, "send compression should be trained"
      assert pull.compression.has_recv_dictionary?, "recv compression should have dict installed via ZDICT frame"
    ensure
      push&.close
      pull&.close
    end
  end


  # RFC Sec. 6.5: a compressed frame whose declared content size
  # exceeds the receiver's max_message_size must cause the connection
  # to drop without invoking the decoder.
  #
  def test_byte_bomb_drops_connection
    Sync do
      push = OMQ::PUSH.new
      pull = OMQ::PULL.new
      push.compression       = OMQ::RFC::Zstd::Compression.none
      pull.compression       = OMQ::RFC::Zstd::Compression.none
      pull.max_message_size  = 4096
      pull.read_timeout      = 0.5

      pull.bind("tcp://127.0.0.1:0")
      push.connect(pull.last_endpoint)

      # 1 MiB of 'A' compresses to a few hundred bytes but declares
      # 1_048_576 in Frame_Content_Size — well past pull's 4096 cap.
      push << ["A" * 1_048_576]

      assert_raises(IO::TimeoutError) { pull.receive }
    ensure
      push&.close
      pull&.close
    end
  end


  def test_round_trip_with_static_dictionary
    dict = ("lorem ipsum dolor sit amet " * 20).b
    Sync do
      push = OMQ::PUSH.new
      pull = OMQ::PULL.new
      push.compression = OMQ::RFC::Zstd::Compression.with_dictionary(dict)
      pull.compression = OMQ::RFC::Zstd::Compression.with_dictionary(dict)

      pull.bind("tcp://127.0.0.1:0")
      push.connect(pull.last_endpoint)

      msg = ("lorem ipsum dolor " * 50).b
      push << [msg]
      assert_equal [msg], pull.receive
    ensure
      push&.close
      pull&.close
    end
  end
end
