import CoreTransferable
import Foundation
import Photos
import UniformTypeIdentifiers

/// A photo or video from the picker, kept as a temporary file of our own.
struct PickedFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            try PickedFile(receiving: received)
        }
        FileRepresentation(importedContentType: .image) { received in
            try PickedFile(receiving: received)
        }
    }

    /// The picker deletes its file once this returns. A copy it made just for us is moved rather
    /// than copied, so a long video does not need twice its size (and time) on the way in.
    init(receiving received: ReceivedTransferredFile) throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(received.file.lastPathComponent)
        do {
            let moved = !received.isOriginalFile && (try? fm.moveItem(at: received.file, to: dest)) != nil
            if !moved {
                try? fm.removeItem(at: dest)
                try fm.copyItem(at: received.file, to: dest)
            }
        } catch {
            try? fm.removeItem(at: dir)
            throw error
        }
        url = dest
    }
}

/// Deletes the originals of imported photos and videos from the Photos library. iOS shows its own
/// confirmation before anything is deleted, and deleted items stay in 「最近删除」 for a while.
enum FolderPhotoOriginals {
    /// Deletes the assets with these local identifiers and returns a message for the banner.
    static func delete(_ identifiers: [String]) async -> String {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            return "没有访问「照片」的权限，原件已保留。可以在「设置」→ FileBox → 照片 里允许访问"
        }
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        let assets = fetched.objects(at: IndexSet(integersIn: 0..<fetched.count))
        guard !assets.isEmpty else {
            if status == .limited {
                return "FileBox 只能访问部分照片，删不了这些原件。可以在「设置」→ FileBox → 照片 里改成「完全访问」"
            }
            return "在「照片」里找不到这些原件，可能已经删除了"
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets as NSArray)
            }
        } catch {
            if let photosError = error as? PHPhotosError, photosError.code == .userCancelled {
                return "已保留原件"
            }
            return "删除原件失败：\(error.localizedDescription)"
        }
        let skipped = identifiers.count - assets.count
        if skipped > 0 {
            return "已删除 \(assets.count) 个原件，另有 \(skipped) 个无法访问，已保留"
        }
        return "已从「照片」删除 \(assets.count) 个原件，可在「最近删除」里找回"
    }
}
