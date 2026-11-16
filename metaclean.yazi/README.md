# metaclean.yazi

Remove identity metadata from local media without reencoding. MetaClean keeps
only the technical metadata each format needs for rendering or playback and
removes everything else: EXIF, GPS, maker notes, XMP, IPTC, Photoshop
resources, C2PA Content Credentials, comments, text chunks, QuickTime user
data and editor data.

macOS only.

## How it works

Each file is copied to a staging folder beside it and cleaned there. The copy
replaces the original only after every check passes:

- every remaining metadata tag is on the format's allowlist, and the
  rendering tags on it (orientation, colour space, ICC profile, resolution,
  animation timing) have their original values;
- ExifTool's validation finds no more errors than in the original;
- the encoded image data is byte-identical and decodes to the same frames
  (for HEIF, FFprobe also hashes every image item);
  for video and audio, no byte outside the neutralized metadata regions
  changes and the stream layout reported by FFprobe is identical;
- the file's mode, owner, flags, ACL and preserved extended attributes match
  the original;
- the original has not changed since it was measured.

Anything that cannot be proven is skipped and left unchanged. Up to eight
files are cleaned at once, one per CPU core.

As a final, format-independent check, the text of every removed tag (camera
model, serial number, owner, dates and so on) is searched for in the cleaned
file, in UTF-8 and UTF-16. A file that still holds one of those values
anywhere, for example in camera data inside the video stream, is skipped.
The same search covers this Mac's home folder path (`/Users/<name>`), the
account's full name and the computer name, which editors embed in project
paths and histories, even inside a tag that is otherwise kept; a file that
holds one of them is skipped too, and is never reported as already clean.

HDR gain maps (Ultra HDR, ISO 21496-1 and Apple) are image data and are kept.
Maker notes are removed, with one exception: for a photo with a gain map,
Apple's two HDR values (`HDRHeadroom` and `HDRGain`) stay in a minimal maker
note of their own, because Apple's renderer needs them to show the photo at
full HDR brightness. This includes the previews inside Apple ProRAW files.

Live Photos are linked to their video by an identifier in both files, which
is removed; a cleaned photo and video are no longer paired.

ICC colour profiles are kept, but a Mac display profile, which macOS embeds
in screenshots, holds the display's serial number and manufacture date in a
private tag that no colour management reads. In JPEG, PNG, GIF, WebP, HEIF,
AVIF, TIFF, MP4 and MOV files those bytes are zeroed and the profile's
checksum is cleared (which the ICC standard allows); the rest of the profile
stays byte for byte. Profiles from calibration tools such as DisplayCAL record
the display's EDID in a metadata dictionary; its serial number, hash and
manufacture date become zeros the same way. A JPEG XL profile is part of the
codestream and is left as it is.

## Formats

| Format | Method | Kept |
| --- | --- | --- |
| JPEG | ExifTool rewrite; segment-level check that image data, JFIF, ICC and Adobe segments are byte-identical (a thumbnail inside the JFIF segment is removed). A file whose image data runs to its end without an end-of-image marker gets the marker. An HDR gain map is stripped to its image data and gain-map metadata and the MPF index is rebuilt. A Motion Photo keeps its video, cleaned like any MP4: Google Motion Photo and MicroVideo (with a minimal rebuilt XMP) and Samsung (with a trailer that holds only the video; capture time and mobile country code go). Everything else after the image (preview thumbnails, padding, and stale card or computer data that some cameras leave there) is removed | Orientation, resolution, colour space, Adobe colour transform, ICC, HDR gain map, Motion Photo video |
| PNG, APNG | Chunk-level rewrite; rendering chunks are copied byte-for-byte | IHDR, PLTE, tRNS, cHRM, gAMA, iCCP, sBIT, sRGB, cICP, mDCV, cLLI, bKGD, pHYs, animation chunks; orientation as a minimal eXIf chunk |
| WebP, animated WebP | Chunk-level rewrite; image and animation frames are copied byte for byte and decode identically. A non-default EXIF orientation is rebuilt as an EXIF chunk with only that value | VP8, VP8L, ALPH, ICCP, VP8X, ANIM, ANMF (loop count, background colour, frame timing), orientation |
| JPEG XL | Box-level rewrite: Exif, XMP and JUMBF boxes (plain or Brotli-compressed) and JPEG reconstruction data, which can hold the original JPEG's comments and application segments, are removed; the codestream is copied byte for byte. A recompressed JPEG then can no longer be turned back into the identical original JPEG | Codestream, including its ICC profile and orientation |
| GIF | Block-level rewrite | Image data, timing, loop count, ICC |
| TIFF, including multi-page documents | ExifTool tag deletion on the first page; on later pages the document name, page name, description, make, model, software, date, artist, host computer and copyright become blank in place, and their image data is compared byte for byte. Uncompressed, LZW, JPEG, Deflate, PackBits and CCITT fax (scanned documents) images | Image structure tags, sensor black and white levels (DJI multispectral cameras), page numbers and ICC |
| DNG (Apple ProRAW, Google, DJI, Adobe DNG Converter and others) | ExifTool deletes the Exif, GPS, maker note, IPTC and XMP data and the identity tags (camera, lens and raw-data serial numbers, original raw file name, software, preview dates and names, shot counter); DNG private data (a copy of the maker notes) and the Exif, XMP and comment segments inside embedded JPEG previews become zeros in place. The raw data, previews and mattes of every IFD and SubIFD are compared byte for byte | Make, model and the DNG camera model name (which raw developers use to pick profiles and corrections), every DNG rendering tag (colour matrices, calibration, black and white levels, crops, opcodes, noise profiles), previews with their gain maps, Apple semantic mattes and their XMP |
| SVG | Tokenized removal of comments, `<metadata>` and Inkscape, Sodipodi, Sketch and Serif editor data | Everything else, including `<title>` and `<desc>` |
| BMP | No embedded identity metadata; bytes stay identical | Everything |
| ICO | Embedded PNG entries are cleaned like PNG | BMP entries unchanged |
| HEIC, HEIF, AVIF | The meta box is rebuilt without the Exif and XMP items and with empty item names, padded to its old size; their bytes are zero-filled. No image byte moves. A Motion Photo keeps its video (cleaned like any MP4) and an XMP rewritten to only locate it; a Samsung trailer box with shot data and a C2PA box are zero-filled | Image items, tiles, thumbnails, alpha and HDR gain-map images, Apple HDR headroom, rotation, mirroring, crop, colour (ICC or CICP), light levels, gain-map XMP |
| MP4, MOV, M4V, M4A, M4B, 3GP, 3G2 | In place: `udta`, `meta`, XMP, C2PA, Sony `USMT` and KDDI phone `uuid` boxes (including cover art) become zero-filled `free` boxes, free space is zeroed, and movie, track and media dates are set to zero. When the movie user data holds iTunes' gapless-playback offsets (`iTunSMPB`) or Sound Check loudness (`iTunNORM`), it keeps only those two items, rebuilt in place. Timed-metadata tracks (Apple `mebx` with detected faces and Live Photo data, GoPro `gpmd`, Google `camm`) and timecode tracks are removed the same way and their samples zeroed. Fragmented files (OBS, screen recorders, streaming downloads) are cleaned the same way; their producer reference times (`prft`, the wall-clock time of each fragment) and event messages (`emsg`) are removed too. Media data that no sample uses, such as an earlier movie box an editor left there, is zeroed too, and then every video and audio sample is compared. No byte outside those regions changes. ExifTool identifies `.m4b` as `M4A`; it follows the same audio-only policy. | Video and audio streams (audio-only files too), chapter tracks, sample tables, edit lists, rotation matrix, codec configuration (including AV1, VP9, Opus, FLAC, AC-3, E-AC-3, ALAC and PCM), HDR mastering, light-level, ambient-viewing and Dolby Vision boxes |
| MKV, WebM, MKA, MKS | In place: tags, cover art and other non-font attachments, title, date, segment identifiers, track names and codec names become zero-filled EBML Void elements, the writing applications become empty, free space is zeroed and CRC-32 checksums are recomputed. Vorbis, Theora and FLAC codec data lose their comments (the decoded audio or video is compared), and ASS/SSA subtitle headers lose titles, authors, comments and editor file paths. Clusters are never touched | Video, audio and subtitle tracks, codec data, chapters, cues, subtitle fonts |
| AVI | In place: `LIST INFO`, `IDIT` capture dates, stream names, camera EXIF in `strd` and maker chunks (such as Pentax `hydt`) become zero-filled `JUNK` chunks of the same size, and existing `JUNK` is zeroed. Indexes and frames stay byte-identical; when camera data was the codec data FFmpeg reports, the decoded video is compared | Header and stream lists, OpenDML indexes, frames, `idx1` |
| MTS, M2TS, TS (AVCHD) | In place: the camera metadata AVCHD camcorders write into the H.264 stream of every frame (make, model, recording date and time zone, exposure, timecode; MDPM user data, also nested in 3D MVC streams) is filled with `0xFF`, keeping the stream's emulation-prevention bytes so its structure stays valid. Only those payload bytes change. ExifTool normalizes 188-byte `.ts` and `.mts` files to `M2T`, and 192-byte `.m2ts` files to `M2TS`. | Video and audio streams, transport stream structure |
| MP3, AAC (ADTS) | Rewritten without ID3v2 (before or after the audio), ID3v1, APEv2 and Lyrics3 tags (including cover art); the audio frames are copied byte for byte and decode identically | MPEG audio and ADTS frames, including the Xing/LAME header |
| FLAC | Rewritten with only the stream information, seek table, cue sheet and a Vorbis comment block reduced to playback values; pictures, padding, application data and ID3 tags go. Audio frames are copied byte for byte | Stream information (with its MD5), seek table, cue sheet, channel mask, ReplayGain |
| Ogg Opus, Vorbis, FLAC, Speex and Theora (`.opus`, `.ogg`, `.oga`, `.spx`, `.ogv`), including multiplexed streams | In place, stream by stream: the comment header keeps an empty vendor and only loudness values and is padded with zeros to its old length; Ogg FLAC comment and picture blocks become padding blocks; an Ogg Skeleton loses its date. Only the CRCs of those pages change, and the decoded audio and video are compared | Audio and video pages, codec headers, output gain, R128 and ReplayGain values, Skeleton content types, roles and numbered track names |
| DSF | Rewritten without the ID3v2 tag; the DSD chunk's file size and tag pointer are updated | Format and audio chunks, byte for byte |
| WavPack | Rewritten without APEv2 and ID3v1 tags | Audio blocks, byte for byte |
| Monkey's Audio (`.ape`), Musepack SV7 (`.mpc`) | Rewritten without the trailing APEv2, ID3v1 and Lyrics3 tags; the decoded audio is compared | Header, seek table and frames, byte for byte (including Musepack's ReplayGain header fields) |
| WMA, WMV, ASF | In place: content description, extended content description, metadata, metadata library, content branding and script command objects become zero-filled padding objects of the same size, existing padding is zeroed, and the file identifier and creation date are zeroed. Packets and indexes stay byte-identical | Stream properties, codec list, markers, aspect ratio |
| WAV, AIFF | Rewritten with only the format, audio, sample count, channel layout, cue, loop and tempo chunks; Broadcast WAV (`bext`), iXML, `LIST` INFO, ID3, NAME, AUTH, ANNO and other chunks go | Audio data and those chunks, byte for byte |

Skipped unchanged:

- camera RAW formats other than DNG (CR2, CR3, NEF, ARW, RAF and others),
  PDF and other unsupported formats;
- WebP with unknown chunks inside an animation frame or an EXIF orientation
  behind a JPEG-style `Exif` header (viewers disagree about reading it), TIFF
  with more than 1,000 pages, sub-IFDs, Photoshop layers, JPEG-compressed
  strips or tiles that carry their own metadata segments, or unrecognized
  private tags (for example raw DNG data), and JPEG files with stereo
  or panorama MPF frames, more than one gain map, Samsung trailers with
  other content (Selective Focus images), Samsung trailers combined with a
  Google Motion Photo, undeclared appended videos, embedded depth items, or
  Photoshop paths; Samsung HEIF Motion Photos;
- PNG files with unknown critical chunks or corrupt chunk CRCs;
- HEIF image sequences and animated AVIF, JPEG-coded HEIF items, unknown
  item types, properties or references, an EXIF orientation without a
  matching `irot`, and XMP on auxiliary images with anything but technical
  values;
- GIF files with plain-text extensions;
- SVG files with scripts, event handlers, animation, external references,
  embedded data URIs, CDATA, or a DOCTYPE other than the standard W3C SVG one
  without an internal subset;
- Motion-JPEG videos (AVI, QuickTime, Matroska) whose frames carry their
  own Exif, XMP or IPTC segments, which ExifTool does not read;
- encrypted or Smooth Streaming QuickTime fragments, externally referenced
  QuickTime files, and files with other data tracks (hint or unknown tracks);
- chained Ogg files, Ogg streams in other codecs and Ogg Skeleton headers
  other than content type, role and a numbered track name;
- WavPack and Monkey's Audio files that store the original file's own
  metadata chunks or trailing data, Monkey's Audio and Musepack files with a
  leading ID3v2 tag, Musepack SV8 (which ExifTool cannot read), OptimFROG
  files, and ASF files with DRM, a digital signature, stream names or unknown
  objects;
- JPEG XL files with unknown boxes;
- AVCHD sidecar files (`.CPI`, `.MPL` in the `PRIVATE/AVCHD` folder) carry
  recording dates too and are not media files MetaClean reads;
- AVI files whose first video frame holds EXIF or XMP, or whose `strd`
  chunk holds codec data rather than camera data;
- RF64 WAV files, and audio files that ExifTool or FFprobe cannot read;
- encrypted Matroska tracks, Matroska data tracks, chapters that link other
  files or run commands, and Matroska elements outside the specification;
- symlinks, hard-linked files, special files, immutable or append-only files,
  iCloud Drive files that are not downloaded (reading them would download
  them), and malformed files.

## Filesystem metadata

MetaClean removes Finder tags and comments, download-source (`WhereFroms`),
download-date and last-used-date attributes, and sets the creation and
modification dates to 2001-01-01 00:00 local time, on APFS and HFS+ as well
as on exFAT and FAT camera cards and USB drives. Resource forks,
quarantine, provenance, `com.apple.macl`, other extended attributes, ACLs,
permissions and file flags are kept. Read-only files are cleaned and stay
read-only.

Folders are searched recursively after a confirmation. App packages and
libraries such as `.photoslibrary`, `.app` and `.fcpbundle` are never entered.

When macOS sees a file replaced by rename, Spotlight re-applies the replaced
file's download source and download date from its index a few seconds later.
MetaClean therefore removes those attributes from the original and re-imports
it into Spotlight (`mdimport`) just before the replacement, waiting until
Spotlight no longer lists them; otherwise the file is skipped.

MetaClean does not erase earlier copies of a file: APFS snapshots, backups,
sync services, previous versions, filenames and folder names are outside its
scope. The cleaned file replaces the original, whose bytes stay in the
volume's free space until they are overwritten, which matters most on camera
cards that are passed on.

## Installation

```sh
ya pkg add deppess/yazi-plugins:metaclean
```

Requires macOS, Yazi 26.9.1 or later, ExifTool, FFmpeg (`ffmpeg` and
`ffprobe`) and `timeout`, which current macOS includes (GNU coreutils
provides it on older versions). MetaClean stops with a message naming any
tool it cannot find.

## Usage

```toml
# keymap.toml
[[mgr.prepend_keymap]]
on   = ["m", "c"]
run  = "plugin metaclean"
desc = "Remove media metadata"

[[mgr.prepend_keymap]]
on   = ["m", "p"]
run  = "plugin metaclean preview"
desc = "Preview media metadata removal"
```

The plugin cleans the selected files and folders, or the hovered file when
nothing is selected. Choose a key that does not conflict with your other
bindings.

With `preview`, nothing is written. A scrollable window lists the files
MetaClean would clean, each with the tags it would remove grouped by
metadata group, then the files that are already clean and the files it
would skip with the reason; files, groups and tags are sorted. Scroll with
`j`/`k`, the arrow keys, `Ctrl-d`/`Ctrl-u`, `Space` or the mouse wheel,
jump with `g`/`G`, and close with `q`, `Esc` or `Enter`. A cleaned file
still has to pass every check, so a previewed file can still be skipped.

After cleaning, a notification summarizes the result. When files are
skipped, it groups them by reason, most common first, with an example file
for each. Batches of 200 or more files report their progress at each
quarter.

## Build and test

```sh
lua metaclean.yazi/tests/run.lua
METACLEAN_SLOW=1 lua metaclean.yazi/tests/run.lua   # adds the ~1 min Spotlight test
METACLEAN_ONLY=JPEG lua metaclean.yazi/tests/run.lua # only tests whose name contains JPEG
stylua --check .
```

Run it from the repository root. The suite generates disposable fixtures and
only writes under `metaclean.yazi/tests/working/`, `originals/` and
`reports/`. It loads the
production plugin through an adapter for Yazi's APIs and drives the real
transaction. A passing run deletes its working folder; a failing one keeps it
for inspection. It also uses `cwebp`, `gif2webp`, `webpinfo`, `jpeginfo`,
`pngcheck`, `gifsicle`, `tiffinfo`, `mp4dump`, `xmllint`, `heif-enc`, `heif-dec`,
`heif-info`, `avifenc`, `mkvmerge`, `cjxl`, `djxl`, `tiffcp`, `tiffcmp`,
`dcraw_emu` (LibRaw), FFmpeg with `libx264`, `libmp3lame`, `libsvtav1`,
`libvpx` and `libopus` and, if present, ImageMagick; these are not runtime
dependencies.

## License

AGPL-3.0-or-later. See [LICENSE](LICENSE).
