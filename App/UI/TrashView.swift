import QuickLook
import SwiftUI

/// 回收站: deleted files stay here for `Vault.trashDays` days. Tap one to look at it, swipe to
/// restore it to where it was or to delete it for good; 清空 removes everything now.
struct TrashView: View {
    @EnvironmentObject private var store: FileStore

    @State private var entries: [Vault.TrashEntry] = []
    @State private var pendingForever: Vault.TrashEntry?
    @State private var confirmEmpty = false
    /// A trashed file shown read-only in Quick Look.
    @State private var previewURL: URL?

    var body: some View {
        List {
            ForEach(entries) { entry in
                Button {
                    if !entry.isDirectory { previewURL = entry.url }
                } label: {
                    row(entry)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button { store.restore([entry]) } label: {
                        Label("恢复", systemImage: "arrow.uturn.backward")
                    }
                    Button(role: .destructive) { pendingForever = entry } label: {
                        Label("彻底删除", systemImage: "trash.slash")
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button { pendingForever = entry } label: {
                        Label("彻底删除", systemImage: "trash.slash")
                    }
                    .tint(.red)
                    Button { store.restore([entry]) } label: {
                        Label("恢复", systemImage: "arrow.uturn.backward")
                    }
                    .tint(.blue)
                }
                .confirmationDialog(
                    "彻底删除「\(entry.name)」？",
                    isPresented: foreverBinding(entry),
                    titleVisibility: .visible
                ) {
                    Button("彻底删除", role: .destructive) { store.deleteForever([entry]) }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("彻底删除后无法恢复。")
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView(
                    "回收站是空的",
                    systemImage: "trash",
                    description: Text("删除的文件会在这里保留 \(Vault.trashDays) 天")
                )
            }
        }
        .safeAreaInset(edge: .top) {
            if !entries.isEmpty {
                Text("左滑可以恢复或彻底删除。超过 \(Vault.trashDays) 天的会自动彻底删除。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.bar)
            }
        }
        .navigationTitle("回收站")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("清空", role: .destructive) { confirmEmpty = true }
                    .disabled(entries.isEmpty)
                    .confirmationDialog("清空回收站？", isPresented: $confirmEmpty, titleVisibility: .visible) {
                        Button("彻底删除 \(entries.count) 项", role: .destructive) {
                            store.deleteForever(entries)
                        }
                        Button("取消", role: .cancel) {}
                    } message: {
                        Text("彻底删除后无法恢复。")
                    }
            }
        }
        .quickLookPreview($previewURL)
        .onAppear(perform: reload)
        .onChange(of: store.revision) { reload() }
    }

    private func row(_ entry: Vault.TrashEntry) -> some View {
        HStack(spacing: 12) {
            ThumbnailView(item: FileItem(url: entry.url), side: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .lineLimit(2)
                Text(detail(entry))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private func detail(_ entry: Vault.TrashEntry) -> String {
        let from = entry.originalFolder.isEmpty ? "FileBox" : entry.originalFolder
        let daysLeft = max(1, Int((entry.expiresAt.timeIntervalSinceNow / 86_400).rounded(.up)))
        var parts = ["原位置：\(from)", "\(daysLeft) 天后彻底删除"]
        if !entry.isDirectory {
            parts.insert(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file), at: 0)
        }
        return parts.joined(separator: " · ")
    }

    private func foreverBinding(_ entry: Vault.TrashEntry) -> Binding<Bool> {
        Binding(
            get: { pendingForever?.id == entry.id },
            set: { if !$0, pendingForever?.id == entry.id { pendingForever = nil } }
        )
    }

    /// Restored and deleted rows slide away instead of vanishing.
    private func reload() {
        let fresh = store.trashEntries()
        guard fresh != entries else { return }
        if entries.isEmpty {
            entries = fresh
        } else {
            withAnimation(.snappy) { entries = fresh }
        }
    }
}
