import XCTest
@testable import Porridge

/// Rewriting a selection with AI: the prompt, the saved presets, and how the selection is taken from the Markdown
/// and the answer put back.
@MainActor
final class AIRewriteTests: XCTestCase {
    private func range(of needle: String, in text: String) -> Range<Int> {
        let found = text.range(of: needle)!
        let lower = text.distance(from: text.startIndex, to: found.lowerBound)
        return lower..<(lower + needle.count)
    }

    // MARK: Prompt

    func testPromptCarriesInstructionPassageAndContext() {
        let prompt = AIRewrite.prompt(instruction: "  Make it shorter. ", selection: "Wir treffen uns morgen um zehn Uhr im Büro.", before: "Notizen", after: "Ende")
        XCTAssertTrue(prompt.user.hasPrefix("Instruction: Make it shorter.\n"))
        XCTAssertTrue(prompt.user.contains("Passage:\n<<<\nWir treffen uns morgen um zehn Uhr im Büro.\n>>>"))
        XCTAssertTrue(prompt.user.contains("Text before the passage (context only, do not repeat it):\nNotizen"))
        XCTAssertTrue(prompt.user.contains("Text after the passage (context only, do not repeat it):\nEnde"))
        XCTAssertTrue(prompt.system.contains("German"), "the passage's language is named for small models")
        XCTAssertTrue(prompt.system.contains("Markdown"))
    }

    func testPromptWithoutContext() {
        let prompt = AIRewrite.prompt(instruction: "Fix it", selection: "teh cat")
        XCTAssertFalse(prompt.user.contains("Text before"))
        XCTAssertFalse(prompt.user.contains("Text after"))
    }

    func testContextIsCutToTheLimit() {
        let markdown = String(repeating: "a", count: 50) + "PASSAGE" + String(repeating: "b", count: 50)
        let target = RewriteTarget(markdown: markdown, range: range(of: "PASSAGE", in: markdown))
        XCTAssertEqual(target.selected, "PASSAGE")
        let context = target.context(limit: 10)
        XCTAssertEqual(context.before, String(repeating: "a", count: 10))
        XCTAssertEqual(context.after, String(repeating: "b", count: 10))
        XCTAssertEqual(target.context(limit: 0).before, "")
    }

    func testLimitsFollowTheModel() {
        XCTAssertLessThan(AIRewrite.limit(for: .local(.apple)), AIRewrite.limit(for: .local(.qwen3)))
        XCTAssertLessThan(AIRewrite.limit(for: .local(.qwen3)), AIRewrite.limit(for: .cloud(.anthropic, "x")))
        XCTAssertEqual(AIRewrite.contextLimit(for: .local(.apple)), 0)
        XCTAssertLessThanOrEqual(AIRewrite.tokenLimit(for: String(repeating: "x", count: 100_000)), 4_000)
    }

    func testCleanRemovesWhatModelsAdd() {
        XCTAssertEqual(AIRewrite.clean("<<<\nShort text.\n>>>", original: "x"), "Short text.")
        XCTAssertEqual(AIRewrite.clean("```markdown\n- a\n- b\n```", original: "a, b"), "- a\n- b")
        XCTAssertEqual(AIRewrite.clean("Here is the rewritten passage:\n\nBetter text.", original: "x"), "Better text.")
        XCTAssertEqual(AIRewrite.clean("<think>hmm</think>\nDone.", original: "x"), "Done.")
        XCTAssertEqual(AIRewrite.clean("```\ncode\n```", original: "```\ncode\n```"), "```\ncode\n```", "a code block that was selected stays one")
        XCTAssertEqual(AIRewrite.clean("Sure: this stays", original: "x"), "Sure: this stays", "a single line is never cut")
    }

    // MARK: Presets

    private func makeStore() -> (RewritePresetStore, UserDefaults) {
        let name = "AIRewriteTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return (RewritePresetStore(defaults: defaults, cloud: nil), defaults)
    }

    func testBuiltInPresetsHaveUniqueIDs() {
        let ids = RewritePreset.builtIn.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertTrue(RewritePreset.builtIn.contains { $0.title == "Fix Spelling & Grammar" })
        XCTAssertTrue(RewritePreset.builtIn.contains { $0.title == "Translate to German" })
    }

    func testSavingPresetsStoresJSONAndSkipsDuplicates() throws {
        let (store, defaults) = makeStore()
        XCTAssertTrue(store.presets.isEmpty)
        XCTAssertNil(store.save("   "))
        let first = try XCTUnwrap(store.save("  Write it like a pirate  "))
        XCTAssertEqual(first.instruction, "Write it like a pirate")
        XCTAssertEqual(first.title, "Write it like a pirate")
        XCTAssertEqual(store.save("write it like a PIRATE")?.id, first.id, "the same instruction is kept once")
        store.save("Make it rhyme")
        XCTAssertEqual(store.presets.map(\.instruction), ["Write it like a pirate", "Make it rhyme"])
        let data = try XCTUnwrap(defaults.data(forKey: RewritePresetStore.key))
        XCTAssertEqual(RewritePresetStore.decode(data)?.count, 2, "stored as JSON in the defaults")
        let reopened = RewritePresetStore(defaults: defaults, cloud: nil)
        XCTAssertEqual(reopened.presets, store.presets)
    }

    func testRemovingAndRestoringAPreset() throws {
        let (store, _) = makeStore()
        store.save("One")
        let two = try XCTUnwrap(store.save("Two"))
        store.save("Three")
        let index = try XCTUnwrap(store.remove(two))
        XCTAssertEqual(index, 1)
        XCTAssertEqual(store.presets.map(\.instruction), ["One", "Three"])
        store.restore(two, at: index)
        XCTAssertEqual(store.presets.map(\.instruction), ["One", "Two", "Three"])
        store.restore(two, at: 0)
        XCTAssertEqual(store.presets.count, 3, "restoring twice adds nothing")
    }

    func testLongInstructionGetsAShortTitle() {
        let preset = RewritePreset.custom(String(repeating: "word ", count: 30) + "\nsecond line")
        XCTAssertLessThanOrEqual(preset.title.count, 40)
        XCTAssertTrue(preset.title.hasSuffix("…"))
        XCTAssertTrue(preset.id.hasPrefix("custom-"))
    }

    // MARK: Selection

    func testSelectionWithinALineStaysOutOfItsMark() {
        let markdown = "# Title\n- [ ] Buy milk today\nEnd"
        // From the start of the line (before "- [ ] ") to the end of "milk".
        let line = range(of: "- [ ] Buy milk", in: markdown)
        let normalized = RewriteEdit.normalize(line, in: markdown)
        XCTAssertEqual(normalized.map { RewriteEdit.substring(markdown, $0) }, "Buy milk")
    }

    func testSelectionTrimsBlankSpace() {
        let markdown = "Hello   world  \nnext"
        let normalized = RewriteEdit.normalize(range(of: "   world  \n", in: markdown), in: markdown)
        XCTAssertEqual(normalized.map { RewriteEdit.substring(markdown, $0) }, "world")
        XCTAssertNil(RewriteEdit.normalize(range(of: "   ", in: markdown), in: markdown))
    }

    func testSelectionAcrossLinesTakesWholeLines() {
        let markdown = "Intro\n- first item\n- second item\nOutro"
        let normalized = RewriteEdit.normalize(range(of: "item\n- sec", in: markdown), in: markdown)
        XCTAssertEqual(normalized.map { RewriteEdit.substring(markdown, $0) }, "- first item\n- second item")
    }

    func testSelectionDoesNotCutInlineMarks() {
        let markdown = "Some **bold words** and *italic* and [[Other Note]] here"
        let bold = RewriteEdit.normalize(range(of: "words** and", in: markdown), in: markdown)
        XCTAssertEqual(bold.map { RewriteEdit.substring(markdown, $0) }, "**bold words** and")
        let link = RewriteEdit.normalize(range(of: "Other", in: markdown), in: markdown)
        XCTAssertEqual(link.map { RewriteEdit.substring(markdown, $0) }, "[[Other Note]]")
        let italic = RewriteEdit.normalize(range(of: "and *ital", in: markdown), in: markdown)
        XCTAssertEqual(italic.map { RewriteEdit.substring(markdown, $0) }, "and *italic*")
    }

    func testMarkLengths() {
        XCTAssertEqual(RewriteEdit.markLength("## Heading"), 3)
        XCTAssertEqual(RewriteEdit.markLength("  - [x] done"), 8)
        XCTAssertEqual(RewriteEdit.markLength("12. twelve"), 4)
        XCTAssertEqual(RewriteEdit.markLength("> quote"), 2)
        XCTAssertEqual(RewriteEdit.markLength("plain"), 0)
        XCTAssertEqual(RewriteEdit.markLength("#tag at start"), 0, "a tag is no heading")
    }

    // MARK: Applying

    func testReplacingKeepsTheRestOfTheMarkdown() {
        let markdown = "# Title\n- [ ] Buy milk today\nEnd"
        let target = range(of: "Buy milk today", in: markdown)
        let result = RewriteEdit.replacing(target, with: "Buy oat milk\n", in: markdown)
        XCTAssertEqual(result.markdown, "# Title\n- [ ] Buy oat milk\nEnd")
        XCTAssertEqual(RewriteEdit.substring(result.markdown, result.range), "Buy oat milk")
    }

    func testListAnswerForAWholeLineReplacesItsMark() {
        let markdown = "Intro\n> apples, pears and plums\nOutro"
        let target = range(of: "apples, pears and plums", in: markdown)
        let result = RewriteEdit.replacing(target, with: "- apples\n- pears\n- plums", in: markdown)
        XCTAssertEqual(result.markdown, "Intro\n- apples\n- pears\n- plums\nOutro")
        XCTAssertEqual(RewriteEdit.substring(result.markdown, result.range), "- apples\n- pears\n- plums")
    }

    func testReplacingPartOfALineKeepsTheLine() {
        let markdown = "We met **yesterday** at noon."
        let target = RewriteEdit.normalize(range(of: "yesterday** at", in: markdown), in: markdown)!
        let result = RewriteEdit.replacing(target, with: "*on Monday* at", in: markdown)
        XCTAssertEqual(result.markdown, "We met *on Monday* at noon.")
    }

    func testInsertBelowAddsLinesAfterTheSelection() {
        let markdown = "First line here\nSecond line"
        let target = range(of: "line", in: markdown)
        let result = RewriteEdit.insertingBelow(target, text: "\nTranslated line\n", in: markdown)
        XCTAssertEqual(result.markdown, "First line here\nTranslated line\nSecond line")
        XCTAssertEqual(RewriteEdit.substring(result.markdown, result.range), "Translated line")
        let atEnd = RewriteEdit.insertingBelow(range(of: "Second", in: markdown), text: "Added", in: markdown)
        XCTAssertEqual(atEnd.markdown, "First line here\nSecond line\nAdded")
    }

    func testLocateFollowsAChangedNote() {
        let markdown = "Alpha beta gamma"
        let target = RewriteTarget(markdown: markdown, range: range(of: "beta", in: markdown))
        XCTAssertEqual(RewriteEdit.locate(target, in: markdown), target.range)
        let edited = "New start. Alpha beta gamma"
        XCTAssertEqual(RewriteEdit.locate(target, in: edited).map { RewriteEdit.substring(edited, $0) }, "beta")
        XCTAssertNil(RewriteEdit.locate(target, in: "beta and beta"), "ambiguous: left alone")
        XCTAssertNil(RewriteEdit.locate(target, in: "gone"))
    }

    func testUnicodeOffsets() {
        let markdown = "Grüße 👋🏽 an alle\n- Punkt"
        let target = range(of: "an alle", in: markdown)
        let result = RewriteEdit.replacing(target, with: "an euch", in: markdown)
        XCTAssertEqual(result.markdown, "Grüße 👋🏽 an euch\n- Punkt")
    }

    // MARK: Diff

    func testDiffMarksChangedWords() throws {
        let pieces = try XCTUnwrap(RewriteDiff.pieces(from: "the quick cat sat", to: "the slow cat sat down"))
        XCTAssertEqual(pieces.filter { $0.kind == .removed }.map(\.text).joined(), "quick")
        XCTAssertEqual(pieces.filter { $0.kind == .added }.map(\.text).joined(), "slow down")
        XCTAssertEqual(pieces.filter { $0.kind != .removed }.map(\.text).joined(), "the slow cat sat down", "without the removed words it is the new text")
        XCTAssertEqual(pieces.filter { $0.kind != .added }.map(\.text).joined(), "the quick cat sat", "without the added words it is the old text")
    }

    func testDiffOfLongTextsFallsBack() {
        let long = String(repeating: "word ", count: 3_000)
        XCTAssertNil(RewriteDiff.pieces(from: long, to: long + "x"))
    }

    // MARK: Editor

    /// The rewrite goes into the editor as one step: the note's Markdown changes, Undo brings the old text back.
    func testEditorAppliesRewriteAsOneUndoableChange() throws {
        var stored = "# Plan\n- [ ] call **Anna** tomorrow\nDone"
        let controller = NoteEditorController()
        let coordinator = NoteTextCoordinator(text: NoteTextBinding(get: { stored }, set: { stored = $0 }), controller: controller)
        let textView = NotePlatformTextView(usingTextLayoutManager: true)
        textView.coordinator = coordinator
        textView.delegate = coordinator
        coordinator.textView = textView
        coordinator.load(stored)
        controller.bind(coordinator)
        textView.isEditable = true

        let text = textView.text as NSString
        textView.selectedRange = text.range(of: "call Anna tomorrow")
        let target = try XCTUnwrap(coordinator.rewriteTarget())
        XCTAssertEqual(target.selected, "call **Anna** tomorrow")
        XCTAssertTrue(controller.canRewrite)

        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        XCTAssertTrue(coordinator.applyRewrite(target, text: "phone **Anna** on Monday", insertBelow: false, undoManager: undo))
        undo.endUndoGrouping()
        XCTAssertEqual(stored, "# Plan\n- [ ] phone **Anna** on Monday\nDone")
        undo.undo()
        XCTAssertEqual(stored, "# Plan\n- [ ] call **Anna** tomorrow\nDone")
        undo.redo()
        XCTAssertEqual(stored, "# Plan\n- [ ] phone **Anna** on Monday\nDone")

        textView.isEditable = false
        XCTAssertNil(coordinator.rewriteTarget(), "a view-only note is not rewritten")
    }

    // MARK: Links to entries

    func testLinksToEntriesGoToTheModelAsTokensAndComeBackWhole() {
        let a = UUID(), b = UUID()
        let first = EntryLinks.markdown(id: a, title: "Q3 [plan]")
        let second = EntryLinks.markdown(id: b, title: "Budget")
        let passage = "See \(first) and \(second), then \(first) again."
        let (sent, links) = RewriteLinks.protect(passage)
        XCTAssertEqual(sent, "See [[L1]] and [[L2]], then [[L3]] again.")
        XCTAssertFalse(sent.contains("porridge://"))
        XCTAssertEqual(links, [first, second, first])
        // The model moved and kept the tokens: every link comes back, the URL unchanged.
        let answer = RewriteLinks.restore("Then [[L2]]; see [[L1]] and [[L3]].", links: links)
        XCTAssertEqual(answer, "Then \(second); see \(first) and \(first).")
        XCTAssertEqual(EntryLinks.linkedIDs(in: answer), [a, b])
        XCTAssertEqual(RewriteLinks.removedCount(original: passage, rewritten: answer), 0)
        // A token left out: that link is not added back, and it is counted.
        let shorter = RewriteLinks.restore("See [[L1]] and [[L2]].", links: links)
        XCTAssertEqual(RewriteLinks.removedCount(original: passage, rewritten: shorter), 1)
        // Nothing to protect: the text as it is.
        XCTAssertEqual(RewriteLinks.protect("No links here").text, "No links here")
        XCTAssertEqual(RewriteLinks.restore("No links here", links: []), "No links here")
        // The context names the entries, without URLs.
        XCTAssertEqual(RewriteLinks.plain("Before \(second)."), "Before Budget.")
    }

    func testThePromptAsksToKeepTheLinkTokens() {
        let prompt = AIRewrite.prompt(instruction: "Shorter", selection: "See [[L1]].")
        XCTAssertTrue(prompt.system.contains("[[L1]]"))
        XCTAssertTrue(prompt.user.contains("See [[L1]]."))
    }
}
