import Foundation

/// A question that a session's last message asks and nobody answered, with the text that led to it.
public struct PendingQuestion: Equatable, Sendable {
    /// How the session asked. Jean answers each form with a different message.
    enum Form: Equatable, Sendable {
        /// A Claude `AskUserQuestion` tool call.
        case tool
        /// Text with a "Reply with a number:" list, which Jean shows as buttons.
        case text
    }

    /// The tool call id, or the message id for a question asked as text.
    public let id: String
    /// What the assistant wrote before it asked. Empty when it wrote nothing.
    public let situation: String
    public let questions: [Question]
    let form: Form

    /// Picked option indexes, by question index.
    public typealias Picks = [Int: Set<Int>]

    public struct Option: Decodable, Equatable, Sendable {
        public let label: String
        public let description: String?

        init(label: String, description: String? = nil) {
            self.label = label
            self.description = description
        }
    }

    public struct Question: Decodable, Equatable, Sendable {
        public let question: String
        public let multiSelect: Bool
        public let options: [Option]

        enum CodingKeys: String, CodingKey {
            case question, multiSelect, multiple, options
        }

        init(question: String, options: [Option]) {
            self.question = question
            self.multiSelect = false
            self.options = options
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            question = try c.decode(String.self, forKey: .question)
            // Some backends name the flag `multiple`.
            multiSelect = (try? c.decodeIfPresent(Bool.self, forKey: .multiSelect))
                ?? (try? c.decodeIfPresent(Bool.self, forKey: .multiple)) ?? false
            options = (try? c.decodeIfPresent([Option].self, forKey: .options)) ?? []
        }
    }

    /// True when every question has at least one picked option.
    public func isAnswered(by picks: Picks) -> Bool {
        questions.indices.allSatisfy { picks[$0]?.isEmpty == false }
    }

    /// The message in the format of Jean's own UI: `inlineQuestionAnswer`
    /// (src/components/chat/inline-question-utils.ts) for a question asked as text,
    /// `formatAnswersAsNaturalLanguage` (src/services/chat.ts) for a tool question.
    /// Jean lists picked options in click order; this lists them in option order.
    public func answerText(for picks: Picks) -> String {
        if form == .text, let pick = picks[0]?.min(), let options = questions.first?.options,
           options.indices.contains(pick) {
            return "\(pick + 1). \(options[pick].label)"
        }
        let parts: [String] = questions.enumerated().compactMap { index, question in
            let labels = (picks[index] ?? []).sorted()
                .filter(question.options.indices.contains)
                .map { question.options[$0].label }
                .filter { !$0.isEmpty }
                .map { "- \($0)" }
            guard !labels.isEmpty else { return nil }
            return "For \"\(question.question)\", I selected:\n" + labels.joined(separator: "\n")
        }
        return parts.isEmpty ? "No specific preferences selected." : parts.joined(separator: "\n\n")
    }

    /// The `## Recap` block when the assistant wrote one, else the whole text.
    /// Keeps the end of a long text, because the lines before the question say the most.
    static func situation(from content: String, limit: Int = 400) -> String {
        let recap = content.range(of: "## Recap", options: .backwards).map { String(content[$0.upperBound...]) }
        let text = (recap ?? content).trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > limit else { return text }
        let tail = text.suffix(limit)
        let fromLineStart = tail.firstIndex(of: "\n").map { tail[tail.index(after: $0)...] } ?? tail
        return "…" + fromLineStart.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Saved answers

extension PendingQuestion {
    /// `answered_questions` and `submitted_answers` with this answer added to the session's
    /// current values, in the shape Jean's question card saves them (`QuestionAnswer` in Jean's
    /// src/types/chat.ts). `update_session_state` replaces both values, so they must be merged.
    /// `sessionResponse` is the raw `get_session` response message.
    func savedAnswers(for picks: Picks, sessionResponse raw: Data) -> (answered: [String], submitted: [String: any Sendable]) {
        let session = (try? JSONSerialization.jsonObject(with: raw) as? [String: Any])?["data"] as? [String: Any]
        var answered = session?["answered_questions"] as? [String] ?? []
        if !answered.contains(id) { answered.append(id) }
        var submitted = (session?["submitted_answers"] as? [String: Any] ?? [:]).mapValues(Self.sendable)
        submitted[id] = picks.keys.sorted().map { index -> any Sendable in
            ["questionIndex": index, "selectedOptions": (picks[index] ?? []).sorted()] as [String: any Sendable]
        }
        return (answered, submitted)
    }

    /// A JSON value from `JSONSerialization`, as a value that can cross to the client actor.
    private static func sendable(_ value: Any) -> any Sendable {
        switch value {
        case let dictionary as [String: Any]: dictionary.mapValues(sendable)
        case let array as [Any]: array.map(sendable)
        case let string as String: string
        case let number as NSNumber: number
        default: NSNull()
        }
    }
}

// MARK: - get_session

/// The fields of Jean's `get_session` response (`Session` with the messages of its last runs)
/// that tell if a question is pending.
public struct SessionDetail: Decodable, Sendable {
    let messages: [Message]
    let answeredQuestions: [String]

    struct Message: Decodable {
        let id: String
        let role: String
        /// The message text: `content`, or the text blocks when `content` is empty, as Jean reads it.
        let content: String
        let toolCalls: [ToolCall]

        enum CodingKeys: String, CodingKey { case id, role, content, toolCalls, contentBlocks }

        private struct Block: Decodable {
            let type: String
            let text: String?
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            role = try c.decode(String.self, forKey: .role)
            let whole = ((try? c.decodeIfPresent(String.self, forKey: .content)) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let blocks = (try? c.decodeIfPresent([Block].self, forKey: .contentBlocks)) ?? []
            content = whole.isEmpty
                ? blocks.filter { $0.type == "text" }.compactMap(\.text).joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                : whole
            toolCalls = (try? c.decodeIfPresent([ToolCall].self, forKey: .toolCalls)) ?? []
        }
    }

    struct ToolCall: Decodable {
        let id: String
        let name: String
        /// Empty for a tool that is not `AskUserQuestion`.
        let questions: [PendingQuestion.Question]

        enum CodingKeys: String, CodingKey { case id, name, input }
        enum InputKeys: String, CodingKey { case questions }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            name = try c.decode(String.self, forKey: .name)
            guard name == "AskUserQuestion",
                  let input = try? c.nestedContainer(keyedBy: InputKeys.self, forKey: .input)
            else {
                questions = []
                return
            }
            // The list is a JSON array, or a string that holds the JSON array.
            if let list = try? input.decode([PendingQuestion.Question].self, forKey: .questions) {
                questions = list
            } else if let text = try? input.decode(String.self, forKey: .questions),
                      let list = try? JSONDecoder().decode([PendingQuestion.Question].self, from: Data(text.utf8)) {
                questions = list
            } else {
                questions = []
            }
        }
    }

    enum CodingKeys: String, CodingKey { case messages, answeredQuestions }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        messages = try c.decodeIfPresent([Message].self, forKey: .messages) ?? []
        answeredQuestions = (try? c.decodeIfPresent([String].self, forKey: .answeredQuestions)) ?? []
    }

    /// The question in the last message, when the assistant wrote that message
    /// (no user message came after it) and Jean has no answer for it.
    public var pendingQuestion: PendingQuestion? {
        guard let last = messages.last, last.role == "assistant" else { return nil }
        if let call = last.toolCalls.last(where: { !$0.questions.isEmpty }) {
            guard !answeredQuestions.contains(call.id) else { return nil }
            return PendingQuestion(
                id: call.id,
                situation: PendingQuestion.situation(from: last.content),
                questions: call.questions,
                form: .tool
            )
        }
        guard let asked = InlineQuestion(last.content) else { return nil }
        return PendingQuestion(
            id: last.id,
            situation: PendingQuestion.situation(from: asked.rest),
            questions: [.init(question: asked.question, options: asked.options.map { .init(label: $0) })],
            form: .text
        )
    }
}

// MARK: - Question asked as text

/// A question asked as text: a "Reply with a number:" line next to a numbered list of
/// 2 to 8 options. Uses the last such list. Jean's prompt asks every backend for this form
/// when it has no question tool.
/// Port of `parseInlineNumberedQuestion` in Jean's src/components/chat/inline-question-utils.ts,
/// so the notch shows a question exactly when Jean shows buttons.
struct InlineQuestion: Equatable {
    /// The last line before the list, without the cue.
    let question: String
    let options: [String]
    /// The text without the question, the cue and the list.
    let rest: String

    private static let cue = #"(?i)\breply with (?:a|the|one) (?:number|option)\b[^.:?!\n]*[.:]?"#

    private struct NumberedList {
        var start: Int
        var end: Int
        var options: [String] = []
    }

    init?(_ text: String) {
        let lines = text.components(separatedBy: "\n")
        var found: NumberedList?
        var current: NumberedList?

        func isBlank(_ line: String) -> Bool { line.allSatisfy(\.isWhitespace) }
        func hasCue(_ index: Int?) -> Bool {
            index.map { lines[$0].range(of: Self.cue, options: .regularExpression) != nil } ?? false
        }
        func closeList() {
            guard let list = current, list.options.count >= 2 else { return }
            let before = lines[..<list.start].lastIndex { !isBlank($0) }
            let after = lines[(list.end + 1)...].firstIndex { !isBlank($0) }
            if hasCue(before) || hasCue(after) { found = list }
        }

        for (index, line) in lines.enumerated() {
            guard let item = line.wholeMatch(of: /\s{0,3}([0-9]{1,2})[.)]\s+(.+?)\s*/) else {
                // Blank lines and indented continuation lines stay inside a list.
                if !isBlank(line), line.prefixMatch(of: /\s{2,}\S/) == nil {
                    closeList()
                    current = nil
                }
                continue
            }
            let number = Int(item.1) ?? 0
            if number == 1 {
                closeList()
                current = NumberedList(start: index, end: index)
            }
            if let list = current, number == list.options.count + 1 {
                current?.options.append(Self.plain(String(item.2)))
                current?.end = index
            } else {
                closeList()
                current = nil
            }
        }
        closeList()

        guard let list = found, list.options.count <= 8, Set(list.options).count == list.options.count else {
            return nil
        }
        // Only the first cue of a line, as Jean does.
        func withoutCue(_ line: String) -> String {
            var line = line
            if let cue = line.range(of: Self.cue, options: .regularExpression) { line.removeSubrange(cue) }
            return line.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
        }
        let questionIndex = lines[..<list.start].lastIndex { !Self.plain(withoutCue($0)).isEmpty }
        let asked = questionIndex.map { Self.plain(withoutCue(lines[$0])) } ?? ""
        question = asked.isEmpty ? "Choose an option" : asked
        options = list.options
        rest = lines.enumerated()
            .filter { $0.offset != questionIndex && !(list.start...list.end).contains($0.offset) }
            .map { withoutCue($0.element) }
            .joined(separator: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Text without bold, code and heading marks, and with each link as its label.
    private static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: #"\*\*|__|`"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"^#+\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
