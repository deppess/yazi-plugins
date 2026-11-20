# translate-macos.yazi

Writes English subtitles for the hovered video using only on-device Apple models. The spoken language is detected, the speech is transcribed by the Speech framework on the Neural Engine, and it is translated by the Translation framework. Nothing leaves the Mac and no Python or downloaded ML runtime is needed.

The subtitles are saved as `<video>.srt` next to the video. They are written live: each sentence is translated as soon as it is complete and its subtitles are appended, so the file fills in while the video is still being processed.

Requires macOS 26 or newer (automatic language detection was tested on macOS 27), Yazi 26.9.1 or newer and the Xcode Command Line Tools (`xcode-select --install`). On first use the plugin compiles its Swift helper into `~/Library/Caches/translate-macos`, and rebuilds it after an update. FFmpeg is optional: MP4, MOV and M4V are decoded by AVFoundation, and other containers (MKV, WebM, AVI and so on) need `ffmpeg` in `/opt/homebrew/bin` or `/usr/local/bin`.

## Installation

```sh
ya pkg add deppess/yazi-plugins:translate-macos
```

## Usage

```toml
# keymap.toml
[[mgr.prepend_keymap]]
on = ["n", "t"]
run = "plugin translate-macos"
desc = "Translate to English"

[[mgr.prepend_keymap]]
on = ["n", "T"]
run = "plugin translate-macos -- pick"
desc = "Translate to English from a chosen language"
```

`plugin translate-macos` detects the spoken language. `-- pick` asks for it from the configured list instead, and a language code such as `-- ja` uses that language.

Each translation is a task in the task manager (`w`). Its bar shows the subtitles written so far, with the percentage on the right. The percentage covers detection, transcription and translation, and the recheck of unclear passages. Each stage gets a share sized by its expected running time, estimated from the video's length and how much of it is speech, so the percentage follows elapsed time. Building the helper on first use takes no share; the task's log says it is building. `x` there cancels it: the helper stops at once and the partly written subtitles are removed. When it finishes, the cursor moves to the new `.srt`.

To keep task progress out of the status bar and in the task manager only, add this to `init.lua`:

```lua
function Progress:redraw() return {} end
```

## Language detection

The spoken language is identified by Speech's own language detector, the model macOS uses to recognise which language you are speaking. It is a SpeechAnalyzer module that the framework includes but leaves out of its public interface. It knows all 65 locales that Speech and Dictation can transcribe, needs no per-language downloads, and runs on the Neural Engine at well over 100 times real time.

Before transcribing, the plugin maps the language through the whole video, ten seconds at a time. The language heard most becomes the main language, which a language given with `-- ja` or `-- pick` overrides. Windows the detector is unsure of, such as music or silence, only count when there is nothing else. On clear speech it is typically over 0.9 sure, even for a second of audio. If it can't tell the language at all, the plugin asks you to choose it with `-- pick`.

Because the detector isn't public API, `build.sh` builds the helper against a copy of the SDK's Speech interface with the declarations in `speech-spi.swiftinterface` added, and weak-links Speech. On a macOS without the detector, auto-detection says so, and `-- pick` or a language code still work.

To see what the detector heard, run the helper directly: `TRANSLATE_DEBUG=1 ~/Library/Caches/translate-macos/translate <video> <output.srt> auto en`.

## Mixed languages and unclear passages

A video can switch languages. Stretches the timeline puts in another language than the main one are transcribed with that language's model and translated from it. The main model's lines there are dropped, unless it was very sure and the stretch has nothing at that time.

Each subtitle also carries the speech model's confidence. Low-confidence lines are usually a short passage in another language or noise, and come out as phonetic nonsense. After the main pass, the detector identifies each one again. If it's another language, the line is transcribed and translated in that language. A line that still reads plainly in its language, such as overlapping voices, stays, and the rest is dropped as noise.

## Subtitles

Words are grouped into sentences with NaturalLanguage's tokenizer, which knows abbreviations and scripts without spaces. Each sentence is translated whole, and sentences that pile up while translation is busy are translated in batches of four, about 5% faster than one at a time.

The translation is then laid out after [Netflix's timed text guidelines](https://backlothelp.netflix.com/hc/en-us/articles/215758617):

- Each subtitle has at most two balanced lines of 42 characters (16 for scripts without spaces) and lasts at most 7 seconds.
- A longer sentence is split across subtitles, preferably after punctuation or at a pause, with the translation shared out in proportion.
- A subtitle stays up at least five-sixths of a second, and long enough to read at 17 characters a second, running into the silence before the next one and leaving two frames between them.

## Configuration

```lua
-- init.lua
require("translate-macos"):setup({
	languages = { "ja", "ko", "zh", "es", "fr", "de", "it", "pt", "ru" },
	target = "en",
})
```

- `languages`: the languages `-- pick` offers, as language codes (`de`) or locales (`de-CH`). A bare code uses its most common region. Detection isn't limited to these.
- `target`: the subtitle language. When it matches the source, the speech is only transcribed.

## Languages

Transcription uses `SpeechTranscriber`, Apple's long-form model, where it supports the language: English, German, Spanish, French, Italian, Portuguese, Japanese, Korean, Chinese, Cantonese, Hindi and several other Indian languages. Other languages fall back to `DictationTranscriber`, the Dictation model, which adds Arabic, Catalan, Czech, Danish, Dutch, Finnish, Greek, Hebrew, Croatian, Hungarian, Indonesian, Malay, Norwegian, Polish, Romanian, Russian, Slovak, Swedish, Thai, Turkish, Ukrainian and Vietnamese. Dictation may leave out punctuation, so its sentences break at pauses, or after 20 seconds.

The speech model for a language downloads automatically the first time it is used. Speech keeps at most five languages reserved per app beyond the system's own. The plugin releases the oldest to make room for a new one, and macOS may then remove that model, so it downloads again the next time it is needed.

Translation models are not downloaded automatically. If a language is missing, the plugin says so. Add it in System Settings › General › Language & Region › Translation Languages.

## License

This plugin is licensed under PolyForm Strict License 1.0.0 (`SPDX-License-Identifier: PolyForm-Strict-1.0.0`). See [LICENSE](LICENSE).
