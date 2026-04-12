import SwiftUI
import UniformTypeIdentifiers

struct PhotoAssignmentView: View {
    let event: Event
    @Environment(AppState.self) private var appState

    @State private var dayPhotos: [DayName: [URL]]
    @State private var blogPhotos: [URL]
    @State private var pickerTarget: PickerTarget? = nil

    var totalPhotos: Int { dayPhotos.values.reduce(0) { $0 + $1.count } }

    enum PickerTarget: Equatable {
        case day(DayName)
        case blog
    }

    init(event: Event) {
        self.event = event
        var loaded: [DayName: [URL]] = [:]
        for day in DayName.allCases {
            loaded[day] = event.days[day.rawValue]?.photoPaths ?? []
        }
        _dayPhotos = State(initialValue: loaded)
        _blogPhotos = State(initialValue: event.blogPhotoPaths)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                EventHeader(event: event, subtitle: "Assign Photos")
                    .padding([.horizontal, .top], Spacing.xl)
                    .padding(.bottom, Spacing.md)

                BrandBanner(
                    icon: "rectangle.3.group",
                    message: "Drop photos into each posting day. Blog photos go in the section at the bottom and appear in the full blog post."
                )
                .padding(.horizontal, Spacing.xl)
                .padding(.bottom, Spacing.lg)

                ForEach(DayName.allCases, id: \.self) { day in
                    PhotoDaySection(
                        label: day.displayName,
                        photos: dayBinding(day),
                        onAddPhotos: { pickerTarget = .day(day) }
                    )
                }

                PhotoDaySection(
                    label: "Blog Photos",
                    subtitle: "Appear in the full blog post",
                    photos: blogBinding,
                    onAddPhotos: { pickerTarget = .blog }
                )

                HStack {
                    Spacer()
                    Button("Continue to Generation") { advance() }
                        .buttonStyle(BrandButtonStyle())
                        .disabled(totalPhotos == 0)
                }
                .padding(Spacing.xl)
            }
        }
        .background(Color.cream)
        .fileImporter(
            isPresented: Binding(
                get: { pickerTarget != nil },
                set: { if !$0 { pickerTarget = nil } }
            ),
            allowedContentTypes: [.image],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result { handlePickedFiles(urls) }
            pickerTarget = nil
        }
    }

    // MARK: - Bindings

    private func dayBinding(_ day: DayName) -> Binding<[URL]> {
        Binding(
            get: { dayPhotos[day] ?? [] },
            set: { dayPhotos[day] = $0; save() }
        )
    }

    private var blogBinding: Binding<[URL]> {
        Binding(
            get: { blogPhotos },
            set: { blogPhotos = $0; save() }
        )
    }

    // MARK: - File handling

    private func handlePickedFiles(_ urls: [URL]) {
        switch pickerTarget {
        case .day(let day):
            var list = dayPhotos[day] ?? []
            for url in urls where !list.contains(url) { list.append(url) }
            dayPhotos[day] = list
        case .blog:
            for url in urls where !blogPhotos.contains(url) { blogPhotos.append(url) }
        case nil:
            break
        }
        save()
    }

    // MARK: - Persistence

    private func save() {
        var ev = event
        for day in DayName.allCases {
            ev.days[day.rawValue] = PostingDay(day: day, photoPaths: dayPhotos[day] ?? [])
        }
        ev.blogPhotoPaths = blogPhotos
        appState.updateEvent(ev)
    }

    private func advance() {
        var ev = event
        for day in DayName.allCases {
            ev.days[day.rawValue] = PostingDay(day: day, photoPaths: dayPhotos[day] ?? [])
        }
        ev.blogPhotoPaths = blogPhotos
        ev.stage = .assetsGenerated
        appState.updateEvent(ev)
    }
}

// MARK: - PhotoDaySection

private struct PhotoDaySection: View {
    let label: String
    var subtitle: String? = nil
    @Binding var photos: [URL]
    let onAddPhotos: () -> Void

    @State private var isExpanded = true
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            Button(action: { isExpanded.toggle() }) {
                HStack(alignment: .center, spacing: Spacing.sm) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: Spacing.sm) {
                            Text(label.uppercased())
                                .font(.system(size: 10, weight: .medium))
                                .tracking(1.2)
                                .foregroundStyle(isExpanded ? Color.roseGold : Color.warmMid)
                            if !photos.isEmpty {
                                PhotoCountBadge(count: photos.count)
                            }
                        }
                        if let subtitle {
                            Text(subtitle)
                                .font(.light(11))
                                .foregroundStyle(Color.warmMid)
                        }
                    }
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color.warmMid)
                }
                .contentShape(Rectangle())
                .padding(.horizontal, Spacing.xl)
                .padding(.vertical, 14)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    if photos.isEmpty {
                        PhotoDropZone(isTargeted: isDropTargeted)
                    } else {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 80))],
                            spacing: Spacing.sm
                        ) {
                            ForEach(photos.indices, id: \.self) { i in
                                PhotoThumb(url: photos[i]) {
                                    photos.remove(at: i)
                                }
                            }
                        }
                    }
                    Button(photos.isEmpty ? "Add Photos…" : "Add more…", action: onAddPhotos)
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.roseGold)
                }
                .padding(.horizontal, Spacing.xl)
                .padding(.bottom, Spacing.md)
                .background(isDropTargeted ? Color.roseGold.opacity(0.03) : Color.clear)
            }

            RoseGoldDivider(opacity: 0.3)
        }
        .onDrop(of: [.image, .fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    Task { @MainActor in
                        if !photos.contains(url) { photos.append(url) }
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, _ in
                    guard let url else { return }
                    let captured = url
                    Task { @MainActor in
                        if !photos.contains(captured) { photos.append(captured) }
                    }
                }
            }
        }
        return true
    }
}

// MARK: - PhotoDropZone

private struct PhotoDropZone: View {
    let isTargeted: Bool

    var body: some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 24))
                .foregroundStyle(Color.roseGold.opacity(isTargeted ? 0.8 : 0.35))
            VStack(alignment: .leading, spacing: 3) {
                Text("Drop photos here")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isTargeted ? Color.roseGold : Color.warmMid)
                Text("JPEG · PNG · HEIC")
                    .font(.light(10))
                    .foregroundStyle(Color.warmMid)
            }
            Spacer()
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity)
        .background(Color.creamDeep)
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md)
                .strokeBorder(
                    isTargeted ? Color.roseGold : Color.roseGold.opacity(0.2),
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                )
        )
        .animation(.easeOut(duration: 0.12), value: isTargeted)
    }
}

// MARK: - PhotoCountBadge

private struct PhotoCountBadge: View {
    let count: Int
    var body: some View {
        Text("\(count)")
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(Color.cream)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.roseGold.opacity(0.65))
            .clipShape(Capsule())
    }
}

// MARK: - PhotoThumb

private struct PhotoThumb: View {
    let url: URL
    let onRemove: () -> Void
    @State private var image: NSImage?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color.creamDeep
                        .overlay {
                            ProgressView()
                                .controlSize(.small)
                                .tint(Color.roseGold)
                        }
                }
            }
            .frame(width: 80, height: 80)
            .clipShape(RoundedRectangle(cornerRadius: Radius.md))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.md)
                    .strokeBorder(Color.creamEdge, lineWidth: 0.5)
            )

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.cream, Color.warmDark.opacity(0.7))
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
            .padding(3)
        }
        .task { image = await Task.detached { NSImage(contentsOf: url) }.value }
    }
}
