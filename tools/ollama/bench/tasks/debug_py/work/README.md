# dertlv: a minimal DER TLV reader

`tlv.py` must behave as follows. `ValueError` is raised for every malformed input.

1. `read_tlv(buf, offset=0) -> (tag, value, next_offset)` reads one TLV at `offset`.
   - Tags are a single byte (high-tag-number form, tag byte & 0x1f == 0x1f, is rejected).
   - Lengths: short form (one byte, 0..127) and definite long form (first byte 0x81..0x84, followed by
     that many big-endian length bytes).
   - The indefinite form (0x80) and long forms with more than 4 length bytes are rejected.
   - If the header or the value runs past the end of `buf`, the input is truncated: rejected.
2. `iter_tlv(buf) -> list of (tag, value)` returns every TLV in `buf`, in order. `buf` must be consumed
   exactly; an empty buffer gives an empty list.
3. `encode_length(n) -> bytes` returns the minimal DER length encoding of `n` (0 <= n < 2**32);
   negative or larger values are rejected.
4. `find_extension(extensions, oid) -> bytes | None`. `extensions` is the content of a SEQUENCE OF
   Extension, where Extension ::= SEQUENCE { extnID OBJECT IDENTIFIER, critical BOOLEAN OPTIONAL,
   extnValue OCTET STRING }. `oid` is the DER content bytes of the wanted OID. Return the content of
   that extension's extnValue OCTET STRING, or None if no extension has that OID. A malformed
   Extension is rejected.

Run the visible tests with `python3 -m unittest -q`.
