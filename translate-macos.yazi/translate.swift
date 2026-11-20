// SPDX-License-Identifier: PolyForm-Strict-1.0.0
//
// Writes subtitles for a video with on-device Apple models. Speech's spoken-language
// detector maps the language through the whole video first; the language heard most
// (unless one is given) is transcribed by SpeechTranscriber, or DictationTranscriber
// for languages it lacks, and translated by the Translation framework. Audio streams
// from the decoder into the analyzer; the words are grouped into sentences, which are
// translated whole, in batches, and laid out as subtitles that are appended to the SRT
// as soon as they are ready. Passages in another language, or that the model hears
// poorly, are identified again afterwards and handled in their own language.

import AVFoundation
import Foundation
import NaturalLanguage
import Speech
import Translation

// A sentence also ends at a pause, or once it runs this long.
let pauseSeconds = 1.0
let maxSentenceSeconds = 20.0

// Subtitle layout, after Netflix's timed text guidelines: at most two lines and seven
// seconds, at least five-sixths of a second and time to read at 17 characters a
// second, and two frames between subtitles.
let maxLines = 2
let maxCueSeconds = 7.0
let minCueSeconds = 5.0 / 6.0
let readingSpeed = 17.0
let cueGap = 2.0 / 24.0

// Characters per line: 42 for text with spaces between words, 16 for scripts without.
func lineLimit(_ text: String) -> Int { text.contains(" ") ? 42 : 16 }

// The language timeline's resolution, in seconds of audio.
let timelineSeconds = 10.0

// The detector's confidence, summed over a language's regional variants, below which
// it doesn't know the language, and from which a window or passage counts as being in
// that language.
let minDetection = 0.25
let sureDetection = 0.5

// Cues below `retryScore` are identified again after the main pass; below `dropScore`
// they are noise unless they still read as their language.
let retryScore = 0.5
let dropScore = 0.35

let debugging = ProcessInfo.processInfo.environment["TRANSLATE_DEBUG"] != nil

func debug(_ message: @autoclosure () -> String) {
	if debugging { FileHandle.standardError.write(Data((message() + "\n").utf8)) }
}

struct Failure: Error, CustomStringConvertible {
	let description: String
	init(_ description: String) { self.description = description }
}

struct Word {
	let text: String
	let start: Double
	let end: Double
	let confidence: Double?

	func shifted(by offset: Double) -> Word {
		Word(text: text, start: start + offset, end: end + offset, confidence: confidence)
	}
}

// The words of one sentence, or of a passage the tokenizer couldn't split.
struct Sentence {
	let words: [Word]
	let text: String

	init(_ words: [Word]) {
		self.words = words
		text = words.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
	}

	var start: Double { words.first?.start ?? 0 }
	var end: Double { words.last?.end ?? 0 }

	// The model's confidence in the sentence, weighted by the length of each word.
	var confidence: Double {
		let total = words.reduce(0) { $0 + $1.text.count }
		guard total > 0 else { return 0 }
		return words.reduce(0) { $0 + ($1.confidence ?? 0) * Double($1.text.count) } / Double(total)
	}

	func describe(_ note: String = "") -> String {
		String(format: "sentence %.1f-%.1f %.2f%@ %@", start, end, confidence, note, text)
	}
}

// A stretch of the audio, in seconds.
struct Window {
	let start: Double
	let duration: Double
	var end: Double { start + duration }
}

func timestamp(_ seconds: Double) -> String {
	var ms = Int((seconds * 1000).rounded())
	let hours = ms / 3_600_000
	ms %= 3_600_000
	let minutes = ms / 60000
	ms %= 60000
	return String(format: "%02d:%02d:%02d,%03d", hours, minutes, ms / 1000, ms % 1000)
}

// MARK: Progress

// Rough running times on Apple silicon, from which each stage's share of the progress
// bar is estimated: seconds per second of audio, and per stage to load its models.
enum Cost {
	static let timeline = 0.009
	static let transcription = 0.008
	static let translation = 0.07  // per second of speech
	static let recheck = 0.085  // per second of audio checked again
	static let download = 20.0  // a speech model, in seconds
	static let setup = 0.3
}

enum Stage: Hashable {
	case timeline, download, transcription, recheck
}

// The plugin reads progress from stdout, one line each: `progress <0-1>`, `stage <text>`,
// `cue` for every subtitle written, and `done <summary>` at the end. A `tick` every
// quarter second keeps the plugin's reads returning, so it can notice a cancel.
//
// Each stage gets a band of the bar sized by its expected running time, so the bar
// moves at an even pace. The bands are first estimated from the video's length, and
// laid out again over what is left once the timeline shows how much of it is speech.
final class Reporter: @unchecked Sendable {
	private let lock = NSLock()
	private var bands: [Stage: (start: Double, end: Double)] = [:]
	private var last = 0.0
	private var lastTime = Date.distantPast

	func line(_ text: String) {
		lock.withLock { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }
	}

	func stage(_ text: String) { line("stage " + text) }

	// Lays the coming stages out over the rest of the bar, in proportion to their cost.
	func plan(_ stages: [(Stage, Double)]) {
		lock.withLock {
			let total = stages.reduce(0) { $0 + $1.1 }
			var start = last
			for (stage, cost) in stages {
				let end = total > 0 ? start + (1 - last) * cost / total : start
				bands[stage] = (start, end)
				start = end
			}
		}
	}

	// Reports `fraction` of a stage. Progress only moves forward, and is sent at most
	// about four times a second.
	func progress(_ stage: Stage, _ fraction: Double) {
		let value = lock.withLock { () -> Double? in
			guard let band = bands[stage] else { return nil }
			let value = band.start + (band.end - band.start) * min(max(fraction, 0), 1)
			guard value > last, value - last >= 0.01 || Date().timeIntervalSince(lastTime) > 0.25 else { return nil }
			last = value
			lastTime = Date()
			return value
		}
		if let value { line(String(format: "progress %.4f", value)) }
	}
}

let reporter = Reporter()

// MARK: Speech

struct Engine {
	let module: any SpeechModule
	let locale: Locale
	let words: AsyncThrowingStream<Word, Error>
	let heard: Clock
}

// The point in the audio up to which the model has finalized its results.
final class Clock: @unchecked Sendable {
	private let lock = NSLock()
	private var time = 0.0

	var seconds: Double { lock.withLock { time } }
	func advance(to seconds: Double) { lock.withLock { time = max(time, seconds) } }
}

func words<S: AsyncSequence & Sendable>(
	from results: S, heard: Clock, text: @escaping @Sendable (S.Element) -> AttributedString
) -> AsyncThrowingStream<Word, Error> where S.Element: SpeechModuleResult {
	AsyncThrowingStream { continuation in
		let task = Task {
			// Dictation punctuation comes as untimed runs; they join the word before them.
			var last: Word?
			do {
				for try await result in results {
					let finalized = result.resultsFinalizationTime
					if finalized.isNumeric { heard.advance(to: finalized.seconds) }
					let text = text(result)
					for run in text.runs {
						let piece = String(text[run.range].characters)
						if let range = run.audioTimeRange {
							if piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
							if let word = last { continuation.yield(word) }
							last = Word(
								text: piece, start: range.start.seconds, end: range.end.seconds,
								confidence: run.transcriptionConfidence)
						} else if let word = last {
							last = Word(text: word.text + piece, start: word.start, end: word.end, confidence: word.confidence)
						}
					}
				}
				if let word = last { continuation.yield(word) }
				continuation.finish()
			} catch {
				continuation.finish(throwing: error)
			}
		}
		continuation.onTermination = { _ in task.cancel() }
	}
}

// SpeechTranscriber is the long-form model; DictationTranscriber covers the
// languages it lacks (Russian, Dutch, Polish, Turkish, Arabic and more).
func engine(for code: String) async throws -> Engine {
	// A bare code like "de" takes its most likely region (de-DE, not de-AT).
	let requested = Locale(identifier: Locale.Language(identifier: code).maximalIdentifier)

	if SpeechTranscriber.isAvailable, let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) {
		let module = SpeechTranscriber(
			locale: locale, transcriptionOptions: [], reportingOptions: [],
			attributeOptions: [.audioTimeRange, .transcriptionConfidence])
		let heard = Clock()
		return Engine(module: module, locale: locale, words: words(from: module.results, heard: heard) { $0.text }, heard: heard)
	}

	if let locale = await DictationTranscriber.supportedLocale(equivalentTo: requested) {
		let module = DictationTranscriber(
			locale: locale, contentHints: [], transcriptionOptions: [.punctuation], reportingOptions: [],
			attributeOptions: [.audioTimeRange, .transcriptionConfidence])
		let heard = Clock()
		return Engine(module: module, locale: locale, words: words(from: module.results, heard: heard) { $0.text }, heard: heard)
	}

	throw Failure("On-device speech recognition doesn't support \(code)")
}

// AssetInventory.status only counts this app's reservations, but any model on the
// Mac can be used; the installed lists are system-wide.
func isInstalled(_ engine: Engine) async -> Bool {
	let installed =
		engine.module is DictationTranscriber
		? await DictationTranscriber.installedLocales : await SpeechTranscriber.installedLocales
	return installed.contains { $0.identifier == engine.locale.identifier }
}

// Downloads the on-device speech model the first time a language is used. Speech
// keeps a few locales reserved per app; make room by releasing the oldest.
func install(_ engine: Engine, progress: ((Double) -> Void)? = nil) async throws {
	var reserved = await AssetInventory.reservedLocales
	if !reserved.contains(engine.locale) {
		while reserved.count >= AssetInventory.maximumReservedLocales, let oldest = reserved.first {
			await AssetInventory.release(reservedLocale: oldest)
			reserved.removeFirst()
		}
		try await AssetInventory.reserve(locale: engine.locale)
	}

	guard let request = try await AssetInventory.assetInstallationRequest(supporting: [engine.module]) else { return }
	reporter.stage("Downloading the \(engine.locale.identifier) speech model")
	let poll = Task {
		while !Task.isCancelled {
			progress?(request.progress.fractionCompleted)
			try? await Task.sleep(for: .milliseconds(250))
		}
	}
	defer { poll.cancel() }
	try await request.downloadAndInstall()
}

// One key per language and script: en-US and en-GB are the same language, zh-CN and
// zh-TW are not.
func languageKey(_ locale: Locale) -> String { languageKey(locale.language) }

func languageKey(_ language: Locale.Language) -> String {
	let language = Locale.Language(identifier: language.maximalIdentifier)
	return [language.languageCode?.identifier, language.script?.identifier].compactMap { $0 }.joined(separator: "-")
}

func audioFormat(for engine: Engine) async throws -> AVAudioFormat {
	guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [engine.module]) else {
		throw Failure("No audio format available for \(engine.locale.identifier)")
	}
	return format
}

func analyzer(for modules: [any SpeechModule]) -> SpeechAnalyzer {
	let options: SpeechAnalyzer.Options
	if #available(macOS 27, *) {
		options = .init(priority: .userInitiated, modelRetention: .whileInUse, ignoresResourceLimits: true)
	} else {
		options = .init(priority: .userInitiated, modelRetention: .whileInUse)
	}
	return SpeechAnalyzer(modules: modules, options: options)
}

// Feeds the whole sequence to the analyzer and waits for its last results.
func analyze<S: AsyncSequence & Sendable>(_ analyzer: SpeechAnalyzer, _ sequence: S) async throws
where S.Element == AnalyzerInput {
	if let end = try await analyzer.analyzeSequence(sequence) {
		try await analyzer.finalizeAndFinish(through: end)
	} else {
		await analyzer.cancelAndFinishNow()
	}
}

func replay(_ inputs: [AnalyzerInput]) -> AsyncStream<AnalyzerInput> {
	AsyncStream { continuation in
		inputs.forEach { continuation.yield($0) }
		continuation.finish()
	}
}

// MARK: Audio

// Pulls PCM from the decoder only as fast as the analyzer consumes it.
final class AudioInput: AsyncSequence, @unchecked Sendable {
	typealias Element = AnalyzerInput

	let format: AVAudioFormat
	private let read: () throws -> Data?
	private let finish: () throws -> Void

	init(format: AVAudioFormat, read: @escaping () throws -> Data?, finish: @escaping () throws -> Void) {
		self.format = format
		self.read = read
		self.finish = finish
	}

	struct Iterator: AsyncIteratorProtocol {
		let input: AudioInput

		mutating func next() async throws -> AnalyzerInput? {
			let stride = Int(input.format.streamDescription.pointee.mBytesPerFrame)
			while let data = try input.read() {
				let frames = AVAudioFrameCount(data.count / stride)
				guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: input.format, frameCapacity: frames) else {
					continue
				}
				buffer.frameLength = frames
				data.withUnsafeBytes { bytes in
					let target = buffer.audioBufferList.pointee.mBuffers.mData!
					target.copyMemory(from: bytes.baseAddress!, byteCount: Int(frames) * stride)
				}
				return AnalyzerInput(buffer: buffer)
			}
			try input.finish()
			return nil
		}
	}

	func makeAsyncIterator() -> Iterator { Iterator(input: self) }
}

func pcmSettings(_ format: AVAudioFormat) -> [String: Any] {
	[
		AVFormatIDKey: kAudioFormatLinearPCM,
		AVSampleRateKey: format.sampleRate,
		AVNumberOfChannelsKey: format.channelCount,
		AVLinearPCMBitDepthKey: format.commonFormat == .pcmFormatFloat32 ? 32 : 16,
		AVLinearPCMIsFloatKey: format.commonFormat == .pcmFormatFloat32,
		AVLinearPCMIsBigEndianKey: false,
		AVLinearPCMIsNonInterleaved: false,
	]
}

func tool(_ name: String) -> String? {
	["/opt/homebrew/bin/", "/usr/local/bin/"].map { $0 + name }.first(where: FileManager.default.isExecutableFile)
}

func duration(of video: URL) async -> Double? {
	if let time = try? await AVURLAsset(url: video).load(.duration), time.isNumeric, time.seconds > 0 {
		return time.seconds
	}
	guard let ffprobe = tool("ffprobe") else { return nil }

	let process = Process()
	let stdout = Pipe()
	process.executableURL = URL(fileURLWithPath: ffprobe)
	process.arguments = ["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", video.path]
	process.standardOutput = stdout
	process.standardError = FileHandle.nullDevice
	guard (try? process.run()) != nil else { return nil }
	let text = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
	process.waitUntilExit()
	return Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
}

// AVFoundation decodes MP4, MOV and M4V; FFmpeg takes the containers it can't open.
// Without a window, the whole track is read.
func audioInput(for video: URL, format: AVAudioFormat, window: Window? = nil) async throws -> AudioInput {
	if let input = try? await avFoundationInput(for: video, format: format, window: window) {
		return input
	}
	return try ffmpegInput(for: video, format: format, window: window)
}

func avFoundationInput(for video: URL, format: AVAudioFormat, window: Window?) async throws -> AudioInput? {
	let asset = AVURLAsset(url: video)
	guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return nil }

	let reader = try AVAssetReader(asset: asset)
	if let window {
		reader.timeRange = CMTimeRange(
			start: CMTime(seconds: window.start, preferredTimescale: 600),
			duration: CMTime(seconds: window.duration, preferredTimescale: 600))
	}
	let output = AVAssetReaderTrackOutput(track: track, outputSettings: pcmSettings(format))
	reader.add(output)
	guard reader.startReading() else {
		throw reader.error ?? CocoaError(.fileReadUnknown)
	}

	return AudioInput(
		format: format,
		read: {
			guard let sample = output.copyNextSampleBuffer(),
				let block = CMSampleBufferGetDataBuffer(sample)
			else { return nil }
			var data = Data(count: CMBlockBufferGetDataLength(block))
			let status = data.withUnsafeMutableBytes {
				CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
			}
			guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
			return data
		},
		finish: {
			if reader.status != .completed {
				throw reader.error ?? CocoaError(.fileReadUnknown)
			}
		})
}

func ffmpegInput(for video: URL, format: AVAudioFormat, window: Window?) throws -> AudioInput {
	guard let ffmpeg = tool("ffmpeg") else {
		throw Failure("No audio track macOS can read; install FFmpeg for other containers")
	}
	let seek = window.map { ["-ss", String($0.start), "-t", String($0.duration)] } ?? []

	let process = Process()
	let stdout = Pipe()
	let stderr = Pipe()
	process.executableURL = URL(fileURLWithPath: ffmpeg)
	process.arguments =
		["-nostdin", "-hide_banner", "-loglevel", "error"] + seek + [
			"-i", video.path, "-map", "0:a:0", "-vn",
			"-ac", String(format.channelCount), "-ar", String(Int(format.sampleRate)),
			"-f", format.commonFormat == .pcmFormatFloat32 ? "f32le" : "s16le", "-",
		]
	process.standardOutput = stdout
	process.standardError = stderr
	try process.run()

	let pipe = stdout.fileHandleForReading
	return AudioInput(
		format: format,
		read: {
			let data = try pipe.read(upToCount: 64 * 1024)
			return data?.isEmpty == false ? data : nil
		},
		finish: {
			process.waitUntilExit()
			guard process.terminationStatus != 0 else { return }
			let detail = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
				.trimmingCharacters(in: .whitespacesAndNewlines)
			throw Failure(detail.contains("matches no streams") ? "No audio track" : "FFmpeg: \(detail)")
		})
}

// One stretch of the audio, decoded once per audio format and replayed for each
// analysis.
final class Samples {
	private let video: URL
	let window: Window
	private var decoded: [String: [AnalyzerInput]] = [:]

	init(video: URL, window: Window) {
		self.video = video
		self.window = window
	}

	func inputs(in format: AVAudioFormat) async throws -> [AnalyzerInput] {
		if let inputs = decoded[format.description] { return inputs }
		var inputs: [AnalyzerInput] = []
		for try await input in try await audioInput(for: video, format: format, window: window) {
			inputs.append(input)
		}
		decoded[format.description] = inputs
		return inputs
	}
}

// MARK: Language detection

// Speech ships a spoken-language detector, a SpeechAnalyzer module it leaves out of
// its public interface (see speech-spi.swiftinterface). It knows every language
// Speech and Dictation transcribe, needs no per-language models, and takes a
// fraction of a second. It runs without voice activity detection, which misses
// speech in short stretches; music and silence just give guesses too unsure to count.

struct Detection {
	let locale: Locale
	let confidence: Double
}

// Speech is weak-linked, so on a macOS without the detector this symbol is missing.
let detectorAvailable =
	dlsym(
		UnsafeMutableRawPointer(bitPattern: -2),  // RTLD_DEFAULT
		"$s6Speech16LanguageDetectorC7options10clientInfoAcA0bC7OptionsVSg_AA06ClientF0VtcfC") != nil

func detector() -> LanguageDetector {
	let options = LanguageDetectorOptions(
		languageConstraints: nil, alternativeCount: 10, resultReportingFrequency: .once, useVAD: false)
	return LanguageDetector(options: options, clientInfo: ClientInfo(identifier: "translate-macos"))
}

// The detector's own audio format, 16 kHz mono.
func detectorFormat() async -> AVAudioFormat? {
	await detector().availableCompatibleAudioFormats.max { $0.sampleRate < $1.sampleRate }
}

// The detector splits its confidence between regional variants (en-US, en-GB and so
// on), so it is summed per language; the language comes in its likeliest variant.
func best(_ alternatives: [LanguageDetector.LocaleAlternative]) -> Detection? {
	var languages: [String: (total: Double, top: LanguageDetector.LocaleAlternative)] = [:]
	for alternative in alternatives {
		let key = languageKey(alternative.locale)
		var language = languages[key] ?? (0, alternative)
		language.total += alternative.confidence
		if alternative.confidence > language.top.confidence { language.top = alternative }
		languages[key] = language
	}
	return languages.values.max { $0.total < $1.total }.map { Detection(locale: $0.top.locale, confidence: $0.total) }
}

// Names the language of some audio, or nil when the detector heard no speech.
func identify(_ inputs: [AnalyzerInput]) async throws -> Detection? {
	let detector = detector()
	let analyzer = analyzer(for: [detector])
	let collector = Task {
		var last: [LanguageDetector.LocaleAlternative] = []
		for try await result in detector.results { last = result.alternatives }
		return last
	}
	do {
		try await analyze(analyzer, replay(inputs))
		let alternatives = try await collector.value
		debug("detected " + alternatives.map { String(format: "%@ %.3f", $0.locale.identifier, $0.confidence) }.joined(separator: ", "))
		return best(alternatives)
	} catch let error as NSError where error.domain == "SFSpeechErrorDomain" && error.code == 14 {
		// No speech detected.
		await analyzer.cancelAndFinishNow()
		return nil
	}
}

func identify(_ samples: Samples) async throws -> Detection? {
	guard detectorAvailable, let format = await detectorFormat() else { return nil }
	return try await identify(samples.inputs(in: format))
}

// The language heard in one window of the timeline; nil when it had no speech.
struct Span {
	let window: Window
	let detection: Detection?

	var sure: Detection? { detection.flatMap { $0.confidence >= sureDetection ? $0 : nil } }
}

// The language through the whole video, a window at a time, read in one pass over the
// audio.
final class Timeline {
	let spans: [Span]

	init(_ spans: [Span] = []) { self.spans = spans }

	// Seconds of the video the detector was sure held speech.
	var speech: Double { spans.filter { $0.sure != nil }.reduce(0) { $0 + $1.window.duration } }

	// The language heard most, weighed by the detector's confidence. Windows it was
	// unsure of, such as music, only count when there is nothing else.
	var main: Detection? {
		let detections = spans.compactMap(\.detection)
		let sure = detections.filter { $0.confidence >= sureDetection }
		var languages: [String: (total: Double, top: Detection)] = [:]
		for detection in sure.isEmpty ? detections : sure {
			let key = languageKey(detection.locale)
			var language = languages[key] ?? (0, detection)
			language.total += detection.confidence
			if detection.confidence > language.top.confidence { language.top = detection }
			languages[key] = language
		}
		return languages.values.max { $0.total < $1.total }.map(\.top)
	}

	// The language at the middle of a sentence, when the detector was sure of it.
	func language(at sentence: Sentence) -> Detection? {
		let middle = (sentence.start + sentence.end) / 2
		return spans.first { $0.window.start <= middle && middle < $0.window.end }?.sure
	}

	// Neighbouring windows the detector was sure are in another language than
	// `locale`, merged per language.
	func regions(otherThan locale: Locale) -> [(window: Window, locale: Locale)] {
		var regions: [(window: Window, locale: Locale)] = []
		for span in spans {
			guard let detection = span.sure, languageKey(detection.locale) != languageKey(locale) else { continue }
			if let last = regions.last, languageKey(last.locale) == languageKey(detection.locale),
				abs(last.window.end - span.window.start) < 0.5
			{
				regions[regions.count - 1].window = Window(start: last.window.start, duration: span.window.end - last.window.start)
			} else {
				regions.append((span.window, detection.locale))
			}
		}
		return regions
	}

	static func read(_ video: URL, length: Double?) async throws -> Timeline {
		guard let format = await detectorFormat() else { return Timeline() }
		let windowFrames = AVAudioFrameCount(timelineSeconds * format.sampleRate)
		var spans: [Span] = []
		var inputs: [AnalyzerInput] = []
		var frames: AVAudioFrameCount = 0

		func close() async throws {
			guard frames > 0 else { return }
			let start = spans.last?.window.end ?? 0
			let window = Window(start: start, duration: Double(frames) / format.sampleRate)
			let detection = try await identify(inputs)
			spans.append(Span(window: window, detection: detection))
			debug(String(format: "window %.1f-%.1f ", window.start, window.end)
				+ (detection.map { String(format: "%@ %.2f", $0.locale.identifier, $0.confidence) } ?? "no speech"))
			if let length, length > 0 { reporter.progress(.timeline, window.end / length) }
			inputs = []
			frames = 0
		}

		for try await input in try await audioInput(for: video, format: format) {
			inputs.append(input)
			frames += input.buffer.frameLength
			if frames >= windowFrames { try await close() }
		}
		try await close()
		return Timeline(spans)
	}
}

// How likely NaturalLanguage thinks it is that `text` is written in `language`.
func likelihood(of text: String, in language: Locale.Language) -> Double {
	let base = { (code: String) in code == "yue" ? "zh" : String(code.prefix { $0 != "-" && $0 != "_" }) }
	let code = base(language.languageCode?.identifier ?? "")
	let recognizer = NLLanguageRecognizer()
	recognizer.processString(text)
	return recognizer.languageHypotheses(withMaximum: 10).filter { base($0.key.rawValue) == code }.map(\.value).max() ?? 0
}

// MARK: Sentences

// Groups words into sentences with NaturalLanguage's tokenizer, which knows
// abbreviations and scripts without spaces. A sentence is handed on once the next has
// begun, or at a pause; one that runs on is cut at `maxSentenceSeconds`.
struct SentenceBuilder {
	private var words: [Word] = []

	// Adds a word, and returns the sentences it completed.
	mutating func add(_ word: Word) -> [Sentence] {
		var done: [Sentence] = []
		if let last = words.last, word.start - last.end > pauseSeconds || word.end - words[0].start > maxSentenceSeconds {
			done = flush()
		}
		words.append(word)
		let groups = SentenceBuilder.split(words)
		if groups.count > 1 {
			done += groups.dropLast().map(Sentence.init)
			words = groups.last!
		}
		return done
	}

	mutating func flush() -> [Sentence] {
		defer { words = [] }
		return SentenceBuilder.split(words).map(Sentence.init)
	}

	static func sentences(from words: [Word]) -> [Sentence] {
		var builder = SentenceBuilder()
		return words.flatMap { builder.add($0) } + builder.flush()
	}

	// Each word goes to the sentence its first letter falls in.
	private static func split(_ words: [Word]) -> [[Word]] {
		guard words.count > 1 else { return words.isEmpty ? [] : [words] }
		let text = words.map(\.text).joined()
		var offsets: [Int] = []
		var offset = 0
		for word in words {
			offsets.append(offset + word.text.prefix { $0.isWhitespace }.count)
			offset += word.text.count
		}

		let tokenizer = NLTokenizer(unit: .sentence)
		tokenizer.string = text
		var ends: [Int] = []
		tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
			ends.append(text.distance(from: text.startIndex, to: range.upperBound))
			return true
		}

		var groups: [[Word]] = []
		var sentence = 0
		for (word, offset) in zip(words, offsets) {
			while sentence < ends.count - 1, offset >= ends[sentence] { sentence += 1 }
			if groups.count <= sentence { groups.append([]) }
			groups[groups.count - 1].append(word)
		}
		return groups
	}
}

// How far the main pass has got through the audio: up to the last sentence written
// out, or, once translation has caught up, as far as the model has finalized.
final class Tracker: @unchecked Sendable {
	private let lock = NSLock()
	private var emitted = 0.0
	private var written = 0.0

	func emit(_ sentence: Sentence) { lock.withLock { emitted = max(emitted, sentence.end) } }
	func write(_ sentence: Sentence) { lock.withLock { written = max(written, sentence.end) } }
	func position(heard: Double) -> Double { lock.withLock { written >= emitted ? heard : written } }
}

// Hands each sentence on as soon as it is complete.
func sentences(from words: AsyncThrowingStream<Word, Error>, tracker: Tracker) -> AsyncThrowingStream<Sentence, Error> {
	AsyncThrowingStream { continuation in
		let task = Task {
			var builder = SentenceBuilder()
			func emit(_ sentences: [Sentence]) {
				for sentence in sentences where !sentence.text.isEmpty {
					tracker.emit(sentence)
					continuation.yield(sentence)
				}
			}

			do {
				for try await word in words { emit(builder.add(word)) }
				emit(builder.flush())
				continuation.finish()
			} catch {
				continuation.finish(throwing: error)
			}
		}
		continuation.onTermination = { _ in task.cancel() }
	}
}

// MARK: Layout

struct Entry {
	let start: Double
	let end: Double
	let text: String
}

// Lays a sentence's translation out over as many subtitles as its length and duration
// need. The sentence is cut between words near even points in time, preferably after
// punctuation or at a pause, and the translation is shared out in proportion to the
// source text in each part.
func layout(_ sentence: Sentence, as translation: String) -> [Entry] {
	let text = translation.trimmingCharacters(in: .whitespacesAndNewlines)
	guard !text.isEmpty, !sentence.words.isEmpty else { return [] }
	let byTime = Int(((sentence.end - sentence.start) / maxCueSeconds).rounded(.up))
	let byLength = Int((Double(text.count) / Double(maxLines * lineLimit(text))).rounded(.up))
	let parts = cut(sentence.words, into: min(max(byTime, byLength, 1), sentence.words.count))
	let pieces = share(text, by: parts.map { Double($0.reduce(0) { $0 + $1.text.count }) })
	return zip(parts, pieces).compactMap { words, piece in
		piece.isEmpty ? nil : Entry(start: words.first!.start, end: words.last!.end, text: wrap(piece))
	}
}

// Cuts words into `count` runs of about equal duration.
func cut(_ words: [Word], into count: Int) -> [[Word]] {
	guard count > 1 else { return [words] }
	let start = words.first!.start
	let span = words.last!.end - start
	var cuts: [Int] = []
	for part in 1..<count {
		let ideal = start + span * Double(part) / Double(count)
		let lower = (cuts.last ?? 0) + 1
		let upper = words.count - (count - part)
		guard lower <= upper else { break }
		// Distance from the ideal point, less a pull towards punctuation and pauses.
		func cost(_ index: Int) -> Double {
			let previous = words[index - 1]
			let punctuated = previous.text.trimmingCharacters(in: .whitespaces).last.map { ",;:.?!、，。？！".contains($0) } ?? false
			return abs(words[index].start - ideal) - (punctuated ? 1 : 0) - min(words[index].start - previous.end, 1)
		}
		cuts.append((lower...upper).min { cost($0) < cost($1) }!)
	}
	return zip([0] + cuts, cuts + [words.count]).map { Array(words[$0..<$1]) }
}

// Shares text out in proportion to the weights, between words, or between characters
// for scripts without spaces. Each word goes to the part its middle falls in.
func share(_ text: String, by weights: [Double]) -> [String] {
	guard weights.count > 1 else { return [text] }
	let spaced = text.contains(" ")
	let tokens = spaced ? text.split(separator: " ").map(String.init) : text.map(String.init)
	let total = max(weights.reduce(0, +), 1)
	let length = Double(text.count)

	var parts = Array(repeating: [String](), count: weights.count)
	var bounds = weights.reduce(into: [Double]()) { $0.append(($0.last ?? 0) + $1 / total * length) }
	bounds[bounds.count - 1] = .infinity
	var position = 0.0
	var part = 0
	for token in tokens {
		let middle = position + Double(token.count) / 2
		while middle > bounds[part] { part += 1 }
		parts[part].append(token)
		position += Double(token.count + (spaced ? 1 : 0))
	}
	return parts.map { $0.joined(separator: spaced ? " " : "") }
}

// Breaks a subtitle over two lines when it is too long for one, where the lines come
// out most even, preferably after punctuation.
func wrap(_ text: String) -> String {
	let characters = Array(text)
	guard characters.count > lineLimit(text) else { return text }
	let breaks = text.contains(" ") ? characters.indices.filter { characters[$0] == " " } : [characters.count / 2]
	func cost(_ index: Int) -> Int {
		let punctuated = index > 0 && ",;:.?!".contains(characters[index - 1])
		return abs(index - (characters.count - index)) - (punctuated ? 8 : 0)
	}
	let at = breaks.min { cost($0) < cost($1) }!
	let skip = characters[at] == " " ? 1 : 0
	return String(characters[..<at]) + "\n" + String(characters[(at + skip)...])
}

// Gives a subtitle time to be read: at least `minCueSeconds`, or as long as its text
// takes at `readingSpeed`, running into the silence before the next one but leaving
// `cueGap`, and no longer than `maxCueSeconds`.
func paced(_ entry: Entry, before next: Entry?) -> Entry {
	let reading = max(minCueSeconds, Double(entry.text.count) / readingSpeed)
	var end = max(entry.end, entry.start + min(reading, maxCueSeconds))
	if let next { end = min(end, next.start - cueGap) }
	return Entry(start: entry.start, end: max(end, min(entry.end, entry.start + 0.2)), text: entry.text)
}

// MARK: Output

func checkTranslation(from source: Locale.Language, to target: Locale.Language) async throws {
	switch await LanguageAvailability().status(from: source, to: target) {
	case .installed:
		return
	case .supported:
		throw Failure(
			"Download the \(source.minimalIdentifier) translation language in System Settings › General › Language & Region › Translation Languages"
		)
	default:
		throw Failure("Translation from \(source.minimalIdentifier) to \(target.minimalIdentifier) is not supported")
	}
}

// Translates several texts in one batch, which the Translation framework handles more
// efficiently than one at a time.
func translated(_ texts: [String], with session: TranslationSession?) async throws -> [String] {
	guard let session, !texts.isEmpty else { return texts }
	let requests = texts.indices.map { TranslationSession.Request(sourceText: texts[$0], clientIdentifier: String($0)) }
	var results = texts
	for response in try await session.translations(from: requests) {
		guard let id = response.clientIdentifier, let index = Int(id) else { continue }
		results[index] = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
	}
	return results
}

// The SRT being written. Subtitles are appended as they are ready, so the file fills
// in while the video is still being transcribed; each waits for the next so it can be
// paced up to it. The file is only created once there is a first subtitle, so a run
// that fails early leaves an existing file alone.
final class Output: @unchecked Sendable {
	let url: URL
	private(set) var created = false
	private var written: [Entry] = []
	private var pending: Entry?
	private var file: FileHandle?

	init(_ url: URL) { self.url = url }

	var count: Int { written.count + (pending == nil ? 0 : 1) }

	func append(_ entry: Entry) throws {
		if let pending { try write(paced(pending, before: entry)) }
		pending = entry
	}

	private func write(_ entry: Entry) throws {
		if file == nil {
			guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
				throw Failure("Can't write \(url.lastPathComponent)")
			}
			created = true
			file = try FileHandle(forWritingTo: url)
		}
		written.append(entry)
		try file!.write(contentsOf: Data(Output.srt(written.count, entry).utf8))
		reporter.line("cue")
	}

	// Subtitles recovered after the main pass belong between the others, so then the
	// file is paced again and rewritten in time order.
	func finish(adding late: [Entry]) throws {
		guard !late.isEmpty else {
			if let pending { try write(paced(pending, before: nil)) }
			pending = nil
			try file?.close()
			file = nil
			return
		}
		try file?.close()
		file = nil

		let all = (written + [pending].compactMap { $0 } + late).sorted { $0.start < $1.start }
		for _ in written.count..<all.count { reporter.line("cue") }
		written = all.indices.map { paced(all[$0], before: $0 + 1 < all.count ? all[$0 + 1] : nil) }
		pending = nil
		let temp = url.appendingPathExtension("tmp")
		try written.enumerated().map { Output.srt($0.offset + 1, $0.element) }.joined()
			.write(to: temp, atomically: false, encoding: .utf8)
		guard rename(temp.path, url.path) == 0 else {
			try? FileManager.default.removeItem(at: temp)
			throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
		}
		created = true
	}

	private static func srt(_ number: Int, _ entry: Entry) -> String {
		"\(number)\n\(timestamp(entry.start)) --> \(timestamp(entry.end))\n\(entry.text)\n\n"
	}
}

// Sentences waiting for translation. The writer takes all that have piled up, up to
// `translationBatch`, so they are translated together while translation is the
// bottleneck and one at a time, without delay, once it has caught up. Batches of four
// translate about 5% faster than single sentences, and larger ones gain nothing more
// while making the output arrive in lumps.
let translationBatch = 4

final class Inbox: @unchecked Sendable {
	private let lock = NSLock()
	private var items: [Sentence] = []
	private var closed = false
	private var failure: Error?
	private var waiter: CheckedContinuation<Void, Never>?

	func put(_ sentence: Sentence) {
		lock.withLock { () -> CheckedContinuation<Void, Never>? in
			items.append(sentence)
			defer { waiter = nil }
			return waiter
		}?.resume()
	}

	func close(_ error: Error? = nil) {
		lock.withLock { () -> CheckedContinuation<Void, Never>? in
			closed = true
			failure = error
			defer { waiter = nil }
			return waiter
		}?.resume()
	}

	// Waits for a sentence and returns up to `limit`; nothing once closed and empty.
	func take(_ limit: Int) async throws -> [Sentence] {
		while true {
			let (batch, done, failure) = lock.withLock { () -> ([Sentence], Bool, Error?) in
				let batch = Array(items.prefix(limit))
				items.removeFirst(batch.count)
				return (batch, closed, self.failure)
			}
			if !batch.isEmpty { return batch }
			if done {
				if let failure { throw failure }
				return []
			}
			await withCheckedContinuation { continuation in
				let ready = lock.withLock { () -> Bool in
					if !items.isEmpty || closed { return true }
					waiter = continuation
					return false
				}
				if ready { continuation.resume() }
			}
		}
	}
}

// Translates and appends sentences as they arrive. Sentences the model was unsure of,
// or that the timeline puts in another language, are held back for `recover`.
func writeSubtitles(
	_ sentences: AsyncThrowingStream<Sentence, Error>, to output: Output, session: TranslationSession?,
	tracker: Tracker, timeline: Timeline, locale: Locale
) async throws -> [Sentence] {
	let inbox = Inbox()
	let feeder = Task {
		do {
			for try await sentence in sentences { inbox.put(sentence) }
			inbox.close()
		} catch {
			inbox.close(error)
		}
	}
	defer { feeder.cancel() }

	var held: [Sentence] = []
	while true {
		let batch = try await inbox.take(translationBatch)
		if batch.isEmpty { break }
		var ready: [Sentence] = []
		for sentence in batch {
			debug(sentence.describe())
			let elsewhere = timeline.language(at: sentence).map { languageKey($0.locale) != languageKey(locale) } ?? false
			if sentence.confidence < retryScore || elsewhere { held.append(sentence) } else { ready.append(sentence) }
		}
		let texts = try await translated(ready.map(\.text), with: session)
		for (sentence, text) in zip(ready, texts) {
			for entry in layout(sentence, as: text) { try output.append(entry) }
		}
		batch.forEach(tracker.write)
	}
	return held
}

// MARK: Recovery

// Whether an unsure sentence no other language explains is still worth keeping:
// fairly confident, or plainly readable as its language (overlapping voices, say).
func isKept(_ sentence: Sentence, in language: Locale.Language) -> Bool {
	if sentence.confidence >= dropScore { return true }
	let letters = sentence.text.filter(\.isLetter).count
	return sentence.confidence >= 0.2 && letters >= 12 && likelihood(of: sentence.text, in: language) >= 0.8
}

// Transcribes a stretch in one language, installing its model when needed. Returns
// nil when the language can't be transcribed; audio errors are thrown.
func transcribe(_ samples: Samples, in code: String) async throws -> [Sentence]? {
	guard let engine = try? await engine(for: code) else { return nil }
	if await !isInstalled(engine) { try await install(engine) }
	guard let format = try? await audioFormat(for: engine) else { return nil }
	let inputs = try await samples.inputs(in: format)

	let analyzer = analyzer(for: [engine.module])
	let collector = Task {
		var words: [Word] = []
		for try await word in engine.words { words.append(word.shifted(by: samples.window.start)) }
		return words
	}
	do {
		try await analyze(analyzer, replay(inputs))
		return SentenceBuilder.sentences(from: try await collector.value)
	} catch {
		await analyzer.cancelAndFinishNow()
		return nil
	}
}

// What the main pass held back. Regions the timeline puts in another language are
// transcribed whole with that language's model and translated from it; the main
// model's sentences there only stay when it was very sure and the region has nothing
// at that time, as where the main language carries on into a window. The other unsure
// sentences, from the main pass or a region, are usually noise or a passage in yet
// another language, and are identified again one stretch at a time: a stretch in
// another language than its model's is transcribed in its own, one in the same
// language stays if still readable, and the rest is dropped as noise. Sentences in a
// language that can't be translated keep their own text.
func recover(
	_ held: [Sentence], in video: URL, locale: Locale, timeline: Timeline, target: Locale.Language,
	main: TranslationSession?
) async throws -> [Entry] {
	var sessions: [String: TranslationSession?] = [languageKey(locale): main]
	func session(for code: String) async -> TranslationSession? {
		let source = Locale.Language(identifier: code)
		if let cached = sessions[languageKey(source)] { return cached }
		var made: TranslationSession?
		if languageKey(source) != languageKey(target),
			await LanguageAvailability().status(from: source, to: target) == .installed
		{
			made = TranslationSession(installedSource: source, target: target)
		}
		sessions[languageKey(source)] = made
		return made
	}

	var entries: [Entry] = []
	func add(_ sentences: [Sentence], in code: String, note: String = "") async throws {
		sentences.forEach { debug($0.describe(note)) }
		let texts = try await translated(sentences.map(\.text), with: session(for: code))
		for (sentence, text) in zip(sentences, texts) { entries += layout(sentence, as: text) }
	}

	// Progress follows the seconds of audio checked; the stretches' share is only known
	// once the regions are done.
	let regions = timeline.regions(otherThan: locale)
	var total = regions.reduce(0) { $0 + $1.window.duration }
	var checked = 0.0
	func step(_ window: Window) {
		checked += window.duration
		reporter.progress(.recheck, checked / max(total, 1))
	}

	// Unsure sentences, with the language of the model that wrote them.
	var unsure = held.map { (sentence: $0, code: locale.identifier) }

	for region in regions {
		let code = region.locale.identifier
		let inside = held.filter { $0.end > region.window.start && $0.start < region.window.end }
		unsure.removeAll { item in inside.contains { $0.start == item.sentence.start && $0.end == item.sentence.end } }
		let found = (try await transcribe(Samples(video: video, window: region.window), in: code) ?? [])
			.filter { $0.confidence >= dropScore }
		try await add(found.filter { $0.confidence >= retryScore }, in: code, note: " \(code)")
		unsure += found.filter { $0.confidence < retryScore }.map { ($0, code) }
		let kept = inside.filter { sentence in
			sentence.confidence >= 0.8 && !found.contains { $0.end > sentence.start && $0.start < sentence.end }
		}
		try await add(kept, in: locale.identifier, note: " kept")
		step(region.window)
	}

	// Each remaining unsure sentence is its own stretch, since neighbours may be in
	// different languages; only fragments too short to identify join the one before.
	var stretches: [(sentences: [Sentence], code: String)] = []
	for item in unsure.sorted(by: { $0.sentence.start < $1.sentence.start }) {
		if let last = stretches.last, last.code == item.code, let previous = last.sentences.last,
			item.sentence.start - previous.end < 0.5, item.sentence.end - item.sentence.start < 1.5
		{
			stretches[stretches.count - 1].sentences.append(item.sentence)
		} else {
			stretches.append(([item.sentence], item.code))
		}
	}
	let windows = stretches.map { stretch in
		let start = max(0, stretch.sentences.first!.start - 0.25)
		return Window(start: start, duration: stretch.sentences.last!.end + 0.25 - start)
	}
	total += windows.reduce(0) { $0 + $1.duration }

	for (stretch, window) in zip(stretches, windows) {
		let samples = Samples(video: video, window: window)
		if let heard = try await identify(samples), heard.confidence >= sureDetection,
			languageKey(heard.locale) != languageKey(Locale(identifier: stretch.code)),
			let found = try await transcribe(samples, in: heard.locale.identifier)
		{
			let code = heard.locale.identifier
			try await add(found.filter { $0.confidence >= dropScore }, in: code, note: " \(code)")
		} else {
			let language = Locale(identifier: stretch.code).language
			stretch.sentences.filter { !isKept($0, in: language) }.forEach { debug($0.describe(" dropped")) }
			try await add(stretch.sentences.filter { isKept($0, in: language) }, in: stretch.code)
		}
		step(window)
	}
	return entries
}

// MARK: Main

func run(video: URL, target: URL, source: String, targetLanguage: Locale.Language) async throws -> String {
	let detected = source == "auto"
	guard detectorAvailable || !detected else {
		throw Failure("This macOS has no spoken-language detector; choose the language with `plugin translate-macos -- pick`")
	}
	let length = await duration(of: video) ?? 0

	// Before the timeline is read, all of the video is taken to be speech to translate.
	reporter.plan([
		(.timeline, Cost.setup + Cost.timeline * length),
		(.transcription, Cost.setup + (Cost.transcription + Cost.translation) * length),
		(.recheck, Cost.recheck * length * 0.02),
	])
	var timeline = Timeline()
	if detectorAvailable {
		reporter.stage("Detecting the spoken language")
		timeline = try await Timeline.read(video, length: length)
	}

	var code = source
	if detected {
		guard let main = timeline.main else { throw Failure("No speech detected") }
		guard main.confidence >= minDetection else {
			throw Failure("Couldn't tell the spoken language; choose it with `plugin translate-macos -- pick`")
		}
		code = main.locale.identifier
	}

	let engine = try await engine(for: code)
	let sourceLanguage = engine.locale.language
	let translates = languageKey(sourceLanguage) != languageKey(targetLanguage)
	if translates {
		try await checkTranslation(from: sourceLanguage, to: targetLanguage)
	}

	// Now the speech, the other languages' regions and any download are known. Speech in
	// other languages is translated in the recheck.
	let other = timeline.regions(otherThan: engine.locale).reduce(0) { $0 + $1.window.duration }
	let speech = timeline.spans.isEmpty ? length : max(timeline.speech - other, 0)
	let reading = Cost.transcription * length
	let writing = translates ? Cost.translation * speech : 0
	reporter.plan([
		(.download, await isInstalled(engine) ? 0 : Cost.download),
		(.transcription, Cost.setup + reading + writing),
		(.recheck, Cost.recheck * (other + 0.02 * speech)),
	])

	try await install(engine) { reporter.progress(.download, $0) }
	let format = try await audioFormat(for: engine)
	let analyzer = analyzer(for: [engine.module])
	async let prepared: Void = analyzer.prepareToAnalyze(in: format)
	let input = try await audioInput(for: video, format: format)
	try await prepared

	reporter.stage(translates ? "Transcribing and translating" : "Transcribing")
	let session = translates ? TranslationSession(installedSource: sourceLanguage, target: targetLanguage) : nil
	let output = Output(target)
	let tracker = Tracker()
	let writer = Task {
		try await writeSubtitles(
			sentences(from: engine.words, tracker: tracker), to: output, session: session, tracker: tracker,
			timeline: timeline, locale: engine.locale)
	}

	// The main pass's progress: transcription follows the audio the model has finalized,
	// translation the audio written out, each weighted by its share of the work.
	let ticker = Task {
		guard length > 0 else { return }
		while !Task.isCancelled {
			let heard = engine.heard.seconds
			let read = heard / length
			let written = tracker.position(heard: heard) / length
			reporter.progress(.transcription, (reading * read + writing * written) / max(reading + writing, .ulpOfOne))
			try? await Task.sleep(for: .milliseconds(250))
		}
	}
	defer { ticker.cancel() }

	do {
		try await analyze(analyzer, input)
		let held = try await writer.value
		ticker.cancel()
		reporter.progress(.transcription, 1)

		var late: [Entry] = []
		if !held.isEmpty {
			reporter.stage("Checking unclear passages")
			late = try await recover(
				held, in: video, locale: engine.locale, timeline: timeline, target: targetLanguage, main: session)
		}
		try output.finish(adding: late)
	} catch {
		await analyzer.cancelAndFinishNow()
		writer.cancel()
		_ = try? await writer.value
		try? output.finish(adding: [])
		if output.created { try? FileManager.default.removeItem(at: target) }
		throw error
	}

	if output.count == 0 {
		if output.created { try? FileManager.default.removeItem(at: target) }
		throw Failure("No speech detected")
	}
	reporter.progress(.recheck, 1)
	let names = Locale(identifier: "en")
	let from = names.localizedString(forIdentifier: engine.locale.identifier) ?? engine.locale.identifier
	let to = names.localizedString(forIdentifier: targetLanguage.minimalIdentifier) ?? targetLanguage.minimalIdentifier
	return "\(from)\(detected ? ", detected" : "") → \(to) · \(output.count) subtitles"
}

@main
struct Translate {
	static func main() async {
		let args = CommandLine.arguments
		guard (4...5).contains(args.count) else {
			FileHandle.standardError.write(Data("usage: translate <video> <output.srt> <source|auto> [target]\n".utf8))
			exit(2)
		}

		let video = URL(fileURLWithPath: args[1])
		let target = URL(fileURLWithPath: args[2])
		guard FileManager.default.fileExists(atPath: video.path) else {
			FileHandle.standardError.write(Data("File not found: \(video.path)\n".utf8))
			exit(2)
		}

		Task {
			while true {
				reporter.line("tick")
				try? await Task.sleep(for: .milliseconds(250))
			}
		}

		let language = Locale.Language(identifier: args.count == 5 ? args[4] : "en")
		do {
			reporter.line("done " + (try await run(video: video, target: target, source: args[3], targetLanguage: language)))
		} catch {
			let message = (error as? Failure)?.description ?? error.localizedDescription
			FileHandle.standardError.write(Data("\(message)\n".utf8))
			exit(1)
		}
	}
}
