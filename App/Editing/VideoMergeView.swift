import SwiftUI

// STUB: replaced by the video-editing work package. Keep this initializer signature.
/// Asks for confirmation, then appends `second` after `first` into a new video next to `first`.
/// Both originals are kept.
struct VideoMergeView: View {
    let first: FileItem
    let second: FileItem

    @Environment(\.dismiss) private var dismiss

    init(first: FileItem, second: FileItem) {
        self.first = first
        self.second = second
    }

    var body: some View {
        NavigationStack {
            Text("\(first.name) + \(second.name)")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { dismiss() }
                    }
                }
        }
    }
}
