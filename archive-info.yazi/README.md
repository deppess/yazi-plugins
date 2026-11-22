# archive-info.yazi

Previews an archive's stats and tests its integrity, in the same layout as [mediainfo.yazi](https://github.com/boydaihungst/mediainfo.yazi). It replaces Yazi's built-in archive previewer, which only lists the files and shows a corrupted archive the same as a good one.

Requires Yazi 26.9.1 or newer and [7-Zip](https://www.7-zip.org) (`7zz` or `7z`). `bsdtar` is optional; macOS includes it.

## What it shows

The status comes first: OK, BROKEN, INCOMPLETE, ENCRYPTED, PARTLY OK, LOCKED or NO CHECKSUM, with a one-line summary. Below it are the format, size on disk, unpacked size, compression ratio, file and folder counts, compression methods, encryption, largest file and date range, then sections for problems, volumes, each format layer 7-Zip reports, and the contents.

Hovering an archive runs 7-Zip's full test, which reads every file's data and checks its checksum. Listing alone can't tell a corrupted archive from a good one. The stats appear at once and the status follows when the test finishes. Moving to another file stops the test, and results are kept for the session, so going back to an archive doesn't test it again.

- **Encrypted archives:** the file list and structure are still checked. Contents that need the password are reported as not verified rather than broken, and a 7z with encrypted file names is reported as locked.
- **Multi-volume sets:** `.7z.001`, `.zip.001` and other numbered splits, spanned zips (`.z01` … `.zip`) and RAR volumes (`.part1.rar`, `.r00`). Hovering any part shows the whole set. Every volume is checked for gaps and for a size that differs from the others, so a missing or truncated part is named. When a file's data is damaged, the volumes that hold it are named where the format records file positions (zip). A solid 7z doesn't, so only the damaged files are named.
- **Compressed tar** (`.tar.gz`, `.tar.xz`, `.tar.zst`, `.tar.bz2` and so on): the compressed stream's checksum is tested and the tar inside is listed. Tar itself stores no data checksums. 7-Zip reports the extended-attribute headers macOS `tar` writes as a header error; when `bsdtar` reads every header cleanly, that is shown as a note instead.

The contents list stops after 2,000 entries.

## Installation

```sh
ya pkg add deppess/yazi-plugins:archive-info
```

## Usage

```toml
# yazi.toml
[plugin]
prepend_previewers = [
  { mime = "application/{zip,rar,7z*,tar,gzip,xz,zstd,bzip*,lzma,compress,archive,cpio,arj,xar,ms-cab*}", run = "archive-info" },
  { url = "*.[0-9][0-9][0-9]", run = "archive-info" },
  { url = "*.z[0-9][0-9]", run = "archive-info" },
  { url = "*.r[0-9][0-9]", run = "archive-info" },
]
```

The first rule takes over every archive type Yazi's built-in previewer handles. The other three catch volumes whose names don't identify them as archives. Scroll the preview with `J` and `K`.

## License

This plugin is licensed under PolyForm Strict License 1.0.0 (`SPDX-License-Identifier: PolyForm-Strict-1.0.0`). See [LICENSE](LICENSE).
