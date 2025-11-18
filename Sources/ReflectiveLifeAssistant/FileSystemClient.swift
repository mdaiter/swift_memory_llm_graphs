import Foundation

protocol FileSystemClient {
    func listDocuments() async throws -> [FileSummary]
}

struct FileSummary: Equatable {
    let path: String
    let sizeBytes: Int
    let modifiedAt: Date
    let kind: String
}

final class MockFileSystemClient: FileSystemClient {
    var files: [FileSummary]

    init(files: [FileSummary]) {
        self.files = files
    }

    func listDocuments() async throws -> [FileSummary] {
        return files
    }
}
