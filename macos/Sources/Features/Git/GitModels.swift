import Foundation

// MARK: Status

/// A repository operation in progress, from the marker files git leaves in its directory.
enum GitRepoState: String {
    case merging
    case rebasing
    case cherryPicking
    case reverting
    case bisecting

    var title: String {
        switch self {
        case .merging: return "Merging"
        case .rebasing: return "Rebasing"
        case .cherryPicking: return "Cherry-picking"
        case .reverting: return "Reverting"
        case .bisecting: return "Bisecting"
        }
    }

    static func detect(gitDirectory: String) -> GitRepoState? {
        let fileManager = FileManager.default
        func exists(_ name: String) -> Bool {
            fileManager.fileExists(atPath: (gitDirectory as NSString).appendingPathComponent(name))
        }
        if exists("rebase-merge") || exists("rebase-apply") { return .rebasing }
        if exists("MERGE_HEAD") { return .merging }
        if exists("CHERRY_PICK_HEAD") { return .cherryPicking }
        if exists("REVERT_HEAD") { return .reverting }
        if exists("BISECT_LOG") { return .bisecting }
        return nil
    }
}

/// A path in `git status`. `index` and `workTree` are the two status letters, with "." for
/// no change.
struct GitStatusFile: Hashable {
    enum Kind: Hashable {
        case changed
        case renamed
        case unmerged
        case untracked
    }

    let path: String
    let originalPath: String?
    let index: Character
    let workTree: Character
    let kind: Kind
}

struct GitStatus: Equatable {
    var branch: String?
    var head: String?
    var upstream: String?
    var ahead: Int = 0
    var behind: Int = 0
    var state: GitRepoState?
    var files: [GitStatusFile] = []

    /// Whether git listed more files than the output limit allowed.
    var truncated: Bool = false

    /// Parses `git status --porcelain=v2 --branch -z`. A rename record is followed by its
    /// original path as a separate token.
    static func parse(_ output: GitOutput) -> GitStatus {
        var status = GitStatus()
        var tokens = output.text.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        if output.truncated, !tokens.isEmpty {
            // The last token may have been cut off.
            tokens.removeLast()
            status.truncated = true
        }

        var index = 0
        while index < tokens.count {
            let line = tokens[index]
            index += 1
            guard let type = line.first else { continue }

            switch type {
            case "#":
                status.parseHeader(line)

            case "1":
                let fields = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                guard fields.count == 9, let xy = letters(fields[1]) else { continue }
                status.files.append(.init(path: String(fields[8]), originalPath: nil, index: xy.0, workTree: xy.1, kind: .changed))

            case "2":
                let fields = line.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
                let original = index < tokens.count ? tokens[index] : nil
                index += 1
                guard fields.count == 10, let xy = letters(fields[1]) else { continue }
                status.files.append(.init(path: String(fields[9]), originalPath: original, index: xy.0, workTree: xy.1, kind: .renamed))

            case "u":
                let fields = line.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                guard fields.count == 11, let xy = letters(fields[1]) else { continue }
                status.files.append(.init(path: String(fields[10]), originalPath: nil, index: xy.0, workTree: xy.1, kind: .unmerged))

            case "?":
                guard line.count > 2 else { continue }
                status.files.append(.init(path: String(line.dropFirst(2)), originalPath: nil, index: ".", workTree: "?", kind: .untracked))

            default:
                continue
            }
        }
        return status
    }

    private mutating func parseHeader(_ line: String) {
        let parts = line.dropFirst(2).split(separator: " ", maxSplits: 1)
        guard parts.count == 2 else { return }
        let value = String(parts[1])
        switch parts[0] {
        case "branch.oid": head = value == "(initial)" ? nil : value
        case "branch.head": branch = value == "(detached)" ? nil : value
        case "branch.upstream": upstream = value
        case "branch.ab":
            let counts = value.split(separator: " ")
            guard counts.count == 2 else { return }
            ahead = Int(counts[0].dropFirst()) ?? 0
            behind = Int(counts[1].dropFirst()) ?? 0
        default:
            break
        }
    }

    private static func letters(_ field: Substring) -> (Character, Character)? {
        guard field.count == 2, let x = field.first, let y = field.last else { return nil }
        return (x, y)
    }
}

// MARK: Changes

/// The groups of the Changes page, in the order they are shown.
enum GitChangeGroup: CaseIterable, Hashable {
    case conflicts
    case staged
    case unstaged
    case untracked

    var title: String {
        switch self {
        case .conflicts: return "Conflicts"
        case .staged: return "Staged"
        case .unstaged: return "Changes"
        case .untracked: return "Untracked"
        }
    }
}

/// One row of the Changes page. A file with both staged and unstaged changes has a row in each.
struct GitChange: Hashable, Identifiable {
    let group: GitChangeGroup
    let file: GitStatusFile

    var id: String { "\(group)/\(file.path)" }

    /// The status letter shown for the row.
    var letter: Character {
        switch group {
        case .conflicts: return "U"
        case .staged: return file.index
        case .unstaged: return file.workTree
        case .untracked: return "?"
        }
    }
}

extension GitStatus {
    func changes(in group: GitChangeGroup) -> [GitChange] {
        files.compactMap { file in
            let belongs: Bool
            switch group {
            case .conflicts: belongs = file.kind == .unmerged
            case .untracked: belongs = file.kind == .untracked
            case .staged: belongs = file.kind != .unmerged && file.kind != .untracked && file.index != "."
            case .unstaged: belongs = file.kind != .unmerged && file.kind != .untracked && file.workTree != "."
            }
            return belongs ? GitChange(group: group, file: file) : nil
        }
    }
}

// MARK: History

struct GitRef: Hashable {
    enum Kind: Hashable {
        case head
        case branch
        case remote
        case tag
    }

    let name: String
    let kind: Kind

    /// Whether HEAD points at this branch (or this is a detached HEAD).
    let isHead: Bool
}

struct GitCommit: Hashable, Identifiable {
    let hash: String
    let parents: [String]
    let author: String
    let email: String
    let date: Date
    let refs: [GitRef]
    let subject: String

    var id: String { hash }
    var shortHash: String { String(hash.prefix(8)) }

    static let logFormat = "%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%D%x1f%s%x1e"

    static func parseLog(_ text: String) -> [GitCommit] {
        text.split(separator: "\u{1e}").compactMap { record in
            let fields = record
                .drop { $0 == "\n" || $0 == "\r" }
                .split(separator: "\u{1f}", maxSplits: 6, omittingEmptySubsequences: false)
            guard fields.count == 7 else { return nil }
            return GitCommit(
                hash: String(fields[0]),
                parents: fields[1].split(separator: " ").map(String.init),
                author: String(fields[2]),
                email: String(fields[3]),
                date: Date(timeIntervalSince1970: TimeInterval(fields[4]) ?? 0),
                refs: parseDecorations(String(fields[5])),
                subject: String(fields[6]))
        }
    }

    /// Parses `%D` as printed with `--decorate=full`, such as
    /// "HEAD -> refs/heads/main, tag: refs/tags/v1.0, refs/remotes/origin/main".
    static func parseDecorations(_ text: String) -> [GitRef] {
        var refs: [GitRef] = []
        for rawPart in text.components(separatedBy: ", ") {
            var part = rawPart.trimmingCharacters(in: .whitespaces)
            guard !part.isEmpty else { continue }
            if part == "HEAD" {
                refs.append(.init(name: "HEAD", kind: .head, isHead: true))
                continue
            }

            var isHead = false
            if part.hasPrefix("HEAD -> ") {
                part = String(part.dropFirst("HEAD -> ".count))
                isHead = true
            }

            if part.hasPrefix("tag: ") {
                let name = String(part.dropFirst("tag: ".count))
                refs.append(.init(name: name.removingPrefix("refs/tags/"), kind: .tag, isHead: false))
            } else if part.hasPrefix("refs/heads/") {
                refs.append(.init(name: part.removingPrefix("refs/heads/"), kind: .branch, isHead: isHead))
            } else if part.hasPrefix("refs/remotes/") {
                let name = part.removingPrefix("refs/remotes/")
                if !name.hasSuffix("/HEAD") {
                    refs.append(.init(name: name, kind: .remote, isHead: false))
                }
            } else if part.hasPrefix("refs/tags/") {
                refs.append(.init(name: part.removingPrefix("refs/tags/"), kind: .tag, isHead: false))
            } else if !part.hasPrefix("refs/") {
                // Stashes, notes and other internal refs are left out.
                refs.append(.init(name: part, kind: .branch, isHead: isHead))
            }
        }
        return refs
    }
}

/// A file changed by a commit, from `git diff-tree --name-status`.
struct GitChangedFile: Hashable, Identifiable {
    let path: String
    let originalPath: String?
    let status: Character

    var id: String { path }

    /// Parses `git diff-tree --name-status -z`: "R100\0old\0new\0" for a rename or copy,
    /// "M\0path\0" for anything else.
    static func parse(_ output: GitOutput) -> [GitChangedFile] {
        var tokens = output.text.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        if output.truncated, !tokens.isEmpty {
            tokens.removeLast()
        }

        var files: [GitChangedFile] = []
        var index = 0
        while index < tokens.count {
            let code = tokens[index]
            index += 1
            guard let status = code.first else { continue }
            if status == "R" || status == "C" {
                guard index + 1 < tokens.count else { break }
                files.append(.init(path: tokens[index + 1], originalPath: tokens[index], status: status))
                index += 2
            } else {
                guard index < tokens.count else { break }
                files.append(.init(path: tokens[index], originalPath: nil, status: status))
                index += 1
            }
        }
        return files
    }
}

struct GitCommitDetail: Equatable {
    let hash: String
    let parents: [String]
    let author: String
    let authorEmail: String
    let authorDate: Date
    let committer: String
    let commitDate: Date
    let message: String
    var files: [GitChangedFile] = []
    var filesTruncated: Bool = false

    static let format = "%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%cn%x1f%ce%x1f%ct%x1f%B"

    static func parse(_ text: String) -> GitCommitDetail? {
        let fields = text.split(separator: "\u{1f}", maxSplits: 8, omittingEmptySubsequences: false)
        guard fields.count == 9 else { return nil }
        return GitCommitDetail(
            hash: String(fields[0]),
            parents: fields[1].split(separator: " ").map(String.init),
            author: String(fields[2]),
            authorEmail: String(fields[3]),
            authorDate: Date(timeIntervalSince1970: TimeInterval(fields[4]) ?? 0),
            committer: String(fields[5]),
            commitDate: Date(timeIntervalSince1970: TimeInterval(fields[7]) ?? 0),
            message: fields[8].trimmingCharacters(in: .newlines))
    }
}

// MARK: Diff

/// A unified diff as git prints it, split into the lines the diff viewer draws.
struct GitDiff: Equatable {
    enum LineKind: Equatable {
        case hunk
        case context
        case added
        case removed
        case note
    }

    struct Line: Equatable, Identifiable {
        let id: Int
        let kind: LineKind
        let text: String
        let oldNumber: Int?
        let newNumber: Int?
    }

    var lines: [Line] = []
    var isBinary: Bool = false

    /// Whether the diff was longer than the output limit.
    var truncated: Bool = false

    var isEmpty: Bool { lines.isEmpty && !isBinary }

    static func parse(_ output: GitOutput) -> GitDiff {
        var diff = GitDiff(truncated: output.truncated)
        var oldLine = 0
        var newLine = 0
        var inHunk = false

        // A combined diff (a conflicted file) has two columns of markers per line.
        var combined = false

        func append(_ kind: LineKind, _ text: String, old: Int? = nil, new: Int? = nil) {
            diff.lines.append(.init(id: diff.lines.count, kind: kind, text: text, oldNumber: old, newNumber: new))
        }

        for rawLine in output.text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)

            if line.hasPrefix("diff ") {
                // A new file's headers follow; its hunks start again at their own numbers.
                inHunk = false
                continue
            }

            if line.hasPrefix("@@@") {
                inHunk = true
                combined = true
                append(.hunk, line)
                continue
            }

            if line.hasPrefix("@@") {
                inHunk = true
                combined = false
                (oldLine, newLine) = hunkStarts(line)
                append(.hunk, line)
                continue
            }

            guard inHunk else {
                if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
                    diff.isBinary = true
                }
                continue
            }

            if line.hasPrefix("\\") {
                append(.note, String(line.dropFirst(2)))
                continue
            }

            if combined {
                let markers = line.prefix(2)
                let text = String(line.dropFirst(2))
                if markers.contains("+") {
                    append(.added, text)
                } else if markers.contains("-") {
                    append(.removed, text)
                } else {
                    append(.context, text)
                }
                continue
            }

            switch line.first {
            case "+":
                append(.added, String(line.dropFirst()), new: newLine)
                newLine += 1
            case "-":
                append(.removed, String(line.dropFirst()), old: oldLine)
                oldLine += 1
            case " ":
                append(.context, String(line.dropFirst()), old: oldLine, new: newLine)
                oldLine += 1
                newLine += 1
            default:
                // The empty string after the last newline.
                continue
            }
        }
        return diff
    }

    /// The first old and new line numbers of a hunk header, "@@ -12,7 +12,9 @@ ...".
    private static func hunkStarts(_ header: String) -> (Int, Int) {
        let parts = header.split(separator: " ")
        func start(_ part: Substring?) -> Int {
            guard let part else { return 0 }
            return Int(part.dropFirst().split(separator: ",").first ?? "") ?? 0
        }
        let old = parts.first { $0.hasPrefix("-") }
        let new = parts.first { $0.hasPrefix("+") }
        return (start(old), start(new))
    }
}

private extension String {
    func removingPrefix(_ prefix: String) -> String {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : self
    }
}
