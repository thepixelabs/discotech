import Darwin

/// Thin, allocation-light wrapper around `getattrlistbulk(2)`.
///
/// We hand-roll the attribute bitmap constants instead of relying on the imported
/// C macros from `<sys/attr.h>`: several of them (e.g. `ATTR_CMN_RETURNED_ATTRS` =
/// 0x80000000) straddle the Int32/UInt32 import boundary and the ClangImporter's
/// choice of type is not worth depending on. These values are stable Darwin ABI
/// (unchanged since 10.10) — see `/usr/include/sys/attr.h`.
enum Attr {
    // Common attribute group (attrlist.commonattr).
    static let cmnName: UInt32 = 0x0000_0001
    static let cmnDevID: UInt32 = 0x0000_0002
    static let cmnObjType: UInt32 = 0x0000_0008
    static let cmnFileID: UInt32 = 0x0200_0000
    static let cmnError: UInt32 = 0x2000_0000
    static let cmnReturnedAttrs: UInt32 = 0x8000_0000

    // Directory attribute group (attrlist.dirattr).
    static let dirMountStatus: UInt32 = 0x0000_0004
    static let dirMntStatusMntPoint: UInt32 = 0x0000_0001

    // File attribute group (attrlist.fileattr).
    static let fileLinkCount: UInt32 = 0x0000_0001
    static let fileAllocSize: UInt32 = 0x0000_0004

    // fsobj_type_t values (match `enum vtype` in <sys/vnode.h>).
    static let vDirectory: UInt32 = 2
}

/// One directory entry as decoded from a `getattrlistbulk` result buffer.
struct BulkEntry {
    var name: String
    var objType: UInt32
    var devID: Int32
    var fileID: UInt64
    /// Only meaningful when `objType == Attr.vDirectory`.
    var isMountPoint: Bool
    /// Only valid when `hasFileAttrs` is true (i.e. the filesystem returned the
    /// file attribute group for this entry — normally regular files only).
    var hasFileAttrs: Bool
    var allocSize: Int64
    var linkCount: UInt32

    var isDirectory: Bool { objType == Attr.vDirectory }
}

enum AttrListBulkError: Error {
    case syscallFailed(errno: Int32)
}

/// Lists every entry of an already-open directory `dirFD`, invoking `onEntry` for
/// each successfully-decoded entry. Entries that the kernel reports an error for
/// (`ATTR_CMN_ERROR`, e.g. a file that vanished mid-listing) are skipped silently.
///
/// `scratch` is a caller-owned reusable buffer (one per worker thread) so we don't
/// allocate a fresh buffer for every directory — this matters at the scale of
/// millions of directories.
///
/// Throws only if the initial `getattrlistbulk` call itself fails (e.g. the fd
/// was invalidated) or if `onEntry` throws (used to propagate cancellation).
func listDirectoryBulk(
    dirFD: Int32,
    scratch: UnsafeMutableRawBufferPointer,
    onEntry: (BulkEntry) throws -> Void
) throws {
    var list = attrlist()
    list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
    list.commonattr = Attr.cmnReturnedAttrs | Attr.cmnName | Attr.cmnError
        | Attr.cmnObjType | Attr.cmnDevID | Attr.cmnFileID
    list.dirattr = Attr.dirMountStatus
    list.fileattr = Attr.fileLinkCount | Attr.fileAllocSize

    while true {
        let count: Int32 = withUnsafeMutablePointer(to: &list) { listPtr in
            Int32(getattrlistbulk(dirFD, listPtr, scratch.baseAddress, scratch.count, 0))
        }
        if count < 0 {
            throw AttrListBulkError.syscallFailed(errno: errno)
        }
        if count == 0 { return }

        var entryOffset = 0
        for _ in 0..<count {
            var field = entryOffset

            let length = scratch.loadUnaligned(fromByteOffset: field, as: UInt32.self)
            field += 4
            let nextEntryOffset = entryOffset + Int(length)
            defer { entryOffset = nextEntryOffset }

            // attribute_set_t: commonattr, volattr, dirattr, fileattr, forkattr.
            let commonReturned = scratch.loadUnaligned(fromByteOffset: field, as: UInt32.self)
            field += 4
            field += 4 // volattr (unused, never requested)
            let dirReturned = scratch.loadUnaligned(fromByteOffset: field, as: UInt32.self)
            field += 4
            let fileReturned = scratch.loadUnaligned(fromByteOffset: field, as: UInt32.self)
            field += 4
            field += 4 // forkattr (unused, never requested)

            if commonReturned & Attr.cmnError != 0 {
                let errorCode = scratch.loadUnaligned(fromByteOffset: field, as: UInt32.self)
                field += 4
                if errorCode != 0 { continue } // skip this entry, keep going
            }

            var name = ""
            if commonReturned & Attr.cmnName != 0 {
                let refOffset = field
                let dataOffset = scratch.loadUnaligned(fromByteOffset: field, as: Int32.self)
                field += 4
                let dataLength = scratch.loadUnaligned(fromByteOffset: field, as: UInt32.self)
                field += 4
                let nameStart = refOffset + Int(dataOffset)
                // attr_length includes the trailing NUL; drop it before decoding.
                let strLen = dataLength > 0 ? Int(dataLength) - 1 : 0
                let nameBytes = UnsafeRawBufferPointer(rebasing: scratch[nameStart..<(nameStart + strLen)])
                name = String(decoding: nameBytes, as: UTF8.self)
            }

            var devID: Int32 = -1
            if commonReturned & Attr.cmnDevID != 0 {
                devID = scratch.loadUnaligned(fromByteOffset: field, as: Int32.self)
                field += 4
            }
            var objType: UInt32 = 0
            if commonReturned & Attr.cmnObjType != 0 {
                objType = scratch.loadUnaligned(fromByteOffset: field, as: UInt32.self)
                field += 4
            }
            var fileID: UInt64 = 0
            if commonReturned & Attr.cmnFileID != 0 {
                fileID = scratch.loadUnaligned(fromByteOffset: field, as: UInt64.self)
                field += 8
            }

            var isMountPoint = false
            if dirReturned & Attr.dirMountStatus != 0 {
                let status = scratch.loadUnaligned(fromByteOffset: field, as: UInt32.self)
                field += 4
                isMountPoint = status & Attr.dirMntStatusMntPoint != 0
            }

            var hasFileAttrs = false
            var linkCount: UInt32 = 1
            var allocSize: Int64 = 0
            if fileReturned & Attr.fileLinkCount != 0 {
                hasFileAttrs = true
                linkCount = scratch.loadUnaligned(fromByteOffset: field, as: UInt32.self)
                field += 4
            }
            if fileReturned & Attr.fileAllocSize != 0 {
                hasFileAttrs = true
                allocSize = Int64(bitPattern: scratch.loadUnaligned(fromByteOffset: field, as: UInt64.self))
                field += 8
            }

            guard !name.isEmpty else { continue }

            try onEntry(BulkEntry(
                name: name, objType: objType, devID: devID, fileID: fileID,
                isMountPoint: isMountPoint, hasFileAttrs: hasFileAttrs,
                allocSize: allocSize, linkCount: linkCount
            ))
        }
    }
}
