import SwiftUI

// STUB: replaced by the video-editing work package. Keep this initializer signature.
/// Cuts a part out of a video and saves it as a new file next to the original.
struct VideoTrimView: View {
    let item: FileItem

    @Environment(\.dismiss) private var dismiss

    init(item: FileItem) {
        self.item = item
    }

    var body: some View {
        NavigationStack {
            Text(item.name)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { dismiss() }
                    }
                }
        }
    }
}
