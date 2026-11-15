"""Minimal DER TLV reader (see README.md)."""


def read_tlv(buf, offset=0):
    if offset < 0 or offset + 2 > len(buf):
        raise ValueError("truncated header")
    tag = buf[offset]
    if tag & 0x1F == 0x1F:
        raise ValueError("high-tag-number form not supported")
    first = buf[offset + 1]
    pos = offset + 2
    if first < 0x80:
        length = first
    else:
        n = first & 0x7F
        if n == 0:
            raise ValueError("indefinite length")
        if n > 4:
            raise ValueError("length too large")
        if pos + n > len(buf):
            raise ValueError("truncated length")
        length = int.from_bytes(buf[pos:pos + n], "big")
        pos += n
    end = pos + length
    if end > len(buf):
        raise ValueError("truncated value")
    return tag, bytes(buf[pos:end]), end


def iter_tlv(buf):
    out = []
    offset = 0
    while offset < len(buf):
        tag, value, offset = read_tlv(buf, offset)
        out.append((tag, value))
    return out


def encode_length(n):
    if n < 0 or n >= 2 ** 32:
        raise ValueError("length out of range")
    if n < 0x80:
        return bytes([n])
    body = n.to_bytes((n.bit_length() + 7) // 8, "big")
    return bytes([0x80 | len(body)]) + body


def find_extension(extensions, oid):
    for tag, ext in iter_tlv(extensions):
        if tag != 0x30:
            raise ValueError("extension is not a SEQUENCE")
        parts = iter_tlv(ext)
        if not parts or parts[0][0] != 0x06:
            raise ValueError("extension without an OID")
        rest = parts[1:]
        if rest and rest[0][0] == 0x01:
            rest = rest[1:]
        if len(rest) != 1 or rest[0][0] != 0x04:
            raise ValueError("extension without an extnValue")
        if parts[0][1] == oid:
            return rest[0][1]
    return None
