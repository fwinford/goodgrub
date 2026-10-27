// Pure, dependency-free structural image validation shared by the two routes
// that accept an uploaded screenshot: the W4-S1 proposal route and the W4-H1a
// placed-order evidence validator. Moved out of `screenshotProposalRoute.ts`
// byte-for-byte (only `export` was added to the two entry points), so S1's
// accepted behavior is unchanged and there is exactly one implementation of
// this security-sensitive parsing. Nothing here reads, logs, or stores bytes.

/**
 * Strict base64 acceptance ahead of decoding: `Buffer.from(str, "base64")`
 * does not throw on invalid input — it silently drops unrecognized
 * characters — so a malformed payload would otherwise decode into whatever
 * bytes happened to remain rather than being refused.
 *
 * A single flat character class with no nested repetition, checked
 * separately from the length/multiple-of-4 requirement: an equivalent
 * pattern built from a repeated 4-character group
 * (`(?:[A-Za-z0-9+/]{4})*...`) hit V8's regex call-stack limit on inputs at
 * this route's multi-megabyte size ceiling. `={0,2}$` anchors padding to the
 * very end only, since the preceding `+` class excludes `=` itself — no
 * interior padding character can match.
 */
const BASE64_PATTERN = /^[A-Za-z0-9+/]+={0,2}$/;

export function isStrictBase64(value: string): boolean {
  return value.length > 0 && value.length % 4 === 0 && BASE64_PATTERN.test(value);
}

/** Full 8-byte PNG signature, not just its first 4 bytes. */
const PNG_SIGNATURE = Buffer.from([
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
]);
/** Signature (8) + the smallest possible complete chunk stream: an IHDR
 * chunk (8 + 13 + 4 CRC bytes) and an IEND chunk (8 + 0 + 4 CRC bytes). */
const PNG_MIN_STRUCTURAL_BYTES = 8 + (8 + 13 + 4) + (8 + 0 + 4);
/** Defense against a pathological many-tiny-chunks payload; a real PNG
 * this route's size ceiling would ever encounter needs nowhere near this
 * many chunks. */
const PNG_MAX_CHUNKS = 512;

/** Standard IEEE 802.3 CRC-32 table, used to verify each PNG chunk's CRC —
 * the same algorithm every PNG encoder/decoder uses. Verifying it is what
 * turns "these bytes have the right shape" into "these bytes are a
 * self-consistent chunk stream," without decoding image content. */
const CRC32_TABLE: Uint32Array = (() => {
  const table = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) {
      c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    }
    table[n] = c >>> 0;
  }
  return table;
})();

function crc32(buffer: Buffer): number {
  let crc = 0xffffffff;
  for (let i = 0; i < buffer.length; i++) {
    crc = CRC32_TABLE[(crc ^ buffer[i]!) & 0xff]! ^ (crc >>> 8);
  }
  return (crc ^ 0xffffffff) >>> 0;
}

/**
 * Valid PNG bit-depth values per color type (spec table 11.1). A combination
 * outside this table cannot be decoded by any conforming PNG decoder — it is
 * not merely unusual, it is an impossible image.
 */
const PNG_VALID_BIT_DEPTHS_BY_COLOR_TYPE: Readonly<Record<number, readonly number[]>> = {
  0: [1, 2, 4, 8, 16], // grayscale
  2: [8, 16], // truecolor
  3: [1, 2, 4, 8], // indexed-color
  4: [8, 16], // grayscale + alpha
  6: [8, 16], // truecolor + alpha
};

/**
 * Validates the fixed 13-byte IHDR payload against every invariant the PNG
 * spec places on it, independent of chunk shape/CRC (which the caller has
 * already verified). A CRC-valid IHDR whose *content* describes an
 * impossible image — zero width/height, an invalid bit-depth/color-type
 * combination, a non-zero compression/filter method, or an out-of-range
 * interlace method — is not a real PNG a conforming encoder could ever have
 * produced, and must be refused before this payload is treated as a
 * supported image.
 */
function isValidIhdrSemantics(ihdr: Buffer): boolean {
  const width = ihdr.readUInt32BE(0);
  const height = ihdr.readUInt32BE(4);
  const bitDepth = ihdr[8]!;
  const colorType = ihdr[9]!;
  const compressionMethod = ihdr[10]!;
  const filterMethod = ihdr[11]!;
  const interlaceMethod = ihdr[12]!;

  if (width === 0 || height === 0) return false;
  const validBitDepths = PNG_VALID_BIT_DEPTHS_BY_COLOR_TYPE[colorType];
  if (!validBitDepths || !validBitDepths.includes(bitDepth)) return false;
  // The only value ever defined for either method; any other value is not
  // merely unsupported, it is not a valid PNG.
  if (compressionMethod !== 0) return false;
  if (filterMethod !== 0) return false;
  // 0 = no interlace, 1 = Adam7; nothing else is defined.
  if (interlaceMethod !== 0 && interlaceMethod !== 1) return false;

  return true;
}

/**
 * Walks the complete PNG chunk stream after the 8-byte signature, the
 * bounded structural parser this format gets instead of full image
 * decoding. Requires, in order: the first chunk is exactly `IHDR` with its
 * fixed 13-byte payload and semantically valid content
 * (`isValidIhdrSemantics`); every chunk's declared length stays inside the
 * buffer; every chunk's CRC-32 (computed over its own type+data, the same
 * way every PNG encoder computes it) matches its stored CRC exactly; at
 * least one `IDAT` chunk appears; and the stream ends with a zero-length
 * `IEND` chunk that is the last thing in the buffer — not merely present
 * somewhere, but exactly consuming every remaining byte.
 *
 * This rejects a payload that has a well-formed `IHDR` header (the right
 * length, type, and even a correctly recomputed CRC) but content describing
 * an impossible image — e.g. width `0` — which a shape-and-CRC-only check
 * cannot catch, since an attacker can always recompute a valid CRC for
 * whatever 13 bytes they choose.
 */
function isStructurallyValidPng(buffer: Buffer): boolean {
  if (buffer.length < PNG_MIN_STRUCTURAL_BYTES) return false;
  if (!buffer.subarray(0, 8).equals(PNG_SIGNATURE)) return false;

  let offset = 8;
  let chunkIndex = 0;
  let sawIDAT = false;

  while (offset < buffer.length) {
    chunkIndex += 1;
    if (chunkIndex > PNG_MAX_CHUNKS) return false;
    if (offset + 8 > buffer.length) return false;

    const length = buffer.readUInt32BE(offset);
    const type = buffer.toString("ascii", offset + 4, offset + 8);
    const dataStart = offset + 8;
    const dataEnd = dataStart + length;
    const crcEnd = dataEnd + 4;
    if (crcEnd > buffer.length) return false;

    if (chunkIndex === 1) {
      if (type !== "IHDR" || length !== 13) return false;
      if (!isValidIhdrSemantics(buffer.subarray(dataStart, dataEnd))) return false;
    }

    const storedCrc = buffer.readUInt32BE(dataEnd);
    const computedCrc = crc32(buffer.subarray(offset + 4, dataEnd));
    if (storedCrc !== computedCrc) return false;

    if (type === "IDAT") sawIDAT = true;
    if (type === "IEND") {
      return length === 0 && sawIDAT && crcEnd === buffer.length;
    }

    offset = crcEnd;
  }

  return false;
}

const JPEG_SOI_MARKER = Buffer.from([0xff, 0xd8]);
const JPEG_EOI_MARKER = Buffer.from([0xff, 0xd9]);
/** A real screenshot is comfortably larger than this; nothing this small can
 * hold usable Grubhub screen content regardless of format validity. */
const JPEG_MIN_STRUCTURAL_BYTES = 100;
/** Same defensive bound as `PNG_MAX_CHUNKS`, for marker segments. */
const JPEG_MAX_SEGMENTS = 512;
/** Start-Of-Frame markers (baseline/progressive/etc. DCT), excluding
 * 0xC4 (DHT), 0xC8 (reserved/JPG), and 0xCC (DAC) — those share the 0xC0–0xCF
 * range but are not frame headers. */
function isStartOfFrameMarker(marker: number): boolean {
  return marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc;
}
const JPEG_START_OF_SCAN_MARKER = 0xda;
/** Markers with no following length-prefixed segment. */
function isStandaloneMarker(marker: number): boolean {
  return marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7);
}

/**
 * SOF payload: precision(1) + height(2) + width(2) + numComponents(1),
 * followed by 3 bytes (id, sampling factors, quant-table selector) per
 * component. The length field itself (2 bytes) plus that fixed 6-byte
 * header is the smallest a segment declaring at least one component can be.
 */
const JPEG_SOF_FIXED_HEADER_BYTES = 6;
const JPEG_SOF_MIN_SEGMENT_LENGTH = 2 + JPEG_SOF_FIXED_HEADER_BYTES + 3;
/** Every real encoder this route accepts a screenshot from produces
 * grayscale (1), YCbCr (3), or CMYK/YCCK (4) frames; nothing else is a
 * plausible photographic/UI screenshot. */
const JPEG_MAX_FRAME_COMPONENTS = 4;

/** SOS payload: numComponents(1), 2 bytes per scan component (selector +
 * table selectors), then spectral-selection/approximation (3 bytes). */
const JPEG_SOS_FIXED_HEADER_BYTES = 1 + 3;
const JPEG_SOS_MIN_SEGMENT_LENGTH = 2 + JPEG_SOS_FIXED_HEADER_BYTES + 2;

interface JpegFrame {
  componentCount: number;
}

/**
 * Validates a Start-Of-Frame segment's actual payload — not merely that a
 * SOF marker is present with *some* length >= 2. `segmentStart` points at
 * the segment's 2-byte length field; the caller has already bounds-checked
 * `segmentStart + segmentLength` against the buffer. Requires: nonzero
 * width and height (a zero-dimension frame is not a real image), a
 * component count in the range real encoders produce, and — critically —
 * the segment's declared length exactly matching what that component count
 * requires, so a segment claiming a component but not actually carrying its
 * 3-byte descriptor is refused rather than silently accepted.
 */
function parseStartOfFrame(
  buffer: Buffer,
  segmentStart: number,
  segmentLength: number
): JpegFrame | null {
  if (segmentLength < JPEG_SOF_MIN_SEGMENT_LENGTH) return null;
  const payloadStart = segmentStart + 2;
  const height = buffer.readUInt16BE(payloadStart + 1);
  const width = buffer.readUInt16BE(payloadStart + 3);
  const componentCount = buffer[payloadStart + 5]!;
  if (width === 0 || height === 0) return null;
  if (componentCount < 1 || componentCount > JPEG_MAX_FRAME_COMPONENTS) return null;
  const expectedLength = 2 + JPEG_SOF_FIXED_HEADER_BYTES + 3 * componentCount;
  if (segmentLength !== expectedLength) return null;
  return { componentCount };
}

/**
 * Validates a Start-Of-Scan segment's actual payload against the frame it
 * must belong to (`frame`, from a SOF this walker has already accepted
 * earlier in the same stream — a SOS with no prior SOF is refused by the
 * caller, never reaching this function). Requires: at least one scan
 * component, no more scan components than the frame actually declared (a
 * scan cannot reference a component the frame never defined), and the
 * segment's declared length exactly matching what that scan component count
 * requires.
 */
function isValidStartOfScan(
  buffer: Buffer,
  segmentStart: number,
  segmentLength: number,
  frame: JpegFrame
): boolean {
  if (segmentLength < JPEG_SOS_MIN_SEGMENT_LENGTH) return false;
  const payloadStart = segmentStart + 2;
  const scanComponentCount = buffer[payloadStart]!;
  if (scanComponentCount < 1 || scanComponentCount > frame.componentCount) return false;
  const expectedLength = 2 + 1 + 2 * scanComponentCount + 3;
  return segmentLength === expectedLength;
}

/**
 * Walks JPEG marker segments after the SOI marker — the bounded structural
 * parser this format gets instead of full image decoding. Requires a
 * genuine Start-Of-Frame segment with valid, internally consistent content
 * (`parseStartOfFrame`) followed by a Start-Of-Scan segment whose content is
 * valid and consistent with that frame (`isValidStartOfScan`) — not merely
 * that SOF/SOS markers are present with *some* length. Both are discovered
 * by actually walking length-prefixed segments rather than assumed from a
 * prefix. Once a valid SOS is confirmed this stops walking — the
 * entropy-coded scan data that follows is not re-parsed as segments — but
 * the buffer was already confirmed to end with a genuine EOI marker before
 * this walk begins, so "SOI + APP0 + padding + EOI" (no real frame/scan
 * structure at all) fails here even though the outer bytes look plausible,
 * and so does "SOF/SOS present but with an empty/impossible payload."
 */
function isStructurallyValidJpeg(buffer: Buffer): boolean {
  if (buffer.length < JPEG_MIN_STRUCTURAL_BYTES) return false;
  if (!buffer.subarray(0, 2).equals(JPEG_SOI_MARKER)) return false;
  if (!buffer.subarray(buffer.length - 2).equals(JPEG_EOI_MARKER)) return false;

  let offset = 2;
  let segmentIndex = 0;
  let frame: JpegFrame | null = null;

  while (offset < buffer.length - 1) {
    segmentIndex += 1;
    if (segmentIndex > JPEG_MAX_SEGMENTS) return false;
    if (buffer[offset] !== 0xff) return false;

    // Marker padding: a run of extra 0xFF fill bytes may precede the
    // actual marker byte.
    let markerOffset = offset + 1;
    while (markerOffset < buffer.length && buffer[markerOffset] === 0xff) {
      markerOffset += 1;
    }
    if (markerOffset >= buffer.length) return false;
    const marker = buffer[markerOffset]!;
    offset = markerOffset + 1;

    if (isStandaloneMarker(marker)) continue;
    if (marker === 0xd9) return false; // EOI reached before a real scan segment

    if (offset + 2 > buffer.length) return false;
    const segmentLength = buffer.readUInt16BE(offset);
    if (segmentLength < 2 || offset + segmentLength > buffer.length) return false;

    if (isStartOfFrameMarker(marker)) {
      frame = parseStartOfFrame(buffer, offset, segmentLength);
      if (!frame) return false;
    }

    if (marker === JPEG_START_OF_SCAN_MARKER) {
      if (!frame) return false;
      return isValidStartOfScan(buffer, offset, segmentLength, frame);
    }

    offset += segmentLength;
  }

  return false;
}

/**
 * Bounded structural validity, not full image decoding: a single forward
 * walk over chunk/marker headers per format, with no decompression and no
 * unbounded scanning (`PNG_MAX_CHUNKS`/`JPEG_MAX_SEGMENTS` cap iteration).
 * This is still not authenticity verification — a well-formed PNG/JPEG with
 * fabricated pixel content passes exactly as the accepted eligibility
 * contract already allows — but it rejects truncated files, valid-prefix-
 * plus-garbage payloads, and constructed non-images that merely start and
 * end with the right marker bytes.
 */
export function isStructurallyValidImage(buffer: Buffer, mimeType: string): boolean {
  if (mimeType === "image/png") return isStructurallyValidPng(buffer);
  if (mimeType === "image/jpeg") return isStructurallyValidJpeg(buffer);
  return false;
}
