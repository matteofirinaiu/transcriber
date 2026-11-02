import Foundation
import Testing
@testable import TranscriberCore

@Suite struct TimestampTests {
    @Test func formatsHoursMinutesSeconds() {
        #expect(Timestamp.format(0) == "00:00:00")
        #expect(Timestamp.format(754.9) == "00:12:34")
        #expect(Timestamp.format(3_723) == "01:02:03")
        #expect(Timestamp.format(-5) == "00:00:00")
    }

    @Test func parsesBothForms() {
        #expect(Timestamp.parse("00:47:12") == 2_832)
        #expect(Timestamp.parse("12:34") == 754)
        #expect(Timestamp.parse("abc") == nil)
    }
}

@Suite struct ParagraphBuilderTests {
    private func word(_ text: String, _ start: TimeInterval, _ end: TimeInterval) -> TimedText {
        TimedText(text: text, start: start, end: end)
    }

    @Test func breaksOnLongPause() {
        let paragraphs = ParagraphBuilder().build([
            word("Okay,", 0.5, 0.8), word("let's", 0.9, 1.1), word("start.", 1.2, 1.6),
            word("Next", 5.0, 5.3), word("topic.", 5.4, 5.9),
        ])
        #expect(paragraphs == [
            Paragraph(start: 0.5, text: "Okay, let's start."),
            Paragraph(start: 5.0, text: "Next topic."),
        ])
        #expect(ParagraphBuilder.render(paragraphs) == "[00:00:00] Okay, let's start.\n\n[00:00:05] Next topic.")
    }

    @Test func breaksLongParagraphAtSentenceEnd() {
        var units: [TimedText] = []
        var time: TimeInterval = 0
        for index in 0..<120 {
            let text = index % 10 == 9 ? "end." : "word"
            units.append(word(text, time, time + 0.4))
            time += 0.5
        }
        let paragraphs = ParagraphBuilder(softMaxDuration: 20, hardMaxDuration: 90).build(units)
        #expect(paragraphs.count > 1)
        #expect(paragraphs.dropLast().allSatisfy { $0.text.hasSuffix("end.") })
    }

    @Test func forcesBreakWithoutPunctuation() {
        let units = (0..<300).map { word("word", Double($0) * 0.5, Double($0) * 0.5 + 0.4) }
        let paragraphs = ParagraphBuilder(hardMaxDuration: 60).build(units)
        #expect(paragraphs.count >= 2)
        #expect(paragraphs[1].start <= 61)
    }

    /// Real case from the test audio: "week." ends at 35.12 s but really at ~34.4 s,
    /// and the 2.5 s pause before "Perfetto," looked like 1.5 s.
    @Test func ignoresStretchedLastWordBeforePause() {
        let units = [word("this", 33.44, 33.60), word("week.", 33.84, 35.12), word("Perfetto,", 36.64, 37.76)]
        #expect(ParagraphBuilder.words.build(units).count == 2)
        #expect(ParagraphBuilder.sentences.build(units).count == 1)
    }

    @Test func skipsEmptyText() {
        #expect(ParagraphBuilder().build([word("  ", 0, 1)]).isEmpty)
    }
}

@Suite struct DraftCutTests {
    private func word(_ text: String, _ start: TimeInterval) -> TimedText {
        TimedText(text: text, start: start, end: start + 0.4)
    }

    @Test func prefersTheLastSentenceEnd() {
        let words = [word("We", 10), word("agree.", 10.5), word("Then", 11), word("the", 11.5), word("budget", 12), word("is", 17.5)]
        #expect(DraftCut.index(in: words, before: 15) == 1)
    }

    @Test func fallsBackToTheLastWordBeforeTheLimit() {
        let words = [word("one", 1), word("two", 2), word("three", 3), word("four", 9)]
        #expect(DraftCut.index(in: words, before: 5) == 2)
    }

    @Test func ignoresSentenceEndsTooFarBack() {
        let words = [word("Old.", 1), word("long", 12), word("talk", 13), word("now", 18)]
        #expect(DraftCut.index(in: words, before: 15) == 2)
    }

    @Test func returnsNilWhenNothingIsStable() {
        #expect(DraftCut.index(in: [word("late", 14)], before: 10) == nil)
        #expect(DraftCut.index(in: [], before: 10) == nil)
    }
}

@Suite struct SpeakerTests {
    private func word(_ text: String, _ start: TimeInterval, _ end: TimeInterval) -> TimedText {
        TimedText(text: text, start: start, end: end)
    }

    @Test func labelsWordsAndNumbersPeopleInOrderOfAppearance() {
        let words = [word("Hello.", 0, 0.5), word("Ciao,", 2, 2.4), word("come", 2.4, 2.7), word("stai?", 2.7, 3.1), word("Fine.", 4, 4.4)]
        let spans = [
            SpeakerSpan(speaker: "S2", start: 0, end: 1),
            SpeakerSpan(speaker: "S1", start: 1.9, end: 3.2),
            SpeakerSpan(speaker: "S2", start: 3.9, end: 4.5),
        ]
        let labeled = SpeakerAssignment.label(words, with: spans)
        #expect(labeled.map(\.speaker) == ["Speaker 1", "Speaker 2", "Speaker 2", "Speaker 2", "Speaker 1"])
        #expect(ParagraphBuilder.render(ParagraphBuilder.words.build(labeled))
            == "[00:00:00] Speaker 1: Hello.\n\n[00:00:02] Speaker 2: Ciao, come stai?\n\n[00:00:04] Speaker 1: Fine.")
    }

    @Test func singleVoiceGetsNoLabels() {
        let words = [word("Just", 0, 0.4), word("me.", 0.5, 0.9)]
        let labeled = SpeakerAssignment.label(words, with: [SpeakerSpan(speaker: "S1", start: 0, end: 1)])
        #expect(labeled.allSatisfy { $0.speaker == nil })
    }

    @Test func absorbsATinyIslandBetweenTheSameVoice() {
        let words = [word("We", 0, 0.3), word("the", 0.35, 0.5), word("plan.", 0.55, 0.9), word("Sì,", 3, 3.4), word("certo.", 3.4, 3.9)]
        let spans = [
            SpeakerSpan(speaker: "S1", start: 0, end: 0.34),
            SpeakerSpan(speaker: "S2", start: 0.34, end: 0.52),
            SpeakerSpan(speaker: "S1", start: 0.52, end: 1),
            SpeakerSpan(speaker: "S2", start: 2.9, end: 4),
        ]
        #expect(SpeakerAssignment.label(words, with: spans).map(\.speaker)
            == ["Speaker 1", "Speaker 1", "Speaker 1", "Speaker 2", "Speaker 2"])
    }

    @Test func wordsOutsideEveryVoiceFollowTheirNeighbour() {
        let words = [word("A", 0, 0.3), word("B", 5, 5.3), word("C", 10, 10.3)]
        let spans = [SpeakerSpan(speaker: "S1", start: 0, end: 0.5), SpeakerSpan(speaker: "S2", start: 9.9, end: 10.5)]
        #expect(SpeakerAssignment.label(words, with: spans).map(\.speaker) == ["Speaker 1", "Speaker 1", "Speaker 2"])
    }

    /// "week.", stretched into the pause, stays with whoever said it.
    @Test func stretchedLastWordStaysWithItsSpeaker() {
        let words = [word("this", 33.44, 33.6), word("week.", 33.84, 35.12), word("Perfetto,", 36.64, 37.2)]
        let spans = [SpeakerSpan(speaker: "S1", start: 30, end: 34.4), SpeakerSpan(speaker: "S2", start: 34.5, end: 38)]
        #expect(SpeakerAssignment.label(words, with: spans).map(\.speaker) == ["Speaker 1", "Speaker 1", "Speaker 2"])
    }

    /// Real case from the test audio: speaker separation gave "to August." to the next speaker.
    @Test func movesAMidSentenceChangeToTheNextPause() {
        let words = [
            word("third", 31.27, 31.75), word("compared", 31.75, 32.23), word("to", 32.23, 32.47),
            word("August.", 32.47, 33.43), word("Perfetto,", 33.99, 35.03), word("allora", 35.03, 35.43),
        ]
        let spans = [SpeakerSpan(speaker: "S2", start: 27.79, end: 32.0), SpeakerSpan(speaker: "S3", start: 32.0, end: 39)]
        #expect(SpeakerAssignment.label(words, with: spans).map(\.speaker)
            == ["Speaker 1", "Speaker 1", "Speaker 1", "Speaker 1", "Speaker 2", "Speaker 2"])
    }

    @Test func movesAMidSentenceChangeBackToTheSentenceEnd() {
        let words = [word("We", 0, 0.3), word("agree.", 0.3, 0.8), word("So", 0.8, 1.0), word("the", 1.0, 1.2), word("plan", 1.2, 1.6)]
        let spans = [SpeakerSpan(speaker: "A", start: 0, end: 1.0), SpeakerSpan(speaker: "B", start: 1.0, end: 2)]
        #expect(SpeakerAssignment.label(words, with: spans).map(\.speaker)
            == ["Speaker 1", "Speaker 1", "Speaker 2", "Speaker 2", "Speaker 2"])
    }

    @Test func keepsChangesThatAlreadyFallOnAPauseOrSentenceEnd() {
        let words = [word("Fine.", 0, 0.4), word("Hi", 0.4, 0.7), word("to", 0.7, 0.8), word("everyone", 2.0, 2.4), word("ok", 2.4, 2.6)]
        let spans = [
            SpeakerSpan(speaker: "A", start: 0, end: 0.4), SpeakerSpan(speaker: "B", start: 0.4, end: 0.85),
            SpeakerSpan(speaker: "A", start: 1.9, end: 3),
        ]
        #expect(SpeakerAssignment.label(words, with: spans).map(\.speaker)
            == ["Speaker 1", "Speaker 2", "Speaker 2", "Speaker 1", "Speaker 1"])
    }

    @Test func renamesOnlyAtTheStartOfParagraphs() {
        let body = "[00:00:00] Speaker 1: Hi.\n\n[00:00:02] Speaker 2: Hello.\n\n[00:00:04] Speaker 1: Speaker 2: said yes."
        #expect(SpeakerNames.rename("Speaker 1", to: "Marco", in: body)
            == "[00:00:00] Marco: Hi.\n\n[00:00:02] Speaker 2: Hello.\n\n[00:00:04] Marco: Speaker 2: said yes.")
        #expect(SpeakerNames.rename("Speaker 3", to: "Anna", in: body) == body)
    }

    @Test func cleansNamesAndMergesDuplicates() {
        #expect(SpeakerNames.clean("  Marco: Rossi,\n jr ") == "Marco Rossi jr")
        #expect(SpeakerNames.clean(":,") == "")
        #expect(SpeakerNames.unique(["Marco", "Anna", "Marco"]) == ["Marco", "Anna"])
    }
}

@Suite struct MarkdownTests {
    private let date = Date(timeIntervalSince1970: 1_793_370_600) // around 30/10/2026

    @Test func roundTripsAllFields() {
        let document = TranscriptDocument(
            title: "Call: budget \"Q4\"", date: date, duration: 2_832, languages: ["en", "it"],
            speakers: ["Marco", "Speaker 2"], kind: .final,
            body: "[00:00:04] Marco: Okay.\n\n[00:01:12] Speaker 2: Sounds good.")
        let parsed = TranscriptMarkdown.parse(TranscriptMarkdown.render(document), fallbackTitle: "x", fallbackDate: .distantPast)
        #expect(parsed == document)
    }

    @Test func writesEnglishKeys() {
        let rendered = TranscriptMarkdown.render(TranscriptDocument(
            title: "T", date: date, duration: 75, languages: ["en"], speakers: ["Speaker 1", "Speaker 2"],
            kind: .draft, body: "x"))
        for line in ["title: \"T\"", "duration: 00:01:15", "languages: en", "speakers: Speaker 1, Speaker 2", "version: draft"] {
            #expect(rendered.contains("\n\(line)\n"))
        }
    }

    /// The first versions of the app wrote the frontmatter in Italian: those files must still open.
    @Test func readsFilesWrittenWithItalianKeys() {
        let text = """
            ---
            titolo: "Riunione 30/10/2026 13:33"
            data: 2026-10-30T13:33:00+01:00
            durata: 00:12:34
            lingue: en, it
            persone: Marco, Persona 2
            versione: bozza
            id: D9DF21CE-2F4E-4F0A-A800-0C0CB0D5D054
            ---

            # Riunione 30/10/2026 13:33

            [00:00:04] Marco: Okay.
            """
        let parsed = TranscriptMarkdown.parse(text, fallbackTitle: "x", fallbackDate: .distantPast)
        #expect(parsed.title == "Riunione 30/10/2026 13:33")
        #expect(parsed.date == ISO8601DateFormatter().date(from: "2026-10-30T12:33:00Z"))
        #expect(parsed.duration == 754)
        #expect(parsed.languages == ["en", "it"])
        #expect(parsed.speakers == ["Marco", "Persona 2"])
        #expect(parsed.kind == .draft)
        #expect(parsed.id == UUID(uuidString: "D9DF21CE-2F4E-4F0A-A800-0C0CB0D5D054"))
        #expect(parsed.body == "[00:00:04] Marco: Okay.")
    }

    @Test func readsHandWrittenFileWithoutFrontmatter() {
        let fallbackID = TranscriptMarkdown.stableID(for: URL(fileURLWithPath: "/tmp/notes.md"))
        let parsed = TranscriptMarkdown.parse("# Notes\n\nFree text.", fallbackTitle: "file", fallbackDate: date, fallbackID: fallbackID)
        #expect(parsed.id == fallbackID)
        #expect(fallbackID == TranscriptMarkdown.stableID(for: URL(fileURLWithPath: "/tmp/notes.md")))
        #expect(parsed.title == "Notes")
        #expect(parsed.body == "Free text.")
        #expect(parsed.date == date)
        #expect(parsed.kind == .final)
    }

    @Test func plainTextHasNoFrontmatter() {
        let document = TranscriptDocument(title: "T", date: date, duration: 1, languages: [], kind: .draft, body: "[00:00:00] Hi.")
        #expect(document.plainText == "T\n\n[00:00:00] Hi.\n")
    }
}

@Suite struct LibraryTests {
    private func temporaryLibrary() throws -> TranscriptLibrary {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("transcriber-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return TranscriptLibrary(folder: folder)
    }

    @Test func defaultTitleSpellsTheMonthOut() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 9, minute: 5)))
        #expect(TranscriptLibrary.defaultTitle(for: date) == "Recording 31 Oct 2026, 09:05")
    }

    @Test func savesRenamesAndSearches() throws {
        let library = try temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: library.folder) }
        let date = Date()
        var document = TranscriptDocument(
            title: TranscriptLibrary.defaultTitle(for: date), date: date, duration: 60, languages: ["en"],
            kind: .final, body: "[00:00:01] The roadmap is ready.")

        let first = try library.save(document, replacing: nil)
        #expect(first.lastPathComponent.hasSuffix(" Recording.md"))

        document.title = "Budget: Q4/2026"
        let renamed = try library.save(document, replacing: first)
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(renamed.lastPathComponent.hasSuffix(" Budget. Q4-2026.md"))

        let all = library.loadAll()
        #expect(all.count == 1)
        #expect(all[0].document == document)
        #expect(all[0].id == document.id)
        #expect(all[0].matches("ROADMAP"))
        #expect(all[0].matches("budget"))
        #expect(!all[0].matches("minutes"))
    }

    @Test func keepsDifferentRecordingsApart() throws {
        let library = try temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: library.folder) }
        let date = Date()
        let document = TranscriptDocument(title: "Stand-up", date: date, duration: 1, languages: [], kind: .final, body: "a")
        let first = try library.save(document, replacing: nil)
        let second = try library.save(document, replacing: nil)
        #expect(first != second)
        #expect(library.loadAll().count == 2)
    }
}

@Suite struct WavWriterTests {
    @Test func writesValidHeaderAndRepairsAfterCrash() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("transcriber-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try WavFileWriter(url: url)
        let samples = [Float](repeating: 0.5, count: 16_000)
        try samples.withUnsafeBufferPointer { try writer.append($0) }
        try writer.close()
        #expect(writer.duration == 1)

        let data = try Data(contentsOf: url)
        #expect(data.count == 44 + 32_000)
        #expect(String(decoding: data[0..<4], as: UTF8.self) == "RIFF")
        #expect(data[40..<44].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } == 32_000)

        // Simulates a crash: zeroed header and one byte too many.
        let handle = try FileHandle(forUpdating: url)
        try handle.seek(toOffset: 40)
        try handle.write(contentsOf: Data(count: 4))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x01]))
        try handle.close()

        #expect(try WavFileWriter.repair(url: url) == 1)
        let repaired = try Data(contentsOf: url)
        #expect(repaired.count == 44 + 32_000)
        #expect(repaired[40..<44].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } == 32_000)
    }
}

@Suite struct RecordingFolderTests {
    @Test func listsPendingRecordingsWithAudio() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("transcriber-rec-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }

        let meta = RecordingMeta(draftLanguage: "en")
        let folder = try RecordingFolder.create(meta: meta, in: base)
        #expect(RecordingFolder.pending(in: base).isEmpty)

        let writer = try WavFileWriter(url: folder.audioURL)
        try writer.close()
        try folder.saveDraft([DraftSegment(start: 0, end: 1, text: "Hello.")])

        let pending = RecordingFolder.pending(in: base)
        #expect(pending.count == 1)
        #expect(pending[0].meta == meta)
        #expect(pending[0].folder.loadDraft().first?.text == "Hello.")
    }
}

@Suite struct AppVersionTests {
    @Test func readsTheVersionFromTheReleasePage() {
        #expect(AppVersion.fromReleaseTag("https://github.com/matteofirinaiu/transcriber/releases/tag/v1.2.0") == "1.2.0")
        #expect(AppVersion.fromReleaseTag("v1.10.3") == "1.10.3")
        // Without any release, GitHub sends you to the list of releases instead.
        #expect(AppVersion.fromReleaseTag("https://github.com/matteofirinaiu/transcriber/releases") == nil)
        #expect(AppVersion.fromReleaseTag("v1.2-beta") == nil)
    }

    @Test func comparesNumberByNumber() {
        #expect(AppVersion.isNewer("1.2.0", than: "1.1.1"))
        #expect(AppVersion.isNewer("1.10.0", than: "1.9.9"))
        #expect(AppVersion.isNewer("2.0", than: "1.9.9"))
        #expect(!AppVersion.isNewer("1.1.1", than: "1.1.1"))
        #expect(!AppVersion.isNewer("1.2", than: "1.2.0"))
        #expect(!AppVersion.isNewer("1.1.0", than: "1.2.0"))
    }
}

@Suite struct LanguageGuessTests {
    @Test func findsEnglishAndItalian() {
        let languages = LanguageGuess.dominantLanguages(in: [
            "Okay, let's get started with the roadmap for the next quarter and the hiring plan.",
            "We need to finalize the budget before the end of the month, otherwise we are late.",
            "Perfetto, allora io preparo la presentazione per il cliente entro venerdì prossimo.",
        ])
        #expect(languages == ["en", "it"])
        #expect(LanguageGuess.displayName("it") == "Italian")
    }
}
