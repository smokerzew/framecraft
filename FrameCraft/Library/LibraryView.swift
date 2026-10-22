import PhotosUI
import SwiftUI

/// The app's own photo library: every capture and imported photo with its edit. Opening one restores the edit;
/// deleting one removes only the app's copy (photos in the Photos app are never touched).
struct LibraryView: View {
    @Bindable var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var pendingDelete: PhotoProject?

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 3)]

    var body: some View {
        NavigationStack {
            Group {
                if app.projects.isEmpty {
                    ContentUnavailableView("No Photos Yet", systemImage: "photo.on.rectangle",
                                           description: Text("Photos you take or import appear here with their edits."))
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 3) {
                            ForEach(app.projects) { project in
                                tile(project)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    PhotosPicker(selection: $pickerItems, maxSelectionCount: 20, selectionBehavior: .ordered,
                                 matching: .images, preferredItemEncoding: .current) {
                        Label("Import", systemImage: "square.and.arrow.down")
                    }
                }
            }
            .onChange(of: pickerItems) { _, items in
                guard !items.isEmpty else { return }
                dismiss()
                app.importPhotos(items)
                pickerItems = []
            }
            .confirmationDialog("Delete this photo and its edits?", isPresented: Binding(
                get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible,
                                presenting: pendingDelete) { project in
                Button("Delete from FrameCraft", role: .destructive) { app.delete(project) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("This removes the app's copy and its edits. Photos you saved to the Photos app stay there.")
            }
            .appAlert(app)
        }
        .modifier(GlassSheetBackground())
    }

    private func tile(_ project: PhotoProject) -> some View {
        let store = app.store
        let thumb = store.flatMap { AppModel.loadThumbnail($0.thumbnailURL(project.id)) }
        let missing = store.map { !$0.hasOriginal(project) } ?? true
        return Button {
            Task { await app.open(project) }
        } label: {
            ZStack(alignment: .bottomLeading) {
                Group {
                    if let thumb {
                        Image(decorative: thumb, scale: 1).resizable().scaledToFill()
                    } else {
                        Color.secondary.opacity(0.2)
                            .overlay { Image(systemName: missing ? "exclamationmark.triangle" : "photo").foregroundStyle(.secondary) }
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fill)
                .clipped()

                HStack(spacing: 4) {
                    if project.isRAW { badge(project.source == .cameraProRAW ? "ProRAW" : "RAW") }
                    if !project.edit.isIdentity { badge("EDITED") }
                    if missing { badge("MISSING") }
                }
                .padding(5)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Duplicate Edit", systemImage: "plus.square.on.square") { app.duplicate(project) }
                .disabled(missing)
            Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = project }
        }
        .accessibilityLabel("Photo from \(project.created.formatted(date: .abbreviated, time: .shortened))")
        .accessibilityValue([project.isRAW ? "RAW" : nil, project.edit.isIdentity ? nil : "Edited",
                             missing ? "Original missing" : nil].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint("Opens it for editing. Touch and hold for more.")
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.black.opacity(0.55), in: Capsule())
    }
}
