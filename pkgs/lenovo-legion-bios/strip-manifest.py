"""Neutralize the RT_MANIFEST resource of Windows PEs in place.

The ESD-extracted WinPE cannot create activation contexts for 32-bit
applications (every manifest-bearing binary fails with
ERROR_SXS_CANT_GEN_ACTCTX, regardless of manifest content - validated under
QEMU 2026-09-13). Removing the manifest resource makes the loader use the
default context and the plain DLL search order, so the vendor VC90 DLLs
shipped flat in the same directory resolve normally.

Mechanism: for each PE, walk the resource directory to the type-24
(RT_MANIFEST) subdirectory and zero its NumberOfNamedEntries /
NumberOfIdEntries fields, turning it into an empty directory. The PE headers,
sections and code remain untouched.
"""

import struct
import sys

import pefile

RT_MANIFEST = 24


def zero_manifest_directory(path: str) -> bool:
    pe = pefile.PE(path)
    if not hasattr(pe, "DIRECTORY_ENTRY_RESOURCE"):
        return False
    root_file_off = pe.get_offset_from_rva(
        pe.OPTIONAL_HEADER.DATA_DIRECTORY[2].VirtualAddress
    )
    patched = False
    for entry in pe.DIRECTORY_ENTRY_RESOURCE.entries:
        if entry.struct.Id != RT_MANIFEST:
            continue
        # Resource-tree offsets are relative to the resource root, not image RVAs.
        file_off = root_file_off + (entry.struct.OffsetToData & 0x7FFFFFFF)
        with open(path, "r+b") as f:
            f.seek(file_off + 12)
            counts = f.read(4)
            if counts != b"\x00\x00\x00\x00":
                f.seek(file_off + 12)
                f.write(b"\x00\x00\x00\x00")
                patched = True
    return patched


def main() -> None:
    for path in sys.argv[1:]:
        if zero_manifest_directory(path):
            print(f"neutralized RT_MANIFEST: {path}")
        else:
            print(f"no RT_MANIFEST entries: {path}")


if __name__ == "__main__":
    main()
