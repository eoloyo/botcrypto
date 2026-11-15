import unittest
from tlv import read_tlv, iter_tlv, encode_length, find_extension

OID_A = bytes([0x55, 0x1D, 0x0E])
OID_B = bytes([0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x30, 0x01, 0x02])


def ext(oid, value, critical=None):
    body = bytes([0x06, len(oid)]) + oid
    if critical is not None:
        body += bytes([0x01, 0x01, 0xFF if critical else 0x00])
    body += bytes([0x04, len(value)]) + value
    return bytes([0x30, len(body)]) + body


class Hidden(unittest.TestCase):
    def test_long_form_one_byte(self):
        buf = bytes([0x04, 0x81, 0x80]) + b"y" * 128
        self.assertEqual(read_tlv(buf)[2], 131)

    def test_long_form_big_endian(self):
        buf = bytes([0x04, 0x82, 0x01, 0x02]) + b"z" * 258
        tag, value, end = read_tlv(buf)
        self.assertEqual((len(value), end), (258, 262))

    def test_long_form_three_bytes(self):
        buf = bytes([0x04, 0x83, 0x01, 0x00, 0x01]) + b"q" * 65537
        self.assertEqual(len(read_tlv(buf)[1]), 65537)

    def test_offset(self):
        buf = bytes([0xFF, 0x02, 0x01, 0x09])
        self.assertEqual(read_tlv(buf, 1), (0x02, b"\x09", 4))

    def test_indefinite_rejected(self):
        with self.assertRaises(ValueError):
            read_tlv(bytes([0x30, 0x80, 0x00, 0x00]))

    def test_too_many_length_bytes(self):
        with self.assertRaises(ValueError):
            read_tlv(bytes([0x04, 0x85, 0, 0, 0, 0, 1, 0x41]))

    def test_truncated_value(self):
        with self.assertRaises(ValueError):
            read_tlv(bytes([0x04, 0x05, 0x01, 0x02]))

    def test_truncated_header(self):
        with self.assertRaises(ValueError):
            read_tlv(bytes([0x04]))
        with self.assertRaises(ValueError):
            read_tlv(bytes([0x04, 0x82, 0x01]))

    def test_high_tag_rejected(self):
        with self.assertRaises(ValueError):
            read_tlv(bytes([0x1F, 0x81, 0x00]))

    def test_iter_exact_end_and_empty(self):
        self.assertEqual(iter_tlv(b""), [])
        self.assertEqual(iter_tlv(bytes([0x05, 0x00])), [(0x05, b"")])
        self.assertEqual(iter_tlv(bytes([0x02, 0x01, 0x01, 0x05, 0x00])), [(0x02, b"\x01"), (0x05, b"")])

    def test_iter_trailing_garbage(self):
        with self.assertRaises(ValueError):
            iter_tlv(bytes([0x02, 0x01, 0x01, 0x04]))

    def test_encode_boundaries(self):
        cases = {0: b"\x00", 127: b"\x7f", 128: b"\x81\x80", 255: b"\x81\xff", 256: b"\x82\x01\x00",
                 65535: b"\x82\xff\xff", 65536: b"\x83\x01\x00\x00", 2 ** 32 - 1: b"\x84\xff\xff\xff\xff"}
        for n, want in cases.items():
            self.assertEqual(encode_length(n), want, n)

    def test_encode_rejects(self):
        for n in (-1, 2 ** 32):
            with self.assertRaises(ValueError):
                encode_length(n)

    def test_encode_roundtrip(self):
        for n in (1, 200, 4096, 70000):
            buf = bytes([0x04]) + encode_length(n) + b"r" * n
            self.assertEqual(len(read_tlv(buf)[1]), n)

    def test_find_with_critical(self):
        exts = ext(OID_A, b"\x01\x02") + ext(OID_B, b"\x04\x02\xbe\xef", critical=True)
        self.assertEqual(find_extension(exts, OID_B), b"\x04\x02\xbe\xef")
        self.assertEqual(find_extension(exts, OID_A), b"\x01\x02")

    def test_find_critical_false_and_missing(self):
        exts = ext(OID_A, b"\x07", critical=False)
        self.assertEqual(find_extension(exts, OID_A), b"\x07")
        self.assertIsNone(find_extension(exts, OID_B))
        self.assertIsNone(find_extension(b"", OID_A))

    def test_find_malformed(self):
        no_value = bytes([0x30, 0x05, 0x06, 0x03]) + OID_A
        with self.assertRaises(ValueError):
            find_extension(no_value, OID_A)
        not_seq = bytes([0x04, 0x02, 0x00, 0x00])
        with self.assertRaises(ValueError):
            find_extension(not_seq, OID_A)
        wrong_type = bytes([0x30, 0x08, 0x06, 0x03]) + OID_A + bytes([0x02, 0x01, 0x05])
        with self.assertRaises(ValueError):
            find_extension(wrong_type, OID_A)


if __name__ == "__main__":
    unittest.main()
