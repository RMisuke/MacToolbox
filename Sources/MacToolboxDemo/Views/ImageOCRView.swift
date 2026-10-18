import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import VisionKit
#if canImport(ToolboxCore)
import ToolboxCore
#endif

// MARK: - Controller

@MainActor
private final class OCRController: ObservableObject {
    @Published var image: NSImage?
    @Published var imageName = ""
    @Published var imageType = ""
    @Published var imageSize: CGSize?
    @Published var text = ""
    @Published var isRecognizing = false
    @Published var errorMessage: String?
    @Published var copied = false
    @Published var language = "auto"
    @Published var duration: Double?

    private var sourceURL: URL?
    private var imageData: Data?
    private var task: Task<Void, Never>?
    private var token = UUID()

    var hasImage: Bool { image != nil }

    func load(url: URL) {
        guard let image = NSImage(contentsOf: url) else {
            fail("无法读取图片：\(url.lastPathComponent)")
            return
        }
        self.image = image
        imageName = url.lastPathComponent
        imageType = url.pathExtension.isEmpty ? "IMAGE" : url.pathExtension.uppercased()
        sourceURL = url
        imageData = nil
        imageSize = Self.pixelSize(url: url) ?? Self.pixelSize(image: image)
        errorMessage = nil
        recognize()
    }

    func load(image: NSImage, name: String) {
        guard let data = image.tiffRepresentation else {
            fail("无法读取剪贴板图片")
            return
        }
        self.image = image
        imageName = name
        imageType = "剪贴板"
        sourceURL = nil
        imageData = data
        imageSize = Self.pixelSize(image: image)
        errorMessage = nil
        recognize()
    }

    func pasteImage() {
        let board = NSPasteboard.general

        if let urls = board.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], let url = urls.first {
            load(url: url)
            return
        }

        if let images = board.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           let image = images.first {
            load(image: image, name: "剪贴板图片")
            return
        }

        if let data = board.data(forType: .png) ?? board.data(forType: .tiff),
           let image = NSImage(data: data) {
            load(image: image, name: "剪贴板图片")
            return
        }

        fail("剪贴板里没有图片")
    }

    func recognize() {
        guard hasImage else { return }
        task?.cancel()
        let currentToken = UUID()
        token = currentToken
        errorMessage = nil
        text = ""
        duration = nil
        isRecognizing = true

        let url = sourceURL
        let data = imageData
        let language = language

        task = Task { [weak self] in
            do {
                guard ImageAnalyzer.isSupported else {
                    throw OCRError.unsupported
                }
                let started = Date()
                let analyzer = ImageAnalyzer()
                var configuration = ImageAnalyzer.Configuration([.text])
                if language != "auto" {
                    configuration.locales = Self.locales(for: language)
                }

                let transcript: String
                if let url {
                    let analysis = try await analyzer.analyze(
                        imageAt: url,
                        orientation: Self.orientation(url: url),
                        configuration: configuration
                    )
                    transcript = analysis.transcript
                } else if let data, let image = NSImage(data: data) {
                    let analysis = try await analyzer.analyze(
                        image,
                        orientation: .up,
                        configuration: configuration
                    )
                    transcript = analysis.transcript
                } else {
                    throw OCRError.noImage
                }

                let elapsed = Date().timeIntervalSince(started)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, self.token == currentToken else { return }
                    self.isRecognizing = false
                    self.text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.duration = elapsed
                    if self.text.isEmpty {
                        self.errorMessage = "没有识别到文字"
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, self.token == currentToken else { return }
                    self.isRecognizing = false
                    self.text = ""
                    self.errorMessage = "OCR 失败：\(error.localizedDescription)"
                }
            }
        }
    }

    func copyText() {
        guard !text.isEmpty else { return }
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            self?.copied = false
        }
    }

    func saveText() {
        guard !text.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        panel.nameFieldStringValue = "OCR-\(formatter.string(from: Date())).txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            errorMessage = nil
        } catch {
            errorMessage = "保存失败：\(error.localizedDescription)"
        }
    }

    func clearText() {
        text = ""
        duration = nil
        errorMessage = nil
        copied = false
    }

    func removeImage() {
        task?.cancel()
        task = nil
        token = UUID()
        image = nil
        imageName = ""
        imageType = ""
        imageSize = nil
        sourceURL = nil
        imageData = nil
        isRecognizing = false
        clearText()
    }

    private func fail(_ message: String) {
        task?.cancel()
        errorMessage = message
        isRecognizing = false
    }

    // MARK: VisionKit

    nonisolated private static func locales(for code: String) -> [String] {
        switch code {
        case "zh-Hans":
            return ["zh-Hans", "en-US"]
        case "zh-Hant":
            return ["zh-Hant", "en-US"]
        case "en":
            return ["en-US"]
        case "ja":
            return ["ja-JP", "en-US"]
        case "ko":
            return ["ko-KR", "en-US"]
        default:
            return []
        }
    }

    nonisolated private static func orientation(url: URL?) -> CGImagePropertyOrientation {
        guard let url,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let raw = (properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value,
              let orientation = CGImagePropertyOrientation(rawValue: raw)
        else { return .up }
        return orientation
    }

    nonisolated private static func pixelSize(url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue
        else { return nil }
        return CGSize(width: width, height: height)
    }

    nonisolated private static func pixelSize(image: NSImage) -> CGSize? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        return CGSize(width: cgImage.width, height: cgImage.height)
    }
}

private enum OCRError: LocalizedError {
    case unsupported
    case noImage

    var errorDescription: String? {
        switch self {
        case .unsupported:
            return "当前 Mac 不支持系统 Live Text OCR"
        case .noImage:
            return "图片数据不可用"
        }
    }
}

// MARK: - View

struct ImageOCRView: View {
    let tool: LoadedTool
    @StateObject private var ocr = OCRController()
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 34)
                .padding(.top, 28)
                .padding(.bottom, 16)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    inputCard
                    resultCard
                }
                .padding(.horizontal, 34)
                .padding(.bottom, 28)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("")
        .onAppear {
            if ocr.image == nil,
               let path = ProcessInfo.processInfo.environment["MCT_OCR_IMAGE"],
               !path.isEmpty {
                ocr.load(url: URL(fileURLWithPath: path))
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            ToolIconTile(tool: tool, size: 64)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(tool.manifest.name)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                    Text("v\(tool.manifest.version)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.1)))
                }
                Text(tool.manifest.summary ?? "")
                    .font(.body)
                    .foregroundStyle(.secondary)
                Text(tool.manifest.category ?? "媒体")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(categoryColor(tool.manifest.category))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(categoryColor(tool.manifest.category).opacity(0.12)))
            }

            Spacer()
        }
    }

    private var inputCard: some View {
        SectionCard("图片") {
            VStack(alignment: .leading, spacing: 12) {
                if let image = ocr.image {
                    imagePane(image)
                } else {
                    emptyDropZone
                }

                if let error = ocr.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if ocr.hasImage {
                    controls
                }
            }
            .contentShape(Rectangle())
            .onDrop(of: [.fileURL, .image], isTargeted: $isTargeted) { providers in
                handleDrop(providers)
            }
        }
    }

    private var emptyDropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: isTargeted ? "photo.badge.arrow.down.fill" : "photo.on.rectangle.angled")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary)

            Text(isTargeted ? "松开即可识别这张图片" : "拖拽图片到此处")
                .font(.headline)

            Text("支持 PNG / JPEG / HEIC / TIFF / WebP / GIF；也可以直接粘贴剪贴板图片（⇧⌘V）")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 10) {
                Button {
                    chooseImage()
                } label: {
                    Label("选择图片…", systemImage: "folder")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    ocr.pasteImage()
                } label: {
                    Label("粘贴图片", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.bordered)
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .help("从剪贴板读取图片（⇧⌘V）")
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, minHeight: 210)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isTargeted ? Color.accentColor.opacity(0.08) : Color(nsColor: .textBackgroundColor).opacity(0.4))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.28),
                    style: StrokeStyle(lineWidth: isTargeted ? 2 : 1.2, dash: [7, 5])
                )
        )
        .animation(.easeOut(duration: 0.15), value: isTargeted)
    }

    private func imagePane(_ image: NSImage) -> some View {
        HStack(alignment: .top, spacing: 18) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .frame(height: 300)
                .background(Color.black.opacity(0.16))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 10) {
                Text(ocr.imageName)
                    .font(.headline)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Text(ocr.imageType)
                    if let size = ocr.imageSize {
                        Text("·")
                        Text("\(Int(size.width)) × \(Int(size.height))")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if ocr.isRecognizing {
                    HStack(spacing: 7) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在识别…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 8) {
                    Button("更换图片…") { chooseImage() }
                        .buttonStyle(.bordered)
                    Button("粘贴图片") { ocr.pasteImage() }
                        .buttonStyle(.bordered)
                    Button("移除") { ocr.removeImage() }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                }

                if let duration = ocr.duration {
                    Text("耗时 \(String(format: "%.2f", duration)) 秒")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 230, alignment: .leading)
        }
    }

    private var controls: some View {
        HStack(spacing: 14) {
            Picker("语言", selection: $ocr.language) {
                Text("自动").tag("auto")
                Text("简体中文").tag("zh-Hans")
                Text("繁体中文").tag("zh-Hant")
                Text("英语").tag("en")
                Text("日语").tag("ja")
                Text("韩语").tag("ko")
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 180)

            Button {
                ocr.recognize()
            } label: {
                Label("重新识别", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(ocr.isRecognizing)

            Spacer()
        }
        .font(.caption)
        .onChange(of: ocr.language) { _, _ in
            if ocr.hasImage { ocr.recognize() }
        }
    }

    private var resultCard: some View {
        SectionCard("识别结果") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Text(resultStats)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button {
                        ocr.copyText()
                    } label: {
                        Label(
                            ocr.copied ? "已复制" : "一键复制",
                            systemImage: ocr.copied ? "checkmark" : "doc.on.doc"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(ocr.text.isEmpty)

                    Button {
                        ocr.saveText()
                    } label: {
                        Label("保存 TXT", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.bordered)
                    .disabled(ocr.text.isEmpty)

                    Button("清空") {
                        ocr.clearText()
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .disabled(ocr.text.isEmpty)
                }

                ZStack(alignment: .topLeading) {
                    TextEditor(text: $ocr.text)
                        .font(.system(size: 13, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(9)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color(nsColor: .textBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.secondary.opacity(0.22), lineWidth: 1)
                        )
                        .frame(minHeight: 260)

                    if ocr.text.isEmpty {
                        Text(ocr.isRecognizing ? "识别中…" : "识别结果会显示在这里，可直接编辑。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 16)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
    }

    private var resultStats: String {
        let chars = ocr.text.count
        let lines = ocr.text.isEmpty
            ? 0
            : ocr.text.split(separator: "\n", omittingEmptySubsequences: false).count
        return ["\(chars) 字符", "\(lines) 行"].joined(separator: " · ")
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                var url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let value = item as? URL {
                    url = value
                } else if let value = item as? NSURL {
                    url = value as URL
                }
                DispatchQueue.main.async {
                    if let error {
                        ocr.errorMessage = "拖入文件失败：\(error.localizedDescription)"
                    } else if let url {
                        ocr.load(url: url)
                    } else {
                        ocr.errorMessage = "无法读取拖入的文件"
                    }
                }
            }
            return true
        }

        let imageTypes = [
            UTType.image.identifier,
            UTType.png.identifier,
            UTType.tiff.identifier,
            UTType.jpeg.identifier,
        ]
        for identifier in imageTypes where provider.hasItemConformingToTypeIdentifier(identifier) {
            provider.loadDataRepresentation(forTypeIdentifier: identifier) { data, error in
                DispatchQueue.main.async {
                    if let error {
                        ocr.errorMessage = "拖入图片失败：\(error.localizedDescription)"
                    } else if let data, let image = NSImage(data: data) {
                        ocr.load(image: image, name: "拖拽图片")
                    } else {
                        ocr.errorMessage = "无法读取拖入的图片"
                    }
                }
            }
            return true
        }

        return false
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        let types = ["png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "webp", "gif", "bmp"]
            .compactMap { UTType(filenameExtension: $0) }
        if !types.isEmpty {
            panel.allowedContentTypes = types
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        ocr.load(url: url)
    }
}
