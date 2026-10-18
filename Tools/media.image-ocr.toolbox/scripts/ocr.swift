// MacToolbox OCR CLI helper.
//
// GUI 使用 VisionKit 的 ImageAnalyzer；这个独立小工具使用 Vision 的
// VNRecognizeTextRequest，供 CLI / Agent 在无 App 进程时识别图片。
// 由 scripts/tool.py 按需编译并缓存到 ~/Library/Caches/MacToolboxDemo/ocr/。
//
// 用法：
//   ocr --image /tmp/a.png [--language auto|zh-Hans|zh-Hant|en|ja|ko]
//       [--format json|txt] [--output /tmp/out.txt] [--plain]
//
// JSON 输出：
//   {"ok":true,"text":"...","lines":[{"text":"...","confidence":0.99,
//    "bbox":{"x":0.1,"y":0.2,"width":0.3,"height":0.05}}],
//    "width":1280,"height":720,"languages":["zh-Hans"],"durationMs":120}

import Foundation
import ImageIO
import Vision

struct Options {
    var image: String = ""
    var language: String = "auto"
    var format: String = "json"
    var output: String = ""
    var plain: Bool = false
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    fputs("error: \(message)\n", stderr)
    exit(code)
}

func parseOptions() -> Options {
    var options = Options()
    var index = 1
    let args = CommandLine.arguments
    while index < args.count {
        let arg = args[index]
        switch arg {
        case "--image":
            index += 1
            guard index < args.count else { fail("--image 缺少值") }
            options.image = args[index]
        case "--language":
            index += 1
            guard index < args.count else { fail("--language 缺少值") }
            options.language = args[index]
        case "--format":
            index += 1
            guard index < args.count else { fail("--format 缺少值") }
            options.format = args[index]
        case "--output":
            index += 1
            guard index < args.count else { fail("--output 缺少值") }
            options.output = args[index]
        case "--plain":
            options.plain = true
        case "--help", "-h":
            print("""
            ocr --image <path> [--language auto|zh-Hans|zh-Hant|en|ja|ko]
                [--format json|txt] [--output <path>] [--plain]
            """)
            exit(0)
        default:
            fail("未知参数：\(arg)")
        }
        index += 1
    }
    if options.image.isEmpty {
        fail("必须提供 --image")
    }
    return options
}

func languages(for code: String) -> [String] {
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

let options = parseOptions()
let url = URL(fileURLWithPath: (options.image as NSString).expandingTildeInPath)
guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
    fail("无法读取图片：\(url.path)")
}
guard CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
    fail("无法解码图片（PDF 请先用 sips 转 PNG）：\(url.path)")
}
let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
let started = Date()

func recognize(_ requested: [String], level: VNRequestTextRecognitionLevel)
    throws -> [VNRecognizedTextObservation] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = level
    request.usesLanguageCorrection = true
    if !requested.isEmpty {
        request.recognitionLanguages = requested
    }
    // 使用 URL handler：它会自动读取 EXIF orientation；实测 cgImage handler
    // 在当前 macOS 上会抛 Foundation._GenericObjCError。
    let handler = VNImageRequestHandler(url: url, options: [:])
    try handler.perform([request])
    return request.results ?? []
}

var observations: [VNRecognizedTextObservation] = []
var usedLanguages: [String] = []
var usedLevel = "accurate"
var languageFallback = false
var levelFallback = false
do {
    observations = try recognize(languages(for: options.language), level: .accurate)
    usedLanguages = languages(for: options.language)
} catch {
    // 某些 macOS 环境没有 accurate 模型；回退到 fast，而不是直接失败。
    levelFallback = true
    usedLevel = "fast"
    do {
        observations = try recognize(languages(for: options.language), level: .fast)
        usedLanguages = languages(for: options.language)
    } catch {
        languageFallback = true
        usedLanguages = []
        do {
            observations = try recognize([], level: .fast)
        } catch {
            fail("OCR 失败：\(error.localizedDescription)")
        }
    }
}

var lines: [[String: Any]] = []
var textLines: [String] = []
for observation in observations {
    guard let candidate = observation.topCandidates(1).first else { continue }
    let box = observation.boundingBox
    textLines.append(candidate.string)
    lines.append([
        "text": candidate.string,
        "confidence": Double(candidate.confidence),
        "bbox": [
            "x": Double(box.origin.x),
            "y": Double(box.origin.y),
            "width": Double(box.size.width),
            "height": Double(box.size.height),
        ],
    ])
}

let text = textLines.joined(separator: "\n")
let elapsed = Int(Date().timeIntervalSince(started) * 1000)

if options.format == "txt" || options.plain {
    if !options.output.isEmpty {
        do {
            try text.write(toFile: options.output, atomically: true, encoding: .utf8)
        } catch {
            fail("写入失败：\(error.localizedDescription)")
        }
    } else {
        print(text)
    }
    exit(0)
}

let payload: [String: Any] = [
    "ok": true,
    "text": text,
    "lines": lines,
    "lineCount": lines.count,
    "charCount": text.count,
    "width": width,
    "height": height,
    "language": options.language,
    "languages": usedLanguages,
    "recognitionLevel": usedLevel,
    "languageFallback": languageFallback,
    "levelFallback": levelFallback,
    "durationMs": elapsed,
]
let data = try JSONSerialization.data(
    withJSONObject: payload,
    options: [.prettyPrinted, .withoutEscapingSlashes]
)
guard let json = String(data: data, encoding: .utf8) else {
    fail("无法编码 JSON")
}
if !options.output.isEmpty {
    do {
        try json.write(toFile: options.output, atomically: true, encoding: .utf8)
    } catch {
        fail("写入失败：\(error.localizedDescription)")
    }
} else {
    print(json)
}
