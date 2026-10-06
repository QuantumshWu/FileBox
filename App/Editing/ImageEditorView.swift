import SwiftUI

// STUB: replaced by the image-editing work package. Keep this initializer signature.
/// Crop / rotate / adjust an image and save the result as a new file next to the original.
struct ImageEditorView: View {
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
