import SwiftUI

// STUB: replaced by the media-viewer work package. Keep this initializer signature.
/// Full-screen viewer for the images, videos and audio of one folder.
struct MediaViewer: View {
    let items: [FileItem]
    let startIndex: Int

    @EnvironmentObject private var viewer: ViewerCoordinator

    init(items: [FileItem], startIndex: Int) {
        self.items = items
        self.startIndex = startIndex
    }

    var body: some View {
        NavigationStack {
            Text(items.indices.contains(startIndex) ? items[startIndex].name : "")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { viewer.close() }
                    }
                }
        }
    }
}
