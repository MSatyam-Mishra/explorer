import 'dart:typed_data';

/// Implements a minimal SCSI / Bulk-Only Transport (BOT) driver.
/// See: https://www.usb.org/sites/default/files/usbmassbulk_10.pdf
class MassStorageDriver {
  static const int _cbwSignature = 0x43425355; // 'USBC'
  static const int _cswSignature = 0x53425355; // 'USBS'
  static const int _bulkOutEndpoint = 0; // Placeholder, set dynamically
  static const int _bulkInEndpoint = 0; // Placeholder, set dynamically

  int _tag = 1;

  Uint8List createCBW({
    required int dataTransferLength,
    required bool directionIn,
    required int lun,
    required Uint8List cb, // Command Block (SCSI CDB)
  }) {
    final buffer = ByteData(31);
    buffer.setUint32(0, _cbwSignature, Endian.little);
    buffer.setUint32(4, _tag++, Endian.little);
    buffer.setUint32(8, dataTransferLength, Endian.little);
    buffer.setUint8(
      12,
      directionIn ? 0x80 : 0x00,
    ); // Flags: 0x80 = IN, 0x00 = OUT
    buffer.setUint8(13, lun); // LUN
    buffer.setUint8(14, cb.length); // CB Length

    // Copy CB
    for (int i = 0; i < cb.length; i++) {
      buffer.setUint8(15 + i, cb[i]);
    }

    return buffer.buffer.asUint8List();
  }

  // SCSI Command: READ_10 (0x28)
  // SCSI Command: WRITE_10 (0x2A)
  // SCSI Command: INQUIRY (0x12)
  // SCSI Command: READ_CAPACITY_10 (0x25)

  static const int opWrite10 = 0x2A;
  static const int opReadCapacity10 = 0x25;

  Uint8List buildWrite10CDB({
    required int logicalBlockAddress,
    required int transferLengthBlocks,
  }) {
    final cdb = ByteData(10);
    cdb.setUint8(0, opWrite10);
    cdb.setUint8(1, 0); // Relay/Obsolete
    cdb.setUint32(2, logicalBlockAddress, Endian.big); // LBA (Big Endian)
    cdb.setUint8(6, 0); // Reserved
    cdb.setUint16(7, transferLengthBlocks, Endian.big); // Transfer Length
    cdb.setUint8(9, 0); // Control
    return cdb.buffer.asUint8List();
  }

  Uint8List buildReadCapacity10CDB() {
    final cdb = ByteData(10);
    cdb.setUint8(0, opReadCapacity10);
    // Rest is usually 0
    return cdb.buffer.asUint8List();
  }
}
