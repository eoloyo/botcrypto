import unittest
from tlv import read_tlv, iter_tlv, encode_length, find_extension


class Visible(unittest.TestCase):
    def test_short_form(self):
        self.assertEqual(read_tlv(bytes([0x04, 0x02, 0xAA, 0xBB])), (0x04, b"\xaa\xbb", 4))

    def test_long_form_two_bytes(self):
        buf = bytes([0x04, 0x82, 0x01, 0x00]) + b"x" * 256
        tag, value, end = read_tlv(buf)
        self.assertEqual((tag, len(value), end), (0x04, 256, 260))

    def test_iter_two_items(self):
        buf = bytes([0x02, 0x01, 0x05, 0x05, 0x00])
        self.assertEqual(iter_tlv(buf), [(0x02, b"\x05"), (0x05, b"")])

    def test_encode_small(self):
        self.assertEqual(encode_length(5), b"\x05")
        self.assertEqual(encode_length(300), b"\x82\x01\x2c")

    def test_find_extension_plain(self):
        oid = bytes([0x55, 0x1D, 0x0E])
        ext = bytes([0x30, 0x09, 0x06, 0x03]) + oid + bytes([0x04, 0x02, 0xCA, 0xFE])
        self.assertEqual(find_extension(ext, oid), b"\xca\xfe")
        self.assertIsNone(find_extension(ext, bytes([0x55, 0x1D, 0x0F])))


if __name__ == "__main__":
    unittest.main()
