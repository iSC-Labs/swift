//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2016 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//


// Conversions between different Unicode encodings.  Note that UTF-16 and
// UTF-32 decoding are *not* currently resilient to erroneous data.

/// The result of one Unicode decoding step.
///
/// A unicode scalar value, an indication that no more unicode scalars
/// are available, or an indication of a decoding error.
public enum UnicodeDecodingResult {
  case Result(UnicodeScalar)
  case EmptyInput
  case Error

  /// Returns `true` if `self` indicates no more unicode scalars are
  /// available.
  @warn_unused_result
  public func isEmptyInput() -> Bool {
    switch self {
    case .EmptyInput:
      return true
    default:
      return false
    }
  }
}

/// A Unicode [encoding scheme](http://www.unicode.org/glossary/#character_encoding_scheme).
///
/// Consists of an underlying [code unit](http://www.unicode.org/glossary/#code_unit) and functions to
/// translate between sequences of these code units and [unicode scalar values](http://www.unicode.org/glossary/#unicode_scalar_value).
public protocol UnicodeCodecType {

  /// A type that can hold [code unit](http://www.unicode.org/glossary/#code_unit) values for this
  /// encoding.
  associatedtype CodeUnit

  init()

  /// Start or continue decoding a UTF sequence.
  ///
  /// In order to decode a code unit sequence completely, this function should
  /// be called repeatedly until it returns `UnicodeDecodingResult.EmptyInput`.
  /// Checking that the generator was exhausted is not sufficient.  The decoder
  /// can have an internal buffer that is pre-filled with data from the input
  /// generator.
  ///
  /// Because of buffering, it is impossible to find the corresponding position
  /// in the generator for a given returned `UnicodeScalar` or an error.
  ///
  /// - parameter next: A generator of code units to be decoded.
  mutating func decode<
    G : GeneratorType where G.Element == CodeUnit
  >(next: inout G) -> UnicodeDecodingResult

  /// Encode a `UnicodeScalar` as a series of `CodeUnit`s by
  /// calling `output` on each `CodeUnit`.
  static func encode(input: UnicodeScalar, output: (CodeUnit) -> Void)
}

/// A codec for [UTF-8](http://www.unicode.org/glossary/#UTF_8).
public struct UTF8 : UnicodeCodecType {
  // See Unicode 8.0.0, Ch 3.9, UTF-8.
  // http://www.unicode.org/versions/Unicode8.0.0/ch03.pdf

  /// A type that can hold [code unit](http://www.unicode.org/glossary/#code_unit)
  /// values for this encoding.
  public typealias CodeUnit = UInt8

  public init() {}

  /// Lookahead buffer used for UTF-8 decoding.  New bytes are inserted at MSB,
  /// and bytes are read at LSB.  Note that we need to use a buffer, because
  /// in case of invalid subsequences we sometimes don't know whether we should
  /// consume a certain byte before looking at it.
  var _decodeBuffer: UInt32 = 0

  /// The number of bits in `_decodeBuffer` that are current filled.
  var _bitsInBuffer: UInt8 = 0

  /// Whether we have exhausted the generator.  Note that this doesn't mean
  /// we are done decoding, as there might still be bytes left in the buffer.
  var _atEnd: Bool = false

  /// Start or continue decoding a UTF-8 sequence.
  ///
  /// In order to decode a code unit sequence completely, this function should
  /// be called repeatedly until it returns `UnicodeDecodingResult.EmptyInput`.
  /// Checking that the generator was exhausted is not sufficient.  The decoder
  /// can have an internal buffer that is pre-filled with data from the input
  /// generator.
  ///
  /// Because of buffering, it is impossible to find the corresponding position
  /// in the generator for a given returned `UnicodeScalar` or an error.
  ///
  /// - parameter next: A generator of code units to be decoded.  Repeated
  /// calls to this method on the same instance should always reuse the same
  /// generator.  Failing to do so will result in undefined behavior.
  public mutating func decode<
    G : GeneratorType where G.Element == CodeUnit
    >(next: inout G) -> UnicodeDecodingResult {

      refillBuffer: if !_atEnd {
        // Bufferless ASCII fastpath.
        if _fastPath(_bitsInBuffer == 0) {
          if let codeUnit = next.next() {
            if codeUnit & 0x80 == 0 {
              return .Result(UnicodeScalar(_unchecked: UInt32(codeUnit)))
            } else { // Non-ASCII, switch to buffering mode.
              _decodeBuffer = UInt32(codeUnit)
              _bitsInBuffer = 8
            }
          } else { // Exhausted generator.
            _atEnd = true
            return .EmptyInput
          }
        } else if(_decodeBuffer & 0x80 == 0) {
          // ASCII in buffer.  We don't refill the buffer so we can return
          // to bufferless mode once we've exhausted it.
          break refillBuffer
        }
        // Buffering mode.
        // Fill buffer back to 4 bytes (or as many as are left in the generator).
        _sanityCheck(_bitsInBuffer < 32)
        repeat {
          if let codeUnit = next.next() {
            // We use & 0x1f to make the compiler omit a bounds check branch.
            _decodeBuffer |= (UInt32(codeUnit) << UInt32(_bitsInBuffer & 0x1f))
            _bitsInBuffer = _bitsInBuffer &+ 8
          } else { // Exhausted generator.
            _atEnd = true
            if _bitsInBuffer == 0 { return .EmptyInput }
            break // We still have some bytes left in our buffer.
          }
        } while _bitsInBuffer < 32
      } else if _bitsInBuffer == 0 {
        return .EmptyInput
      }

      // Decode one unicode scalar.
      // Note our empty bytes are always 0x00, which is required for this call.
      let (result, length) = UTF8._decodeOne(_decodeBuffer)

      // Consume the decoded bytes (or maximal subpart of ill-formed sequence).
      let bitsConsumed = 8 &* length
      _sanityCheck(1...4 ~= length && bitsConsumed <= _bitsInBuffer)
      // Swift doesn't allow shifts greater than or equal to the type width.
      // _decodeBuffer >>= UInt32(bitsConsumed) // >>= 32 crashes.
      _decodeBuffer = UInt32(truncatingBitPattern:
        UInt64(_decodeBuffer) >> (UInt64(bitsConsumed) & 0x1f))
      _bitsInBuffer = _bitsInBuffer &- bitsConsumed

      if _fastPath(result != nil) {
        return .Result(UnicodeScalar(_unchecked: result!))
      } else {
        return .Error // Ill-formed UTF-8 code unit sequence.
      }
  }

  /// Attempts to decode a single UTF-8 code unit sequence starting at the LSB
  /// of `buffer`.
  ///
  /// - Returns:
  ///   - result: The decoded code point if the code unit sequence is
  ///   well-formed; `nil` otherwise.
  ///   - length: The length of the code unit sequence in bytes if it is
  ///   well-formed; otherwise the *maximal subpart of the ill-formed
  ///   sequence* (Unicode 8.0.0, Ch 3.9, D93b), i.e. the number of leading
  ///   code units that were valid or 1 in case none were valid.  Unicode
  ///   recommends to skip these bytes bytes and replace them by a single
  ///   replacement character (U+FFFD).
  ///
  /// - Requires: There is at least one used byte in `buffer`, and the unused
  /// space in `buffer` is filled with some value not matching the UTF-8
  /// continuation byte form (`0b10xxxxxx`).
  @warn_unused_result
  public // @testable
  static func _decodeOne(buffer: UInt32) -> (result: UInt32?, length: UInt8) {

    if buffer & 0x80 == 0 { // 1-byte sequence (ASCII), [ XXX XXX XXX CU0 ].
      let value = buffer & 0xff
      return (value, 1)
    }

    // Determine sequence length using high 5 bits of 1st byte.  We use a
    // look-up table to branch less.  1-byte sequences are handled above.
    //
    //  case | pattern | description
    // ----------------------------
    //   00  |  110xx  | 2-byte sequence
    //   01  |  1110x  | 3-byte sequence
    //   10  |  11110  | 4-byte sequence
    //   11  |  other  | invalid
    //
    //                     11xxx      10xxx      01xxx      00xxx
    let lut0: UInt32 = 0b1011_0000__1111_1111__1111_1111__1111_1111
    let lut1: UInt32 = 0b1100_0000__1111_1111__1111_1111__1111_1111

    let index = (buffer >> 3) & 0x1f
    let bit0 = (lut0 >> index) & 1
    let bit1 = (lut1 >> index) & 1

    switch (bit1, bit0) {
    case (0, 0): // 2-byte sequence, [ XXX XXX CU1 CU0 ].
      // Require 10xx xxxx  110x xxxx.
      if _slowPath(buffer & 0xc0e0 != 0x80c0) { return (nil, 1) }
      // Disallow xxxx xxxx  xxx0 000x (<= 7 bits case).
      if _slowPath(buffer & 0x001e == 0x0000) { return (nil, 1) }
      // Extract data bits.
      let value = (buffer & 0x3f00) >> 8
                | (buffer & 0x001f) << 6
      return (value, 2)

    case (0, 1): // 3-byte sequence, [ XXX CU2 CU1 CU0 ].
      // Disallow xxxx xxxx  xx0x xxxx  xxxx 0000 (<= 11 bits case).
      if _slowPath(buffer & 0x00200f == 0x000000) { return (nil, 1) }
      // Disallow xxxx xxxx  xx1x xxxx  xxxx 1101 (surrogate code points).
      if _slowPath(buffer & 0x00200f == 0x00200d) { return (nil, 1) }
      // Require 10xx xxxx  10xx xxxx  1110 xxxx.
      if _slowPath(buffer & 0xc0c0f0 != 0x8080e0) {
        if buffer & 0x00c000 != 0x008000 { return (nil, 1) }
        return (nil, 2) // All checks on CU0 & CU1 passed.
      }
      // Extract data bits.
      let value = (buffer & 0x3f0000) >> 16
                | (buffer & 0x003f00) >> 2
                | (buffer & 0x00000f) << 12
      return (value, 3)

    case (1, 0): // 4-byte sequence, [ CU3 CU2 CU1 CU0 ].
      // Disallow xxxx xxxx  xxxx xxxx  xx00 xxxx  xxxx x000 (<= 16 bits case).
      if _slowPath(buffer & 0x00003007 == 0x00000000) { return (nil, 1) }
      // If xxxx xxxx  xxxx xxxx  xxxx xxxx  xxxx x1xx.
      if buffer & 0x00000004 == 0x00000004 {
        // Require xxxx xxxx  xxxx xxxx  xx00 xxxx  xxxx xx00 (<= 0x10FFFF).
        if _slowPath(buffer & 0x00003003 != 0x00000000) { return (nil, 1) }
      }
      // Require 10xx xxxx  10xx xxxx  10xx xxxx  1111 0xxx.
      if _slowPath(buffer & 0xc0c0c0f8 != 0x808080f0) {
        if buffer & 0x0000c000 != 0x00008000 { return (nil, 1) }
        // All other checks on CU0, CU1 & CU2 passed.
        if buffer & 0x00c00000 != 0x00800000 { return (nil, 2) }
        return (nil, 3)
      }
      // Extract data bits.
      let value = (buffer & 0x3f000000) >> 24
                | (buffer & 0x003f0000) >> 10
                | (buffer & 0x00003f00) << 4
                | (buffer & 0x00000007) << 18
      return (value, 4)

    default: // Invalid sequence (CU0 invalid).
      return (nil, 1)
    }
  }

  /// Encode a `UnicodeScalar` as a series of `CodeUnit`s by
  /// calling `output` on each `CodeUnit`.
  public static func encode(
    input: UnicodeScalar,
    output put: (CodeUnit) -> Void
  ) {
    var c = UInt32(input)
    var buf3 = UInt8(c & 0xFF)

    if c >= UInt32(1<<7) {
      c >>= 6
      buf3 = (buf3 & 0x3F) | 0x80 // 10xxxxxx
      var buf2 = UInt8(c & 0xFF)
      if c < UInt32(1<<5) {
        buf2 |= 0xC0              // 110xxxxx
      }
      else {
        c >>= 6
        buf2 = (buf2 & 0x3F) | 0x80 // 10xxxxxx
        var buf1 = UInt8(c & 0xFF)
        if c < UInt32(1<<4) {
          buf1 |= 0xE0              // 1110xxxx
        }
        else {
          c >>= 6
          buf1 = (buf1 & 0x3F) | 0x80 // 10xxxxxx
          put(UInt8(c | 0xF0)) // 11110xxx
        }
        put(buf1)
      }
      put(buf2)
    }
    put(buf3)
  }

  /// Returns `true` if `byte` is a continuation byte of the form
  /// `0b10xxxxxx`.
  @warn_unused_result
  public static func isContinuation(byte: CodeUnit) -> Bool {
    return byte & 0b11_00__0000 == 0b10_00__0000
  }
}

/// A codec for [UTF-16](http://www.unicode.org/glossary/#UTF_16).
public struct UTF16 : UnicodeCodecType {
  /// A type that can hold [code unit](http://www.unicode.org/glossary/#code_unit) values for this
  /// encoding.
  public typealias CodeUnit = UInt16

  public init() {}

  /// A lookahead buffer for one UTF-16 code unit.
  var _decodeLookahead: UInt32 = 0

  /// Flags with layout: `0b0000_00xy`.
  ///
  /// `y` is the EOF flag.
  ///
  /// `x` is set when `_decodeLookahead` contains a code unit.
  var _lookaheadFlags: UInt8 = 0

  /// Start or continue decoding a UTF sequence.
  ///
  /// In order to decode a code unit sequence completely, this function should
  /// be called repeatedly until it returns `UnicodeDecodingResult.EmptyInput`.
  /// Checking that the generator was exhausted is not sufficient.  The decoder
  /// can have an internal buffer that is pre-filled with data from the input
  /// generator.
  ///
  /// Because of buffering, it is impossible to find the corresponding position
  /// in the generator for a given returned `UnicodeScalar` or an error.
  ///
  /// - parameter next: A generator of code units to be decoded.
  public mutating func decode<
    G : GeneratorType where G.Element == CodeUnit
  >(input: inout G) -> UnicodeDecodingResult {
    if _lookaheadFlags & 0b01 != 0 {
      return .EmptyInput
    }

    // Note: maximal subpart of ill-formed sequence for UTF-16 can only have
    // length 1.  Length 0 does not make sense.  Neither does length 2 -- in
    // that case the sequence is valid.

    var unit0: UInt32
    if _fastPath(_lookaheadFlags & 0b10 == 0) {
      if let first = input.next() {
        unit0 = UInt32(first)
      } else {
        // Set EOF flag.
        _lookaheadFlags |= 0b01
        return .EmptyInput
      }
    } else {
      // Fetch code unit from the lookahead buffer and note this fact in flags.
      unit0 = _decodeLookahead
      _lookaheadFlags &= 0b01
    }

    // A well-formed pair of surrogates looks like this:
    // [1101 10ww wwxx xxxx] [1101 11xx xxxx xxxx]

    if _fastPath((unit0 >> 11) != 0b1101_1) {
      // Neither high-surrogate, nor low-surrogate -- sequence of 1 code unit,
      // decoding is trivial.
      return .Result(UnicodeScalar(unit0))
    }

    if _slowPath((unit0 >> 10) == 0b1101_11) {
      // `unit0` is a low-surrogate.  We have an ill-formed sequence.
      return .Error
    }

    // At this point we know that `unit0` is a high-surrogate.

    var unit1: UInt32
    if let second = input.next() {
      unit1 = UInt32(second)
    } else {
      // EOF reached.  Set EOF flag.
      _lookaheadFlags |= 0b01

      // We have seen a high-surrogate and EOF, so we have an ill-formed
      // sequence.
      return .Error
    }

    if _fastPath((unit1 >> 10) == 0b1101_11) {
      // `unit1` is a low-surrogate.  We have a well-formed surrogate pair.

      let result = 0x10000 + (((unit0 & 0x03ff) << 10) | (unit1 & 0x03ff))
      return .Result(UnicodeScalar(result))
    }

    // Otherwise, we have an ill-formed sequence.  These are the possible
    // cases:
    //
    // * `unit1` is a high-surrogate, so we have a pair of two high-surrogates.
    //
    // * `unit1` is not a surrogate.  We have an ill-formed sequence:
    //   high-surrogate followed by a non-surrogate.

    // Save the second code unit in the lookahead buffer.
    _decodeLookahead = unit1
    _lookaheadFlags |= 0b10
    return .Error
  }

  /// Try to decode one Unicode scalar, and return the actual number of code
  /// units it spanned in the input.  This function may consume more code
  /// units than required for this scalar.
  mutating func _decodeOne<
    G : GeneratorType where G.Element == CodeUnit
  >(input: inout G) -> (UnicodeDecodingResult, Int) {
    let result = decode(&input)
    switch result {
    case .Result(let us):
      return (result, UTF16.width(us))

    case .EmptyInput:
      return (result, 0)

    case .Error:
      return (result, 1)
    }
  }

  /// Encode a `UnicodeScalar` as a series of `CodeUnit`s by
  /// calling `output` on each `CodeUnit`.
  public static func encode(
    input: UnicodeScalar,
    output put: (CodeUnit) -> Void
  ) {
    let scalarValue: UInt32 = UInt32(input)

    if scalarValue <= UInt32(UInt16.max) {
      put(UInt16(scalarValue))
    }
    else {
      let lead_offset = UInt32(0xd800) - UInt32(0x10000 >> 10)
      put(UInt16(lead_offset + (scalarValue >> 10)))
      put(UInt16(0xdc00 + (scalarValue & 0x3ff)))
    }
  }

  var _value = UInt16()
}

/// A codec for [UTF-32](http://www.unicode.org/glossary/#UTF_32).
public struct UTF32 : UnicodeCodecType {
  /// A type that can hold [code unit](http://www.unicode.org/glossary/#code_unit) values for this
  /// encoding.
  public typealias CodeUnit = UInt32

  public init() {}

  /// Start or continue decoding a UTF sequence.
  ///
  /// In order to decode a code unit sequence completely, this function should
  /// be called repeatedly until it returns `UnicodeDecodingResult.EmptyInput`.
  /// Checking that the generator was exhausted is not sufficient.  The decoder
  /// can have an internal buffer that is pre-filled with data from the input
  /// generator.
  ///
  /// Because of buffering, it is impossible to find the corresponding position
  /// in the generator for a given returned `UnicodeScalar` or an error.
  ///
  /// - parameter next: A generator of code units to be decoded.
  public mutating func decode<
    G : GeneratorType where G.Element == CodeUnit
  >(input: inout G) -> UnicodeDecodingResult {
    return UTF32._decode(&input)
  }

  static func _decode<
    G : GeneratorType where G.Element == CodeUnit
  >(input: inout G) -> UnicodeDecodingResult {
    guard let x = input.next() else { return .EmptyInput }
    if _fastPath((x >> 11) != 0b1101_1 && x <= 0x10ffff) {
      return .Result(UnicodeScalar(x))
    } else {
      return .Error
    }
  }

  /// Encode a `UnicodeScalar` as a series of `CodeUnit`s by
  /// calling `output` on each `CodeUnit`.
  public static func encode(
    input: UnicodeScalar,
    output put: (CodeUnit) -> Void
  ) {
    put(UInt32(input))
  }
}

/// Translate `input`, in the given `InputEncoding`, into `output`, in
/// the given `OutputEncoding`.
///
/// - parameter stopOnError: Causes encoding to stop when an encoding
///   error is detected in `input`, if `true`.  Otherwise, U+FFFD
///   replacement characters are inserted for each detected error.
public func transcode<
  Input : GeneratorType,
  InputEncoding : UnicodeCodecType,
  OutputEncoding : UnicodeCodecType
  where InputEncoding.CodeUnit == Input.Element>(
  inputEncoding: InputEncoding.Type, _ outputEncoding: OutputEncoding.Type,
  _ input: Input, _ output: (OutputEncoding.CodeUnit) -> Void,
  stopOnError: Bool
) -> Bool {
  var input = input

  // NB.  It is not possible to optimize this routine to a memcpy if
  // InputEncoding == OutputEncoding.  The reason is that memcpy will not
  // substitute U+FFFD replacement characters for ill-formed sequences.

  var inputDecoder = inputEncoding.init()
  var hadError = false
  var scalar = inputDecoder.decode(&input)
  while !scalar.isEmptyInput() {
    switch scalar {
    case .Result(let us):
      OutputEncoding.encode(us, output: output)
    case .EmptyInput:
      _sanityCheckFailure("should not enter the loop when input becomes empty")
    case .Error:
      if stopOnError {
        return (hadError: true)
      } else {
        OutputEncoding.encode("\u{fffd}", output: output)
        hadError = true
      }
    }
    scalar = inputDecoder.decode(&input)
  }
  return hadError
}

/// Transcode UTF-16 to UTF-8, replacing ill-formed sequences with U+FFFD.
///
/// Returns the index of the first unhandled code unit and the UTF-8 data
/// that was encoded.
@warn_unused_result
internal func _transcodeSomeUTF16AsUTF8<
  Input : CollectionType
  where Input.Generator.Element == UInt16>(
  input: Input, _ startIndex: Input.Index
) -> (Input.Index, _StringCore.UTF8Chunk) {
  typealias UTF8Chunk = _StringCore.UTF8Chunk

  let endIndex = input.endIndex
  let utf8Max = sizeof(UTF8Chunk.self)
  var result: UTF8Chunk = 0
  var utf8Count = 0
  var nextIndex = startIndex
  while nextIndex != input.endIndex && utf8Count != utf8Max {
    let u = UInt(input[nextIndex])
    let shift = UTF8Chunk(utf8Count * 8)
    var utf16Length: Input.Index.Distance = 1

    if _fastPath(u <= 0x7f) {
      result |= UTF8Chunk(u) << shift
      utf8Count += 1
    } else {
      var scalarUtf8Length: Int
      var r: UInt
      if _fastPath((u >> 11) != 0b1101_1) {
        // Neither high-surrogate, nor low-surrogate -- well-formed sequence
        // of 1 code unit, decoding is trivial.
        if u < 0x800 {
          r = 0b10__00_0000__110__0_0000
          r |= u >> 6
          r |= (u & 0b11_1111) << 8
          scalarUtf8Length = 2
        }
        else {
          r = 0b10__00_0000__10__00_0000__1110__0000
          r |= u >> 12
          r |= ((u >> 6) & 0b11_1111) << 8
          r |= (u        & 0b11_1111) << 16
          scalarUtf8Length = 3
        }
      } else {
        let unit0 = u
        if _slowPath((unit0 >> 10) == 0b1101_11) {
          // `unit0` is a low-surrogate.  We have an ill-formed sequence.
          // Replace it with U+FFFD.
          r = 0xbdbfef
          scalarUtf8Length = 3
        } else if _slowPath(nextIndex.advancedBy(1) == endIndex) {
          // We have seen a high-surrogate and EOF, so we have an ill-formed
          // sequence.  Replace it with U+FFFD.
          r = 0xbdbfef
          scalarUtf8Length = 3
        } else {
          let unit1 = UInt(input[nextIndex.advancedBy(1)])
          if _fastPath((unit1 >> 10) == 0b1101_11) {
            // `unit1` is a low-surrogate.  We have a well-formed surrogate
            // pair.
            let v = 0x10000 + (((unit0 & 0x03ff) << 10) | (unit1 & 0x03ff))

            r = 0b10__00_0000__10__00_0000__10__00_0000__1111_0__000
            r |= v >> 18
            r |= ((v >> 12) & 0b11_1111) << 8
            r |= ((v >> 6) & 0b11_1111) << 16
            r |= (v        & 0b11_1111) << 24
            scalarUtf8Length = 4
            utf16Length = 2
          } else {
            // Otherwise, we have an ill-formed sequence.  Replace it with
            // U+FFFD.
            r = 0xbdbfef
            scalarUtf8Length = 3
          }
        }
      }
      // Don't overrun the buffer
      if utf8Count + scalarUtf8Length > utf8Max {
        break
      }
      result |= numericCast(r) << shift
      utf8Count += scalarUtf8Length
    }
    nextIndex = nextIndex.advancedBy(utf16Length)
  }
  // FIXME: Annoying check, courtesy of <rdar://problem/16740169>
  if utf8Count < sizeofValue(result) {
    result |= ~0 << numericCast(utf8Count * 8)
  }
  return (nextIndex, result)
}

/// Instances of conforming types are used in internal `String`
/// representation.
public // @testable
protocol _StringElementType {
  @warn_unused_result
  static func _toUTF16CodeUnit(_: Self) -> UTF16.CodeUnit

  @warn_unused_result
  static func _fromUTF16CodeUnit(utf16: UTF16.CodeUnit) -> Self
}

extension UTF16.CodeUnit : _StringElementType {
  public // @testable
  static func _toUTF16CodeUnit(x: UTF16.CodeUnit) -> UTF16.CodeUnit {
    return x
  }
  public // @testable
  static func _fromUTF16CodeUnit(
    utf16: UTF16.CodeUnit
  ) -> UTF16.CodeUnit {
    return utf16
  }
}

extension UTF8.CodeUnit : _StringElementType {
  public // @testable
  static func _toUTF16CodeUnit(x: UTF8.CodeUnit) -> UTF16.CodeUnit {
    _sanityCheck(x <= 0x7f, "should only be doing this with ASCII")
    return UTF16.CodeUnit(x)
  }
  public // @testable
  static func _fromUTF16CodeUnit(
    utf16: UTF16.CodeUnit
  ) -> UTF8.CodeUnit {
    _sanityCheck(utf16 <= 0x7f, "should only be doing this with ASCII")
    return UTF8.CodeUnit(utf16)
  }
}

extension UTF16 {
  /// Returns the number of code units required to encode `x`.
  @warn_unused_result
  public static func width(x: UnicodeScalar) -> Int {
    return x.value <= 0xFFFF ? 1 : 2
  }

  /// Returns the high surrogate code unit of a [surrogate pair](http://www.unicode.org/glossary/#surrogate_pair) representing
  /// `x`.
  ///
  /// - Requires: `width(x) == 2`.
  @warn_unused_result
  public static func leadSurrogate(x: UnicodeScalar) -> UTF16.CodeUnit {
    _precondition(width(x) == 2)
    return UTF16.CodeUnit((x.value - 0x1_0000) >> (10 as UInt32)) + 0xD800
  }

  /// Returns the low surrogate code unit of a [surrogate pair](http://www.unicode.org/glossary/#surrogate_pair) representing
  /// `x`.
  ///
  /// - Requires: `width(x) == 2`.
  @warn_unused_result
  public static func trailSurrogate(x: UnicodeScalar) -> UTF16.CodeUnit {
    _precondition(width(x) == 2)
    return UTF16.CodeUnit(
      (x.value - 0x1_0000) & (((1 as UInt32) << 10) - 1)
    ) + 0xDC00
  }

  @warn_unused_result
  public static func isLeadSurrogate(x: CodeUnit) -> Bool {
    return 0xD800...0xDBFF ~= x
  }

  @warn_unused_result
  public static func isTrailSurrogate(x: CodeUnit) -> Bool {
    return 0xDC00...0xDFFF ~= x
  }

  public // @testable
  static func _copy<T : _StringElementType, U : _StringElementType>(
    source: UnsafeMutablePointer<T>,
    destination: UnsafeMutablePointer<U>, count: Int
  ) {
    if strideof(T.self) == strideof(U.self) {
      _memcpy(
        dest: UnsafeMutablePointer(destination),
        src: UnsafeMutablePointer(source),
        size: UInt(count) * UInt(strideof(U.self)))
    }
    else {
      for i in 0..<count {
        let u16 = T._toUTF16CodeUnit((source + i).memory)
        (destination + i).memory = U._fromUTF16CodeUnit(u16)
      }
    }
  }

  /// Returns the number of UTF-16 code units required for the given code unit
  /// sequence when transcoded to UTF-16, and a bit describing if the sequence
  /// was found to contain only ASCII characters.
  ///
  /// If `repairIllFormedSequences` is `true`, the function always succeeds.
  /// If it is `false`, `nil` is returned if an ill-formed code unit sequence is
  /// found in `input`.
  @warn_unused_result
  public static func measure<
      Encoding : UnicodeCodecType, Input : GeneratorType
      where Encoding.CodeUnit == Input.Element
  >(
    _: Encoding.Type, input: Input, repairIllFormedSequences: Bool
  ) -> (Int, Bool)? {
    var input = input
    var count = 0
    var isAscii = true

    var inputDecoder = Encoding()
    loop:
    while true {
      switch inputDecoder.decode(&input) {
      case .Result(let us):
        if us.value > 0x7f {
          isAscii = false
        }
        count += width(us)
      case .EmptyInput:
        break loop
      case .Error:
        if !repairIllFormedSequences {
          return nil
        }
        isAscii = false
        count += width(UnicodeScalar(0xfffd))
      }
    }
    return (count, isAscii)
  }
}

// Unchecked init to avoid precondition branches in hot code paths were we
// already know the value is a valid unicode scalar.
extension UnicodeScalar {
  /// Create an instance with numeric value `value`, bypassing the regular
  /// precondition checks for code point validity.
  init(_unchecked value: UInt32) {
    _sanityCheck(value < 0xD800 || value > 0xDFFF,
      "high- and low-surrogate code points are not valid Unicode scalar values")
    _sanityCheck(value <= 0x10FFFF, "value is outside of Unicode codespace")

    self._value = value
  }
}
