import AppKit
import PDFKit
import Vision
import UniformTypeIdentifiers

struct EvantoError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum Storage {
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Evanto", isDirectory: true)
    }
    static func directory(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return url
    }
}

struct ReferenceFile: Identifiable, Codable {
    let id: UUID
    let name: String
    let added: Date
    let text: String
    let image: Data?

    var kind: String { (name as NSString).pathExtension.uppercased() }
}

enum ReferenceLibrary {
    static var folder: URL { Storage.root.appendingPathComponent("References", isDirectory: true) }

    static func load(from directory: URL = folder) throws -> [ReferenceFile] {
        let files = try FileManager.default.contentsOfDirectory(at: Storage.directory(directory),
            includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        return try files.map { try JSONDecoder().decode(ReferenceFile.self, from: Data(contentsOf: $0)) }
            .sorted { $0.added < $1.added }
    }

    static func add(_ url: URL, to directory: URL = folder) throws -> ReferenceFile {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        let ref = try read(url)
        let location = try Storage.directory(directory).appendingPathComponent(ref.id.uuidString + ".json")
        try JSONEncoder().encode(ref).write(to: location, options: .atomic)
        return ref
    }

    static func read(_ url: URL) throws -> ReferenceFile {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 32 * 1024 * 1024 else { throw EvantoError("Choose a file smaller than 32 MB.") }
        let ext = url.pathExtension.lowercased()
        var image: Data?
        var text: String
        if ext == "pdf" {
            text = try pdfText(url)
        } else if let type = UTType(filenameExtension: ext), type.conforms(to: .image) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let bitmap = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1550] as CFDictionary) else {
                throw EvantoError("This image could not be opened.")
            }
            image = jpeg(bitmap)
            text = (try? recognize(bitmap)) ?? ""
        } else if ["docx", "pptx", "xlsx", "odt", "odp", "ods"].contains(ext) {
            text = try OfficeText.extract(url, extension: ext)
        } else if ["rtf", "doc"].contains(ext) {
            let type: NSAttributedString.DocumentType = ext == "rtf" ? .rtf : .docFormat
            text = try NSAttributedString(url: url, options: [.documentType: type], documentAttributes: nil).string
        } else {
            let data = try Data(contentsOf: url)
            let utf16 = data.starts(with: [255, 254]) || data.starts(with: [254, 255])
            guard let plain = String(data: data, encoding: utf16 ? .utf16 : .utf8),
                  !plain.unicodeScalars.contains(where: { $0.value == 0 }) else {
                throw EvantoError("This file has no readable text. Export it as a PDF, Office document, image, or text file.")
            }
            text = plain
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || image != nil else { throw EvantoError("No readable content was found in this file.") }
        guard text.utf8.count <= 4_000_000 else { throw EvantoError("Split this document into files under 4 MB of extracted text.") }
        return ReferenceFile(id: UUID(), name: url.lastPathComponent, added: Date(), text: text, image: image)
    }

    static func remove(_ ref: ReferenceFile, from directory: URL = folder) throws {
        try FileManager.default.removeItem(at: directory.appendingPathComponent(ref.id.uuidString + ".json"))
    }

    static func recognize(_ image: CGImage, fast: Bool = false) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = fast ? .fast : .accurate
        request.usesLanguageCorrection = !fast
        try VNImageRequestHandler(cgImage: image).perform([request])
        return request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n") ?? ""
    }

    static func jpeg(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.72])
    }

    private static func pdfText(_ url: URL) throws -> String {
        guard let pdf = PDFDocument(url: url), !pdf.isLocked else { throw EvantoError("Unlock the PDF and import it again.") }
        var pages = [String]()
        for index in 0..<pdf.pageCount {
            guard let page = pdf.page(at: index) else { continue }
            var text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if text.isEmpty {
                let bounds = page.bounds(for: .mediaBox)
                let scale = 1650 / max(1, max(bounds.width, bounds.height))
                let size = NSSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
                let thumbnail = page.thumbnail(of: size, for: .mediaBox)
                if let bitmap = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    text = try recognize(bitmap)
                }
            }
            if !text.isEmpty { pages.append(text) }
        }
        return pages.joined(separator: "\n\n")
    }
}

private final class OfficeText: NSObject, XMLParserDelegate {
    private var buffer = ""
    private var capture = false
    private var cellType = ""
    private var value = ""
    private var strings: [String] = []
    private var collectingStrings = false

    static func extract(_ url: URL, extension ext: String) throws -> String {
        let reader = OfficeText()
        let entries = try unzip(["-Z1", url.path]).components(separatedBy: .newlines)
        var parts: [String]
        switch ext {
        case "docx": parts = ["word/document.xml"]
        case "pptx": parts = entries.filter { $0.range(of: #"^ppt/slides/slide[0-9]+\.xml$"#, options: .regularExpression) != nil }
        case "xlsx":
            if entries.contains("xl/sharedStrings.xml") {
                reader.collectingStrings = true
                try reader.parse(unzip(["-p", url.path, "xl/sharedStrings.xml"]))
                reader.collectingStrings = false
            }
            parts = entries.filter { $0.range(of: #"^xl/worksheets/sheet[0-9]+\.xml$"#, options: .regularExpression) != nil }
        default: parts = ["content.xml"]
        }
        for part in parts.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            try reader.parse(unzip(["-p", url.path, part]))
            reader.buffer += "\n"
        }
        return reader.buffer
    }

    private static func unzip(_ arguments: [String]) throws -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        var data = Data()
        while let chunk = try pipe.fileHandleForReading.read(upToCount: 64 * 1024), !chunk.isEmpty {
            data.append(chunk)
            if data.count > 24 * 1024 * 1024 {
                process.terminate()
                try? pipe.fileHandleForReading.close()
                process.waitUntilExit()
                throw EvantoError("This Office document is too large to extract.")
            }
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else {
            throw EvantoError("The Office document could not be read.")
        }
        return text
    }

    private func parse(_ xml: String) throws {
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = self
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else { throw EvantoError("The Office document contains invalid XML.") }
    }

    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        let name = element.split(separator: ":").last
        if name == "si" { value = "" }
        if name == "c" { cellType = attributes["t"] ?? ""; value = "" }
        if name == "t" || name == "v" || element == "text:p" || element == "text:h" { capture = true }
        if ["w:tab", "w:br", "text:s", "text:tab"].contains(element) { buffer += " " }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard capture else { return }
        if collectingStrings || cellType == "s" { value += string } else { buffer += string }
    }

    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        let name = element.split(separator: ":").last
        if name == "t" || name == "v" || element == "text:p" || element == "text:h" { capture = false }
        if name == "si", collectingStrings { strings.append(value) }
        if name == "c" {
            if cellType == "s", let index = Int(value), strings.indices.contains(index) { buffer += strings[index] }
            buffer += "\t"
            cellType = ""
        }
        if ["p", "h", "row", "table-row"].contains(name) { buffer += "\n" }
    }
}
