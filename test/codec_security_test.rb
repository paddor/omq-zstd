# frozen_string_literal: true

require_relative "test_helper"
require "omq/rfc/zstd/codec"
require "omq/rfc/zstd/compression"
require "rzstd"

# RFC Sec. 6.5 security rules: byte-bomb prevention, mandatory
# Frame_Content_Size, multipart running-total enforcement.
#
class CodecSecurityTest < Minitest::Test
  Codec       = OMQ::RFC::Zstd::Codec
  Compression = OMQ::RFC::Zstd::Compression


  def setup
    @compression = Compression.none # no-dict, zstd-active profile
  end


  # -- Byte-bomb prevention (declared size > budget) -----------------------

  def test_rejects_frame_whose_declared_content_size_exceeds_budget
    payload = "A" * 100_000
    frame   = build_zstd_part(payload)
    # Budget smaller than declared size.
    assert_raises(OMQ::RFC::Zstd::DecompressedSizeExceedsMaxError) do
      Codec.decode_part(frame, @compression, budget_remaining: 1_000)
    end
  end


  def test_decoder_is_not_invoked_when_budget_would_be_exceeded
    # A legitimate 10 MB payload compresses to ~300 bytes. Without the
    # header check the decoder would allocate 10 MB; the check rejects
    # the frame on its declared size alone.
    payload = "A" * 10_000_000
    frame   = build_zstd_part(payload)
    before  = memory_footprint
    assert_raises(OMQ::RFC::Zstd::DecompressedSizeExceedsMaxError) do
      Codec.decode_part(frame, @compression, budget_remaining: 1_000_000)
    end
    after = memory_footprint
    # Loose upper bound: rejecting on header alone should cost much less
    # than the 10 MB allocation we are preventing.
    assert_operator (after - before), :<, 2_000_000,
      "byte-bomb rejection allocated too much (#{after - before} bytes)"
  end


  def test_allows_frame_whose_declared_content_size_fits_budget
    payload = "A" * 8_000
    frame   = build_zstd_part(payload)
    plaintext = Codec.decode_part(frame, @compression, budget_remaining: 10_000)
    assert_equal payload, plaintext
  end


  def test_no_budget_check_when_max_is_nil
    payload = "A" * 8_000
    frame   = build_zstd_part(payload)
    plaintext = Codec.decode_part(frame, @compression, budget_remaining: nil)
    assert_equal payload, plaintext
  end


  # -- Missing Frame_Content_Size ------------------------------------------

  def test_rejects_compressed_frame_without_content_size
    # Hand-crafted zstd frame (magic + FHD=0x00 + WD=0x00 + last empty
    # raw block) — the producer omitted Frame_Content_Size entirely.
    raw_frame = [0x28, 0xB5, 0x2F, 0xFD, 0x00, 0x00, 0x01, 0x00, 0x00].pack("C*")
    # Wire frame body starts with the zstd magic sentinel; no extra
    # wrapper bytes, since zstd magic IS the sentinel (RFC Sec. 6.4).
    assert_raises(OMQ::RFC::Zstd::MissingContentSizeError) do
      Codec.decode_part(raw_frame, @compression, budget_remaining: 10_000)
    end
  end


  def test_missing_content_size_error_inherits_protocol_zmtp_error
    # So omq's recv pump treats it as expected disconnect.
    assert_operator OMQ::RFC::Zstd::MissingContentSizeError,
                    :<, Protocol::ZMTP::Error
    assert_operator OMQ::RFC::Zstd::DecompressedSizeExceedsMaxError,
                    :<, Protocol::ZMTP::Error
  end


  # -- Multipart running-total enforcement --------------------------------

  def test_multipart_sum_exceeding_budget_is_rejected_before_decoder
    part_a = build_zstd_part("A" * 8_000)
    part_b = build_zstd_part("B" * 8_000) # sum = 16_000
    budget = 10_000

    plaintext_a = Codec.decode_part(part_a, @compression, budget_remaining: budget)
    remaining = budget - plaintext_a.bytesize
    assert_raises(OMQ::RFC::Zstd::DecompressedSizeExceedsMaxError) do
      Codec.decode_part(part_b, @compression, budget_remaining: remaining)
    end
  end


  # -- Uncompressed sentinel also respects the budget ----------------------

  def test_uncompressed_sentinel_is_charged_against_budget
    body = OMQ::RFC::Zstd::SENTINEL_UNCOMPRESSED + ("x" * 20_000)
    assert_raises(OMQ::RFC::Zstd::DecompressedSizeExceedsMaxError) do
      Codec.decode_part(body, @compression, budget_remaining: 1_000)
    end
  end


  private


  def build_zstd_part(plaintext)
    # Produces a body whose first 4 bytes are the zstd magic (= the
    # ZMTP-Zstd "compressed" sentinel), with Frame_Content_Size set to
    # plaintext.bytesize by rzstd's compress2.
    RZstd.compress(plaintext)
  end


  def memory_footprint
    GC.start
    GC.stat(:total_allocated_objects)
  end
end
