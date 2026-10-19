import Foundation
import SwiftTerm
import WorkbenchCore

final class SemanticCommandCapture {
    private struct Point { let row: Int; let col: Int }
    private final class RowProof {
        weak var line: BufferLine?
        let generation: UInt64
        let row: Int
        init(_ line: BufferLine, row: Int) { self.line = line; generation = line.generation; self.row = row }
    }
    private struct Snapshot {
        let start: Point
        let end: Point
        let command: String
        let output: String
        let columns: Int
        let rows: [RowProof]
    }
    private var prompt: Point?
    private var hasInput = false
    private var outputStart: Point?
    private var command = ""
    private var started: Date?
    private var snapshots: [Snapshot] = []
    private let now: () -> Date
    var completed: ((TimeInterval, Int?) -> Void)?
    init(now: @escaping () -> Date = Date.init) { self.now = now }
    func reset() { prompt = nil; hasInput = false; outputStart = nil; command = ""; started = nil; snapshots = [] }
    func receive(_ action: ShellMarkerAction, terminal: Terminal) {
        if terminal.isCurrentBufferAlternate { reset(); return }
        let trim = terminal.buffer.totalLinesTrimmed
        switch action {
        case .invalidate: reset()
        case .prompt:
            outputStart = nil; started = nil; hasInput = false; command = ""
            prompt = terminal.activeSemanticPromptOrigin.map { Point(row: $0.row + trim, col: $0.col) }
        case .input: hasInput = prompt != nil
        case .begin:
            guard let prompt, hasInput, let cursor = cursor(terminal), valid(prompt, terminal: terminal), let text = text(terminal, from: prompt, to: cursor, role: .input), !text.isEmpty else { outputStart = nil; started = nil; return }
            command = text; outputStart = cursor; started = now(); hasInput = false
        case .end(let status):
            defer { outputStart = nil; started = nil; hasInput = false }
            if let started, outputStart != nil { completed?(max(0, now().timeIntervalSince(started)), status) }
            guard let prompt, let outputStart, let end = cursor(terminal), valid(prompt, terminal: terminal),
                  let currentInput = text(terminal, from: prompt, to: outputStart, role: .input), currentInput == command,
                  let output = text(terminal, from: outputStart, to: end, role: .output) else { return }
            let lastRow = end.col == 0 ? end.row - 1 : end.row
            guard lastRow >= prompt.row, lastRow - prompt.row <= 2000 else { return }
            var proofs: [RowProof] = []
            for row in prompt.row...lastRow {
                guard let line = terminal.bufferLine(atRow: row - trim) else { return }
                proofs.append(RowProof(line, row: row))
            }
            snapshots.insert(Snapshot(start: prompt, end: end, command: command, output: output, columns: terminal.cols, rows: proofs), at: 0)
            var bytes = 0
            snapshots = Array(snapshots.prefix(20).prefix { snapshot in
                bytes += snapshot.command.utf8.count + snapshot.output.utf8.count
                return bytes <= 1024 * 1024
            })
        }
    }
    func selectedText(terminal: Terminal, start: Position, end: Position, output: Bool) -> String? {
        guard !terminal.isCurrentBufferAlternate, start != end else { return nil }
        let trim = terminal.buffer.totalLinesTrimmed
        let lower = Position.compare(start, end) == .after ? end : start
        let upper = Position.compare(start, end) == .after ? start : end
        for snapshot in snapshots {
            guard snapshot.columns == terminal.cols,
                  before(snapshot.start, Point(row: lower.row + trim, col: lower.col)), before(Point(row: upper.row + trim, col: upper.col), snapshot.end),
                  snapshot.rows.allSatisfy({ proof in
                      guard proof.row >= trim, let line = proof.line else { return false }
                      return terminal.bufferLine(atRow: proof.row - trim) === line && line.generation == proof.generation
                  }) else { continue }
            return output ? snapshot.output : snapshot.command
        }
        return nil
    }
    private func valid(_ point: Point, terminal: Terminal) -> Bool {
        let row = point.row - terminal.buffer.totalLinesTrimmed
        return row >= 0 && terminal.semanticPromptMarks(at: row).contains { $0.kind == .initial && $0.position.col == point.col }
    }
    private func cursor(_ terminal: Terminal) -> Point? {
        var lower = 0; var upper = max(1, terminal.rows)
        while terminal.bufferLine(atRow: upper) != nil { lower = upper; upper *= 2 }
        while lower + 1 < upper { let middle = (lower + upper) / 2; if terminal.bufferLine(atRow: middle) == nil { upper = middle } else { lower = middle } }
        let cursor = terminal.getCursorLocation()
        guard upper >= terminal.rows else { return nil }
        return Point(row: upper - terminal.rows + cursor.y + terminal.buffer.totalLinesTrimmed, col: cursor.x)
    }
    private func before(_ first: Point, _ second: Point) -> Bool { first.row < second.row || (first.row == second.row && first.col <= second.col) }
    private func text(_ terminal: Terminal, from start: Point, to end: Point, role: SemanticContent) -> String? {
        let trim = terminal.buffer.totalLinesTrimmed
        guard before(start, end), start.row >= trim, end.row - start.row <= 2000 else { return nil }
        var rows: [(String, Bool)] = []; var bytes = 0
        for row in start.row...end.row {
            guard let line = terminal.bufferLine(atRow: row - trim) else { return nil }
            var column = row == start.row ? start.col : 0
            let limit = min(line.getTrimmedLength(), row == end.row ? end.col : line.count, terminal.cols)
            var content = ""
            while column < limit {
                if terminal.semanticContent(at: Position(col: column, row: row - trim)) != role { column += 1; continue }
                let first = column
                while column < limit, terminal.semanticContent(at: Position(col: column, row: row - trim)) == role { column += 1 }
                content += line.translateToString(startCol: first, endCol: column, skipNullCellsFollowingWide: true, characterProvider: { terminal.getCharacter(for: $0) })
            }
            bytes += content.utf8.count + 1
            guard bytes <= 1024 * 1024 else { return nil }
            rows.append((content, line.isWrapped))
        }
        guard let first = rows.firstIndex(where: { !$0.0.isEmpty }), let last = rows.lastIndex(where: { !$0.0.isEmpty }) else { return "" }
        var result = rows[first].0
        for index in rows.indices where index > first && index <= last { result += (rows[index].1 ? "" : "\n") + rows[index].0 }
        return result
    }
}

extension SafeTerminalView {
    func copySemanticCommand(output: Bool) {
        guard semanticCommandCopyAllowed, selectionActive,
              let text = commandCapture.selectedText(terminal: getTerminal(), start: selection.start, end: selection.end, output: output) else {
            clipboard.report(L10n.text("没有可确认的完整命令。需要 OSC 133 开始/结束标记；清屏、改写、截断、跨命令或 tmux 时请使用普通选区复制。"), failed: true); return
        }
        guard !text.isEmpty else { clipboard.report(L10n.text("这条命令没有可复制的显示输出，原剪贴板未修改。"), failed: true); return }
        clipboard.write(text)
    }
}
