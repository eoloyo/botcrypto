#!/usr/bin/env python3
"""
patch-gvisor-oom.py — neutralise gVisor's OOM-score self-protection writes.

WHY THIS EXISTS
---------------
gVisor (runsc) and its containerd shim try to lower their own / the sandbox's
`oom_score_adj` to a negative value (-999 / -998) so the Linux OOM killer spares
the sandbox supervisor. Lowering oom_score_adj below the inherited value requires
the CAP_SYS_RESOURCE capability. Some locked-down/nested environments strip that
capability from the kernel capability *bounding set* (so not even a --privileged
container can regain it). There, the negative write returns EPERM and gVisor
treats it as FATAL, so no pod sandbox can start.

This script rewrites the *entry* of the two functions that perform those writes
so they become `return nil` no-ops:

  * runsc binary : gvisor.dev/gvisor/runsc/container.setOOMScoreAdj
  * shim  binary : github.com/containerd/containerd/v2/pkg/sys.SetOOMScore
                   (compiled into containerd-shim-runsc-v1)

The functions return a single `error`; on amd64 Go regabi that is (AX,BX). We
overwrite the first 7 bytes of the entry with:

    31 C0            XOR EAX, EAX      ; data word = 0
    31 DB            XOR EBX, EBX      ; type word = 0  -> nil error
    C3               RET
    90 90            NOP NOP           ; padding

Offsets are re-derived per binary via `go tool objdump -s <symbol>` + the ELF
program headers, so the patch is not tied to a specific gVisor release. It only
touches COPIES you pass in; leave your real /usr/bin binaries alone.

SECURITY NOTE: this disables an OOM-killer hardening measure. Do this ONLY in a
throwaway lab/CI sandbox, never on a real node.

USAGE
-----
    python3 patch-gvisor-oom.py <binary> <symbol-substring>
e.g.
    python3 patch-gvisor-oom.py ./runsc.patched         container.setOOMScoreAdj
    python3 patch-gvisor-oom.py ./shim.patched          sys.SetOOMScore
"""
import re
import struct
import subprocess
import sys

NOP_RET = bytes([0x31, 0xC0, 0x31, 0xDB, 0xC3, 0x90, 0x90])  # XOR AX;XOR BX;RET;NOP;NOP
# Go amd64 stack-check prologue: LEAQ -0xNN(SP), R12 ; CMPQ R12, 0x10(R14)
PROLOGUE = re.compile(rb"\x4c\x8d\x64\x24.\x4d\x3b\x66\x10")


def entry_vaddr(binary: str, symbol: str) -> int:
    out = subprocess.run(
        ["go", "tool", "objdump", "-s", re.escape(symbol), binary],
        check=True, capture_output=True, text=True,
    ).stdout
    lines = out.splitlines()
    for i, line in enumerate(lines):
        if line.startswith("TEXT ") and symbol in line:
            for nxt in lines[i + 1:]:
                m = re.search(r"\s(0x[0-9a-fA-F]+)\s", nxt)
                if m:
                    return int(m.group(1), 16)
    raise SystemExit(f"symbol {symbol!r} not found in {binary}")


def vaddr_to_offset(data: bytes, vaddr: int) -> int:
    e_phoff = struct.unpack_from("<Q", data, 0x20)[0]
    e_phentsize = struct.unpack_from("<H", data, 0x36)[0]
    e_phnum = struct.unpack_from("<H", data, 0x38)[0]
    for i in range(e_phnum):
        o = e_phoff + i * e_phentsize
        p_type = struct.unpack_from("<I", data, o)[0]
        p_offset, p_vaddr, _p_paddr, p_filesz = struct.unpack_from("<QQQQ", data, o + 8)
        if p_type == 1 and p_vaddr <= vaddr < p_vaddr + p_filesz:  # PT_LOAD
            return p_offset + (vaddr - p_vaddr)
    raise SystemExit(f"vaddr {vaddr:#x} not in any PT_LOAD segment")


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    binary, symbol = sys.argv[1], sys.argv[2]
    if not open(binary, "rb").read(4) == b"\x7fELF":
        raise SystemExit(f"{binary} is not an ELF binary")

    vaddr = entry_vaddr(binary, symbol)
    data = bytearray(open(binary, "rb").read())
    off = vaddr_to_offset(data, vaddr)

    if data[off:off + len(NOP_RET)] == NOP_RET:
        print(f"[=] {symbol}: already patched (offset {off:#x})")
        return
    if not PROLOGUE.match(bytes(data[off:off + 9])):
        raise SystemExit(
            f"[!] {symbol}: entry at {off:#x} is not a recognised Go func prologue "
            f"({bytes(data[off:off+9]).hex()}); refusing to patch"
        )
    orig = bytes(data[off:off + len(NOP_RET)])
    data[off:off + len(NOP_RET)] = NOP_RET
    open(binary, "wb").write(data)
    print(f"[+] {symbol}: patched -> return nil  (offset {off:#x}, {orig.hex()} -> {NOP_RET.hex()})")


if __name__ == "__main__":
    main()
