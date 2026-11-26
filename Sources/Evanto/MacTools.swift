import AppKit
import CryptoKit

typealias ToolJSON = [String: Any]

struct ToolResult {
    let text: String
    var image: Data?
    var success = true

    var response: ToolJSON {
        var items: [ToolJSON] = [["type": "inputText", "text": text]]
        if let image { items.append(["type": "inputImage", "imageUrl": "data:image/jpeg;base64," + image.base64EncodedString()]) }
        return ["success": success, "contentItems": items]
    }
}

private func tool(_ name: String, _ description: String, _ properties: [String: ToolJSON], required: [String]) -> ToolJSON {
    ["type": "function", "name": name, "description": description, "inputSchema": [
        "type": "object", "properties": properties, "required": required, "additionalProperties": false
    ] as ToolJSON]
}

extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) throws -> String {
        guard let value = self[key] as? String else { throw EvantoError("A string is required for " + key + ".") }
        return value
    }
}

struct MacTaskScope {
    let folder: URL
    let application: NSRunningApplication?
}

@MainActor
final class MacTools {
    let scope: MacTaskScope
    private let files: FolderTools
    private let desktop: DesktopTools?
    private let activity: (String) -> Void

    init(scope: MacTaskScope, images: Bool, activity: @escaping (String) -> Void = { _ in }) {
        self.scope = scope
        files = FolderTools(root: scope.folder, images: images)
        desktop = images ? scope.application.map(DesktopTools.init) : nil
        self.activity = activity
    }

    var specifications: [ToolJSON] {
        let str = ["type": "string"]
        let path = ["type": "string", "description": "Path relative to the chosen folder. Use . for its root."]
        let offset = ["type": "integer", "minimum": 0] as ToolJSON
        var specs = [
            tool("list_files", "List names and types in a folder. Optional filter matches names, case-insensitively. Page using offset.", ["path": path, "filter": str, "offset": offset], required: ["path"]),
            tool("read_file", "Read a file by path. Returns text, a revision for editable UTF-8 files, and a picture for image files when supported. Use the next offset for long text.", ["path": path, "offset": offset], required: ["path"]),
            tool("write_text", "Create a UTF-8 file or replace its whole text. Supply revision 'new' to create, or the revision from read_file to edit. Preserve all unrelated text.", ["path": path, "text": str, "revision": str], required: ["path","text","revision"]),
            tool("make_folder", "Create one folder in an existing parent.", ["path": path], required: ["path"]),
            tool("move_item", "Move or rename an existing item inside the chosen folder. The destination must be unused.", ["path": path, "destination": path], required: ["path","destination"]),
            tool("trash_item", "Move the specified item to the Mac Trash when the user asks to remove it.", ["path": path], required: ["path"])
        ]
        if desktop != nil {
            specs.append(tool("observe_app", "Bring the selected Mac app forward and inspect its front window. Returns the image, its pixel dimensions and an observation ID. Coordinates start at the upper-left.", [:], required: []))
            let pixel: ToolJSON = ["type": "integer", "minimum": 0]
            specs.append(tool("app_input", "Act on the observed window. Move, click, double_click, right_click, drag or scroll need x and y in image pixels. Drag needs endX and endY. Scroll uses signed vertical lines (positive is up). Type uses text. Key uses a named key with optional modifiers such as command+s. Observe again after the action.", [
                "observation": str, "action": ["type":"string", "enum":["move","click","double_click","right_click","drag","scroll","type","key"]],
                "x": pixel, "y": pixel, "endX": pixel, "endY": pixel, "lines": ["type":"integer"], "text": str, "key": str
            ], required: ["observation","action"]))
        }
        return specs
    }

    func call(_ name: String, _ args: ToolJSON) async throws -> ToolResult {
        try Task.checkCancellation()
        if name == "observe_app" || name == "app_input" {
            guard let desktop else { throw EvantoError("Choose a running app and an image-capable model for cursor control.") }
            activity(name == "observe_app" ? "Looking at " + desktop.name : desktop.name + " · " + (args["action"] as? String ?? "Input"))
            return name == "observe_app" ? try await desktop.observe() : try await desktop.input(args)
        }
        let labels = ["list_files": "List", "read_file": "Read", "write_text": "Write", "make_folder": "Create folder", "move_item": "Move", "trash_item": "Trash"]
        guard let label = labels[name] else { throw EvantoError("Unknown Mac tool.") }
        activity(label + " · " + (try args.string("path")))
        return try await files.perform(name, args)
    }
}

actor FolderTools {
    private let root: URL
    private let images: Bool
    private let manager = FileManager.default
    private let textLimit = 4_000_000

    init(root: URL, images: Bool) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.images = images
    }

    private func location(_ path: String, allowRoot: Bool = false) throws -> URL {
        if allowRoot && (path.isEmpty || path == ".") { return root }
        let parts = path.components(separatedBy: "/")
        guard parts.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") && !$0.contains("\0") }) else {
            throw EvantoError("Use a visible path inside the chosen folder.")
        }
        var url = root
        for part in parts {
            url.appendPathComponent(part)
            // Check each component, including dangling symlinks, before following it.
            if let type = try? manager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType, type == .typeSymbolicLink {
                throw EvantoError("This path contains a symbolic link. Choose the actual folder in Evanto.")
            }
            if (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) == true {
                throw EvantoError("Choose a document or ordinary folder.")
            }
        }
        return url
    }

    func perform(_ name: String, _ args: ToolJSON) throws -> ToolResult {
        try Task.checkCancellation()
        let path = try args.string("path")
        let url = try location(path, allowRoot: name == "list_files")
        switch name {
        case "list_files":
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
            let filter = args["filter"] as? String ?? ""
            let entries = try manager.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles)
                .filter { filter.isEmpty || $0.lastPathComponent.localizedCaseInsensitiveContains(filter) }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            let offset = min(entries.count, max(0, args["offset"] as? Int ?? 0))
            let page = entries.dropFirst(offset).prefix(120)
            let names = try page.map { entry in
                let v = try entry.resourceValues(forKeys: keys)
                let kind = v.isSymbolicLink == true ? "link" : (v.isPackage == true ? "package" : (v.isDirectory == true ? "folder" : "file"))
                return kind + "  " + entry.lastPathComponent
            }
            return ToolResult(text: (["\(entries.count) items."] + names + next(offset + page.count, total: entries.count)).joined(separator: "\n"))
        case "read_file": return try read(url, offset: max(0, args["offset"] as? Int ?? 0))
        case "write_text":
            let bytes = Data(try args.string("text").utf8)
            guard bytes.count <= textLimit else { throw EvantoError("Text files can contain up to 4 MB.") }
            let revision = try args.string("revision")
            let coordinator = NSFileCoordinator()
            var coordinationError: NSError?, writeError: Error?
            coordinator.coordinate(writingItemAt: url, options: [], error: &coordinationError) { target in
                do {
                    try Task.checkCancellation()
                    if revision == "new" {
                        let staging = target.deletingLastPathComponent().appendingPathComponent(".evanto-" + UUID().uuidString)
                        defer { try? manager.removeItem(at: staging) }
                        try bytes.write(to: staging, options: .withoutOverwriting)
                        try manager.moveItem(at: staging, to: target)
                    } else {
                        let info = try target.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                        guard info.isRegularFile == true, (info.fileSize ?? Int.max) <= textLimit else { throw EvantoError("Read an editable UTF-8 file before replacing it.") }
                        let old = try Data(contentsOf: target)
                        guard Self.revision(old) == revision else { throw EvantoError("The file changed. Read its latest revision before editing it.") }
                        try bytes.write(to: target, options: .atomic)
                    }
                } catch { writeError = error }
            }
            if let error = writeError ?? coordinationError { throw error }
            return ToolResult(text: "Saved \(bytes.count) UTF-8 bytes to \(path). Revision \(Self.revision(bytes)).")
        case "make_folder":
            try manager.createDirectory(at: url, withIntermediateDirectories: false)
            return ToolResult(text: "Created folder " + path)
        case "move_item":
            let destination = try args.string("destination")
            try manager.moveItem(at: url, to: location(destination))
            return ToolResult(text: "Moved \(path) to \(destination).")
        case "trash_item":
            try manager.trashItem(at: url, resultingItemURL: nil)
            return ToolResult(text: "Moved to Trash: " + path)
        default: throw EvantoError("Unknown file operation.")
        }
    }

    private func read(_ url: URL, offset: Int) throws -> ToolResult {
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard info.isRegularFile == true else { throw EvantoError("Choose a regular file.") }
        let content: String
        var image: Data?, revision: String?
        if (info.fileSize ?? Int.max) <= textLimit, !["pdf","rtf","doc","svg"].contains(url.pathExtension.lowercased()),
           let data = try? Data(contentsOf: url), let plain = String(data: data, encoding: .utf8), !plain.contains("\0") {
            content = plain
            revision = Self.revision(data)
        } else {
            let document = try ReferenceLibrary.read(url)
            content = document.text
            if images { image = document.image }
        }
        let start = min(offset, content.count)
        let page = content.dropFirst(start).prefix(16_000)
        let header = revision.map { "UTF-8 revision " + $0 } ?? "Extracted document"
        return ToolResult(text: ([header, String(page)] + next(start + page.count, total: content.count)).joined(separator: "\n"), image: image)
    }

    private func next(_ end: Int, total: Int) -> [String] { end < total ? ["Next offset: \(end)"] : [] }
    private static func revision(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
