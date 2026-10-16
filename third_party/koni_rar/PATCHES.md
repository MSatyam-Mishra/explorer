# Local patches to koni_rar 0.9.0

Vendored from https://pub.dev/packages/koni_rar (MIT, see LICENSE and NOTICE)
because two bugs made common RAR archives unreadable. Remove this copy and
depend on the published package once upstream includes equivalent fixes.

1. `lib/src/rar5_decoder.dart` `decompressFile`: a solid run whose first
   member is an empty file failed with "RAR5 block without Huffman tables".
   WinRAR stores the run's Huffman tables in that empty member's packed data
   (27 bytes in the test archive), but the decoder skipped its blocks because
   the output size was zero. It now reads the first block of a zero-length
   member so later members can use its tables.

2. `lib/src/rar_reader.dart` (RAR5 and RAR4 solid paths): when looking back
   for the start of a solid run, directory entries no longer count as a run
   boundary, so a directory header inside a run can't restart decoding with
   empty state.

3. The app's RAR driver (lib/core/formats/archive_rar.dart) doesn't use
   this package's `RarReader`; it uses this package's container, crypto,
   PPMd and filter code with patched copies of the two decoders in
   lib/core/formats/archive_rar5_decoder.dart and archive_rar4_decoder.dart.
   Those copies also fix, for solid archives: x86/ARM filter addresses taken
   from the window position instead of the file start, and filters applied
   in place in the LZ window (later members then matched filtered bytes) —
   executables after the first in a solid archive failed their CRC. Solid
   runs larger than the dictionary also decode there, in a bounded window.
   Fold these into this package if upstream takes them.

Verified byte-for-byte against WinRAR 7 output (store, -m1..-m5, solid, -p,
-hp, 6-volume set) and libarchive's RAR4 test archives.
