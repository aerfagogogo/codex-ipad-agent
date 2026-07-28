import Foundation
import PDFKit
import UIKit

struct PreparedFileUpload: Sendable {
    let stagingDirectoryURL: URL
    let fileURL: URL
    let name: String
    let contentType: String
    let size: Int64
    let extractedText: String
    let pageImageDataURLs: [String]

    func removeStagingFiles() {
        try? FileManager.default.removeItem(at: stagingDirectoryURL)
    }
}

enum FileAttachmentPreparationError: LocalizedError {
    case unreadable
    case empty
    case tooLarge
    case unsupported
    case invalidUTF8
    case invalidPDF

    var errorDescription: String? {
        switch self {
        case .unreadable:
            return L10n.text("ui.file_could_not_be_read")
        case .empty:
            return L10n.text("ui.file_cannot_be_empty")
        case .tooLarge:
            return L10n.text("ui.file_cannot_exceed_20_mib")
        case .unsupported:
            return L10n.text("ui.only_pdf_text_and_source_files_are_supported")
        case .invalidUTF8:
            return L10n.text("ui.text_file_must_be_utf8")
        case .invalidPDF:
            return L10n.text("ui.pdf_file_could_not_be_parsed")
        }
    }
}

enum FileAttachmentPreparer {
    static let maximumFileBytes: Int64 = 20 << 20
    static let maximumExtractedTextBytes = 128 << 10
    static let maximumPDFPageImages = 4
    static let maximumPDFPagesToInspect = 200
    static let maximumPDFPageDimension: CGFloat = 1_200
    static let maximumPDFPageImageBytes = 750 << 10

    private static let supportedTextExtensions: Set<String> = [
        "c", "cc", "cpp", "css", "csv", "go", "h", "hpp", "html", "java",
        "js", "json", "jsx", "kt", "kts", "md", "markdown", "php", "py",
        "rb", "rs", "sh", "sql", "swift", "toml", "ts", "tsx", "txt",
        "xml", "yaml", "yml", "zsh"
    ]

    nonisolated static func prepare(selectedURL: URL) async throws -> PreparedFileUpload {
        try await Task.detached(priority: .userInitiated) {
            try prepareSynchronously(selectedURL: selectedURL)
        }.value
    }

    nonisolated static func isSupportedFilename(_ name: String) -> Bool {
        let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
        return ext == "pdf" || supportedTextExtensions.contains(ext)
    }

    private nonisolated static func prepareSynchronously(selectedURL: URL) throws -> PreparedFileUpload {
        let didAccess = selectedURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                selectedURL.stopAccessingSecurityScopedResource()
            }
        }

        let values = try? selectedURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .nameKey])
        guard values?.isRegularFile != false else {
            throw FileAttachmentPreparationError.unreadable
        }
        let name = (values?.name ?? selectedURL.lastPathComponent)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, isSupportedFilename(name) else {
            throw FileAttachmentPreparationError.unsupported
        }
        if let fileSize = values?.fileSize {
            guard fileSize > 0 else {
                throw FileAttachmentPreparationError.empty
            }
            guard Int64(fileSize) <= maximumFileBytes else {
                throw FileAttachmentPreparationError.tooLarge
            }
        }

        let stagingDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MimiFileUploads", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: stagingDirectoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let stagedFileURL = stagingDirectoryURL.appendingPathComponent("content", isDirectory: false)
            try FileManager.default.copyItem(at: selectedURL, to: stagedFileURL)
            let stagedValues = try stagedFileURL.resourceValues(forKeys: [.fileSizeKey])
            let size = Int64(stagedValues.fileSize ?? 0)
            guard size > 0 else {
                throw FileAttachmentPreparationError.empty
            }
            guard size <= maximumFileBytes else {
                throw FileAttachmentPreparationError.tooLarge
            }

            let fileExtension = URL(fileURLWithPath: name).pathExtension.lowercased()
            if fileExtension == "pdf" {
                let preparedPDF = try preparePDF(at: stagedFileURL)
                return PreparedFileUpload(
                    stagingDirectoryURL: stagingDirectoryURL,
                    fileURL: stagedFileURL,
                    name: name,
                    contentType: "application/pdf",
                    size: size,
                    extractedText: preparedPDF.text,
                    pageImageDataURLs: preparedPDF.pageImageDataURLs
                )
            }

            let data = try Data(contentsOf: stagedFileURL, options: [.mappedIfSafe])
            guard let text = String(data: data, encoding: .utf8) else {
                throw FileAttachmentPreparationError.invalidUTF8
            }
            return PreparedFileUpload(
                stagingDirectoryURL: stagingDirectoryURL,
                fileURL: stagedFileURL,
                name: name,
                contentType: contentType(for: fileExtension),
                size: size,
                extractedText: truncatedUTF8(text, maximumBytes: maximumExtractedTextBytes),
                pageImageDataURLs: []
            )
        } catch {
            try? FileManager.default.removeItem(at: stagingDirectoryURL)
            throw error
        }
    }

    private nonisolated static func preparePDF(at url: URL) throws -> (text: String, pageImageDataURLs: [String]) {
        guard let document = PDFDocument(url: url), document.pageCount > 0 else {
            throw FileAttachmentPreparationError.invalidPDF
        }

        var extracted = ""
        var pageImageDataURLs: [String] = []
        // 20 MiB 内仍可能出现上千页的异常 PDF；首版只检查前 200 页，
        // 保证移动端预处理耗时有上界，完整原文件仍会上传到 Mac 缓存。
        for index in 0..<min(document.pageCount, maximumPDFPagesToInspect) {
            guard let page = document.page(at: index) else {
                continue
            }
            if extracted.utf8.count < maximumExtractedTextBytes,
               let pageText = page.string?.trimmingCharacters(in: .whitespacesAndNewlines),
               !pageText.isEmpty {
                let separator = extracted.isEmpty ? "" : "\n\n"
                extracted = truncatedUTF8(
                    extracted + separator + pageText,
                    maximumBytes: maximumExtractedTextBytes
                )
            }
            if pageImageDataURLs.count < maximumPDFPageImages,
               let dataURL = renderedPageDataURL(page) {
                pageImageDataURLs.append(dataURL)
            }
            if extracted.utf8.count >= maximumExtractedTextBytes,
               pageImageDataURLs.count >= maximumPDFPageImages {
                break
            }
        }
        return (extracted, pageImageDataURLs)
    }

    private nonisolated static func renderedPageDataURL(_ page: PDFPage) -> String? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else {
            return nil
        }
        let scale = min(maximumPDFPageDimension / bounds.width, maximumPDFPageDimension / bounds.height, 1)
        let size = CGSize(
            width: max(1, floor(bounds.width * scale)),
            height: max(1, floor(bounds.height * scale))
        )
        let image = page.thumbnail(of: size, for: .mediaBox)
        var quality: CGFloat = 0.72
        var data = image.jpegData(compressionQuality: quality)
        while let candidate = data,
              candidate.count > maximumPDFPageImageBytes,
              quality > 0.4 {
            quality -= 0.08
            data = image.jpegData(compressionQuality: quality)
        }
        guard let data, data.count <= maximumPDFPageImageBytes else {
            return nil
        }
        return "data:image/jpeg;base64,\(data.base64EncodedString())"
    }

    private nonisolated static func truncatedUTF8(_ value: String, maximumBytes: Int) -> String {
        guard value.utf8.count > maximumBytes else {
            return value
        }
        var bytes = Array(value.utf8.prefix(maximumBytes))
        while !bytes.isEmpty {
            if let truncated = String(bytes: bytes, encoding: .utf8) {
                return truncated
            }
            bytes.removeLast()
        }
        return ""
    }

    private nonisolated static func contentType(for fileExtension: String) -> String {
        switch fileExtension {
        case "json":
            return "application/json"
        case "csv":
            return "text/csv"
        case "html":
            return "text/html"
        case "css":
            return "text/css"
        case "xml":
            return "application/xml"
        default:
            return "text/plain; charset=utf-8"
        }
    }
}
