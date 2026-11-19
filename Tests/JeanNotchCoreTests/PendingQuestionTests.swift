import Foundation
import Testing
@testable import JeanNotchCore

// Samples follow Jean's `get_session` response: `Session` (chat/types.rs) with `messages`,
// each a `ChatMessage` with `tool_calls`. The tool `input` keeps the CLI's camelCase keys.

private let askInput = #"{"questions":[{"question":"Which color?","header":"Color","multiSelect":false,"options":[{"label":"Red","description":"Warm"},{"label":"Blue"}]}]}"#

private func detail(messages: String, answered: String = "[]") throws -> SessionDetail {
    let json = #"{"type":"response","id":"1","data":{"id":"s1","answered_questions":\#(answered),"messages":\#(messages)}}"#
    return try ServerMessage.decodeData(SessionDetail.self, from: Data(json.utf8))
}

private func asking(input: String = askInput, content: String = "Two colors fit.") -> String {
    #"""
    [{"id":"m1","role":"user","content":"Pick a color","tool_calls":[]},
     {"id":"m2","role":"assistant","content":"\#(content)","tool_calls":[
        {"id":"t0","name":"Read","input":{"file_path":"/a"},"output":"x"},
        {"id":"t1","name":"AskUserQuestion","input":\#(input)}]}]
    """#
}

@Test func readsThePendingQuestionOfTheLastAssistantMessage() throws {
    let pending = try #require(try detail(messages: asking()).pendingQuestion)
    #expect(pending.id == "t1")
    #expect(pending.situation == "Two colors fit.")
    #expect(pending.questions.count == 1)
    #expect(pending.questions[0].question == "Which color?")
    #expect(pending.questions[0].multiSelect == false)
    #expect(pending.questions[0].options.map(\.label) == ["Red", "Blue"])
    #expect(pending.questions[0].options[0].description == "Warm")
}

@Test func readsQuestionsSentAsAJSONString() throws {
    let input = #"{"questions":"[{\"question\":\"Which color?\",\"multiple\":true,\"options\":[{\"label\":\"Red\"}]}]"}"#
    let pending = try #require(try detail(messages: asking(input: input)).pendingQuestion)
    #expect(pending.questions[0].question == "Which color?")
    #expect(pending.questions[0].multiSelect)
}

@Test func noPendingQuestionOnceAnsweredOrFollowedByAUserMessage() throws {
    #expect(try detail(messages: asking(), answered: #"["t1"]"#).pendingQuestion == nil)

    let followed = asking().dropLast() + #","# + #"{"id":"m3","role":"user","content":"Red","tool_calls":[]}]"#
    #expect(try detail(messages: String(followed)).pendingQuestion == nil)

    let noQuestion = #"[{"id":"m1","role":"assistant","content":"Done","tool_calls":[{"id":"t0","name":"Read","input":{}}]}]"#
    #expect(try detail(messages: noQuestion).pendingQuestion == nil)
    #expect(try detail(messages: "[]").pendingQuestion == nil)
}

@Test func answerTextMatchesJeansFormat() throws {
    let input = #"{"questions":[{"question":"Which color?","multiSelect":false,"options":[{"label":"Red"},{"label":"Blue"}]},{"question":"Which sizes?","multiSelect":true,"options":[{"label":"S"},{"label":"M"},{"label":"L"}]}]}"#
    let pending = try #require(try detail(messages: asking(input: input)).pendingQuestion)

    #expect(pending.answerText(for: [0: [1], 1: [2, 0]]) == """
    For "Which color?", I selected:
    - Blue

    For "Which sizes?", I selected:
    - S
    - L
    """)
    #expect(pending.isAnswered(by: [0: [1], 1: [2, 0]]))
    #expect(!pending.isAnswered(by: [0: [1]]))
    #expect(!pending.isAnswered(by: [0: [1], 1: []]))
}

@Test func situationPrefersTheRecapAndKeepsTheEndOfALongText() {
    #expect(PendingQuestion.situation(from: "Intro\n\n## Recap\n\nTests pass. One choice is open.\n") == "Tests pass. One choice is open.")
    #expect(PendingQuestion.situation(from: "  Short lead-in.\n") == "Short lead-in.")

    let long = (1...40).map { "Line number \($0) of the text." }.joined(separator: "\n")
    let tail = PendingQuestion.situation(from: long, limit: 100)
    #expect(tail.hasPrefix("…Line number "))
    #expect(tail.hasSuffix("Line number 40 of the text."))
    #expect(tail.count <= 101)
}

// The message below is what a Claude session wrote on Jean 1.0.16 when it had no question tool.
private let recapQuestion = """
Two colors are possible for the test banner.

## Recap

The banner has no color yet. **Both** colors pass the contrast check.

Question: Which color do you want for the test banner?

Reply with a number:
1. Red (warm and loud)
2. `Blue` (calm and quiet)
"""

private func textDetail(_ content: String) throws -> SessionDetail {
    let message = try JSONSerialization.data(withJSONObject: [["id": "m9", "role": "assistant", "content": content]])
    return try detail(messages: String(decoding: message, as: UTF8.self))
}

@Test func readsAQuestionAskedAsTextAndAnswersLikeJeansButtons() throws {
    let pending = try #require(try textDetail(recapQuestion).pendingQuestion)
    #expect(pending.id == "m9")
    #expect(pending.questions.count == 1)
    #expect(pending.questions[0].question == "Question: Which color do you want for the test banner?")
    #expect(pending.questions[0].options.map(\.label) == ["Red (warm and loud)", "Blue (calm and quiet)"])
    #expect(pending.situation == "The banner has no color yet. **Both** colors pass the contrast check.")
    #expect(pending.answerText(for: [0: [1]]) == "2. Blue (calm and quiet)")
    #expect(!pending.isAnswered(by: [:]))
}

@Test func inlineQuestionFollowsJeansParserRules() {
    #expect(InlineQuestion("Steps:\n1. Build\n2. Test") == nil)
    #expect(InlineQuestion("Pick?\nReply with a number:\n1. Only one") == nil)
    #expect(InlineQuestion("Pick?\nReply with a number:\n1. Same\n2. Same") == nil)
    #expect(InlineQuestion("Pick?\nReply with a number:\n1. A\n3. C") == nil)

    let cueAfter = InlineQuestion("Intro.\n\nWhich one?\n1) A\n   more about A\n2) B\n\nReply with one option.")
    #expect(cueAfter?.question == "Which one?")
    #expect(cueAfter?.options == ["A", "B"])
    #expect(cueAfter?.rest == "Intro.")

    let lastListWins = InlineQuestion("Old?\nReply with a number:\n1. X\n2. Y\n\nNew?\nReply with a number:\n1. [P](https://p.example)\n2. Q")
    #expect(lastListWins?.question == "New?")
    #expect(lastListWins?.options == ["P", "Q"])

    #expect(InlineQuestion("Reply with a number:\n1. A\n2. B")?.question == "Choose an option")

    let cueTwice = InlineQuestion("Reply with a number. Reply with the option you like: which?\n1. Red\n2. Blue")
    #expect(cueTwice?.question == "Reply with the option you like: which?")
}

@Test func readsTheTextBlocksWhenContentIsEmpty() throws {
    let messages = #"[{"id":"m1","role":"assistant","content":"","content_blocks":[{"type":"text","text":"\n\n    1. A\n2. B\nReply with a number."},{"type":"tool_use","tool_call_id":"t"}]}]"#
    let pending = try #require(try detail(messages: messages).pendingQuestion)
    #expect(pending.questions[0].options.map(\.label) == ["A", "B"])
}

@Test func savedAnswersKeepEarlierAnswersAndUseJeansShape() throws {
    let pending = try #require(try detail(messages: asking()).pendingQuestion)
    let session = Data(#"{"type":"response","id":"1","data":{"answered_questions":["old"],"submitted_answers":{"old":[{"questionIndex":0,"selectedOptions":[2],"customText":"x"}]}}}"#.utf8)

    let saved = pending.savedAnswers(for: [0: [1]], sessionResponse: session)
    #expect(saved.answered == ["old", "t1"])

    let json = try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: saved.submitted)) as? [String: [[String: Any]]]
    #expect(json?["old"]?.first?["customText"] as? String == "x")
    #expect(json?["t1"]?.first?["questionIndex"] as? Int == 0)
    #expect(json?["t1"]?.first?["selectedOptions"] as? [Int] == [1])

    let empty = pending.savedAnswers(for: [0: [0]], sessionResponse: Data(#"{"type":"response","id":"1","data":{}}"#.utf8))
    #expect(empty.answered == ["t1"])
    #expect(empty.submitted.keys.sorted() == ["t1"])
}
