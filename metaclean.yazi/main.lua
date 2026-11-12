--- @since 26.9.1
-- MetaClean: removes identity metadata from local media without reencoding.
--
-- Every supported format has an allowlist of the technical metadata it needs
-- for rendering or playback; everything else is removed. A staged copy
-- replaces the original only after independent checks prove that the encoded
-- media, its rendering metadata and the file's attributes are unchanged.
-- Anything that cannot be proven is skipped unchanged.

local M = {}

local TITLE = "MetaClean"

-- Size, count and depth limits for parsers and command output.
local LIMIT = {
	STDERR = 2048,
	MANIFEST_BYTES = 1024 * 1024,
	INVENTORY_BYTES = 32 * 1024 * 1024,
	ISOBMFF_DEPTH = 32,
	ISOBMFF_BOXES = 100000,
	JPEG_BYTES = 256 * 1024 * 1024,
	PNG_BYTES = 256 * 1024 * 1024,
	GIF_BYTES = 128 * 1024 * 1024,
	ICO_BYTES = 16 * 1024 * 1024,
	SVG_BYTES = 8 * 1024 * 1024,
	RIFF_BYTES = 32 * 1024 * 1024,
	RIFF_CHUNKS = 100000,
	RIFF_DEPTH = 32,
	WEBP_BYTES = 256 * 1024 * 1024,
	WEBP_CHUNKS = 65536,
	WEBP_DIMENSION = 16384,
	ISOBMFF_ITEMS = 4096,
	EBML_VALUE = 1024 * 1024,
	EBML_DEPTH = 32,
	EBML_ELEMENTS = 4000000,
	BINARY_READ = 32 * 1024 * 1024,
	SAFE_INTEGER = 9007199254740991,
	QUICKTIME_TABLE_BYTES = 64 * 1024 * 1024,
	HEIF_META_BYTES = 16 * 1024 * 1024,
	OGG_STREAMS = 16,
	MOTION_BYTES = 256 * 1024 * 1024,
	-- TIFF pages; ExifTool needs about 0.3 ms a page to list them.
	TIFF_PAGES = 1000,
	-- Removed values searched for in a cleaned file; each costs about 40 ms
	-- per GB.
	RESIDUE_NEEDLES = 256,
	-- Files cleaned at once, at most one per CPU core. Most of a file's time
	-- is spent waiting for ExifTool and FFmpeg; beyond eight the gain is small.
	WORKERS = 8,
}
local COMMAND_TIMEOUT_SECONDS = 120
-- Commands that read a whole media file get one extra second per 4 MiB.
local TIMEOUT_BYTES_PER_SECOND = 4 * 1024 * 1024
-- Local time 2001-01-01 00:00:00. Setting a modification time before the
-- birth time makes APFS move the birth time too.
local NEUTRAL_TOUCH_TIME = "200101010000.00"
local QUICKTIME_NEUTRAL_DATE = "0000:00:00 00:00:00"

-- Removed from the staged file, with the name the preview shows; every other
-- extended attribute, including resource forks, quarantine, provenance and
-- com.apple.macl, is preserved.
local FILESYSTEM_IDENTITY_XATTRS = {
	["com.apple.metadata:_kMDItemUserTags"] = "Finder tags",
	["com.apple.metadata:kMDItemFinderComment"] = "Finder comment",
	["com.apple.metadata:kMDItemWhereFroms"] = "Download source",
	["com.apple.lastuseddate#PS"] = "Last opened date",
	["com.apple.metadata:kMDItemDownloadedDate"] = "Download date",
}

-- Directory packages are owned by an application (Photos, Final Cut, Xcode,
-- ...). Rewriting files inside them can corrupt the application's database, so
-- traversal never enters them.
local PACKAGE_EXTENSIONS = {}
for _, extension in ipairs({
	"app",
	"appex",
	"aplibrary",
	"band",
	"bundle",
	"dsym",
	"fcpbundle",
	"framework",
	"imovielibrary",
	"kext",
	"key",
	"logicx",
	"lrdata",
	"lrlibrary",
	"migratedphotolibrary",
	"musiclibrary",
	"numbers",
	"pages",
	"photolibrary",
	"photoslibrary",
	"playground",
	"plugin",
	"rtfd",
	"sparsebundle",
	"theater",
	"tvlibrary",
	"xcodeproj",
	"xcworkspace",
	"xpc",
}) do
	PACKAGE_EXTENSIONS[extension] = true
end

local function notify(content, level)
	ya.notify({ title = TITLE, content = content, level = level or "info", timeout = 5 })
end

local function clean_error(output, err)
	local message = output and output.stderr or err and tostring(err) or "command failed"
	message = message:gsub("%s+$", "")
	if #message > LIMIT.STDERR then
		message = message:sub(1, LIMIT.STDERR) .. "…"
	end
	return message == "" and "command failed" or message
end

local function timeout_args(name, args, seconds)
	local bounded = { "-k", "5", tostring(seconds or COMMAND_TIMEOUT_SECONDS), name }
	if name == "exiftool" then
		-- ExifTool loads ~/.ExifTool_config automatically. A user config can
		-- redefine tags and make the inventory non-deterministic. -config must
		-- be its first option.
		bounded[#bounded + 1] = "-config"
		bounded[#bounded + 1] = ""
	end
	for _, arg in ipairs(args) do
		bounded[#bounded + 1] = arg
	end
	return bounded
end

local function bounded_command(name, args, seconds)
	return Command("timeout")
		:arg(timeout_args(name, args, seconds))
		:env("LC_ALL", "C")
		:env("LANG", "C")
		:env("AV_LOG_FORCE_NOCOLOR", "1")
end

local function command(name, args, seconds)
	return bounded_command(name, args, seconds):stdout(Command.PIPED):stderr(Command.PIPED):output()
end

-- Yazi 26.9 returns Child:read() data as an array of byte values rather than
-- the documented string.
local function read_chunk(data)
	if type(data) ~= "table" then
		return data
	end
	local parts = {}
	for index = 1, #data, 4096 do
		parts[#parts + 1] = string.char(table.unpack(data, index, math.min(index + 4095, #data)))
	end
	return table.concat(parts)
end

-- Collect a producer's stdout up to a byte limit without trusting it to be
-- small. stderr is truncated for error messages.
local function bounded_output(name, args, seconds, limit)
	limit = limit or LIMIT.MANIFEST_BYTES
	local child, spawn_err = bounded_command(name, args, seconds):stdout(Command.PIPED):stderr(Command.PIPED):spawn()
	if not child then
		return nil, tostring(spawn_err or "could not start " .. name)
	end
	local stdout, stderr = {}, {}
	local stdout_size, stderr_size = 0, 0
	while true do
		local data, event = child:read(65536)
		if event == 2 then
			break
		end
		data = read_chunk(data)
		if data and event == 0 then
			stdout_size = stdout_size + #data
			if stdout_size > limit then
				child:start_kill()
				child:wait()
				return nil, name .. " output exceeds " .. tostring(limit) .. " bytes"
			end
			stdout[#stdout + 1] = data
		elseif data and event == 1 and stderr_size < LIMIT.STDERR then
			local fragment = data:sub(1, LIMIT.STDERR - stderr_size)
			stderr[#stderr + 1] = fragment
			stderr_size = stderr_size + #fragment
		end
	end
	local status, wait_err = child:wait()
	if not status or not status.success then
		local message = table.concat(stderr):gsub("%s+$", "")
		if message == "" then
			message = wait_err and tostring(wait_err) ~= "" and tostring(wait_err) or name .. " exited unsuccessfully"
		end
		-- The output so far: ExifTool reports file errors on stdout.
		return nil, message, table.concat(stdout)
	end
	return table.concat(stdout)
end

local function file_size(path)
	local file = io.open(path, "rb")
	if not file then
		return nil
	end
	local size = file:seek("end")
	file:close()
	return size
end

local function media_timeout(path)
	return COMMAND_TIMEOUT_SECONDS + math.ceil((file_size(path) or 0) / TIMEOUT_BYTES_PER_SECOND)
end

local function read_file(path, limit, label)
	local file, open_err = io.open(path, "rb")
	if not file then
		return nil, tostring(open_err or ("could not open " .. label))
	end
	local size = file:seek("end")
	if not size or size > limit then
		file:close()
		return nil, label .. " exceeds parser size limit"
	end
	file:seek("set", 0)
	local data = file:read("a") or ""
	file:close()
	if #data ~= size then
		return nil, "truncated " .. label .. " read"
	end
	return data
end

-- Rewrite a staged file in place. Truncating the existing inode keeps the
-- clone's ACL, flags and extended attributes.
local function rewrite_file(path, data)
	local output, open_err = io.open(path, "wb")
	if not output then
		return nil, tostring(open_err or "could not rewrite staged file")
	end
	local ok, write_err = output:write(data)
	local closed, close_err = output:close()
	if not ok or not closed then
		return nil, tostring(write_err or close_err or "could not write staged file")
	end
	return true
end

local function be_u16(value, offset)
	local a, b = value:byte(offset or 1, (offset or 1) + 1)
	return b and a * 256 + b or nil
end

local function be_u32_at(value, offset)
	local a, b, c, d = value:byte(offset, offset + 3)
	return d and ((a * 256 + b) * 256 + c) * 256 + d or nil
end

local function u32_be_bytes(value)
	return string.char(value // 16777216 % 256, value // 65536 % 256, value // 256 % 256, value % 256)
end

local function u32_le_bytes(value)
	return string.char(value % 256, value // 256 % 256, value // 65536 % 256, value // 16777216 % 256)
end

local CRC32_TABLE = {}
for index = 0, 255 do
	local value = index
	for _ = 1, 8 do
		if value & 1 == 1 then
			value = (value >> 1) ~ 0xEDB88320
		else
			value = value >> 1
		end
	end
	CRC32_TABLE[index] = value
end

-- previous chains the CRC of earlier data.
local function crc32(data, first, last, previous)
	local crc = (previous or 0) ~ 0xFFFFFFFF
	for index = first or 1, last or #data do
		crc = CRC32_TABLE[(crc ~ data:byte(index)) & 0xFF] ~ (crc >> 8)
	end
	return crc ~ 0xFFFFFFFF
end

local function le_u16(value)
	local a, b = value:byte(1, 2)
	return b and (a + b * 256) or nil
end

local function le_u32(value)
	local a, b, c, d = value:byte(1, 4)
	return d and (a + b * 256 + c * 65536 + d * 16777216) or nil
end

local function checked_add(left, right)
	if
		type(left) ~= "number"
		or type(right) ~= "number"
		or left < 0
		or right < 0
		or left % 1 ~= 0
		or right % 1 ~= 0
	then
		return nil, "invalid non-negative integer"
	end
	if left > LIMIT.SAFE_INTEGER - right then
		return nil, "integer overflow"
	end
	return left + right
end

local function validate_ranges(ranges, parent_start, parent_finish)
	if
		type(ranges) ~= "table"
		or type(parent_start) ~= "number"
		or type(parent_finish) ~= "number"
		or parent_start < 0
		or parent_finish < parent_start
	then
		return nil, "invalid range parent"
	end
	local ordered = {}
	for index, range in ipairs(ranges) do
		if
			type(range) ~= "table"
			or type(range.start) ~= "number"
			or type(range.finish) ~= "number"
			or range.start < parent_start
			or range.finish < range.start
			or range.finish > parent_finish
		then
			return nil, "invalid range " .. tostring(index)
		end
		ordered[index] = { start = range.start, finish = range.finish }
	end
	table.sort(ordered, function(a, b)
		return a.start == b.start and a.finish < b.finish or a.start < b.start
	end)
	for index = 2, #ordered do
		if ordered[index].start < ordered[index - 1].finish then
			return nil, "overlapping ranges"
		end
	end
	return ordered
end

local function merge_adjacent_ranges(ranges, parent_start, parent_finish)
	local ordered, err = validate_ranges(ranges, parent_start, parent_finish)
	if not ordered then
		return nil, err
	end
	local merged = {}
	for _, range in ipairs(ordered) do
		local previous = merged[#merged]
		if previous and range.start == previous.finish then
			previous.finish = range.finish
		else
			merged[#merged + 1] = range
		end
	end
	return merged
end

local function binary_reader(path, origin, limit)
	if not io or not io.open then
		return nil, "Lua binary file access is unavailable"
	end
	local file, open_err = io.open(path, "rb")
	if not file then
		return nil, tostring(open_err or "could not open binary file")
	end
	local file_size = file:seek("end")
	if not file_size or file_size < 0 or file_size > LIMIT.SAFE_INTEGER then
		file:close()
		return nil, "unsupported binary file size"
	end
	origin, limit = origin or 0, limit or file_size
	local finish = checked_add(origin, limit)
	if
		type(origin) ~= "number"
		or type(limit) ~= "number"
		or origin < 0
		or limit < 0
		or origin % 1 ~= 0
		or limit % 1 ~= 0
		or not finish
		or finish > file_size
	then
		file:close()
		return nil, "invalid binary reader range"
	end
	if not file:seek("set", origin) then
		file:close()
		return nil, "binary reader seek failed"
	end
	local reader = { file = file, path = path, origin = origin, length = limit, position = 0 }
	function reader:size()
		return self.length
	end
	function reader:tell()
		return self.position
	end
	function reader:remaining()
		return self.length - self.position
	end
	function reader:close()
		if self.file then
			self.file:close()
			self.file = nil
		end
	end
	function reader:seek(offset)
		if not self.file then
			return nil, "binary reader is closed"
		end
		if type(offset) ~= "number" or offset < 0 or offset % 1 ~= 0 or offset > self.length then
			return nil, "invalid binary reader offset"
		end
		if not self.file:seek("set", self.origin + offset) then
			return nil, "binary reader seek failed"
		end
		self.position = offset
		return true
	end
	function reader:read_exact(length)
		if not self.file then
			return nil, "binary reader is closed"
		end
		if
			type(length) ~= "number"
			or length < 0
			or length % 1 ~= 0
			or length > LIMIT.BINARY_READ
			or length > self:remaining()
		then
			return nil, "invalid binary reader length"
		end
		local data = self.file:read(length)
		if not data or #data ~= length then
			return nil, "truncated binary read"
		end
		self.position = self.position + length
		return data
	end
	function reader:slice(offset, length)
		if
			type(offset) ~= "number"
			or type(length) ~= "number"
			or offset < 0
			or length < 0
			or offset % 1 ~= 0
			or length % 1 ~= 0
			or offset > self.length
			or length > self.length - offset
		then
			return nil, "invalid binary reader slice"
		end
		local ok, err = self:seek(offset)
		if not ok then
			return nil, err
		end
		return self:read_exact(length)
	end
	function reader:u8()
		local value, err = self:read_exact(1)
		return value and value:byte(1) or nil, err
	end
	function reader:u16le()
		local value, err = self:read_exact(2)
		return value and le_u16(value) or nil, err
	end
	function reader:u16be()
		local value, err = self:read_exact(2)
		return value and value:byte(2) + value:byte(1) * 256 or nil, err
	end
	local function unsigned(value, big_endian)
		local result = 0
		for index = big_endian and 1 or #value, big_endian and #value or 1, big_endian and 1 or -1 do
			if result > math.floor(LIMIT.SAFE_INTEGER / 256) then
				return nil
			end
			result = result * 256 + value:byte(index)
		end
		return result
	end
	function reader:u24le()
		local value, err = self:read_exact(3)
		return value and unsigned(value, false) or nil, err
	end
	function reader:u24be()
		local value, err = self:read_exact(3)
		return value and unsigned(value, true) or nil, err
	end
	function reader:u32le()
		local value, err = self:read_exact(4)
		return value and le_u32(value) or nil, err
	end
	function reader:u32be()
		local value, err = self:read_exact(4)
		return value and value:byte(4) + value:byte(3) * 256 + value:byte(2) * 65536 + value:byte(1) * 16777216 or nil,
			err
	end
	function reader:u64le()
		local value, err = self:read_exact(8)
		local number = value and unsigned(value, false)
		return number, number and nil or (err or "unsafe unsigned 64-bit value")
	end
	function reader:u64be()
		local value, err = self:read_exact(8)
		local number = value and unsigned(value, true)
		return number, number and nil or (err or "unsafe unsigned 64-bit value")
	end
	function reader:subreader(offset, length)
		if not self.file then
			return nil, "binary reader is closed"
		end
		if
			type(offset) ~= "number"
			or type(length) ~= "number"
			or offset < 0
			or length < 0
			or offset % 1 ~= 0
			or length % 1 ~= 0
			or offset > self.length
			or length > self.length - offset
		then
			return nil, "invalid binary subreader range"
		end
		return binary_reader(self.path, self.origin + offset, length)
	end
	function reader:copy_range(output, offset, length)
		if not self.file then
			return nil, "binary reader is closed"
		end
		if
			not output
			or type(output.write) ~= "function"
			or type(offset) ~= "number"
			or type(length) ~= "number"
			or offset < 0
			or length < 0
			or offset % 1 ~= 0
			or length % 1 ~= 0
			or offset > self.length
			or length > self.length - offset
		then
			return nil, "invalid binary copy range"
		end
		local saved = self.position
		local ok, err = self:seek(offset)
		if not ok then
			return nil, err
		end
		local remaining = length
		while remaining > 0 do
			local block = math.min(remaining, 65536)
			local data, read_err = self:read_exact(block)
			if not data then
				self:seek(saved)
				return nil, read_err
			end
			if not output:write(data) then
				self:seek(saved)
				return nil, "binary copy write failed"
			end
			remaining = remaining - block
		end
		self:seek(saved)
		return true
	end
	return reader
end

local function copy_excluding_ranges(source, output, ranges)
	local reader, reader_err = binary_reader(source)
	if not reader then
		return nil, reader_err
	end
	if not output or type(output.write) ~= "function" then
		reader:close()
		return nil, "invalid binary copy output"
	end
	local ordered, range_err = merge_adjacent_ranges(ranges, 0, reader:size())
	if not ordered then
		reader:close()
		return nil, range_err
	end
	local position = 0
	for _, range in ipairs(ordered) do
		local length = range.start - position
		if length > 0 then
			local ok, err = reader:copy_range(output, position, length)
			if not ok then
				reader:close()
				return nil, err
			end
		end
		position = range.finish
	end
	if position < reader:size() then
		local ok, err = reader:copy_range(output, position, reader:size() - position)
		if not ok then
			reader:close()
			return nil, err
		end
	end
	reader:close()
	return true
end

-- ExifTool groups that describe the file system or ExifTool itself, or are
-- derived from other tags. Every other group goes through the allowlist.
local INVENTORY_IGNORED_GROUPS = { System = true, MacOS = true, ExifTool = true, Composite = true }

-- Read-only metadata inventory. Text output keeps duplicate tags (a MOV track
-- has two HandlerType entries) that JSON would merge, and ExifTool prints
-- control characters as dots so every tag is one line.
local function scan_named(path, options)
	options = options or {}
	-- RequestAll 2 adds only the MacOS group, which is ignored, and costs a
	-- Spotlight query per scan. -validate costs about half a scan, so only
	-- cleaned files are validated.
	local args = { "-s", "-G1", "-a", "-n", "-u", "-api", "requestall=1", "-all" }
	if options.validate then
		args[#args + 1] = "-validate"
	end
	-- Without -ee ExifTool stops reading Matroska at the first cluster.
	if options.embedded then
		args[#args + 1] = "-ee"
	end
	args[#args + 1] = "--"
	args[#args + 1] = path
	local output, err, partial = bounded_output("exiftool", args, media_timeout(path), LIMIT.INVENTORY_BYTES)
	if not output then
		-- A failed run is only read for ExifTool's own error message.
		local message = partial and partial:match("%[ExifTool%]%s+Error%s+: ([^\r\n]+)")
		return nil, message and "ExifTool error: " .. message or err
	end
	local inventory = { entries = {}, values = {} }
	for line in output:gmatch("[^\r\n]+") do
		local group, tag, value = line:match("^%[([^%]]+)%]%s+(%S+)%s*:%s?(.*)$")
		if not group then
			return nil, "unparseable ExifTool inventory line"
		end
		if group == "File" and tag == "FileType" then
			inventory.file_type = value
		elseif group == "File" and tag == "MIMEType" then
			inventory.mime_type = value
		elseif group == "ExifTool" and tag == "Validate" then
			inventory.validate = value
		elseif group == "ExifTool" and tag == "Error" then
			inventory.error = value
		end
		-- Warnings are ExifTool's notes about the file in any group, and
		-- -validate adds more of them.
		if not INVENTORY_IGNORED_GROUPS[group] and tag ~= "Warning" then
			local key = group .. ":" .. tag
			local values = inventory.values[key]
			if not values then
				values = {}
				inventory.values[key] = values
				inventory.entries[#inventory.entries + 1] = key
			end
			values[#values + 1] = value
		end
	end
	if inventory.error then
		return nil, "ExifTool error: " .. inventory.error
	end
	if not inventory.file_type then
		return nil, "ExifTool did not identify the file type"
	end
	return inventory
end

-- ExifTool reads the first 8 KB of a file named .mp3 and reports a format
-- error when the audio there holds bytes that look like an MPEG start code.
-- Without the extension it identifies the file from 256 bytes, so the scan is
-- retried through a link with no extension.
local function scan(path, options)
	local inventory, err = scan_named(path, options)
	if inventory or err ~= "ExifTool error: File format error" or not path:lower():match("^/.*%.mp3$") then
		return inventory, err
	end
	local temporary = (os.getenv("TMPDIR") or "/tmp"):gsub("/+$", "")
	local directory = fs.unique("dir", Url(temporary .. "/metaclean-scan"))
	if not directory then
		return nil, err
	end
	directory = tostring(directory)
	local linked = command("ln", { "-s", "--", path, directory .. "/media" })
	if linked and linked.status.success then
		inventory, err = scan_named(directory .. "/media", options)
	end
	fs.remove("dir_all", Url(directory))
	return inventory, err
end

-- A tag list entry is "Group:Tag", "Group:*", or "^pattern:Tag" where the group
-- is a Lua pattern; with a pattern group the tag may be a "^pattern" too.
local function tag_set(list)
	local exact, patterns = {}, {}
	for _, item in ipairs(list or {}) do
		local group, tag = item:match("^(.*):([^:]+)$")
		assert(group, "invalid tag set entry " .. item)
		if group:sub(1, 1) == "^" then
			patterns[#patterns + 1] = { group = group, tag = tag }
		else
			exact[group .. ":" .. tag] = true
		end
	end
	return function(key)
		if exact[key] then
			return true
		end
		local group, tag = key:match("^(.*):([^:]+)$")
		if not group then
			return false
		end
		if exact[group .. ":*"] then
			return true
		end
		for _, pattern in ipairs(patterns) do
			local tag_pattern = pattern.tag:sub(1, 1) == "^"
			if
				group:match(pattern.group)
				and (pattern.tag == "*" or pattern.tag == tag or tag_pattern and tag:match(pattern.tag))
			then
				return true
			end
		end
		return false
	end
end

-- keep: rendering/playback metadata; must survive with identical values.
-- free: harmless technical values that may appear, change, or disappear.
-- defaults: keep tags the writer may create when they were absent.
-- recomputed: keep tags whose value legitimately changes (offsets).
-- neutral: tags that must hold exactly the given value after cleaning.
local function metadata_spec(spec)
	-- The ICC profile ID is a checksum, zeroed when a profile is patched, and
	-- patched metadata dictionary values change too.
	local recomputed =
		table.move(spec.recomputed or {}, 1, #(spec.recomputed or {}), 3, { "ICC-header:ProfileID", "^ICC%-meta$:*" })
	return {
		keep = tag_set(spec.keep),
		free = tag_set(spec.free),
		defaults = tag_set(spec.defaults),
		recomputed = tag_set(recomputed),
		neutral = spec.neutral or {},
	}
end

local function metadata_clean(inventory, spec)
	for _, key in ipairs(inventory.entries) do
		local neutral = spec.neutral[key]
		if neutral then
			for _, value in ipairs(inventory.values[key]) do
				if value ~= neutral then
					return false, key
				end
			end
		elseif not (spec.keep(key) or spec.free(key) or spec.recomputed(key)) then
			return false, key
		end
	end
	return true
end

local function metadata_equivalent(before, after, spec)
	if before.file_type ~= after.file_type or before.mime_type ~= after.mime_type then
		return nil, "file type changed"
	end
	-- Duplicate tags (two EXIF segments, a repeated IFD entry) collapse into
	-- one, so distinct values are compared. An orientation of 1 is the
	-- default and may disappear.
	local function distinct(values)
		local seen, list = {}, {}
		for _, value in ipairs(values or {}) do
			if not seen[value] then
				seen[value], list[#list + 1] = true, value
			end
		end
		return table.concat(list, "\0")
	end
	for _, key in ipairs(before.entries) do
		if spec.keep(key) and not spec.recomputed(key) and not spec.neutral[key] then
			local previous, current = distinct(before.values[key]), after.values[key]
			local implied = not current and key:match(":Orientation$") and previous == "1"
			if not implied and (not current or previous ~= distinct(current)) then
				return nil, "protected metadata changed: " .. key
			end
		end
	end
	for _, key in ipairs(after.entries) do
		if spec.keep(key) and not before.values[key] and not spec.defaults(key) then
			return nil, "unexpected metadata added: " .. key
		end
	end
	return true
end

local function xattr_names(path)
	local output, err = command("xattr", { path })
	if not output or not output.status.success then
		return nil, clean_error(output, err)
	end
	local names = {}
	for name in output.stdout:gmatch("[^\r\n]+") do
		names[#names + 1] = name
	end
	return names
end

-- Every preserved attribute's value as a hex dump, from one xattr run: each
-- name line ends with a colon and is followed by offset-prefixed hex lines.
-- The second result tells whether any identity attribute was present.
local function preserved_xattrs(path)
	local output, err = command("xattr", { "-l", "-x", path })
	if not output or not output.status.success then
		return nil, clean_error(output, err)
	end
	local attrs, name, identity = {}, nil, false
	for line in output.stdout:gmatch("[^\n]+") do
		if line:match("^%x%x%x%x%x%x%x%x$") or line:match("^%x%x%x%x%x%x%x%x  ") then
			if name then
				attrs[name] = attrs[name] .. line .. "\n"
			end
		else
			name = line:sub(1, -2)
			if FILESYSTEM_IDENTITY_XATTRS[name] then
				name, identity = nil, true
			else
				attrs[name] = ""
			end
		end
	end
	return attrs, identity
end

local function same_xattrs(expected, actual)
	for name, value in pairs(expected) do
		if actual[name] ~= value then
			return nil, "preserved extended attribute changed: " .. name
		end
	end
	for name in pairs(actual) do
		if expected[name] == nil then
			return nil, "unexpected preserved extended attribute: " .. name
		end
	end
	return true
end

-- Mode, owner, group, file flags and ACL entries, as "mode uid gid flags"
-- and the ACL lines. The staged clone must carry exactly the source's values
-- before it may replace it.
local function file_attributes(path)
	local listing, err = command("ls", { "-ledOn", path })
	if not listing or not listing.status.success then
		return nil, clean_error(listing, err)
	end
	-- The first line also holds the link count, size and times, which
	-- legitimately differ, and an @ or + that marks attributes or an ACL.
	local mode, owner, group, flags = listing.stdout:match("^(%S+)%s+%d+%s+(%d+)%s+(%d+)%s+(%S+)")
	if not mode then
		return nil, "could not read file attributes"
	end
	local acl = listing.stdout:gsub("^[^\n]*\n?", ""):gsub("%s+$", "")
	return table.concat({ mode:gsub("[@+]$", ""), owner, group, flags }, " ") .. "\n" .. acl
end

local neutral_epoch_cache

local function neutral_epoch()
	if neutral_epoch_cache then
		return neutral_epoch_cache
	end
	local output, err = command("date", { "-j", "-f", "%Y%m%d%H%M.%S", NEUTRAL_TOUCH_TIME, "+%s" })
	if not output or not output.status.success then
		return nil, clean_error(output, err)
	end
	neutral_epoch_cache = output.stdout:match("(%-?%d+)")
	return neutral_epoch_cache or nil, "could not calculate neutral timestamp"
end

-- Returns whether any identity attribute was present.
local function remove_identity_xattrs(path)
	local names, err = xattr_names(path)
	if not names then
		return nil, err
	end
	local removed = false
	for _, name in ipairs(names) do
		if FILESYSTEM_IDENTITY_XATTRS[name] then
			local output, delete_err = command("xattr", { "-d", name, path })
			if not output or not output.status.success then
				return nil, clean_error(output, delete_err)
			end
			removed = true
		end
	end
	return removed
end

-- Sets a file's creation date through Foundation; the date and the path are
-- arguments, never part of the script.
local SET_CREATION_DATE = [[
ObjC.import("Foundation")
function run(argv) {
	const date = $.NSDate.dateWithTimeIntervalSince1970(Number(argv[0]))
	const attributes = $.NSDictionary.dictionaryWithObjectForKey(date, $.NSFileCreationDate)
	if (!$.NSFileManager.defaultManager.setAttributesOfItemAtPathError(attributes, argv[1], Ref())) {
		throw new Error("could not set the creation date")
	}
}
]]

local function neutralize_filesystem(path)
	local removed, err = remove_identity_xattrs(path)
	if removed == nil then
		return nil, err
	end
	local output, touch_err = command("touch", { "-t", NEUTRAL_TOUCH_TIME, path })
	if not output or not output.status.success then
		return nil, clean_error(output, touch_err)
	end
	return true
end

-- APFS and HFS+ move the creation date back with the modification date;
-- exFAT and FAT (camera cards, USB drives) keep it, so it is set directly.
local function neutralize_creation_date(path)
	local expected, err = neutral_epoch()
	if not expected then
		return nil, err
	end
	local output
	output, err = command("osascript", { "-l", "JavaScript", "-e", SET_CREATION_DATE, expected, path })
	if not output or not output.status.success then
		return nil, "creation date could not be neutralized: " .. clean_error(output, err)
	end
	return true
end

-- When a file is replaced by rename, macOS re-applies kMDItemWhereFroms and
-- kMDItemDownloadedDate from the Spotlight index of the replaced file a few
-- seconds later. Removing them from the original and re-importing it first
-- leaves the index nothing to re-apply, once the index has taken the import:
-- mdimport returns before that, so the index is polled.
local function forget_filesystem_identity(path)
	local removed, err = remove_identity_xattrs(path)
	if removed == nil then
		return nil, err
	end
	-- With Spotlight disabled the import fails, and nothing is re-applied.
	local imported = removed and command("mdimport", { path })
	if not (imported and imported.status.success) then
		return true
	end
	for _ = 1, 50 do
		local listed = command("mdls", { "-raw", "-name", "kMDItemWhereFroms", "-name", "kMDItemDownloadedDate", path })
		if not (listed and listed.status.success) or listed.stdout:gsub("%(null%)", ""):gsub("%z", "") == "" then
			return true
		end
		ya.sleep(0.1)
	end
	return nil, "Spotlight still lists the download source"
end

-- Whether the modification and creation dates are the neutral ones.
local function dates_neutral(path)
	local expected, epoch_err = neutral_epoch()
	if not expected then
		return nil, epoch_err
	end
	local dates, dates_err = command("stat", { "-f", "%m|%B", path })
	if not dates or not dates.status.success then
		return nil, clean_error(dates, dates_err)
	end
	return dates.stdout:gsub("%s+$", "") == expected .. "|" .. expected
end

-- Whether the file's filesystem metadata is clean, and what cleaning changes
-- in it, by name.
local function filesystem_clean(path)
	local names, err = xattr_names(path)
	if not names then
		return nil, err
	end
	local changes = {}
	for _, name in ipairs(names) do
		if FILESYSTEM_IDENTITY_XATTRS[name] then
			changes[#changes + 1] = FILESYSTEM_IDENTITY_XATTRS[name]
		end
	end
	local neutral, dates_err = dates_neutral(path)
	if neutral == nil then
		return nil, dates_err
	elseif not neutral then
		changes[#changes + 1] = "File dates"
	end
	return #changes == 0, changes
end

local sha256_command

-- macOS's sha256 uses the CPU's SHA instructions and is about four times
-- faster than the Perl shasum, which remains the fallback.
local function file_sha256(path)
	if not sha256_command then
		local cha = fs.cha(Url("/sbin/sha256"), false)
		sha256_command = cha and not cha.is_dir and { "/sbin/sha256", "-q" } or { "shasum", "-a", "256" }
	end
	local args = table.move(sha256_command, 2, #sha256_command, 1, {})
	args[#args + 1] = path
	local output, err = command(sha256_command[1], args, media_timeout(path))
	if not output or not output.status.success then
		return nil, clean_error(output, err)
	end
	local digest = output.stdout:match("^(%x+)")
	if not digest or #digest ~= 64 then
		return nil, "invalid content hash"
	end
	return digest
end

-- Nanosecond ctime covers xattr and ACL edits in addition to content
-- changes. Paths are absolute, so BSD stat cannot parse them as options.
local FINGERPRINT_STAT = "%d|%i|%z|%.9Fm|%.9Fc|%.9FB"

-- value: the stat fields when the caller already read them.
local function source_fingerprint(path, value)
	if not value then
		local output, err = command("stat", { "-f", FINGERPRINT_STAT, path })
		if not output or not output.status.success then
			return nil, clean_error(output, err)
		end
		value = output.stdout:gsub("%s+$", "")
	end
	if not value:match("^%d+|%d+|%d+|%-?[%d.]+|%-?[%d.]+|%-?[%d.]+$") then
		return nil, "invalid source fingerprint"
	end
	local digest, hash_err = file_sha256(path)
	if not digest then
		return nil, hash_err
	end
	return value .. "|" .. digest
end

-- Decoded frames are compared only with this run's own decode, so a fast
-- 128-bit hash is enough; SHA-256 cost more than decoding large photos.
local function deterministic_framehash(path, map)
	local output, err = command("ffmpeg", {
		"-hide_banner",
		"-loglevel",
		"error",
		"-i",
		path,
		"-map",
		map or "0:v:0",
		"-f",
		"framehash",
		"-hash",
		"murmur3",
		"-",
	}, media_timeout(path))
	if not output or not output.status.success then
		local detail = clean_error(output, err):match("[^\r\n]*[^%s][^\r\n]*") or ""
		return nil,
			"FFmpeg could not decode the image: " .. detail:gsub("^%[[^%]]+%]%s*", ""):gsub("^%[[^%]]+%]%s*", "")
	end
	local records = {}
	for line in output.stdout:gmatch("[^\r\n]+") do
		if line:match("^#") or line:match("^%d+,") then
			records[#records + 1] = line
		end
	end
	if #records == 0 then
		return nil, "FFmpeg returned no decoded frame records"
	end
	return table.concat(records, "\n")
end

-- One hash over every decoded frame of a stream, for comparing long audio
-- and video without keeping per-frame records. Untrimmed keeps the samples
-- that encoder delay and padding would cut: FFmpeg trims an MP3's last frame
-- only when it finds the end of the audio, which unknown trailing tags hide.
local function decoded_hash(path, map, untrimmed)
	local args = { "-hide_banner", "-loglevel", "error" }
	if untrimmed then
		args[#args + 1] = "-flags2"
		args[#args + 1] = "+skip_manual"
	end
	for _, arg in ipairs({ "-i", path, "-map", map, "-f", "hash", "-hash", "murmur3", "-" }) do
		args[#args + 1] = arg
	end
	local output, err = command("ffmpeg", args, media_timeout(path))
	local digest = output and output.status.success and output.stdout:match("murmur3=(%x+)")
	if not digest then
		local detail = clean_error(output, err):match("[^\r\n]*[^%s][^\r\n]*") or ""
		return nil, "FFmpeg could not decode the media: " .. detail:gsub("^%[[^%]]+%]%s*", "")
	end
	return digest
end

-- The decoder's view of the first video stream. The frames themselves are
-- counted and hashed by deterministic_framehash, which every caller runs.
local function still_stream_manifest(path)
	local fields =
		"codec_name,profile,width,height,coded_width,coded_height,pix_fmt,color_range,color_space,color_transfer,color_primaries,extradata_size,extradata_hash,avg_frame_rate,time_base"
	local output, err = bounded_output("ffprobe", {
		"-v",
		"error",
		"-bitexact",
		"-select_streams",
		"v:0",
		"-noprivate",
		"-show_entries",
		"stream=" .. fields .. ":stream_side_data=side_data_type",
		"-show_data_hash",
		"sha256",
		"-of",
		"json=compact=1:string_validation=fail",
		"--",
		path,
	}, media_timeout(path))
	if not output then
		return nil, err
	end
	-- FFmpeg reports an animated WebP's EXIF chunk as side data; its removal
	-- is the point.
	output = output:gsub('{ "side_data_type": "EXIF metadata" },?%s*', ""):gsub(",(%s*%])", "%1")
	return (output:gsub(',%s*"side_data_list": %[%s*%]', ""))
end

-- The decoded frames and the decoder's view of a still image.
local function still_capture(path)
	local decoded, err = deterministic_framehash(path)
	if not decoded then
		return nil, nil, err
	end
	local stream
	stream, err = still_stream_manifest(path)
	if not stream then
		return nil, nil, err
	end
	return decoded, stream
end

-- An equivalent() that compares the named capture fields; message is a
-- format for the first field that differs.
local function compare_fields(message, fields)
	return function(before, after)
		for _, field in ipairs(fields) do
			if before[field] ~= after[field] then
				return nil, message:format(field)
			end
		end
		return true
	end
end

local function apng_timeline_manifest(path)
	local frames, frames_err = bounded_output("ffprobe", {
		"-v",
		"error",
		"-bitexact",
		"-select_streams",
		"v:0",
		"-show_frames",
		"-show_entries",
		"frame=media_type,stream_index,key_frame,pts,pts_time,pkt_duration,pkt_duration_time,width,height",
		"-of",
		"compact=p=0:nk=0:escape=c",
		"--",
		path,
	}, media_timeout(path))
	if not frames then
		return nil, frames_err
	end
	local normalized = {}
	for line in frames:gmatch("[^\r\n]+") do
		-- FFprobe surfaces PNG text chunks as frame tags; they are removable,
		-- unlike the timeline fields preceding them.
		normalized[#normalized + 1] = line:match("^(.-)|tag:") or line
	end
	if #normalized == 0 then
		return nil, "FFprobe returned no APNG frame records"
	end
	return "apng-timeline-v2\n" .. table.concat(normalized, "\n")
end

local function icc_profile(path)
	local output, err = command("exiftool", { "-b", "-ICC_Profile", "--", path })
	if not output or not output.status.success then
		return nil, clean_error(output, err)
	end
	return output.stdout
end

local function as_set(list)
	local result = {}
	for _, item in ipairs(list) do
		result[item] = true
	end
	return result
end

local FILE_BASICS = { "File:FileType", "File:FileTypeExtension", "File:MIMEType" }

local function with_basics(list)
	local result = {}
	for _, item in ipairs(FILE_BASICS) do
		result[#result + 1] = item
	end
	for _, item in ipairs(list) do
		result[#result + 1] = item
	end
	return result
end

-- Copy data without the given inclusive byte ranges, which must be ordered
-- and disjoint.
local function protected_bytes(data, ranges)
	local parts, offset = {}, 1
	for _, range in ipairs(ranges) do
		parts[#parts + 1] = data:sub(offset, range.start - 1)
		offset = range.finish + 1
	end
	parts[#parts + 1] = data:sub(offset)
	return table.concat(parts)
end

-- Apple's ImageIO scales an iPhone HDR gain map by two values in the Apple
-- maker note (HDRHeadroom and HDRGain); without them the photo shows with
-- much less HDR brightness. For photos with a gain map, those two values and
-- the maker note version are kept as a minimal maker note of their own and
-- every other maker note value is dropped. tiff starts at the TIFF header.
local function apple_hdr_makernote(tiff)
	local ok, result = pcall(function()
		local endian = tiff:sub(1, 2) == "MM" and ">" or tiff:sub(1, 2) == "II" and "<"
		local function ifd(offset)
			local entries = {}
			for index = 0, string.unpack(endian .. "I2", tiff, offset + 1) - 1 do
				local tag, kind, count, value = string.unpack(endian .. "I2I2I4I4", tiff, offset + 3 + 12 * index)
				entries[tag] = { kind = kind, count = count, value = value }
			end
			return entries
		end
		local exif = endian and ifd(string.unpack(endian .. "I4", tiff, 5))[0x8769]
		local note = exif and ifd(exif.value)[0x927C]
		if not note or note.kind ~= 7 then
			return nil
		end
		-- Apple maker notes are big-endian with offsets from their own start.
		local data = tiff:sub(note.value + 1, note.value + note.count)
		if data:sub(1, 14) ~= "Apple iOS\0\0\1MM" then
			return nil
		end
		local tags = {}
		for index = 0, string.unpack(">I2", data, 15) - 1 do
			local at = 17 + 12 * index
			local tag, kind, count, value = string.unpack(">I2I2I4I4", data, at)
			tags[tag] = { kind = kind, count = count, value = value, raw = data:sub(at + 8, at + 11) }
		end
		local version, headroom, gain = tags[0x0001], tags[0x0021], tags[0x0030]
		if
			not (version and headroom and gain)
			or version.kind ~= 9
			or version.count ~= 1
			or headroom.kind ~= 10
			or headroom.count ~= 1
			or gain.kind ~= 10
			or gain.count ~= 1
		then
			return nil
		end
		local values = data:sub(headroom.value + 1, headroom.value + 8) .. data:sub(gain.value + 1, gain.value + 8)
		if #values ~= 16 then
			return nil
		end
		local base = 14 + 2 + 3 * 12 + 4
		return data:sub(1, 14)
			.. string.pack(">I2", 3)
			.. string.pack(">I2I2I4", 0x0001, 9, 1)
			.. version.raw
			.. string.pack(">I2I2I4I4", 0x0021, 10, 1, base)
			.. string.pack(">I2I2I4I4", 0x0030, 10, 1, base + 8)
			.. string.pack(">I4", 0)
			.. values
	end)
	return ok and result or nil
end

-- A TIFF structure that holds nothing but the given maker note.
local function makernote_exif(makernote)
	return "MM\0\42"
		.. string.pack(">I4I2", 8, 1)
		.. string.pack(">I2I2I4I4", 0x8769, 4, 1, 26)
		.. string.pack(">I4I2", 0, 1)
		.. string.pack(">I2I2I4I4", 0x927C, 7, #makernote, 44)
		.. string.pack(">I4", 0)
		.. makernote
end

-- Filled in after the policies exist: Motion Photo videos are cleaned and
-- checked with the QuickTime policy.
local EMBEDDED = {}

-- JPEG ---------------------------------------------------------------------

-- ExifTool performs the JPEG rewrite: -all= drops every metadata segment,
-- the JFIF, Adobe (CMYK colour transform) and ICC segments are kept in place,
-- and only rendering-relevant EXIF values are copied back.
local JPEG_RESTORED_TAGS = {
	"IFD0:Orientation",
	"IFD0:XResolution",
	"IFD0:YResolution",
	"IFD0:ResolutionUnit",
	"IFD0:YCbCrPositioning",
}

-- Restored only when the source declares a colour space: creating an EXIF
-- IFD makes ExifTool add ColorSpace=Uncalibrated, which viewers may read as
-- "not sRGB", and the interoperability index only matters alongside it.
local JPEG_RESTORED_COLOR_TAGS = {
	"ExifIFD:ColorSpace",
	"ExifIFD:ExifImageWidth",
	"ExifIFD:ExifImageHeight",
	"ExifIFD:ComponentsConfiguration",
	"ExifIFD:ExifVersion",
	"ExifIFD:FlashpixVersion",
	"InteropIFD:InteropIndex",
	"InteropIFD:InteropVersion",
}

local JPEG_SPEC = metadata_spec({
	keep = with_basics({
		"File:ImageWidth",
		"File:ImageHeight",
		"File:EncodingProcess",
		"File:BitsPerSample",
		"File:ColorComponents",
		"File:YCbCrSubSampling",
		"JFIF:JFIFVersion",
		"JFIF:ResolutionUnit",
		"JFIF:XResolution",
		"JFIF:YResolution",
		"Adobe:*",
		"^ICC:*",
		"IFD0:Orientation",
		"IFD0:XResolution",
		"IFD0:YResolution",
		"IFD0:ResolutionUnit",
		"IFD0:YCbCrPositioning",
		"ExifIFD:ColorSpace",
	}),
	free = {
		"File:ExifByteOrder",
		-- Restored with ColorSpace; viewers ignore it on its own.
		"InteropIFD:InteropIndex",
		-- Informational for compressed JPEG; ExifTool normalizes malformed values.
		"ExifIFD:ComponentsConfiguration",
		"ExifIFD:ExifImageWidth",
		"ExifIFD:ExifImageHeight",
		"ExifIFD:ExifVersion",
		"ExifIFD:FlashpixVersion",
		"InteropIFD:InteropVersion",
		-- The rebuilt index and directory of a kept HDR gain map; the MPF
		-- checks prove their values.
		"MPF0:*",
		"^MPImage%d+$:*",
		"APP2:UniformResourceName",
		"XMP-hdrgm:Version",
		"XMP-GContainer:*",
		"Google:GainMapImage",
		"Apple:MakerNoteVersion",
		"Apple:HDRHeadroom",
		"Apple:HDRGain",
		-- A kept Samsung Motion Photo video, checked on its own.
		"Samsung:EmbeddedVideoType",
		"Samsung:EmbeddedVideoFile",
		-- A kept Google Motion Photo: its rebuilt XMP and the video.
		"XMP-GCamera:MotionPhoto",
		"XMP-GCamera:MotionPhotoVersion",
		"XMP-GCamera:MotionPhotoPresentationTimestampUs",
		"XMP-GCamera:MicroVideo",
		"XMP-GCamera:MicroVideoVersion",
		"XMP-GCamera:MicroVideoOffset",
		"XMP-GCamera:MicroVideoPresentationTimestampUs",
		"Google:MotionPhotoVideo",
	},
	-- ExifTool creates these mandatory EXIF values when it rebuilds an IFD.
	defaults = {
		"IFD0:XResolution",
		"IFD0:YResolution",
		"IFD0:ResolutionUnit",
		"IFD0:YCbCrPositioning",
	},
})

local function photoshop_has_paths(payload)
	-- Image resources 2000-2999 hold vector and clipping paths, which are part
	-- of print workflows rather than identity metadata.
	local position = 15
	while position + 11 <= #payload do
		if payload:sub(position, position + 3) ~= "8BIM" then
			return false
		end
		local id = be_u16(payload, position + 4)
		local name_length = payload:byte(position + 6)
		if not id or not name_length then
			return false
		end
		local name_total = name_length + 1
		name_total = name_total + name_total % 2
		local size = be_u32_at(payload, position + 6 + name_total)
		if not size then
			return false
		end
		if id >= 2000 and id <= 2999 then
			return true
		end
		position = position + 6 + name_total + 4 + size + size % 2
	end
	return false
end

local function jpeg_segment_kind(marker, payload)
	if marker == 0xE0 then
		return payload:sub(1, 5) == "JFIF\0" and "jfif" or "app0"
	elseif marker == 0xE1 then
		if payload:sub(1, 6) == "Exif\0\0" then
			return "exif"
		elseif payload:sub(1, 29) == "http://ns.adobe.com/xap/1.0/\0" then
			return "xmp"
		elseif payload:sub(1, 35) == "http://ns.adobe.com/xmp/extension/\0" then
			return "xmp_extension"
		end
		return "app1"
	elseif marker == 0xE2 then
		if payload:sub(1, 12) == "ICC_PROFILE\0" then
			return "icc"
		elseif payload:sub(1, 4) == "MPF\0" then
			return "mpf"
		elseif payload:sub(1, 28) == "urn:iso:std:iso:ts:21496:-1\0" then
			return "gainmap"
		end
		return "app2"
	elseif marker == 0xED then
		return "app13"
	elseif marker == 0xEE then
		return payload:sub(1, 5) == "Adobe" and "adobe" or "app14"
	elseif marker >= 0xE3 and marker <= 0xEF then
		return "app" .. tostring(marker - 0xE0)
	elseif marker == 0xFE then
		return "comment"
	end
	return "protected"
end

-- Parse a JPEG file, or the given bytes of an embedded JPEG.
-- ExifTool may split a large ICC profile into segments of other sizes, so
-- the profile is compared reassembled. A malformed sequence is compared
-- segment by segment.
-- Apple display profiles, which macOS embeds in screenshots, carry the
-- display's serial number and manufacture date in their private mmod tag,
-- which no colour management reads. Those eight bytes are zeroed in place,
-- and the profile ID (an MD5 checksum) becomes zero, which means "not
-- computed".
local ICC = {}

-- Calibration tools (DisplayCAL, ArgyllCMS) record the display's EDID in a
-- metadata dictionary; its serial number, EDID hash and manufacture date
-- become zero digits in place. Other entries stay.
function ICC.dict(profile, offset, length)
	local tag = profile:sub(offset + 1, offset + length)
	if #tag < 16 or tag:sub(1, 4) ~= "dict" then
		return profile
	end
	local count, size = string.unpack(">I4I4", tag, 9)
	if (size ~= 16 and size ~= 24 and size ~= 32) or count > 4096 or 16 + count * size > #tag then
		return profile
	end
	for index = 0, count - 1 do
		local name_at, name_size, value_at, value_size = string.unpack(">I4I4I4I4", tag, 17 + index * size)
		local name = name_at + name_size <= #tag and tag:sub(name_at + 1, name_at + name_size):gsub("%z(.)", "%1")
		if
			name
			and (name:lower():find("serial", 1, true) or name == "EDID_hash" or name == "EDID_date")
			and value_size % 2 == 0
			and value_at + value_size <= #tag
		then
			local start = offset + value_at
			profile = profile:sub(1, start)
				.. string.rep("\0\48", value_size // 2)
				.. profile:sub(start + value_size + 1)
		end
	end
	return profile
end

-- Whether ExifTool reports a tag ICC.clean may patch: Apple's mmod
-- (MakeAndModel) or a metadata dictionary entry.
function ICC.reported(inventory)
	if inventory.values["ICC_Profile:MakeAndModel"] then
		return true
	end
	for _, key in ipairs(inventory.entries) do
		if key:find("^ICC%-meta:") then
			return true
		end
	end
	return false
end

-- The cleaned profile, or false when there is nothing to change.
function ICC.clean(profile)
	if #profile < 132 or profile:sub(37, 40) ~= "acsp" then
		return false
	end
	local count = string.unpack(">I4", profile, 129)
	if count > 1024 or 132 + 12 * count > #profile then
		return false
	end
	local patched = profile
	for index = 0, count - 1 do
		local signature, offset, length = string.unpack(">c4I4I4", profile, 133 + 12 * index)
		if
			signature == "mmod"
			and length >= 24
			and offset + length <= #profile
			and profile:sub(offset + 1, offset + 4) == "mmod"
			and profile:sub(offset + 17, offset + 24) ~= string.rep("\0", 8)
		then
			patched = patched:sub(1, offset + 16) .. string.rep("\0", 8) .. patched:sub(offset + 25)
		elseif signature == "meta" and offset + length <= #profile then
			patched = ICC.dict(patched, offset, length)
		end
	end
	if patched == profile then
		return false
	end
	return patched:sub(1, 84) .. string.rep("\0", 16) .. patched:sub(101)
end

-- A zlib stream of stored (uncompressed) deflate blocks.
function ICC.zlib(data)
	local parts, a, b = { "\120\1" }, 1, 0
	for index = 1, #data do
		a = (a + data:byte(index)) % 65521
		b = (b + a) % 65521
	end
	local position = 1
	repeat
		local block = data:sub(position, position + 65534)
		position = position + #block
		parts[#parts + 1] = string.pack("<BI2I2", position > #data and 1 or 0, #block, #block ~ 0xFFFF) .. block
	until position > #data
	parts[#parts + 1] = string.pack(">I4", b << 16 | a)
	return table.concat(parts)
end

-- A GIF ICC application payload (sub-blocks, then a terminator) patched
-- with the same sub-block sizes, or false.
function ICC.gif(block)
	local sizes, parts, position = {}, {}, 1
	while block:byte(position) and block:byte(position) > 0 do
		local length = block:byte(position)
		sizes[#sizes + 1], parts[#parts + 1] = length, block:sub(position + 1, position + length)
		position = position + 1 + length
	end
	local cleaned = ICC.clean(table.concat(parts))
	if not cleaned then
		return false
	end
	local rebuilt, offset = {}, 1
	for index, length in ipairs(sizes) do
		rebuilt[index] = string.char(length) .. cleaned:sub(offset, offset + length - 1)
		offset = offset + length
	end
	return table.concat(rebuilt) .. block:sub(position)
end

local function jpeg_icc_profile(segments)
	local parts, total = {}, nil
	for _, segment in ipairs(segments) do
		local sequence, count = segment:byte(17, 18)
		total = total or count
		if not sequence or count ~= total or sequence < 1 or sequence > count or parts[sequence] then
			return "segments\0" .. table.concat(segments)
		end
		parts[sequence] = segment:sub(19)
	end
	for sequence = 1, total or 0 do
		if not parts[sequence] then
			return "segments\0" .. table.concat(segments)
		end
	end
	return "profile\0" .. table.concat(parts, "", 1, total or 0)
end

-- The reassembled profile as it is after cleaning.
function ICC.jpeg_planned(icc)
	if icc:sub(1, 8) ~= "profile\0" then
		return icc
	end
	return "profile\0" .. (ICC.clean(icc:sub(9)) or icc:sub(9))
end

-- JPEG data with its ICC segments patched in place, or nil when the profile
-- needs no change. Segments may be stored out of sequence order.
function ICC.jpeg_patch(parsed)
	local planned = ICC.jpeg_planned(parsed.icc)
	if planned == parsed.icc then
		return nil
	end
	local profile, lengths, offsets = planned:sub(9), {}, {}
	for _, span in ipairs(parsed.icc_spans) do
		lengths[parsed.data:byte(span.start + 16)] = span.finish - span.start - 17
	end
	local offset = 0
	for sequence = 1, #lengths do
		offsets[sequence], offset = offset, offset + lengths[sequence]
	end
	local parts, position = {}, 1
	for _, span in ipairs(parsed.icc_spans) do
		local sequence = parsed.data:byte(span.start + 16)
		parts[#parts + 1] = parsed.data:sub(position, span.start + 17)
		parts[#parts + 1] = profile:sub(offsets[sequence] + 1, offsets[sequence] + lengths[sequence])
		position = span.finish + 1
	end
	parts[#parts + 1] = parsed.data:sub(position)
	return table.concat(parts)
end

local function jpeg_parse(path, data)
	local err
	if not data then
		data, err = read_file(path, LIMIT.JPEG_BYTES, "JPEG")
		if not data then
			return nil, err
		end
	end
	if data:sub(1, 2) ~= "\255\216" then
		return nil, "invalid JPEG signature"
	end
	local parsed = {
		data = data,
		protected = { "\255\216" },
		jfif = {},
		icc = {},
		icc_spans = {},
		jfif_planned = {},
		jfif_spans = {},
		adobe = {},
		removable = {},
		ranges = {},
	}
	local position, size = 3, #data
	while true do
		if data:byte(position) ~= 0xFF then
			return nil, "invalid JPEG marker"
		end
		while data:byte(position + 1) == 0xFF do
			position = position + 1
		end
		local marker = data:byte(position + 1)
		if not marker then
			return nil, "truncated JPEG"
		end
		if marker == 0xD9 then
			parsed.protected[#parsed.protected + 1] = "\255\217"
			parsed.trailer = size - (position + 1)
			break
		elseif marker == 0x01 or (marker >= 0xD0 and marker <= 0xD7) then
			parsed.protected[#parsed.protected + 1] = data:sub(position, position + 1)
			position = position + 2
		elseif marker == 0xD8 or marker == 0x00 then
			return nil, "unexpected JPEG marker"
		else
			local length = be_u16(data, position + 2)
			if not length or length < 2 or position + 1 + length > size then
				return nil, "truncated JPEG segment"
			end
			local finish = position + 1 + length
			local segment = data:sub(position, finish)
			local payload = segment:sub(5)
			local kind = jpeg_segment_kind(marker, payload)
			if kind == "protected" or kind == "jfif" or kind == "icc" or kind == "adobe" then
				local list = kind == "protected" and parsed.protected or parsed[kind]
				list[#list + 1] = segment
				if kind == "icc" then
					parsed.icc_spans[#parsed.icc_spans + 1] = { start = position, finish = finish }
				elseif kind == "jfif" then
					-- A JFIF segment can carry its own thumbnail, which may show
					-- the image before a crop; the plan keeps only its header.
					local planned = #payload > 14 and "\255\224\0\16" .. payload:sub(1, 12) .. "\0\0" or segment
					parsed.jfif_planned[#parsed.jfif_planned + 1] = planned
					parsed.jfif_spans[#parsed.jfif_spans + 1] = { start = position, finish = finish, planned = planned }
				end
			else
				parsed.removable[#parsed.removable + 1] = kind
				parsed.ranges[#parsed.ranges + 1] =
					{ start = position, finish = finish, kind = kind, payload = payload }
				if kind == "mpf" then
					parsed.mpf = true
				elseif kind == "app13" and payload:sub(1, 14) == "Photoshop 3.0\0" and photoshop_has_paths(payload) then
					parsed.paths = true
				end
			end
			position = finish + 1
			if marker == 0xDA then
				-- Entropy-coded data runs to the next marker that is neither a
				-- stuffed zero nor a restart marker. Some encoders and cut-off
				-- copies end the scan with the file and no end-of-image marker;
				-- decoders finish the image there, and the cleaned file gets
				-- the marker ExifTool needs to write it.
				local scan_start = position
				while true do
					local ff = data:find("\255", position, true)
					if not ff then
						position = size + 1
						parsed.trailer = 0
						break
					elseif ff == size then
						return nil, "truncated JPEG scan"
					end
					local following = data:byte(ff + 1)
					if following == 0x00 or (following >= 0xD0 and following <= 0xD7) then
						position = ff + 2
					else
						position = ff
						break
					end
				end
				parsed.protected[#parsed.protected + 1] = data:sub(scan_start, position - 1)
				if position > size then
					parsed.protected[#parsed.protected + 1] = "\255\217"
					parsed.missing_eoi = true
					break
				end
			end
		end
	end
	parsed.icc = jpeg_icc_profile(parsed.icc)
	for _, field in ipairs({ "protected", "jfif", "jfif_planned", "adobe" }) do
		parsed[field] = table.concat(parsed[field])
	end
	return parsed
end

-- An MPF index (CIPA DC-007) lists images appended after the primary JPEG.
-- HDR gain maps (Ultra HDR, ISO 21496-1 and Apple) are kept with only their
-- gain-map metadata; large thumbnails duplicate the primary and are dropped.
-- Any other appended image, or bytes the index does not explain, is refused.
-- The primary is cleaned like any JPEG and then gets a rebuilt MPF index, the
-- ISO 21496-1 version marker and, for Ultra HDR, a minimal XMP directory.
local MPF = {}

local GAINMAP_SPEC = metadata_spec({
	free = with_basics({
		"File:ImageWidth",
		"File:ImageHeight",
		"File:EncodingProcess",
		"File:BitsPerSample",
		"File:ColorComponents",
		"File:YCbCrSubSampling",
		"JFIF:JFIFVersion",
		"JFIF:ResolutionUnit",
		"JFIF:XResolution",
		"JFIF:YResolution",
		"^ICC:*",
		"APP2:UniformResourceName",
		"XMP-x:XMPToolkit",
		"XMP-hdrgm:*",
		"XMP-HDRGainMap:*",
		"XMP-apdi:NativeFormat",
		"XMP-apdi:StoredFormat",
		"XMP-apdi:AuxiliaryImageType",
	}),
})

function MPF.segment(marker, payload)
	return "\255" .. string.char(marker) .. string.pack(">I2", #payload + 2) .. payload
end

-- The image entries of the MPF segment, with absolute 0-based offsets.
function MPF.entries(range)
	local payload = range.payload
	local order = payload:sub(5, 8)
	local endian = order == "MM\0*" and ">" or order == "II*\0" and "<"
	if not endian then
		return nil
	end
	local ifd = string.unpack(endian .. "I4", payload, 9)
	local count = string.unpack(endian .. "I2", payload, 5 + ifd)
	local images, list
	for index = 0, count - 1 do
		local tag, kind, total, value = string.unpack(endian .. "I2I2I4I4", payload, 7 + ifd + 12 * index)
		if tag == 0xB001 and kind == 4 and total == 1 then
			images = value
		elseif tag == 0xB002 and kind == 7 then
			list = { bytes = total, offset = value }
		end
	end
	if not images or not list or images < 1 or list.bytes ~= 16 * images then
		return nil
	end
	-- Offsets count from the TIFF header that follows "MPF\0".
	local header = range.start + 7
	local entries = {}
	for index = 0, images - 1 do
		local attributes, size, offset = string.unpack(endian .. "I4I4I4", payload, 5 + list.offset + 16 * index)
		entries[#entries + 1] = { attributes = attributes, size = size, start = offset == 0 and 0 or header + offset }
	end
	return entries
end

function MPF.is_gainmap(image)
	for _, range in ipairs(image.ranges) do
		if range.kind == "gainmap" then
			return true
		elseif
			range.kind == "xmp"
			and (
				range.payload:find("http://ns.adobe.com/hdr-gain-map/1.0/", 1, true)
				or range.payload:find("urn:com:apple:photo:2020:aux:hdrgainmap", 1, true)
			)
		then
			return true
		end
	end
	return false
end

-- Split the appended images of a parsed JPEG and classify them.
-- Samsung's trailer: data blocks, then an SEFH directory, its length and
-- "SEFT". Entries that only describe the shot (capture time, mobile country,
-- path hash, capture mode) are dropped and the Motion Photo video is kept;
-- any other entry (Selective Focus images, depth maps) is refused.
MPF.SAMSUNG_DROPPED = {
	Image_UTC_Data = true,
	MCC_Data = true,
	Original_Path_Hash_Key = true,
	Camera_Capture_Mode_Info = true,
	Camera_Scene_Info = true,
	Photo_HDR_Info = true,
	Color_Display_P3 = true,
	Burst_Shot_Info = true,
}

function MPF.samsung(data, primary_end)
	local ok, result, err = pcall(function()
		local length = string.unpack("<I4", data, #data - 7)
		local directory = #data - 8 - length + 1
		if directory <= primary_end + 1 or data:sub(directory, directory + 3) ~= "SEFH" then
			return nil, "invalid Samsung trailer"
		end
		local version, count = string.unpack("<I4I4", data, directory + 4)
		if 12 + 12 * count ~= length then
			return nil, "invalid Samsung trailer"
		end
		local trailer = { version = version }
		for index = 0, count - 1 do
			local _, kind, offset, size = string.unpack("<I2I2I4I4", data, directory + 12 + 12 * index)
			local start = directory - offset
			if start <= primary_end or size < 8 or start + size > directory then
				return nil, "invalid Samsung trailer"
			end
			local name_length = string.unpack("<I4", data, start + 4)
			local name = data:sub(start + 8, start + 7 + name_length)
			if name == "MotionPhoto_Data" and not trailer.video and 8 + name_length < size then
				trailer.kind, trailer.header = kind, data:sub(start, start + 7 + name_length)
				trailer.video = data:sub(start + 8 + name_length, start + size - 1)
			elseif not MPF.SAMSUNG_DROPPED[name] then
				return nil, "unsupported Samsung trailer entry " .. name
			end
		end
		return trailer
	end)
	if not ok then
		return nil, "invalid Samsung trailer"
	end
	return result, err
end

-- The trailer that holds only the given (cleaned) Motion Photo video.
function MPF.samsung_trailer(trailer, video)
	local block = trailer.header .. video
	local directory = "SEFH"
		.. string.pack("<I4I4", trailer.version, 1)
		.. string.pack("<I2I2I4I4", 0, trailer.kind, #block, #block)
	return block .. directory .. string.pack("<I4", #directory) .. "SEFT"
end

-- Everything after the primary image goes, except a gain map that the MPF
-- index points to. Cameras leave previews, padding and even stale card or
-- computer data there; no reader shows it. Containers that hold something a
-- reader uses (Samsung trailers, Motion Photo videos, depth maps, stereo or
-- panorama frames) are refused instead.
function MPF.split(parsed)
	local data, mpf, declared = parsed.data, nil, nil
	for _, range in ipairs(parsed.ranges) do
		if range.kind == "mpf" then
			if mpf then
				return nil, "multiple JPEG MPF segments"
			end
			mpf = range
		elseif range.kind == "xmp" then
			local motion, err = MPF.motion_xmp(range.payload)
			if err then
				return nil, err
			end
			declared = declared or motion
		end
	end
	local primary_end = #data - parsed.trailer
	local samsung
	if data:sub(-4) == "SEFT" then
		if declared then
			return nil, "Samsung trailer with a Google Motion Photo is unsupported"
		end
		local err
		samsung, err = MPF.samsung(data, primary_end)
		if not samsung then
			return nil, err
		end
	elseif not declared and data:sub(primary_end + 1, primary_end + 64):find("ftyp", 1, true) then
		return nil, "JPEG with an undeclared appended video is unsupported"
	end
	local split =
		{ images = {}, primary_attributes = 0x030000, primary_end = primary_end, dropped = primary_end < #data }
	local gainmaps = 0
	if mpf then
		local ok, entries = pcall(MPF.entries, mpf)
		if not ok or not entries or entries[1].start ~= 0 then
			return nil, "invalid JPEG MPF index"
		end
		split.primary_attributes = entries[1].attributes
		for index = 2, #entries do
			local entry, kind = entries[index], entries[index].attributes & 0xFFFFFF
			if kind == 0x020001 or kind == 0x020002 or kind == 0x020003 then
				return nil, string.format("unsupported JPEG MPF image type 0x%06X", kind)
			end
			local image = entry.start >= primary_end
				and entry.size > 0
				and entry.start + entry.size <= #data
				and jpeg_parse(nil, data:sub(entry.start + 1, entry.start + entry.size))
			if image and image.trailer == 0 and MPF.is_gainmap(image) then
				image.kind, image.attributes, image.start = "gainmap", entry.attributes, entry.start
				gainmaps = gainmaps + 1
				split.images[#split.images + 1] = image
			end
		end
	end
	if gainmaps > 1 then
		return nil, "JPEG with more than one gain map is unsupported"
	end
	-- A Google Motion Photo video is the last bytes of the file.
	local gainmap = split.images[1]
	if declared then
		local start = #data - declared.length
		local after = gainmap and gainmap.start + #gainmap.data or primary_end
		if start < after or data:sub(start + 5, start + 8) ~= "ftyp" then
			return nil, "JPEG Motion Photo video not found where its XMP says"
		end
		declared.start, declared.video = start, data:sub(start + 1)
		split.motion = declared
	end
	-- Anything but a gain map that directly follows the primary, then the
	-- Motion Photo video, or a Samsung trailer with nothing but a clean video,
	-- is dropped.
	if samsung and samsung.video then
		if gainmap then
			return nil, "JPEG with both a gain map and a Samsung Motion Photo is unsupported"
		end
		split.samsung = samsung
		split.dropped = data:sub(primary_end + 1) ~= MPF.samsung_trailer(samsung, samsung.video)
			or not EMBEDDED.is_clean(samsung.video)
	else
		local position, exact = primary_end, true
		if gainmap then
			exact, position = gainmap.start == position, gainmap.start + #gainmap.data
		end
		if split.motion then
			exact, position = exact and split.motion.start == position, #data
		end
		split.dropped = not exact
			or position ~= #data
			or (split.motion ~= nil and not EMBEDDED.is_clean(split.motion.video))
	end
	for _, range in ipairs(parsed.ranges) do
		if range.kind == "xmp" then
			split.hdrgm = range.payload:match('hdrgm:Version="([%d.]+)"')
				or range.payload:match("<hdrgm:Version>([%d.]+)</hdrgm:Version>")
				or split.hdrgm
		elseif range.kind == "exif" and gainmaps > 0 then
			split.makernote = apple_hdr_makernote(range.payload:sub(7))
		elseif range.kind == "gainmap" then
			-- The primary carries only the ISO 21496-1 version numbers.
			if #range.payload > 40 then
				return nil, "unsupported ISO 21496-1 primary metadata"
			end
			split.iso = range.payload
		end
	end
	return split
end

function MPF.gainmap(split)
	for _, image in ipairs(split.images) do
		if image.kind == "gainmap" then
			return image
		end
	end
end

-- The gain map without anything but its image data and gain-map metadata.
function MPF.clean_gainmap(image)
	local removed = {}
	for _, range in ipairs(image.ranges) do
		if range.kind ~= "xmp" and range.kind ~= "gainmap" then
			removed[#removed + 1] = range
		end
	end
	return protected_bytes(image.data, removed)
end

-- Everything a reader uses from a gain map, for before/after comparison.
function MPF.gainmap_identity(image)
	local parts = { image.protected, image.jfif, image.icc, image.adobe }
	for _, range in ipairs(image.ranges) do
		if range.kind == "xmp" or range.kind == "gainmap" then
			parts[#parts + 1] = range.kind .. ":" .. range.payload
		end
	end
	return table.concat(parts, "\0")
end

-- The Motion Photo a primary's XMP declares, if any: Google's Motion Photo
-- (a Container item) or the older MicroVideo (an offset from the end). The
-- Container may otherwise list only the primary and a gain map.
-- In HEIF the primary's padding is the header of the video's mpvd box.
function MPF.motion_xmp(payload, heif)
	local motion, primary_padding
	for item in payload:gmatch("<Container:Item%s(.-)/?>") do
		local semantic = item:match('Item:Semantic="([^"]*)"')
		local mime, length = item:match('Item:Mime="([^"]*)"'), item:match('Item:Length="(%d+)"')
		local padding = item:match('Item:Padding="(%d+)"')
		if semantic == "Primary" and heif then
			primary_padding = padding
		elseif padding and padding ~= "0" then
			return nil, "Container item with padding is unsupported"
		elseif semantic == "MotionPhoto" and (mime == "video/mp4" or mime == "video/quicktime") and length then
			if motion then
				return nil, "JPEG with more than one Motion Photo video is unsupported"
			end
			motion = { kind = "motion", mime = mime, length = tonumber(length) }
		elseif semantic ~= "Primary" and semantic ~= "GainMap" then
			return nil, "JPEG with an embedded " .. tostring(semantic) .. " item is unsupported"
		end
	end
	local flag = payload:match(':MotionPhoto="(%d+)"')
	local version = payload:match(':MotionPhotoVersion="(%d+)"')
	local timestamp = payload:match(':MotionPhotoPresentationTimestampUs="(%-?%d+)"')
	local micro = payload:match(':MicroVideo="(%d+)"')
	if micro then
		local offset = payload:match(':MicroVideoOffset="(%d+)"')
		if motion or flag or micro ~= "1" or not offset then
			return nil, "unsupported JPEG MicroVideo"
		end
		return {
			kind = "micro",
			version = payload:match(':MicroVideoVersion="(%d+)"') or "1",
			timestamp = payload:match(':MicroVideoPresentationTimestampUs="(%-?%d+)"') or "-1",
			length = tonumber(offset),
		}
	end
	if motion or flag then
		if not motion or flag ~= "1" or not version or not timestamp then
			return nil, "unsupported JPEG Motion Photo"
		end
		motion.version, motion.timestamp, motion.primary_padding = version, timestamp, primary_padding
	end
	return motion
end

-- The primary's XMP for a kept gain map (Ultra HDR) and Motion Photo, with
-- the item lengths of the cleaned file.
function MPF.primary_xmp(split, gainmap)
	local motion = split.motion
	local attributes, items = {}, {}
	if split.hdrgm then
		attributes[#attributes + 1] = ' hdrgm:Version="' .. split.hdrgm .. '"'
	end
	if motion and motion.kind == "micro" then
		attributes[#attributes + 1] = ' GCamera:MicroVideo="1" GCamera:MicroVideoVersion="'
			.. motion.version
			.. '" GCamera:MicroVideoOffset="'
			.. tostring(motion.length)
			.. '" GCamera:MicroVideoPresentationTimestampUs="'
			.. motion.timestamp
			.. '"'
	elseif motion then
		attributes[#attributes + 1] = ' GCamera:MotionPhoto="1" GCamera:MotionPhotoVersion="'
			.. motion.version
			.. '" GCamera:MotionPhotoPresentationTimestampUs="'
			.. motion.timestamp
			.. '"'
	end
	local function item(semantic, mime, length, padding)
		items[#items + 1] = '<rdf:li rdf:parseType="Resource"><Container:Item Item:Semantic="'
			.. semantic
			.. '" Item:Mime="'
			.. mime
			.. '"'
			.. (length and ' Item:Length="' .. tostring(length) .. '"' or "")
			.. (padding and ' Item:Padding="' .. padding .. '"' or "")
			.. "/></rdf:li>"
	end
	if (split.hdrgm and gainmap) or (motion and motion.kind == "motion") then
		item("Primary", split.primary_mime or "image/jpeg", nil, motion and motion.primary_padding)
		if gainmap then
			item("GainMap", "image/jpeg", gainmap)
		end
		if motion and motion.kind == "motion" then
			item("MotionPhoto", motion.mime, motion.length)
		end
	end
	local body = #items > 0
			and "><Container:Directory><rdf:Seq>" .. table.concat(items) .. "</rdf:Seq></Container:Directory></rdf:Description>"
		or "/>"
	return "http://ns.adobe.com/xap/1.0/\0"
		.. '<x:xmpmeta xmlns:x="adobe:ns:meta/">'
		.. '<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">'
		.. '<rdf:Description rdf:about=""'
		.. (split.hdrgm and ' xmlns:hdrgm="http://ns.adobe.com/hdr-gain-map/1.0/"' or "")
		.. (motion and ' xmlns:GCamera="http://ns.google.com/photos/1.0/camera/"' or "")
		.. (#items > 0 and ' xmlns:Container="http://ns.google.com/photos/1.0/container/"' or "")
		.. (#items > 0 and ' xmlns:Item="http://ns.google.com/photos/1.0/container/item/"' or "")
		.. table.concat(attributes)
		.. body
		.. "</rdf:RDF></x:xmpmeta>"
end

-- The metadata segments a primary with a gain map or Motion Photo carries,
-- given the bytes in front of them, the primary's length without them and
-- the gain map size (nil without one).
function MPF.primary_segments(split, prefix, primary, gainmap)
	local segments = {}
	if split.hdrgm or split.motion then
		segments[#segments + 1] = MPF.segment(0xE1, MPF.primary_xmp(split, gainmap))
	end
	if split.iso and gainmap then
		segments[#segments + 1] = MPF.segment(0xE2, split.iso)
	end
	if not gainmap then
		return table.concat(segments)
	end
	local before = prefix + #table.concat(segments)
	local mpf_size = 4 + 4 + 50 + 32
	local total = primary + #table.concat(segments) + mpf_size
	local header = before + 8
	local index = "MM\0*"
		.. string.pack(">I4I2", 8, 3)
		.. string.pack(">I2I2I4", 0xB000, 7, 4)
		.. "0100"
		.. string.pack(">I2I2I4I4", 0xB001, 4, 1, 2)
		.. string.pack(">I2I2I4I4", 0xB002, 7, 32, 50)
		.. string.pack(">I4", 0)
		.. string.pack(">I4I4I4I2I2", split.primary_attributes, total, 0, 0, 0)
		.. string.pack(">I4I4I4I2I2", MPF.gainmap(split).attributes, gainmap, total - header, 0, 0)
	segments[#segments + 1] = MPF.segment(0xE2, "MPF\0" .. index)
	return table.concat(segments)
end

-- Where the rebuilt segments go: after the leading JFIF and EXIF segments.
function MPF.insertion_point(data)
	local position = 3
	while data:byte(position) == 0xFF and (data:byte(position + 1) == 0xE0 or data:byte(position + 1) == 0xE1) do
		local length = be_u16(data, position + 2)
		if not length then
			return nil
		end
		position = position + 2 + length
	end
	return position
end

-- Whether a primary with a gain map holds exactly the rebuilt segments.
function MPF.primary_clean(parsed, split)
	local gainmap = MPF.gainmap(split)
	local data, ranges = parsed.data, {}
	for _, range in ipairs(parsed.ranges) do
		if range.kind ~= "exif" then
			ranges[#ranges + 1] = range
		end
	end
	if #ranges == 0 then
		return false
	end
	local first, last = ranges[1].start, ranges[#ranges].finish
	for index = 2, #ranges do
		if ranges[index].start ~= ranges[index - 1].finish + 1 then
			return false
		end
	end
	local expected =
		MPF.primary_segments(split, first - 1, split.primary_end - (last - first + 1), gainmap and #gainmap.data)
	local without = data:sub(1, first - 1) .. data:sub(last + 1, split.primary_end)
	return MPF.insertion_point(without) == first and data:sub(first, last) == expected
end

local function jpeg_structure_clean(parsed)
	if ICC.jpeg_planned(parsed.icc) ~= parsed.icc then
		return false, "JPEG ICC profile with the display serial number"
	elseif parsed.jfif_planned ~= parsed.jfif then
		return false, "JPEG JFIF thumbnail"
	end
	local split = parsed.split
	if split then
		if split.dropped then
			return false, "JPEG data after the end marker"
		end
		for _, image in ipairs(split.images) do
			for _, range in ipairs(image.ranges) do
				if range.kind ~= "xmp" and range.kind ~= "gainmap" then
					return false, "JPEG gain map " .. range.kind .. " segment"
				end
			end
		end
		if MPF.gainmap(split) or split.motion then
			local exif = 0
			for _, range in ipairs(parsed.ranges) do
				exif = exif + (range.kind == "exif" and 1 or 0)
			end
			return exif <= 1 and MPF.primary_clean(parsed, split), "JPEG primary metadata segments"
		end
	end
	local exif = 0
	for _, kind in ipairs(parsed.removable) do
		if kind ~= "exif" then
			return false, "JPEG " .. kind .. " segment"
		end
		exif = exif + 1
	end
	return exif <= 1, "multiple JPEG EXIF segments"
end

local JPEG_POLICY = {
	spec = JPEG_SPEC,
	preflight = function(path)
		local parsed, err = jpeg_parse(path)
		if not parsed then
			return nil, err
		end
		if parsed.trailer > 0 then
			local split, split_err = MPF.split(parsed)
			if not split then
				return nil, split_err
			end
			parsed.split = split
		end
		if parsed.paths then
			return nil, "JPEG with Photoshop paths is unsupported"
		end
		return parsed
	end,
	structure_clean = jpeg_structure_clean,
	capture = function(path, _, parsed)
		local decoded, stream, err = still_capture(path)
		if not decoded then
			return nil, err
		end
		return {
			decoded = decoded,
			stream = stream,
			protected = parsed.protected,
			jfif = parsed.jfif_planned,
			icc = ICC.jpeg_planned(parsed.icc),
			adobe = parsed.adobe,
			gainmap = parsed.split and MPF.gainmap(parsed.split) and MPF.gainmap_identity(MPF.gainmap(parsed.split))
				or "",
		}
	end,
	equivalent = compare_fields(
		"JPEG %s data changed",
		{ "protected", "jfif", "icc", "adobe", "decoded", "stream", "gainmap" }
	),
	transform = function(ctx)
		ctx.state.transformed = true
		local split = ctx.state.split
		local gainmap = split and MPF.gainmap(split)
		if split then
			local ok, err = rewrite_file(ctx.staged, ctx.state.data:sub(1, split.primary_end))
			if not ok then
				return nil, err
			end
		elseif ctx.state.missing_eoi then
			local ok, err = rewrite_file(ctx.staged, ctx.state.data .. "\255\217")
			if not ok then
				return nil, err
			end
		end
		local args = {
			"-overwrite_original_in_place",
			"-P",
			"-m",
			"-q",
			"-q",
			"-all=",
			"--JFIF:all",
			"--Adobe:all",
			"--ICC_Profile:all",
			"-tagsFromFile",
			"@",
		}
		for _, tag in ipairs(JPEG_RESTORED_TAGS) do
			args[#args + 1] = "-" .. tag
		end
		if ctx.inventory.values["ExifIFD:ColorSpace"] then
			for _, tag in ipairs(JPEG_RESTORED_COLOR_TAGS) do
				args[#args + 1] = "-" .. tag
			end
			-- Writing a maker note creates an EXIF IFD, so it needs the
			-- source's colour space too.
			if gainmap and split.makernote then
				local path = ctx.staged:match("^(.*)/[^/]+$") .. "/.makernote.bin"
				local ok, err = rewrite_file(path, split.makernote)
				if not ok then
					return nil, err
				end
				args[#args + 1] = "-MakerNotes<=" .. path
				split.makernote_written = true
			end
		end
		args[#args + 1] = "--"
		args[#args + 1] = ctx.staged
		local output, err = command("exiftool", args, media_timeout(ctx.staged))
		if not output or not output.status.success then
			return nil, clean_error(output, err)
		end
		-- ExifTool cannot delete some segments, such as JFXX thumbnails; drop
		-- every remaining metadata segment except the rebuilt EXIF.
		local parsed, parse_err = jpeg_parse(ctx.staged)
		if not parsed then
			return nil, parse_err
		end
		local leftovers = {}
		for _, range in ipairs(parsed.ranges) do
			if range.kind ~= "exif" then
				leftovers[#leftovers + 1] = range
			end
		end
		local cleaned = #leftovers > 0 and protected_bytes(parsed.data, leftovers) or parsed.data
		if ICC.jpeg_planned(parsed.icc) ~= parsed.icc then
			local patched = ICC.jpeg_patch(assert(jpeg_parse(nil, cleaned)))
			if not patched then
				return nil, "JPEG ICC profile could not be patched"
			end
			cleaned = patched
		end
		local reparsed = parsed.jfif_planned ~= parsed.jfif and assert(jpeg_parse(nil, cleaned))
		if reparsed then
			local parts, position = {}, 1
			for _, span in ipairs(reparsed.jfif_spans) do
				parts[#parts + 1] = cleaned:sub(position, span.start - 1) .. span.planned
				position = span.finish + 1
			end
			cleaned = table.concat(parts) .. cleaned:sub(position)
		end
		local function clean_video(motion)
			local directory = ctx.staged:match("^(.*)/[^/]+$")
			local source, target = directory .. "/.motion-source.mp4", directory .. "/.motion.mp4"
			local ok, video_err = rewrite_file(source, motion.video)
			if ok then
				ok, video_err = EMBEDDED.clean(source, target)
			end
			local video = ok and read_file(target, LIMIT.MOTION_BYTES, "embedded video")
			fs.remove("file", Url(source))
			fs.remove("file", Url(target))
			motion.cleaned = video or nil
			return video, video_err or "could not read the cleaned Motion Photo video"
		end
		if split and split.samsung then
			local video, video_err = clean_video(split.samsung)
			if not video then
				return nil, video_err
			end
			cleaned = cleaned .. MPF.samsung_trailer(split.samsung, video)
		end
		if gainmap or (split and split.motion) then
			local at = MPF.insertion_point(cleaned)
			if not at then
				return nil, "invalid cleaned JPEG"
			end
			local image, video = gainmap and MPF.clean_gainmap(gainmap) or "", ""
			if split.motion then
				local video_err
				video, video_err = clean_video(split.motion)
				if not video then
					return nil, video_err
				end
			end
			local segments = MPF.primary_segments(split, at - 1, #cleaned, gainmap and #image)
			cleaned = cleaned:sub(1, at - 1) .. segments .. cleaned:sub(at) .. image .. video
		end
		if cleaned ~= parsed.data then
			return rewrite_file(ctx.staged, cleaned)
		end
		return true
	end,
	-- ExifTool's inventory does not look inside appended images, so the kept
	-- gain map is checked on its own.
	verify = function(source, staged, state)
		local parsed, err = jpeg_parse(staged)
		if not parsed then
			return nil, err
		end
		local function hdr_makernote(jpeg)
			local found
			for _, range in ipairs(jpeg.ranges) do
				if range.kind == "exif" then
					found = apple_hdr_makernote(range.payload:sub(7))
				end
			end
			return found
		end
		-- Without a transform the staged file is a copy of a source whose
		-- content was already clean, so it must keep what the source holds.
		local untouched = not state.transformed
		local makernote, expected = hdr_makernote(parsed), nil
		if untouched then
			local original, original_err = jpeg_parse(source)
			if not original then
				return nil, original_err
			end
			expected = hdr_makernote(original)
		elseif state.split and state.split.makernote_written then
			expected = state.split.makernote
		end
		if makernote ~= expected then
			return nil, "JPEG maker note differs from the planned HDR values"
		end
		if parsed.trailer == 0 then
			return true
		end
		local split
		split, err = MPF.split(parsed)
		if split and state.split and state.split.samsung then
			-- The trailer must hold exactly the video proven in the transform.
			local planned = untouched and state.split.samsung.video or state.split.samsung.cleaned
			if not split.samsung or split.samsung.video ~= planned then
				return nil, "Samsung Motion Photo video differs from the cleaned one"
			end
			return true
		end
		if not split or split.dropped then
			return nil, err or "cleaned JPEG has unexpected appended data"
		end
		if state.split and state.split.motion then
			local planned = untouched and state.split.motion.video or state.split.motion.cleaned
			if not split.motion or split.motion.video ~= planned then
				return nil, "Motion Photo video differs from the cleaned one"
			end
		end
		local gainmap = MPF.gainmap(split)
		if not gainmap then
			return split.motion ~= nil or nil, "cleaned JPEG has unexpected appended data"
		end
		local path = staged:match("^(.*)/[^/]+$") .. "/.gainmap.jpg"
		local ok, write_err = rewrite_file(path, gainmap.data)
		if not ok then
			return nil, write_err
		end
		local inventory, scan_err = scan(path)
		fs.remove("file", Url(path))
		if not inventory then
			return nil, scan_err
		end
		local clean, remaining = metadata_clean(inventory, GAINMAP_SPEC)
		return clean or nil, "gain map metadata outside the allowlist remains: " .. tostring(remaining)
	end,
}

-- PNG and APNG ---------------------------------------------------------------

-- PNG is rewritten chunk by chunk. Rendering and animation chunks are copied
-- byte-for-byte; every other ancillary chunk is dropped. Apple's iDOT chunk
-- holds absolute IDAT offsets, so it is dropped rather than left stale.
local PNG_SIGNATURE = "\137PNG\r\n\26\n"
local PNG_KEEP = {}
for _, kind in ipairs({
	"IHDR",
	"PLTE",
	"IDAT",
	"IEND",
	"tRNS",
	"cHRM",
	"gAMA",
	"iCCP",
	"sBIT",
	"sRGB",
	"cICP",
	"mDCV",
	"cLLI",
	"bKGD",
	"pHYs",
	"acTL",
	"fcTL",
	"fdAT",
}) do
	PNG_KEEP[kind] = true
end

local PNG_SPEC = metadata_spec({
	keep = with_basics({
		"PNG:ImageWidth",
		"PNG:ImageHeight",
		"PNG:BitDepth",
		"PNG:ColorType",
		"PNG:Compression",
		"PNG:Filter",
		"PNG:Interlace",
		"PNG:Palette",
		"PNG:Transparency",
		"PNG:Gamma",
		"PNG:SRGBRendering",
		"PNG:WhitePointX",
		"PNG:WhitePointY",
		"PNG:RedX",
		"PNG:RedY",
		"PNG:GreenX",
		"PNG:GreenY",
		"PNG:BlueX",
		"PNG:BlueY",
		"PNG:BackgroundColor",
		"PNG:SignificantBits",
		"PNG:ProfileName",
		"PNG:AnimationFrames",
		"PNG:AnimationPlays",
		"PNG-pHYs:*",
		"PNG-cICP:*",
		"PNG-mDCV:*",
		"PNG-cLLI:*",
		"^ICC:*",
		"IFD0:Orientation",
	}),
	free = { "File:ExifByteOrder" },
})

local function exif_orientation(tiff)
	local order = tiff:sub(1, 2)
	local u16, u32
	if order == "MM" then
		u16 = function(offset)
			return be_u16(tiff, offset)
		end
		u32 = function(offset)
			return be_u32_at(tiff, offset)
		end
	elseif order == "II" then
		u16 = function(offset)
			return le_u16(tiff:sub(offset, offset + 1))
		end
		u32 = function(offset)
			return le_u32(tiff:sub(offset, offset + 3))
		end
	else
		return nil, nil, "invalid EXIF byte order"
	end
	if u16(3) ~= 42 then
		return nil, nil, "invalid EXIF header"
	end
	local ifd = u32(5)
	local count = ifd and u16(ifd + 1)
	if not count or ifd + 2 + count * 12 > #tiff then
		return nil, nil, "truncated EXIF IFD"
	end
	local orientation
	for index = 0, count - 1 do
		local entry = ifd + 3 + index * 12
		if u16(entry) == 0x0112 then
			if u16(entry + 2) ~= 3 or u32(entry + 4) ~= 1 then
				return nil, nil, "invalid EXIF orientation"
			end
			orientation = u16(entry + 8)
		end
	end
	return orientation, count
end

local function png_chunk(kind, payload)
	return u32_be_bytes(#payload) .. kind .. payload .. u32_be_bytes(crc32(kind .. payload))
end

local function minimal_exif(orientation)
	return "MM\0\42"
		.. u32_be_bytes(8)
		.. "\0\1\1\18\0\3"
		.. u32_be_bytes(1)
		.. string.char(orientation // 256, orientation % 256, 0, 0)
		.. u32_be_bytes(0)
end

local function png_parse(data)
	if data:sub(1, 8) ~= PNG_SIGNATURE then
		return nil, "invalid PNG signature"
	end
	local chunks, position, size = {}, 9, #data
	while true do
		if position + 11 > size then
			return nil, "truncated PNG chunk"
		end
		local length = be_u32_at(data, position)
		local kind = data:sub(position + 4, position + 7)
		if not kind:match("^%a%a%a%a$") then
			return nil, "invalid PNG chunk type"
		end
		if length > 0x7FFFFFFF or position + 11 + length > size then
			return nil, "truncated PNG chunk"
		end
		local finish = position + 11 + length
		-- Image data CRCs are left to the decoder check; checking every small
		-- chunk rejects corrupt files before they are rewritten.
		if
			kind ~= "IDAT"
			and kind ~= "fdAT"
			and crc32(data, position + 4, finish - 4) ~= be_u32_at(data, finish - 3)
		then
			return nil, "PNG chunk CRC mismatch: " .. kind
		end
		chunks[#chunks + 1] = { kind = kind, start = position, finish = finish }
		position = finish + 1
		if kind == "IEND" then
			break
		end
	end
	if position <= size then
		return nil, "data after the PNG end chunk is unsupported"
	end
	if chunks[1].kind ~= "IHDR" then
		return nil, "PNG does not start with IHDR"
	end
	local parsed = { data = data, chunks = chunks, removable = {} }
	for _, chunk in ipairs(chunks) do
		if PNG_KEEP[chunk.kind] then
			chunk.keep = true
		elseif chunk.kind:byte(1) < 97 then
			return nil, "unsupported critical PNG chunk " .. chunk.kind
		else
			parsed.removable[#parsed.removable + 1] = chunk.kind
			if chunk.kind == "eXIf" then
				if parsed.exif then
					return nil, "multiple PNG eXIf chunks"
				end
				local orientation, count, err = exif_orientation(data:sub(chunk.start + 8, chunk.finish - 4))
				if err then
					return nil, err
				end
				parsed.exif = { orientation = orientation, minimal = orientation ~= nil and count == 1 }
			end
		end
	end
	return parsed
end

-- Only when ExifTool reports a patchable tag (ICC.reported) is the
-- decompressed profile read, patched and stored uncompressed.
function ICC.png(path, inventory, parsed)
	if not ICC.reported(inventory) then
		return true
	end
	for _, chunk in ipairs(parsed.chunks) do
		if chunk.kind == "iCCP" then
			local profile, err = bounded_output("exiftool", { "-b", "-ICC_Profile", "--", path }, media_timeout(path))
			if not profile then
				return nil, err
			end
			local cleaned = ICC.clean(profile)
			if cleaned then
				local payload = parsed.data:sub(chunk.start + 8, chunk.finish - 4)
				local name = payload:match("^([^%z]+)%z")
				if not name or payload:byte(#name + 2) ~= 0 then
					return nil, "invalid PNG iCCP chunk"
				end
				chunk.replacement = png_chunk("iCCP", name .. "\0\0" .. ICC.zlib(cleaned))
			end
		end
	end
	return true
end

local function png_structure_clean(parsed)
	for _, chunk in ipairs(parsed.chunks) do
		if chunk.replacement then
			return false, "PNG ICC profile with the display serial number"
		end
	end
	if #parsed.removable == 0 then
		return true
	end
	if #parsed.removable == 1 and parsed.removable[1] == "eXIf" and parsed.exif.minimal then
		return true
	end
	return false, "PNG " .. parsed.removable[1] .. " chunk"
end

local function png_protected(parsed)
	local parts = {}
	for _, chunk in ipairs(parsed.chunks) do
		if chunk.keep then
			parts[#parts + 1] = chunk.replacement or parsed.data:sub(chunk.start, chunk.finish)
		end
	end
	return table.concat(parts)
end

local function png_output(parsed, keep_orientation)
	local parts, inserted = { PNG_SIGNATURE }, false
	local orientation = keep_orientation and parsed.exif and parsed.exif.orientation
	for _, chunk in ipairs(parsed.chunks) do
		if orientation and not inserted and (chunk.kind == "IDAT" or chunk.kind == "fcTL") then
			parts[#parts + 1] = png_chunk("eXIf", minimal_exif(orientation))
			inserted = true
		end
		if chunk.keep then
			parts[#parts + 1] = chunk.replacement or parsed.data:sub(chunk.start, chunk.finish)
		end
	end
	return table.concat(parts)
end

local PNG_POLICY = {
	spec = PNG_SPEC,
	preflight = function(path, inventory)
		local data, err = read_file(path, LIMIT.PNG_BYTES, "PNG")
		if not data then
			return nil, err
		end
		local parsed
		parsed, err = png_parse(data)
		if not parsed then
			return nil, err
		end
		local ok, icc_err = ICC.png(path, inventory, parsed)
		if not ok then
			return nil, icc_err
		end
		return parsed
	end,
	structure_clean = png_structure_clean,
	capture = function(path, inventory, parsed)
		local decoded, stream, err = still_capture(path)
		if not decoded then
			return nil, err
		end
		local timeline
		if inventory.file_type == "APNG" then
			local timeline_err
			timeline, timeline_err = apng_timeline_manifest(path)
			if not timeline then
				return nil, timeline_err
			end
		end
		return {
			decoded = decoded,
			stream = stream,
			timeline = timeline,
			protected = png_protected(parsed),
			orientation = parsed.exif and parsed.exif.orientation,
		}
	end,
	equivalent = compare_fields("PNG %s changed", { "protected", "orientation", "decoded", "stream", "timeline" }),
	transform = function(ctx)
		return rewrite_file(ctx.staged, png_output(ctx.state, true))
	end,
}

-- TIFF -----------------------------------------------------------------------

-- ExifTool cannot drop a TIFF's IFD0 as a whole, because it also describes the
-- image. Known metadata tags are deleted one by one; any IFD0 tag that is
-- neither structural nor known metadata (for example Photoshop layer data)
-- makes the file skip.
local TIFF_STRUCTURAL_TAGS = {
	"SubfileType",
	"OldSubfileType",
	"ImageWidth",
	"ImageHeight",
	"BitsPerSample",
	"Compression",
	"PhotometricInterpretation",
	"Thresholding",
	"CellWidth",
	"CellLength",
	"FillOrder",
	"StripOffsets",
	"Orientation",
	"SamplesPerPixel",
	"RowsPerStrip",
	"StripByteCounts",
	"MinSampleValue",
	"MaxSampleValue",
	"XResolution",
	"YResolution",
	"PlanarConfiguration",
	"XPosition",
	"YPosition",
	"ResolutionUnit",
	"TransferFunction",
	"Predictor",
	"WhitePoint",
	"PrimaryChromaticities",
	"ColorMap",
	"HalftoneHints",
	"TileWidth",
	"TileLength",
	"TileOffsets",
	"TileByteCounts",
	"InkSet",
	"InkNames",
	"NumberofInks",
	"DotRange",
	"ExtraSamples",
	"SampleFormat",
	"SMinSampleValue",
	"SMaxSampleValue",
	"TransferRange",
	"JPEGTables",
	"YCbCrCoefficients",
	"YCbCrSubSampling",
	"YCbCrPositioning",
	"ReferenceBlackWhite",
	"T4Options",
	"T6Options",
	-- Sensor levels that multispectral and scientific cameras (DJI) store
	-- for radiometric calibration.
	"BlackLevelRepeatDim",
	"BlackLevel",
	"WhiteLevel",
}

local TIFF_METADATA_TAGS = {}
for _, tag in ipairs({
	"Make",
	"Model",
	"Software",
	"ModifyDate",
	"DateTimeOriginal",
	"CreateDate",
	"Artist",
	"HostComputer",
	"ImageDescription",
	"Copyright",
	"DocumentName",
	"PageName",
	"PageNumber",
	"TargetPrinter",
	"ImageID",
	"ImageUniqueID",
	"OwnerName",
	"SerialNumber",
	"Rating",
	"RatingPercent",
	"XPTitle",
	"XPComment",
	"XPAuthor",
	"XPKeywords",
	"XPSubject",
	"ApplicationNotes",
	"IPTC-NAA",
	"PhotoshopSettings",
	"ExifOffset",
	"GPSInfo",
	-- DNG identity tags that TIFF writers copy into IFD0.
	"CameraSerialNumber",
	"UniqueCameraModel",
	"LocalizedCameraModel",
	"OriginalRawFileName",
	"CameraLabel",
	"ReelName",
}) do
	TIFF_METADATA_TAGS[tag] = true
end

local TIFF_METADATA_GROUPS = {
	"ExifIFD",
	"GPS",
	"InteropIFD",
	"XMP",
	"IPTC",
	"Photoshop",
	"MakerNotes",
	"PrintIM",
}

local TIFF_SPEC = (function()
	local keep = with_basics({ "File:PageCount", "^ICC:*" })
	for _, tag in ipairs(TIFF_STRUCTURAL_TAGS) do
		keep[#keep + 1] = "IFD0:" .. tag
	end
	return metadata_spec({
		keep = keep,
		-- Later pages are checked entry by entry by TIFF.plan and TIFF.verify.
		free = { "File:ExifByteOrder", "^IFD[1-9]%d*$:*" },
		recomputed = { "IFD0:StripOffsets", "IFD0:TileOffsets" },
	})
end)()

local TIFF_STRUCTURAL = tag_set((function()
	local list = {}
	for _, tag in ipairs(TIFF_STRUCTURAL_TAGS) do
		list[#list + 1] = "IFD0:" .. tag
	end
	return list
end)())

-- Walks the segments before the image data of the JPEG stream at start and
-- returns flagged(marker, identifier) for the first APPn or COM segment it
-- is true for. Only segment headers are read; read(offset, length) reads the
-- file.
local function jpeg_flagged_segment(read, start, finish, flagged)
	local position = read(start, 2) == "\255\216" and start + 2
	while position and position + 4 <= finish do
		local header = read(position, 4)
		local marker = header and header:byte(2)
		if not header or header:byte(1) ~= 0xFF or marker == 0xDA or marker == 0xD9 then
			return nil
		end
		local size = string.unpack(">I2", header, 3)
		if size < 2 then
			return nil
		elseif marker >= 0xE0 and marker <= 0xEF or marker == 0xFE then
			local reason = flagged(marker, read(position + 4, math.min(29, size - 2)) or "")
			if reason then
				return reason
			end
		end
		position = position + 2 + size
	end
	return nil
end

-- Pages after the first, which ExifTool does not edit. Their identity text
-- tags are blanked in place, an ICC profile loses its display serial number,
-- and any tag that is neither structural nor one of those makes the file
-- skip. Every page's image data is compared byte for byte.
local TIFF = {
	-- Structural tags by number (the names of TIFF_STRUCTURAL_TAGS, plus
	-- PageNumber, which numbers the pages).
	PAGE_TAGS = as_set({
		0xFE,
		0xFF,
		0x100,
		0x101,
		0x102,
		0x103,
		0x106,
		0x107,
		0x108,
		0x109,
		0x10A,
		0x111,
		0x112,
		0x115,
		0x116,
		0x117,
		0x118,
		0x119,
		0x11A,
		0x11B,
		0x11C,
		0x11E,
		0x11F,
		0x124,
		0x125,
		0x128,
		0x129,
		0x12D,
		0x13D,
		0x13E,
		0x13F,
		0x140,
		0x141,
		0x142,
		0x143,
		0x144,
		0x145,
		0x14C,
		0x14D,
		0x14E,
		0x150,
		0x152,
		0x153,
		0x154,
		0x155,
		0x156,
		0x15B,
		0x211,
		0x212,
		0x213,
		0x214,
		0xC619,
		0xC61A,
		0xC61D,
	}),
	-- DocumentName, ImageDescription, Make, Model, PageName, Software,
	-- DateTime, Artist, HostComputer, Copyright.
	IDENTITY = as_set({ 0x10D, 0x10E, 0x10F, 0x110, 0x11D, 0x131, 0x132, 0x13B, 0x13C, 0x8298 }),
	ICC = 0x8773,
	SIZES = { 1, 1, 2, 4, 8, 1, 1, 2, 4, 8, 4, 8, 4 },
	-- Offsets and the byte counts of the data they point to.
	DATA = { [0x111] = 0x117, [0x144] = 0x145 },
}

-- Every IFD of a classic TIFF: its entries with the position and size of
-- their values, with subifds also every SubIFD after its parent. nil and a
-- reason for BigTIFF, loops or broken directories.
function TIFF.pages(path, subifds)
	local file = io.open(path, "rb")
	if not file then
		return nil, "could not open TIFF file"
	end
	local size = file:seek("end")
	local function read(offset, length)
		if offset < 0 or offset + length > size then
			return nil
		end
		file:seek("set", offset)
		local data = file:read(length)
		return data and #data == length and data or nil
	end
	local header = read(0, 8) or ""
	local order = header:sub(1, 4) == "II*\0" and "<" or header:sub(1, 4) == "MM\0*" and ">"
	if not order then
		file:close()
		return nil, "unsupported TIFF header"
	end
	local pages, seen = { order = order, read = read, size = size }, {}
	-- A chain of IFDs from offset; with subifds, each IFD's SubIFDs follow it.
	local function chain(offset, depth)
		while offset ~= 0 do
			if seen[offset] or #pages >= LIMIT.TIFF_PAGES or depth > 4 then
				return nil, #pages >= LIMIT.TIFF_PAGES and "too many TIFF pages" or "TIFF directory loop"
			end
			seen[offset] = true
			local count = read(offset, 2)
			count = count and string.unpack(order .. "I2", count)
			local table_data = count and read(offset + 2, count * 12 + 4)
			if not table_data then
				return nil, "truncated TIFF directory"
			end
			local page = { entries = {}, tags = {}, depth = depth }
			for index = 0, count - 1 do
				local tag, kind, values = string.unpack(order .. "I2I2I4", table_data, 1 + index * 12)
				local width = TIFF.SIZES[kind]
				if not width then
					return nil, "unknown TIFF field type"
				end
				local length = width * values
				local field = offset + 2 + index * 12 + 8
				local at = length <= 4 and field or string.unpack(order .. "I4", table_data, 1 + index * 12 + 8)
				if at + length > size then
					return nil, "TIFF value outside the file"
				end
				local entry = { tag = tag, kind = kind, count = values, at = at, length = length }
				page.entries[#page.entries + 1], page.tags[tag] = entry, entry
			end
			pages[#pages + 1] = page
			if subifds and page.tags[0x14A] then
				for _, child in ipairs(TIFF.numbers(pages, page.tags[0x14A])) do
					local ok, err = chain(child, depth + 1)
					if not ok then
						return nil, err
					end
				end
			end
			offset = string.unpack(order .. "I4", table_data, 1 + count * 12)
		end
		return true
	end
	local ok, err = chain(string.unpack(order .. "I4", header, 5), 0)
	if not ok then
		file:close()
		return nil, err
	end
	pages.close = function()
		file:close()
	end
	return pages
end

-- The numbers an entry holds (offsets, byte counts).
function TIFF.numbers(pages, entry)
	local data = pages.read(entry.at, entry.length) or ""
	local format = pages.order .. (entry.kind == 3 and "I2" or "I4")
	local list = {}
	for index = 1, entry.count do
		list[index] = string.unpack(format, data, 1 + (index - 1) * (entry.kind == 3 and 2 or 4))
	end
	return list
end

-- An ASCII value of the same length that says nothing: spaces and the
-- terminating NUL, since readers warn about NULs inside a value.
function TIFF.blank(length)
	return length > 0 and string.rep(" ", length - 1) .. "\0" or ""
end

-- The in-place writes cleaning makes to pages after the first: blanked
-- identity text and patched ICC profiles. nil and a reason when a page holds
-- anything else.
function TIFF.plan(pages)
	local writes = {}
	for index = 2, #pages do
		for _, entry in ipairs(pages[index].entries) do
			if TIFF.IDENTITY[entry.tag] then
				if entry.kind ~= 2 then
					return nil, string.format("unexpected TIFF tag type in page %d", index)
				end
				local blank = TIFF.blank(entry.length)
				if pages.read(entry.at, entry.length) ~= blank then
					writes[#writes + 1] = { start = entry.at, finish = entry.at + entry.length, bytes = blank }
				end
			elseif entry.tag == TIFF.ICC then
				local cleaned = ICC.clean(pages.read(entry.at, entry.length))
				if cleaned then
					writes[#writes + 1] =
						{ start = entry.at, finish = entry.at + entry.length, kind = "bytes", bytes = cleaned }
				end
			elseif not TIFF.PAGE_TAGS[entry.tag] then
				return nil, string.format("unrecognized TIFF tag 0x%04X in page %d", entry.tag, index)
			end
		end
	end
	table.sort(writes, function(a, b)
		return a.start < b.start
	end)
	return writes
end

-- The JPEG-compressed strips and tiles of every page: each may be a whole
-- JPEG stream with its own metadata segments, which ExifTool neither reports
-- nor removes. Only JFIF and Adobe colour segments may come before the image
-- data. Only segment headers are read.
function TIFF.jpeg_metadata(pages)
	for index, page in ipairs(pages) do
		local compression = page.tags[0x103] and TIFF.numbers(pages, page.tags[0x103])[1]
		for tag, counts in pairs(compression == 7 and TIFF.DATA or {}) do
			if page.tags[tag] and page.tags[counts] then
				local lengths = TIFF.numbers(pages, page.tags[counts])
				for strip, start in ipairs(TIFF.numbers(pages, page.tags[tag])) do
					local found = jpeg_flagged_segment(
						pages.read,
						start,
						start + (lengths[strip] or 0),
						function(marker, id)
							local kept = marker == 0xE0 and id:sub(1, 5) == "JFIF\0"
								or marker == 0xEE and id:sub(1, 5) == "Adobe"
							return not kept
						end
					)
					if found then
						return string.format("TIFF page %d holds a JPEG metadata segment in its image data", index)
					end
				end
			end
		end
	end
	return nil
end

-- Whether the strips or tiles an offset tag points to hold the same bytes in
-- both IFDs; the data may have moved.
function TIFF.same_data(a, before, b, after, tag, planned)
	local entry, other, counts = before.tags[tag], after.tags[tag], before.tags[TIFF.DATA[tag]]
	if not entry then
		return other == nil or nil, "TIFF image data added"
	elseif not other or not counts or not after.tags[TIFF.DATA[tag]] then
		return nil, "TIFF image data without byte counts"
	end
	local lengths, from, to = TIFF.numbers(a, counts), TIFF.numbers(a, entry), TIFF.numbers(b, other)
	if #from ~= #to or table.concat(lengths, ",") ~= table.concat(TIFF.numbers(b, after.tags[TIFF.DATA[tag]]), ",") then
		return nil, "TIFF image layout changed"
	end
	for strip = 1, #from do
		local remaining, x, y = lengths[strip] or 0, from[strip], to[strip]
		while remaining > 0 do
			local chunk = math.min(remaining, 65536)
			local expected = a.read(x, chunk)
			-- planned: source regions cleaning zeroes or rewrites (embedded JPEG
			-- metadata).
			for _, region in ipairs(planned or {}) do
				local start, finish = math.max(region.start, x), math.min(region.finish, x + chunk)
				if expected and start < finish then
					local bytes = region.bytes and region.bytes:sub(start - region.start + 1, finish - region.start)
						or string.rep("\0", finish - start)
					expected = expected:sub(1, start - x) .. bytes .. expected:sub(finish - x + 1)
				end
			end
			if expected ~= b.read(y, chunk) then
				return nil, "TIFF page image data changed"
			end
			x, y, remaining = x + chunk, y + chunk, remaining - chunk
		end
	end
	return true
end

-- Apply planned writes to a file in place: zeros, or the planned bytes.
function TIFF.apply(path, writes)
	local file = io.open(path, "r+b")
	if not file then
		return nil, "could not open the staged TIFF file"
	end
	for _, write in ipairs(writes) do
		file:seek("set", write.start)
		if not file:write(write.bytes or string.rep("\0", write.finish - write.start)) then
			file:close()
			return nil, "could not write the staged TIFF file"
		end
	end
	return file:close() and true or nil, "could not write the staged TIFF file"
end

-- Pages after the first must be the source's pages: the same entries, image
-- data byte for byte, identity text blanked and ICC profiles as planned.
function TIFF.verify(source, staged)
	local a, err = TIFF.pages(source)
	if not a then
		return nil, err
	end
	local b
	b, err = TIFF.pages(staged)
	if not b then
		a.close()
		return nil, err
	end
	local function check()
		if #a ~= #b then
			return nil, "TIFF page count changed"
		end
		-- The first page's tags are ExifTool's to rewrite; its image data stays.
		for _, tag in ipairs({ 0x111, 0x144 }) do
			local same, same_err = TIFF.same_data(a, a[1], b, b[1], tag)
			if not same then
				return nil, same_err
			end
		end
		for index = 2, #a do
			local before, after = a[index], b[index]
			if #before.entries ~= #after.entries then
				return nil, "TIFF page entries changed"
			end
			for position, entry in ipairs(before.entries) do
				local other = after.entries[position]
				if other.tag ~= entry.tag or other.kind ~= entry.kind or other.count ~= entry.count then
					return nil, "TIFF page entries changed"
				end
				local value = b.read(other.at, other.length)
				local expected = a.read(entry.at, entry.length)
				if TIFF.IDENTITY[entry.tag] then
					expected = TIFF.blank(entry.length)
				elseif entry.tag == TIFF.ICC then
					expected = ICC.clean(expected) or expected
				end
				if TIFF.DATA[entry.tag] then
					local same, same_err = TIFF.same_data(a, before, b, after, entry.tag)
					if not same then
						return nil, same_err
					end
				elseif value ~= expected then
					return nil, "TIFF page tag changed"
				end
			end
		end
		return true
	end
	local ok, check_err = check()
	a.close()
	b.close()
	return ok, check_err
end

-- Compressions FFmpeg decodes for the pixel comparison: none, CCITT RLE,
-- Group 3 and Group 4 fax (scanned documents), LZW, JPEG, Deflate, PackBits.
local TIFF_COMPRESSIONS = {
	[1] = true,
	[2] = true,
	[3] = true,
	[4] = true,
	[5] = true,
	[7] = true,
	[8] = true,
	[32773] = true,
}

local TIFF_POLICY = {
	spec = TIFF_SPEC,
	preflight = function(path, inventory)
		-- Photoshop keeps editable layers in ImageSourceData; removing them
		-- would flatten the document.
		if inventory.values["Photoshop:LayerCount"] then
			return nil, "TIFF with Photoshop layers is unsupported"
		end
		local removals = {}
		for _, key in ipairs(inventory.entries) do
			local group, tag = key:match("^(.-):(.+)$")
			if group:match("^SubIFD") then
				return nil, "private TIFF IFD is unsupported"
			elseif group == "IFD0" and not TIFF_STRUCTURAL(key) then
				if not TIFF_METADATA_TAGS[tag] then
					return nil, "unrecognized TIFF tag " .. key
				end
				removals[#removals + 1] = "-IFD0:" .. tag .. "="
			end
		end
		local compression = tonumber((inventory.values["IFD0:Compression"] or {})[1])
		if not TIFF_COMPRESSIONS[compression] then
			return nil, "unsupported TIFF compression"
		end
		local subfile = (inventory.values["IFD0:SubfileType"] or { "0" })[1]
		if subfile ~= "0" then
			return nil, "non-primary TIFF image is unsupported"
		end
		local icc
		if ICC.reported(inventory) then
			local profile, err = icc_profile(path)
			if not profile then
				return nil, err
			end
			icc = ICC.clean(profile) or nil
		end
		local pages, pages_err = TIFF.pages(path)
		if not pages then
			return nil, pages_err
		end
		local writes, writes_err = TIFF.plan(pages)
		local embedded = TIFF.jpeg_metadata(pages)
		pages.close()
		if not writes then
			return nil, writes_err
		elseif embedded then
			return nil, embedded
		end
		return { removals = removals, icc = icc, pages = #pages, page_writes = writes }
	end,
	structure_clean = function(state)
		if state.icc then
			return false, "TIFF ICC profile with the display serial number"
		elseif #state.page_writes > 0 then
			return false, "TIFF page with identity text or a display serial number"
		end
		return true
	end,
	capture = function(path)
		local decoded, stream, err = still_capture(path)
		if not decoded then
			return nil, err
		end
		local icc, icc_err = icc_profile(path)
		if not icc then
			return nil, icc_err
		end
		return { decoded = decoded, stream = stream, icc = ICC.clean(icc) or icc }
	end,
	equivalent = compare_fields("TIFF %s changed", { "decoded", "stream", "icc" }),
	transform = function(ctx)
		local args = { "-overwrite_original_in_place", "-P", "-m", "-q", "-q" }
		for _, removal in ipairs(ctx.state.removals) do
			args[#args + 1] = removal
		end
		for _, group in ipairs(TIFF_METADATA_GROUPS) do
			args[#args + 1] = "-" .. group .. ":all="
		end
		local profile = ctx.state.icc and ctx.staged:match("^(.*)/[^/]+$") .. "/.profile.icc"
		if profile then
			local ok, err = rewrite_file(profile, ctx.state.icc)
			if not ok then
				return nil, err
			end
			args[#args + 1] = "-ICC_Profile<=" .. profile
		end
		args[#args + 1] = "--"
		args[#args + 1] = ctx.staged
		local output, err = command("exiftool", args, media_timeout(ctx.staged))
		if profile then
			fs.remove("file", Url(profile))
		end
		if not output or not output.status.success then
			return nil, clean_error(output, err)
		end
		if ctx.state.pages == 1 then
			return true
		end
		-- ExifTool may have moved the later pages; plan on the staged file.
		local pages, pages_err = TIFF.pages(ctx.staged)
		if not pages then
			return nil, pages_err
		end
		local writes, writes_err = TIFF.plan(pages)
		pages.close()
		if not writes then
			return nil, writes_err
		end
		return TIFF.apply(ctx.staged, writes)
	end,
	verify = function(source, staged)
		return TIFF.verify(source, staged)
	end,
}

-- DNG ------------------------------------------------------------------------

-- A DNG keeps every tag a raw developer needs to render it (DNG 1.7) with
-- its value, and ExifTool's names for preview, JPEG and matte images. Make,
-- Model and UniqueCameraModel name the camera model, which raw developers
-- use to pick profiles and lens and noise corrections; serial numbers,
-- dates, software, the original raw file and maker notes go.
TIFF.DNG_TAGS = {
	"DNGVersion",
	"DNGBackwardVersion",
	"Make",
	"Model",
	"UniqueCameraModel",
	"CFAPattern2",
	"CFARepeatPatternDim",
	"CFAPlaneColor",
	"CFALayout",
	"LinearizationTable",
	"BlackLevelRepeatDim",
	"BlackLevel",
	"BlackLevelDeltaH",
	"BlackLevelDeltaV",
	"WhiteLevel",
	"DefaultScale",
	"DefaultCropOrigin",
	"DefaultCropSize",
	"DefaultUserCrop",
	"ColorMatrix1",
	"ColorMatrix2",
	"ColorMatrix3",
	"CameraCalibration1",
	"CameraCalibration2",
	"CameraCalibration3",
	"ReductionMatrix1",
	"ReductionMatrix2",
	"ReductionMatrix3",
	"AnalogBalance",
	"AsShotNeutral",
	"AsShotWhiteXY",
	"BaselineExposure",
	"BaselineExposureOffset",
	"BaselineNoise",
	"BaselineSharpness",
	"BayerGreenSplit",
	"LinearResponseLimit",
	"DNGLensInfo",
	"ChromaBlurRadius",
	"AntiAliasStrength",
	"ShadowScale",
	"MakerNoteSafety",
	"CalibrationIlluminant1",
	"CalibrationIlluminant2",
	"CalibrationIlluminant3",
	"IlluminantData1",
	"IlluminantData2",
	"IlluminantData3",
	"BestQualityScale",
	"ActiveArea",
	"MaskedAreas",
	"AsShotICCProfile",
	"AsShotPreProfileMatrix",
	"CurrentICCProfile",
	"CurrentPreProfileMatrix",
	"ColorimetricReference",
	"CameraCalibrationSig",
	"ProfileCalibrationSig",
	"ExtraCameraProfiles",
	"AsShotProfileName",
	"NoiseReductionApplied",
	"ProfileName",
	"ProfileHueSatMapDims",
	"ProfileHueSatMapData1",
	"ProfileHueSatMapData2",
	"ProfileHueSatMapData3",
	"ProfileHueSatMapEncoding",
	"ProfileToneCurve",
	"ProfileEmbedPolicy",
	"ProfileCopyright",
	"ProfileLookTableDims",
	"ProfileLookTableData",
	"ProfileLookTableEncoding",
	"ProfileGainTableMap",
	"ProfileDynamicRange",
	"ProfileGroupName",
	"ForwardMatrix1",
	"ForwardMatrix2",
	"ForwardMatrix3",
	"PreviewColorSpace",
	"PreviewSettingsDigest",
	"RawImageDigest",
	"NewRawImageDigest",
	"SubTileBlockSize",
	"RowInterleaveFactor",
	"ColumnInterleaveFactor",
	"OpcodeList1",
	"OpcodeList2",
	"OpcodeList3",
	"NoiseProfile",
	"OriginalDefaultFinalSize",
	"OriginalBestQualitySize",
	"OriginalDefaultCropSize",
	"DefaultBlackRender",
	"RawToPreviewGain",
	"DepthFormat",
	"DepthNear",
	"DepthFar",
	"DepthUnits",
	"DepthMeasureType",
	"EnhanceParams",
	"SemanticName",
	"SemanticInstanceID",
	"MaskSubArea",
	"RGBTables",
	"ImageStats",
	"JXLDistance",
	"JXLEffort",
	"JXLDecodeSpeed",
	"PreviewImage",
	"PreviewImageStart",
	"PreviewImageLength",
	"JpgFromRaw",
	"JpgFromRawStart",
	"JpgFromRawLength",
	"OtherImage",
	"OtherImageStart",
	"OtherImageLength",
	"ThumbnailTIFF",
	"ThumbnailImage",
	"ThumbnailOffset",
	"ThumbnailLength",
}
-- Identity tags in the IFDs, deleted one by one.
TIFF.DNG_REMOVED = as_set({
	"CameraSerialNumber",
	"LocalizedCameraModel",
	"OriginalRawFileName",
	"OriginalRawFileData",
	"OriginalRawFileDigest",
	"RawDataUniqueID",
	"Software",
	"ModifyDate",
	"Artist",
	"Copyright",
	"ImageDescription",
	"HostComputer",
	"DocumentName",
	"ImageNumber",
	"ImageID",
	"ImageUniqueID",
	"CameraLabel",
	"ReelName",
	"PreviewApplicationName",
	"PreviewApplicationVersion",
	"PreviewSettingsName",
	"PreviewDateTime",
	"XPTitle",
	"XPComment",
	"XPAuthor",
	"XPKeywords",
	"XPSubject",
	"Rating",
	"RatingPercent",
})
-- XMP that describes an auxiliary image (Apple's semantic mattes) stays.
TIFF.DNG_XMP = { "XMP-x:all", "XMP-apdi:all", "XMP-semanticSegmentationMatte:all" }

TIFF.DNG_SPEC = (function()
	local keep = with_basics({
		"^ICC:*",
		"XMP-apdi:AuxiliaryImageType",
		"XMP-semanticSegmentationMatte:*",
	})
	local recomputed = {}
	for _, group in ipairs({ "IFD0", "^SubIFD%d*$" }) do
		for _, list in ipairs({ TIFF_STRUCTURAL_TAGS, TIFF.DNG_TAGS }) do
			for _, tag in ipairs(list) do
				keep[#keep + 1] = group .. ":" .. tag
			end
		end
		-- Offsets move when ExifTool rewrites the file.
		for _, tag in ipairs({ "StripOffsets", "TileOffsets", "PreviewImageStart", "JpgFromRawStart" }) do
			recomputed[#recomputed + 1] = group .. ":" .. tag
		end
		recomputed[#recomputed + 1] = group .. ":OtherImageStart"
		recomputed[#recomputed + 1] = group .. ":ThumbnailOffset"
	end
	return metadata_spec({
		keep = keep,
		-- DNGPrivateData stays as zeros (TIFF.dng_plan, checked in verify).
		free = { "File:ExifByteOrder", "XMP-x:XMPToolkit", "IFD0:DNGPrivateData" },
		recomputed = recomputed,
	})
end)()

-- Regions of a DNG that cleaning zeroes in place: DNGPrivateData, which
-- holds a copy of the maker notes and which ExifTool does not delete, and the
-- metadata segments (Exif, XMP, comments, application data) of JPEG previews,
-- which repeat the camera, lens, dates and location. JFIF, ICC and Adobe
-- segments stay. Regions already as planned are left out.
function TIFF.dng_plan(pages)
	local regions = {}
	local function zero(start, finish)
		local data = pages.read(start, finish - start)
		if data and data:find("[^%z]") then
			regions[#regions + 1] = { start = start, finish = finish }
		end
	end
	local private = pages[1] and pages[1].tags[0xC634]
	if private then
		zero(private.at, private.at + private.length)
	end
	for _, page in ipairs(pages) do
		for tag, counts in pairs(TIFF.DATA) do
			if page.tags[tag] and page.tags[counts] then
				local lengths = TIFF.numbers(pages, page.tags[counts])
				for index, start in ipairs(TIFF.numbers(pages, page.tags[tag])) do
					local length = lengths[index] or 0
					local jpeg = pages.read(start, 2) == "\255\216"
					if jpeg and length > LIMIT.MOTION_BYTES then
						return nil, "DNG preview is too large to check"
					end
					local data = jpeg and pages.read(start, length)
					-- FF D8 cannot occur in entropy-coded data, so every match starts
					-- an image: the primary, then MPF images such as a gain map,
					-- whose XMP describes it and stays.
					local at = data and 1
					while at do
						local position, secondary = at + 2, at > 1
						while position + 3 <= #data do
							local marker, size = data:byte(position + 1), string.unpack(">I2", data, position + 2)
							if data:byte(position) ~= 0xFF or marker == 0xDA or size < 2 then
								break
							end
							local identifier = data:sub(position + 4, position + 3 + math.min(29, size - 2))
							local kept = marker == 0xE0 and identifier:sub(1, 5) == "JFIF\0"
								or marker == 0xE2 and identifier:sub(1, 12) == "ICC_PROFILE\0"
								or marker == 0xE2 and identifier:sub(1, 4) == "MPF\0"
								or marker == 0xEE and identifier:sub(1, 5) == "Adobe"
								or secondary and marker == 0xE1 and identifier == "http://ns.adobe.com/xap/1.0/\0"
							if (marker >= 0xE0 and marker <= 0xEF or marker == 0xFE) and not kept then
								-- data index k is file offset start + k - 1.
								local finish = math.min(position + 1 + size, #data)
								local payload = data:sub(position + 4, finish)
								-- A primary preview with a gain map keeps the Apple HDR
								-- values as a maker note of their own, padded to the
								-- segment's length.
								local note = not secondary
									and marker == 0xE1
									and payload:sub(1, 6) == "Exif\0\0"
									and data:find("\255\216\255", position + 2 + size, true)
									and apple_hdr_makernote(payload:sub(7))
								local bytes = note and "Exif\0\0" .. makernote_exif(note)
								if bytes and #bytes <= #payload then
									bytes = bytes .. string.rep("\0", #payload - #bytes)
								else
									bytes = nil
								end
								if bytes and bytes ~= payload or not bytes and payload:find("[^%z]") then
									regions[#regions + 1] =
										{ start = start + position + 3, finish = start + finish, bytes = bytes }
								end
							end
							position = position + 2 + size
						end
						at = data:find("\255\216\255", position, true)
					end
				end
			end
		end
	end
	table.sort(regions, function(x, y)
		return x.start < y.start
	end)
	return regions
end

TIFF.DNG_POLICY = {
	spec = TIFF.DNG_SPEC,
	preflight = function(path, inventory)
		local removals, seen = {}, {}
		for _, key in ipairs(inventory.entries) do
			local group, tag = key:match("^(.-):(.+)$")
			if group:match("^IFD[1-9]") then
				return nil, "DNG with more than one main IFD is unsupported"
			elseif (group == "IFD0" or group:match("^SubIFD%d*$")) and TIFF.DNG_REMOVED[tag] then
				if not seen[key] then
					removals[#removals + 1], seen[key] = "-" .. key .. "=", true
				end
			elseif
				(group == "IFD0" or group:match("^SubIFD%d*$"))
				and not (TIFF.DNG_SPEC.keep(key) or TIFF.DNG_SPEC.free(key))
			then
				return nil, "unrecognized DNG tag " .. key
			end
		end
		-- Every image must be reachable to be compared.
		local pages, err = TIFF.pages(path, true)
		if not pages then
			return nil, err
		end
		local zeroed, plan_err = TIFF.dng_plan(pages)
		pages.close()
		if not zeroed then
			return nil, plan_err
		end
		return { removals = removals, zeroed = zeroed }
	end,
	structure_clean = function(state)
		return #state.zeroed == 0, "DNG private data or preview metadata"
	end,
	capture = function()
		return {}
	end,
	equivalent = function()
		return true
	end,
	transform = function(ctx)
		local args = { "-overwrite_original_in_place", "-P", "-m", "-q", "-q" }
		for _, removal in ipairs(ctx.state.removals) do
			args[#args + 1] = removal
		end
		for _, group in ipairs({ "ExifIFD", "GPS", "InteropIFD", "IPTC", "Photoshop", "MakerNotes", "PrintIM" }) do
			args[#args + 1] = "-" .. group .. ":all="
		end
		args[#args + 1] = "-XMP:all="
		for _, group in ipairs(TIFF.DNG_XMP) do
			args[#args + 1] = "--" .. group
		end
		args[#args + 1] = "--"
		args[#args + 1] = ctx.staged
		local output, err = command("exiftool", args, media_timeout(ctx.staged))
		if not output or not output.status.success then
			return nil, clean_error(output, err)
		end
		local pages, pages_err = TIFF.pages(ctx.staged, true)
		if not pages then
			return nil, pages_err
		end
		local zeroed, plan_err = TIFF.dng_plan(pages)
		pages.close()
		if not zeroed then
			return nil, plan_err
		end
		return TIFF.apply(ctx.staged, zeroed)
	end,
	-- Every IFD and SubIFD keeps its image data byte for byte, apart from the
	-- planned preview metadata: the raw data, previews and mattes.
	verify = function(source, staged, state)
		local a, err = TIFF.pages(source, true)
		if not a then
			return nil, err
		end
		local b
		b, err = TIFF.pages(staged, true)
		if not b then
			a.close()
			return nil, err
		end
		local ok, check_err = #a == #b or nil, "DNG image count changed"
		for index = 1, ok and #a or 0 do
			for _, tag in ipairs({ 0x111, 0x144 }) do
				ok, check_err = TIFF.same_data(a, a[index], b, b[index], tag, state.zeroed)
				if not ok then
					break
				end
			end
			if not ok then
				break
			end
		end
		-- Nothing that cleaning zeroes may hold data in the cleaned file.
		local remaining = ok and TIFF.dng_plan(b)
		if ok and (not remaining or #remaining > 0) then
			ok, check_err = nil, "DNG private data or preview metadata remains"
		end
		a.close()
		b.close()
		return ok, check_err
	end,
}

-- GIF ------------------------------------------------------------------------

-- Comment, XMP and unknown application or extension blocks are removed. Loop
-- control and ICC application blocks are kept; plain-text extensions render
-- visible text, so files with them are skipped.
local GIF_SPEC = metadata_spec({
	keep = with_basics({
		"GIF:GIFVersion",
		"GIF:ImageWidth",
		"GIF:ImageHeight",
		"GIF:HasColorMap",
		"GIF:ColorResolutionDepth",
		"GIF:BitsPerPixel",
		"GIF:BackgroundColor",
		"GIF:PixelAspectRatio",
		"GIF:AnimationIterations",
		"GIF:TransparentColor",
		"GIF:FrameCount",
		"GIF:Duration",
		"^ICC:*",
	}),
})

local function gif_structure_manifest(path)
	local data, read_err = read_file(path, LIMIT.GIF_BYTES, "GIF")
	if not data then
		return nil, read_err
	end
	local size = #data
	if size < 14 then
		return nil, "truncated GIF file"
	end
	if data:sub(1, 6) ~= "GIF87a" and data:sub(1, 6) ~= "GIF89a" then
		return nil, "invalid GIF header"
	end
	local position, packed = 14, data:byte(11)
	if packed >= 128 then
		position = position + 3 * 2 ^ ((packed % 8) + 1)
	end
	if position > size + 1 then
		return nil, "truncated GIF color table"
	end
	local frames, records, removable_ranges = 0, {}, {}
	local plain_text, loop_count, icc_patches = false, nil, {}
	local function subblocks(label)
		local bytes = 0
		while true do
			local length = data:byte(position)
			if not length then
				return nil, "truncated GIF " .. label
			end
			position = position + 1
			if length == 0 then
				return bytes
			end
			if position + length - 1 > size then
				return nil, "truncated GIF " .. label
			end
			bytes = bytes + length
			position = position + length
		end
	end
	while position <= size do
		local marker = data:byte(position)
		position = position + 1
		if marker == 0x3B then
			if position ~= size + 1 then
				return nil, "GIF has trailing data"
			end
			return "gif-structure-v2\nframes=" .. tostring(frames) .. "\n" .. table.concat(records, "\n"),
				{
					data = data,
					removable_ranges = removable_ranges,
					plain_text = plain_text,
					loop_count = loop_count,
					icc_patches = icc_patches,
				}
		elseif marker == 0x2C then
			local descriptor = data:sub(position, position + 8)
			if #descriptor ~= 9 then
				return nil, "truncated GIF image descriptor"
			end
			position = position + 9
			local image_packed = descriptor:byte(9)
			if image_packed >= 128 then
				position = position + 3 * 2 ^ ((image_packed % 8) + 1)
			end
			local lzw = data:byte(position)
			if not lzw or lzw < 2 or lzw > 8 then
				return nil, "invalid GIF LZW code size"
			end
			position = position + 1
			local payload, payload_err = subblocks("image data")
			if not payload then
				return nil, payload_err
			end
			frames = frames + 1
			records[#records + 1] = "frame="
				.. tostring(frames)
				.. ",lzw="
				.. tostring(lzw)
				.. ",bytes="
				.. tostring(payload)
		elseif marker == 0x21 then
			local extension_start = position - 1
			local label = data:byte(position)
			if not label then
				return nil, "truncated GIF extension"
			end
			position = position + 1
			if label == 0xF9 then
				local block_size = data:byte(position)
				if block_size ~= 4 or position + 5 > size or data:byte(position + 5) ~= 0 then
					return nil, "invalid GIF graphic control extension"
				end
				local delay = data:byte(position + 2) + data:byte(position + 3) * 256
				records[#records + 1] = "gce=delay:"
					.. tostring(delay)
					.. ",packed:"
					.. tostring(data:byte(position + 1))
				position = position + 6
			elseif label == 0xFE then
				local _, comment_err = subblocks("comment extension")
				if comment_err then
					return nil, comment_err
				end
				removable_ranges[#removable_ranges + 1] = { start = extension_start, finish = position - 1 }
			elseif label == 0x01 then
				plain_text = true
				local payload, payload_err = subblocks("plain-text extension")
				if not payload then
					return nil, payload_err
				end
				records[#records + 1] = "plain-text=" .. tostring(payload)
			elseif label == 0xFF then
				local identifier_size = data:byte(position)
				if identifier_size ~= 11 or position + identifier_size > size then
					return nil, "invalid GIF application extension"
				end
				local identifier = data:sub(position + 1, position + identifier_size)
				position = position + identifier_size + 1
				local payload_start = position
				local payload, payload_err = subblocks("application extension")
				if not payload then
					return nil, payload_err
				end
				if identifier == "NETSCAPE2.0" or identifier == "ANIMEXTS1.0" then
					local loop_marker = data:byte(payload_start + 1)
					local low = data:byte(payload_start + 2)
					local high = data:byte(payload_start + 3)
					if payload ~= 3 or data:byte(payload_start) ~= 3 or loop_marker ~= 1 or not low or not high then
						return nil, "invalid GIF loop extension"
					end
					local value = low + high * 256
					if loop_count and loop_count ~= value then
						return nil, "conflicting GIF loop extensions"
					end
					loop_count = value
					records[#records + 1] = "loop=" .. tostring(value)
				elseif identifier == "ICCRGBG1012" then
					local block = data:sub(payload_start, position - 1)
					local cleaned = ICC.gif(block)
					if cleaned then
						icc_patches[#icc_patches + 1] = { start = payload_start, bytes = cleaned }
					end
					records[#records + 1] = "icc=" .. (cleaned or block)
				else
					removable_ranges[#removable_ranges + 1] = { start = extension_start, finish = position - 1 }
				end
			else
				local _, payload_err = subblocks("extension")
				if payload_err then
					return nil, payload_err
				end
				removable_ranges[#removable_ranges + 1] = { start = extension_start, finish = position - 1 }
			end
		else
			return nil, "unknown GIF block marker"
		end
	end
	return nil, "GIF trailer is missing"
end

local GIF_POLICY = {
	spec = GIF_SPEC,
	preflight = function(path)
		local structure, parsed = gif_structure_manifest(path)
		if not structure then
			return nil, parsed
		end
		if parsed.plain_text then
			return nil, "GIF plain-text extensions are unsupported"
		end
		-- Patched ICC payloads keep their length, so offsets do not move.
		for _, patch in ipairs(parsed.icc_patches) do
			parsed.data = parsed.data:sub(1, patch.start - 1)
				.. patch.bytes
				.. parsed.data:sub(patch.start + #patch.bytes)
		end
		parsed.structure = structure
		return parsed
	end,
	structure_clean = function(parsed)
		if #parsed.icc_patches > 0 then
			return false, "GIF ICC profile with the display serial number"
		end
		return #parsed.removable_ranges == 0, "GIF comment or application block"
	end,
	capture = function(path, _, parsed)
		local decoded, decoded_err = deterministic_framehash(path)
		if not decoded then
			return nil, decoded_err
		end
		return {
			structure = parsed.structure,
			protected = protected_bytes(parsed.data, parsed.removable_ranges),
			decoded = decoded,
		}
	end,
	equivalent = compare_fields("GIF %s changed", { "structure", "protected", "decoded" }),
	transform = function(ctx)
		return rewrite_file(ctx.staged, protected_bytes(ctx.state.data, ctx.state.removable_ranges))
	end,
}

-- SVG ------------------------------------------------------------------------

-- A small XML tokenizer finds exact element, attribute and comment boundaries.
-- Comments, <metadata> and editor-private elements and attributes (Inkscape
-- export paths contain the user's home directory) are removed. Active content,
-- external references, embedded data URIs, DOCTYPEs, CDATA and processing
-- instructions make the file skip. <title> and <desc> are document content
-- used for accessibility and are kept.
local SVG_EDITOR_PREFIXES = { inkscape = true, sodipodi = true, sketch = true, serif = true }
local SVG_ACTIVE_ELEMENTS = { script = true, foreignobject = true, set = true, handler = true, listener = true }

local SVG_SPEC = metadata_spec({
	keep = FILE_BASICS,
	free = { "SVG:*" },
})

local function svg_unsafe_text(text)
	local lower = text:lower()
	if lower:find("@import", 1, true) then
		return true
	end
	for target in lower:gmatch("url%s*%(%s*['\"]?%s*(.)") do
		if target ~= "#" then
			return true
		end
	end
	return false
end

local function svg_parse(path)
	local data, read_err = read_file(path, LIMIT.SVG_BYTES, "SVG")
	if not data then
		return nil, read_err
	end
	local position = data:sub(1, 3) == "\239\187\191" and 4 or 1
	local first = position
	local removable, stack, removing, root = {}, {}, 0, false
	local function add(start, finish)
		if removing == 0 then
			removable[#removable + 1] = { start = start, finish = finish }
		end
	end
	while true do
		local lt = data:find("<", position, true)
		local text = data:sub(position, (lt or #data + 1) - 1)
		if svg_unsafe_text(text) then
			return nil, "external SVG reference"
		end
		if (#stack == 0) and text:match("%S") then
			return nil, "text outside the SVG root"
		end
		if not lt then
			break
		end
		if data:sub(lt, lt + 3) == "<!--" then
			local close = data:find("-->", lt + 4, true)
			if not close then
				return nil, "unterminated SVG comment"
			end
			add(lt, close + 2)
			position = close + 3
		elseif data:sub(lt, lt + 1) == "<!" then
			-- Only the standard W3C SVG document types, before the root and
			-- without an internal subset (which can define entities), are kept.
			local doctype
			if #stack == 0 then
				doctype = data:match("^<!DOCTYPE%s+svg%s*>()", lt)
					or select(
						3,
						data:match(
							"^<!DOCTYPE%s+svg%s+PUBLIC%s+(['\"])-//W3C//DTD SVG [%w%. ]+//EN%1%s+(['\"])"
								.. "http://www%.w3%.org/[%w%./%-]+%.dtd%2%s*>()",
							lt
						)
					)
			end
			if not doctype then
				return nil, "SVG DOCTYPE or CDATA is unsupported"
			end
			position = doctype
		elseif data:sub(lt, lt + 1) == "<?" then
			local close = data:find("?>", lt + 2, true)
			-- XMP packet markers inside a removed <metadata> element go with it.
			if not close or not (removing > 0 or lt == first and data:sub(lt, lt + 5):match("^<%?xml%s")) then
				return nil, "SVG processing instructions are unsupported"
			end
			position = close + 2
		elseif data:sub(lt, lt + 1) == "</" then
			local name, after = data:match("^</([%w_%.:%-]+)%s*>()", lt)
			local open = table.remove(stack)
			if not name or not open or open.name ~= name then
				return nil, "malformed SVG element nesting"
			end
			if open.removed then
				removing = removing - 1
				add(open.start, after - 1)
			end
			position = after
		else
			local name = data:match("^<([%w_%.:%-]+)", lt)
			if not name then
				return nil, "malformed SVG tag"
			end
			local prefix, local_name = name:match("^([^:]+):(.+)$")
			local_name = (local_name or name):lower()
			if SVG_ACTIVE_ELEMENTS[local_name] or local_name:match("^animate") then
				return nil, "active SVG content: " .. name
			end
			if not root then
				if local_name ~= "svg" or #stack > 0 then
					return nil, "invalid SVG root"
				end
				root = true
			elseif #stack == 0 then
				return nil, "multiple SVG root elements"
			end
			local remove_element = local_name == "metadata" or (prefix and SVG_EDITOR_PREFIXES[prefix:lower()])
			if remove_element then
				removing = removing + 1
			end
			local p, self_closing = lt + 1 + #name, false
			while true do
				local spaced = data:match("^%s*()", p)
				if data:sub(spaced, spaced) == ">" then
					p = spaced + 1
					break
				elseif data:sub(spaced, spaced + 1) == "/>" then
					p, self_closing = spaced + 2, true
					break
				end
				local attribute, quote_at = data:match("^([%w_%.:%-]+)%s*=%s*()", spaced)
				if not attribute or spaced == p then
					return nil, "malformed SVG attribute"
				end
				local quote = data:sub(quote_at, quote_at)
				if quote ~= '"' and quote ~= "'" then
					return nil, "unquoted SVG attribute"
				end
				local close = data:find(quote, quote_at + 1, true)
				if not close then
					return nil, "unterminated SVG attribute"
				end
				local value = data:sub(quote_at + 1, close - 1)
				local lower_name = attribute:lower()
				local attribute_prefix = lower_name:match("^([^:]+):")
				if lower_name:match("^on") then
					return nil, "active SVG attribute: " .. attribute
				end
				if lower_name:match("href$") or lower_name == "src" then
					if not value:match("^%s*#") then
						return nil, "external SVG reference"
					end
				end
				if
					svg_unsafe_text(value)
					or (lower_name == "style" and (value:find("&#", 1, true) or value:find("\\", 1, true)))
				then
					return nil, "external SVG reference"
				end
				if attribute_prefix and SVG_EDITOR_PREFIXES[attribute_prefix] then
					add(p, close)
				end
				p = close + 1
			end
			if remove_element and self_closing then
				removing = removing - 1
				add(lt, p - 1)
			elseif not self_closing then
				stack[#stack + 1] = { name = name, start = lt, removed = remove_element }
				if local_name == "style" then
					local close = data:find("</", p, true)
					local css = data:sub(p, (close or #data + 1) - 1)
					if css:find("&#", 1, true) or css:find("\\", 1, true) then
						return nil, "escaped SVG style content is unsupported"
					end
				end
			end
			position = p
		end
	end
	if not root or #stack > 0 then
		return nil, "malformed SVG document"
	end
	return { data = data, removable_ranges = removable }
end

local SVG_POLICY = {
	spec = SVG_SPEC,
	preflight = svg_parse,
	structure_clean = function(parsed)
		return #parsed.removable_ranges == 0, "SVG metadata, comment or editor data"
	end,
	capture = function(_, _, parsed)
		return { protected = protected_bytes(parsed.data, parsed.removable_ranges) }
	end,
	equivalent = function(before, after)
		return before.protected == after.protected or nil, "SVG rendering bytes changed"
	end,
	transform = function(ctx)
		return rewrite_file(ctx.staged, protected_bytes(ctx.state.data, ctx.state.removable_ranges))
	end,
}

-- BMP and ICO ------------------------------------------------------------------

-- BMP headers hold no free-text metadata apart from a linked colour profile
-- path, which is not on the allowlist, so such files skip. The bytes are never
-- changed; only the filesystem metadata is normalized.
local BMP_SPEC = metadata_spec({
	keep = with_basics({
		"File:BMPVersion",
		"File:ImageWidth",
		"File:ImageHeight",
		"File:Planes",
		"File:BitDepth",
		"File:Compression",
		"File:ImageLength",
		"File:PixelsPerMeterX",
		"File:PixelsPerMeterY",
		"File:NumColors",
		"File:NumImportantColors",
		"File:RedMask",
		"File:GreenMask",
		"File:BlueMask",
		"File:AlphaMask",
		"File:ColorSpace",
		"File:RedEndpoint",
		"File:GreenEndpoint",
		"File:BlueEndpoint",
		"File:GammaRed",
		"File:GammaGreen",
		"File:GammaBlue",
		"File:RenderingIntent",
		"File:ProfileDataOffset",
		"File:ProfileSize",
		"^ICC:*",
	}),
})

local function bmp_structure_manifest(path)
	local file, open_err = io.open(path, "rb")
	if not file then
		return nil, tostring(open_err or "could not open BMP file")
	end
	local size = file:seek("end")
	file:seek("set", 0)
	local header = file:read(54)
	file:close()
	if not header or #header < 54 or header:sub(1, 2) ~= "BM" then
		return nil, "invalid BMP header"
	end
	-- The bytes never change, so this only has to recognize a BMP. Older
	-- writers put other values in the file size field, and OS/2 1.x uses a
	-- 12-byte header with 16-bit dimensions.
	local pixels = le_u32(header:sub(11, 14))
	local dib = le_u32(header:sub(15, 18))
	local width, height, planes, bit_depth, compression
	if dib == 12 then
		width, height = le_u16(header:sub(19, 20)), le_u16(header:sub(21, 22))
		planes, bit_depth, compression = le_u16(header:sub(23, 24)), le_u16(header:sub(25, 26)), 0
	else
		width, height = le_u32(header:sub(19, 22)), le_u32(header:sub(23, 26))
		planes, bit_depth = le_u16(header:sub(27, 28)), le_u16(header:sub(29, 30))
		compression = le_u32(header:sub(31, 34))
	end
	if not dib or (dib ~= 12 and dib < 16) or not pixels or pixels < 14 + dib or pixels >= size then
		return nil, "invalid BMP layout"
	end
	if not width or width == 0 or not height or height == 0 or planes ~= 1 or not bit_depth or not compression then
		return nil, "invalid BMP DIB fields"
	end
	return table.concat({
		"bmp-structure-v1",
		"size=" .. tostring(size),
		"dib=" .. tostring(dib),
		"pixels=" .. tostring(pixels),
		"width=" .. tostring(width),
		"height=" .. tostring(height),
		"depth=" .. tostring(bit_depth),
		"compression=" .. tostring(compression),
	}, "\n")
end

local BMP_POLICY = {
	spec = BMP_SPEC,
	preflight = function(path)
		local structure, err = bmp_structure_manifest(path)
		return structure and { structure = structure } or nil, err
	end,
	structure_clean = function()
		return true
	end,
	capture = function(path, _, state)
		local encoded, encoded_err = file_sha256(path)
		if not encoded then
			return nil, encoded_err
		end
		local decoded, decoded_err = deterministic_framehash(path)
		if not decoded then
			return nil, decoded_err
		end
		return { encoded = encoded, decoded = decoded, structure = state.structure }
	end,
	equivalent = compare_fields("BMP %s changed", { "encoded", "decoded", "structure" }),
	transform = function()
		return true
	end,
}

-- ICO entries are BMP DIBs or complete PNG files. Embedded PNGs are cleaned
-- with the PNG chunk rules and the directory is rebuilt with new sizes and
-- offsets; BMP entries are copied unchanged.
local ICO_SPEC = metadata_spec({
	keep = with_basics({
		"File:ImageCount",
		"File:ImageWidth",
		"File:ImageHeight",
		"File:NumColors",
		"File:ColorPlanes",
		"File:BitsPerPixel",
	}),
	recomputed = { "File:ImageLength" },
})

local function ico_parse(path)
	local data, read_err = read_file(path, LIMIT.ICO_BYTES, "ICO")
	if not data then
		return nil, read_err
	end
	local size = #data
	if size < 6 or le_u16(data:sub(1, 2)) ~= 0 or le_u16(data:sub(3, 4)) ~= 1 then
		return nil, "invalid ICO header"
	end
	local count = le_u16(data:sub(5, 6))
	if not count or count == 0 or count > 1024 or 6 + count * 16 > size then
		return nil, "invalid ICO directory"
	end
	local entries, ranges = {}, {}
	for index = 1, count do
		local base = 7 + (index - 1) * 16
		local directory = data:sub(base, base + 15)
		local length, offset = le_u32(directory:sub(9, 12)), le_u32(directory:sub(13, 16))
		if not length or not offset or length == 0 or offset < 6 + count * 16 or offset + length > size then
			return nil, "invalid ICO image range"
		end
		local image = data:sub(offset + 1, offset + length)
		local entry = { index = index, directory = directory, offset = offset, image = image }
		if image:sub(1, 8) == PNG_SIGNATURE then
			local parsed, png_err = png_parse(image)
			if not parsed then
				return nil, "ICO PNG entry: " .. png_err
			end
			if parsed.exif and parsed.exif.orientation and parsed.exif.orientation ~= 1 then
				return nil, "ICO PNG entry with EXIF orientation is unsupported"
			end
			entry.png = parsed
		end
		entries[#entries + 1] = entry
		ranges[#ranges + 1] = { start = offset, finish = offset + length }
	end
	local valid, range_err = validate_ranges(ranges, 0, size)
	if not valid then
		return nil, range_err == "overlapping ranges" and "overlapping ICO image ranges" or range_err
	end
	return { header = data:sub(1, 6), entries = entries }
end

local function ico_manifest(parsed)
	local records = { "ico-structure-v2", "count=" .. tostring(#parsed.entries) }
	local images = {}
	for _, entry in ipairs(parsed.entries) do
		records[#records + 1] = table.concat({
			"image=" .. tostring(entry.index),
			"kind=" .. (entry.png and "png" or "dib"),
			-- Width, height, colours, planes and bit depth; size and offset
			-- legitimately change when an embedded PNG is cleaned.
			"fields=" .. entry.directory:sub(1, 8):gsub(".", function(c)
				return string.format("%02x", c:byte())
			end),
		}, ",")
		images[#images + 1] = entry.png and png_protected(entry.png) or entry.image
	end
	return table.concat(records, "\n"), table.concat(images, "\0")
end

local function ico_output(parsed)
	local ordered = {}
	for _, entry in ipairs(parsed.entries) do
		ordered[#ordered + 1] = entry
	end
	table.sort(ordered, function(a, b)
		return a.offset < b.offset
	end)
	local offset, images, placed = 6 + #parsed.entries * 16, {}, {}
	for _, entry in ipairs(ordered) do
		local image = entry.png and png_output(entry.png, false) or entry.image
		placed[entry.index] = { offset = offset, length = #image }
		images[#images + 1] = image
		offset = offset + #image
	end
	local directory = {}
	for _, entry in ipairs(parsed.entries) do
		local place = placed[entry.index]
		directory[#directory + 1] = entry.directory:sub(1, 8)
			.. u32_le_bytes(place.length)
			.. u32_le_bytes(place.offset)
	end
	return parsed.header .. table.concat(directory) .. table.concat(images)
end

local ICO_POLICY = {
	spec = ICO_SPEC,
	preflight = ico_parse,
	structure_clean = function(parsed)
		for _, entry in ipairs(parsed.entries) do
			if entry.png and #entry.png.removable > 0 then
				return false, "ICO PNG entry metadata"
			end
		end
		return true
	end,
	capture = function(path, _, parsed)
		local decoded, decoded_err = deterministic_framehash(path, "0:v")
		if not decoded then
			return nil, decoded_err
		end
		local structure, protected = ico_manifest(parsed)
		return { decoded = decoded, structure = structure, protected = protected }
	end,
	equivalent = compare_fields("ICO %s changed", { "structure", "protected", "decoded" }),
	transform = function(ctx)
		return rewrite_file(ctx.staged, ico_output(ctx.state))
	end,
}

local function parse_webp(path)
	local data, data_err = read_file(path, LIMIT.WEBP_BYTES, "WebP")
	if not data then
		return nil, data_err
	end
	local size = #data
	if size < 12 then
		return nil, "truncated WebP file"
	end
	if data:sub(1, 4) ~= "RIFF" or data:sub(9, 12) ~= "WEBP" then
		return nil, "invalid WebP RIFF signature"
	end
	local declared = le_u32(data:sub(5, 8))
	if not declared or declared + 8 ~= size then
		return nil, "WebP declared size mismatch"
	end
	local position, image, seen, chunks, frames = 12, nil, {}, {}, {}
	local function u24le(offset)
		local a, b, c = data:byte(offset, offset + 2)
		return c and a + b * 256 + c * 65536 or nil
	end
	-- An ANMF payload is a 16-byte frame header followed by an optional ALPH
	-- chunk and one VP8 or VP8L bitstream; anything else could carry data
	-- that is copied along with the frame.
	local function frame(start, length)
		if length < 16 then
			return nil, "truncated WebP animation frame"
		end
		local first = start + 1
		if data:byte(first + 15) >= 4 then
			return nil, "unsupported WebP animation frame flags"
		end
		local rect = {
			x = u24le(first) * 2,
			y = u24le(first + 3) * 2,
			width = u24le(first + 6) + 1,
			height = u24le(first + 9) + 1,
		}
		local offset, finish, kinds = start + 16, start + length, {}
		while offset < finish do
			if finish - offset < 8 then
				return nil, "truncated WebP frame chunk header"
			end
			local kind, size = data:sub(offset + 1, offset + 4), le_u32(data:sub(offset + 5, offset + 8))
			local next_offset = checked_add(offset + 8, size + size % 2)
			if not next_offset or next_offset > finish then
				return nil, "truncated WebP frame chunk"
			end
			kinds[#kinds + 1] = kind
			offset = next_offset
		end
		local layout = table.concat(kinds, ",")
		if layout ~= "VP8 " and layout ~= "VP8L" and layout ~= "ALPH,VP8 " then
			return nil, "unsupported WebP animation frame chunks"
		end
		return rect
	end
	while position < size do
		if size - position < 8 then
			return nil, "truncated WebP chunk header"
		end
		local index = position + 1
		local kind, length = data:sub(index, index + 3), le_u32(data:sub(index + 4, index + 7))
		local padded = length and checked_add(length, length % 2)
		local finish = padded and checked_add(position + 8, padded)
		if not length or not finish or finish > size then
			return nil, "truncated WebP chunk"
		end
		if #chunks >= LIMIT.WEBP_CHUNKS then
			return nil, "WebP chunk count limit exceeded"
		end
		if kind == "ANMF" then
			local rect, frame_err = frame(position + 8, length)
			if not rect then
				return nil, frame_err
			end
			rect.header_start = position
			frames[#frames + 1] = rect
		elseif kind == "VP8 " or kind == "VP8L" then
			if image then
				return nil, "multiple WebP image payloads"
			end
			image = kind
		elseif
			kind == "VP8X"
			or kind == "ICCP"
			or kind == "EXIF"
			or kind == "XMP "
			or kind == "ALPH"
			or kind == "ANIM"
		then
			if seen[kind] then
				return nil, "duplicate WebP " .. kind .. " chunk"
			end
			seen[kind] = true
		end
		local padding_length = length % 2
		local payload_start = position + 8
		local chunk = {
			index = #chunks + 1,
			type = kind,
			header_start = position,
			payload_start = payload_start,
			payload_length = length,
			padding_start = payload_start + length,
			padding_length = padding_length,
		}
		chunk.bytes = data:sub(position + 1, finish)
		if padding_length == 1 then
			chunk.padding_byte = data:byte(chunk.padding_start + 1)
		end
		chunks[#chunks + 1] = chunk
		position = finish
	end
	if position ~= size then
		return nil, "WebP trailing bytes"
	end
	local animated = seen["ANIM"] or #frames > 0
	if animated then
		if image or seen["ALPH"] then
			return nil, "WebP animation with a still image payload"
		elseif not seen["ANIM"] or #frames == 0 or not seen["VP8X"] then
			return nil, "incomplete WebP animation"
		end
		image = "ANIM"
	elseif not image then
		return nil, "missing WebP image payload"
	end
	local image_chunk
	for _, chunk in ipairs(chunks) do
		if chunk.type == image then
			image_chunk = chunk
			break
		end
	end
	-- Metadata must follow the image payload, which for an animation is the
	-- last frame.
	local payload_end = animated and frames[#frames].header_start or image_chunk.header_start
	if animated and frames[1].header_start < image_chunk.header_start then
		return nil, "invalid WebP ANIM chunk order"
	end
	local function chunk_position(kind)
		for _, chunk in ipairs(chunks) do
			if chunk.type == kind then
				return chunk.header_start
			end
		end
	end
	local vp8x_position, iccp_position, alph_position =
		chunk_position("VP8X"), chunk_position("ICCP"), chunk_position("ALPH")
	local exif_position, xmp_position = chunk_position("EXIF"), chunk_position("XMP ")
	if
		vp8x_position
		and (
			vp8x_position > image_chunk.header_start
			or (iccp_position and vp8x_position > iccp_position)
			or (alph_position and vp8x_position > alph_position)
		)
	then
		return nil, "invalid WebP VP8X chunk order"
	end
	if iccp_position and iccp_position > image_chunk.header_start then
		return nil, "invalid WebP ICCP chunk order"
	end
	if alph_position and alph_position > image_chunk.header_start then
		return nil, "invalid WebP ALPH chunk order"
	end
	if exif_position and exif_position < payload_end then
		return nil, "invalid WebP EXIF chunk order"
	end
	if xmp_position and xmp_position < payload_end then
		return nil, "invalid WebP XMP chunk order"
	end
	if exif_position and xmp_position and exif_position > xmp_position then
		return nil, "invalid WebP metadata chunk order"
	end
	local width, height, vp8l_alpha
	if animated then
		width, height = 0, 0
	elseif image == "VP8L" then
		if image_chunk.payload_length < 5 or data:byte(image_chunk.payload_start + 1) ~= 0x2F then
			return nil, "invalid VP8L header"
		end
		local fields = le_u32(data:sub(image_chunk.payload_start + 2, image_chunk.payload_start + 5))
		if not fields or math.floor(fields / 536870912) ~= 0 then
			return nil, "unsupported VP8L version"
		end
		width, height = fields % 16384 + 1, math.floor(fields / 16384) % 16384 + 1
		vp8l_alpha = math.floor(fields / 268435456) % 2 == 1
	else
		if
			image_chunk.payload_length < 10
			or data:byte(image_chunk.payload_start + 1) % 2 ~= 0
			or data:sub(image_chunk.payload_start + 4, image_chunk.payload_start + 6) ~= "\157\1\42"
		then
			return nil, "invalid VP8 key frame header"
		end
		local encoded_width = le_u16(data:sub(image_chunk.payload_start + 7, image_chunk.payload_start + 8))
		local encoded_height = le_u16(data:sub(image_chunk.payload_start + 9, image_chunk.payload_start + 10))
		if not encoded_width or not encoded_height then
			return nil, "truncated VP8 dimensions"
		end
		width, height = encoded_width % 16384, encoded_height % 16384
		if width == 0 or height == 0 then
			return nil, "invalid VP8 dimensions"
		end
	end
	if (width > LIMIT.WEBP_DIMENSION or height > LIMIT.WEBP_DIMENSION) and not animated then
		return nil, "WebP dimensions exceed parser limit"
	end
	if seen["ALPH"] and image ~= "VP8 " then
		return nil, "ALPH requires VP8 image payload"
	end
	if seen["VP8X"] then
		local vp8x
		for _, chunk in ipairs(chunks) do
			if chunk.type == "VP8X" then
				vp8x = chunk
				break
			end
		end
		if vp8x.payload_length ~= 10 then
			return nil, "invalid VP8X length"
		end
		local flags = data:byte(vp8x.payload_start + 1)
		if flags % 2 ~= 0 or flags >= 64 then
			return nil, "unsupported VP8X reserved flags"
		end
		if (math.floor(flags / 2) % 2 == 1) ~= animated then
			return nil, "VP8X feature flag mismatch: ANIM"
		end
		local canvas_width, canvas_height = u24le(vp8x.payload_start + 5), u24le(vp8x.payload_start + 8)
		if not canvas_width or not canvas_height then
			return nil, "truncated VP8X canvas"
		end
		canvas_width, canvas_height = canvas_width + 1, canvas_height + 1
		if canvas_width > LIMIT.WEBP_DIMENSION or canvas_height > LIMIT.WEBP_DIMENSION then
			return nil, "WebP canvas exceeds parser limit"
		end
		if animated then
			for _, rect in ipairs(frames) do
				if rect.x + rect.width > canvas_width or rect.y + rect.height > canvas_height then
					return nil, "WebP animation frame outside the canvas"
				end
			end
			width, height = canvas_width, canvas_height
		elseif canvas_width ~= width or canvas_height ~= height then
			return nil, "unsupported VP8X canvas mismatch"
		end
		local expected = {
			ICCP = math.floor(flags / 32) % 2 == 1,
			EXIF = math.floor(flags / 8) % 2 == 1,
			["XMP "] = math.floor(flags / 4) % 2 == 1,
		}
		for kind, flagged in pairs(expected) do
			if flagged ~= (seen[kind] and true or false) then
				return nil, "VP8X feature flag mismatch: " .. kind
			end
		end
		-- For an animation the alpha flag is only a hint about its frames.
		local alpha_flagged = math.floor(flags / 16) % 2 == 1
		local alpha_present = seen["ALPH"] or (image == "VP8L" and vp8l_alpha)
		if alpha_flagged ~= alpha_present and not animated then
			return nil, "VP8X feature flag mismatch: ALPH"
		end
		return {
			file_size = size,
			riff_declared_size = declared,
			image_type = image,
			width = width,
			height = height,
			vp8l_alpha = vp8l_alpha,
			chunks = chunks,
			vp8x = { flags = flags, canvas_width = canvas_width, canvas_height = canvas_height },
		}
	elseif seen["ICCP"] or seen["EXIF"] or seen["XMP "] or seen["ALPH"] then
		return nil, "extended WebP chunks require VP8X"
	end
	return {
		file_size = size,
		riff_declared_size = declared,
		image_type = image,
		width = width,
		height = height,
		vp8l_alpha = vp8l_alpha,
		chunks = chunks,
	}
end

-- WebP ---------------------------------------------------------------------------

-- WebP is rewritten chunk by chunk: VP8X, ICCP, ALPH, the image payload and
-- the animation chunks are kept byte-for-byte, EXIF, XMP and unknown chunks
-- are dropped, and the VP8X EXIF/XMP flags are cleared. A non-default EXIF
-- orientation stays as an EXIF chunk with only that value, so viewers that
-- apply it still do.
local WEBP_KEEP = { VP8X = true, ICCP = true, ALPH = true, ["VP8 "] = true, VP8L = true, ANIM = true, ANMF = true }
local WEBP_METADATA_FLAGS = 8 + 4

local WEBP_SPEC = metadata_spec({
	keep = with_basics({
		"RIFF:ImageWidth",
		"RIFF:ImageHeight",
		"RIFF:AlphaIsUsed",
		"RIFF:VP8Version",
		"RIFF:HorizontalScale",
		"RIFF:VerticalScale",
		"RIFF:AlphaPreprocessing",
		"RIFF:AlphaFiltering",
		"RIFF:AlphaCompression",
		"RIFF:BackgroundColor",
		"RIFF:AnimationLoopCount",
		"RIFF:Duration",
		"^ICC:*",
		"IFD0:Orientation",
	}),
	free = { "File:ExifByteOrder" },
	recomputed = { "RIFF:WebP_Flags" },
})

local function serialize_webp_protected(parsed)
	local records =
		{
			"webp-v4-protected",
			"image=" .. parsed.image_type .. ",width=" .. tostring(parsed.width) .. ",height=" .. tostring(
				parsed.height
			) .. ",vp8l_alpha=" .. tostring(parsed.vp8l_alpha == true),
		}
	if parsed.vp8x then
		records[#records + 1] = "vp8x=protected_flags:"
			.. tostring(parsed.vp8x.flags & ~WEBP_METADATA_FLAGS)
			.. ",canvas:"
			.. tostring(parsed.vp8x.canvas_width)
			.. "x"
			.. tostring(parsed.vp8x.canvas_height)
	end
	for _, chunk in ipairs(parsed.chunks) do
		-- VP8X carries the metadata presence bits, recorded above without them.
		if WEBP_KEEP[chunk.type] and chunk.type ~= "VP8X" then
			records[#records + 1] = "chunk=" .. chunk.type .. "\n" .. chunk.bytes
		end
	end
	return table.concat(records, "\n")
end

-- The EXIF chunk that keeps only the orientation, after the image data as
-- the container specification orders it.
local function webp_orientation_chunk(orientation)
	local exif = minimal_exif(orientation)
	return "EXIF" .. u32_le_bytes(#exif) .. exif
end

local function webp_output(parsed)
	local parts = {}
	for _, chunk in ipairs(parsed.chunks) do
		if chunk.type == "VP8X" then
			local payload = chunk.bytes:sub(9, 18)
			parts[#parts + 1] = "VP8X"
				.. u32_le_bytes(10)
				.. string.char(payload:byte(1) & ~WEBP_METADATA_FLAGS | (parsed.orientation and 8 or 0))
				.. payload:sub(2)
		elseif WEBP_KEEP[chunk.type] then
			parts[#parts + 1] = chunk.bytes
		end
	end
	if parsed.orientation then
		parts[#parts + 1] = webp_orientation_chunk(parsed.orientation)
	end
	local body = "WEBP" .. table.concat(parts)
	return "RIFF" .. u32_le_bytes(#body) .. body
end

local WEBP_POLICY = {
	spec = WEBP_SPEC,
	preflight = function(path, inventory)
		local parsed, err = parse_webp(path)
		if not parsed then
			return nil, err
		end
		-- Some viewers rotate WebP by its EXIF orientation, so a non-default
		-- value is kept. EXIF chunks need the extended format.
		local orientations = inventory.values["IFD0:Orientation"] or {}
		local orientation = tonumber(orientations[1])
		if #orientations > 1 or orientations[1] and not (orientation and orientation >= 1 and orientation <= 8) then
			return nil, "WebP with an unclear EXIF orientation"
		elseif orientation and orientation > 1 then
			-- Some writers put JPEG's Exif header before the TIFF data; viewers
			-- disagree about reading it, and so about the rotation.
			local tiff
			for _, chunk in ipairs(parsed.chunks) do
				if chunk.type == "EXIF" then
					tiff = chunk.bytes:sub(9, 8 + chunk.payload_length)
				end
			end
			if not parsed.vp8x or not tiff or exif_orientation(tiff) ~= orientation then
				return nil, "WebP EXIF orientation that viewers may read differently"
			end
			parsed.orientation = math.tointeger(orientation)
		end
		-- The planned ICCP chunk replaces the original for output and checks.
		for _, chunk in ipairs(parsed.chunks) do
			if chunk.type == "ICCP" then
				local cleaned = ICC.clean(chunk.bytes:sub(9, 8 + chunk.payload_length))
				if cleaned then
					chunk.bytes = chunk.bytes:sub(1, 8) .. cleaned .. chunk.bytes:sub(9 + chunk.payload_length)
					parsed.icc_patched = true
				end
			end
		end
		return parsed
	end,
	structure_clean = function(parsed)
		if parsed.icc_patched then
			return false, "WebP ICC profile with the display serial number"
		end
		-- Clean is the planned output: kept chunks, then the orientation chunk.
		local planned = parsed.orientation and webp_orientation_chunk(parsed.orientation)
		for index, chunk in ipairs(parsed.chunks) do
			local last = index == #parsed.chunks
			if not WEBP_KEEP[chunk.type] and not (planned and last and chunk.bytes == planned) then
				return false, "WebP " .. chunk.type .. " chunk"
			end
		end
		local flags = parsed.vp8x and parsed.vp8x.flags & WEBP_METADATA_FLAGS or 0
		if flags ~= (planned and 8 or 0) or planned and parsed.chunks[#parsed.chunks].bytes ~= planned then
			return false, "WebP metadata flags"
		end
		return true
	end,
	capture = function(path, _, parsed)
		local decoded, stream, err = still_capture(path)
		if not decoded then
			return nil, err
		end
		return { decoded = decoded, stream = stream, protected = serialize_webp_protected(parsed) }
	end,
	equivalent = compare_fields("WebP %s changed", { "protected", "decoded", "stream" }),
	transform = function(ctx)
		return rewrite_file(ctx.staged, webp_output(ctx.state))
	end,
}

local function ebml_vint(data, position, identifier)
	local first = data:byte(position)
	if not first then
		return nil, "truncated EBML variable integer"
	end
	local length, marker = 1, 128
	while length <= 8 and first < marker do
		length = length + 1
		marker = marker // 2
	end
	if length > 8 or position + length - 1 > #data then
		return nil, "invalid EBML variable integer"
	end
	if identifier and length > 4 then
		return nil, "unsupported EBML element ID width"
	end
	if not identifier then
		local unknown = first == marker * 2 - 1
		for index = position + 1, position + length - 1 do
			unknown = unknown and data:byte(index) == 255
		end
		if unknown then
			return 0, length, true
		end
	end
	local value = identifier and first or first % marker
	for index = 1, length - 1 do
		if value > math.floor(LIMIT.SAFE_INTEGER / 256) then
			return nil, "unsupported EBML size value"
		end
		value = value * 256 + data:byte(position + index)
	end
	return value, length
end

-- MP4, MOV, M4V and M4A ------------------------------------------------------------

-- QuickTime files are cleaned in place without moving a byte: every metadata
-- box (udta, meta, the XMP uuid) is renamed to "free" and zero-filled, free
-- space is zeroed, and the movie, track and media creation/modification
-- dates are set to zero. Sample tables and media data keep their offsets.
-- Verification proves that the staged file differs from the source only
-- inside exactly those regions.
local QUICKTIME_CHILDREN = {
	[""] = as_set({
		"ftyp",
		"moov",
		"mdat",
		"meta",
		"free",
		"skip",
		"wide",
		"uuid",
		"moof",
		"mfra",
		"sidx",
		"ssix",
		"styp",
		"prft",
		"emsg",
	}),
	moov = as_set({ "mvhd", "trak", "udta", "meta", "iods", "uuid", "free", "skip", "mvex" }),
	trak = as_set({ "tkhd", "edts", "mdia", "tref", "udta", "meta", "tapt", "load", "uuid", "free", "skip" }),
	edts = as_set({ "elst" }),
	mdia = as_set({ "mdhd", "hdlr", "minf", "udta", "free", "skip" }),
	minf = as_set({ "vmhd", "smhd", "gmhd", "nmhd", "hmhd", "sthd", "dinf", "stbl", "hdlr", "free", "skip" }),
	dinf = as_set({ "dref" }),
	stbl = as_set({
		"stsd",
		"stts",
		"ctts",
		"cslg",
		"stss",
		"stps",
		"stsc",
		"stsz",
		"stz2",
		"stco",
		"co64",
		"sdtp",
		"sbgp",
		"sgpd",
		"csgm",
		"subs",
		"saiz",
		"saio",
		"free",
		"skip",
	}),
	tapt = as_set({ "clef", "prof", "enof" }),
	-- Movie fragments. Encrypted fragments (senc, saiz, saio, pssh) are not
	-- supported: their auxiliary data lies in the media data outside samples.
	mvex = as_set({ "mehd", "trex", "free", "skip" }),
	moof = as_set({ "mfhd", "traf", "free", "skip" }),
	traf = as_set({ "tfhd", "tfdt", "trun", "sbgp", "sgpd", "subs", "sdtp", "free", "skip" }),
	mfra = as_set({ "tfra", "mfro", "free", "skip" }),
}
local QUICKTIME_CONTAINERS =
	as_set({ "moov", "trak", "edts", "mdia", "minf", "dinf", "stbl", "tapt", "mvex", "moof", "traf", "mfra" })
-- A producer reference time is the wall-clock time a fragment was made, and
-- an event message carries any payload (ID3 tags in HLS).
local QUICKTIME_FRAGMENT_METADATA = as_set({ "prft", "emsg" })
-- uuid box types. Spherical Video V1 projection metadata is needed to play
-- 360° video. Sony: PROF describes the codec profiles; USMT holds Sony's own
-- metadata (titles and a non-real-time XML document with device data). C2PA
-- Content Credentials hold the creator, device and edit history. KDDI phones
-- add a family of boxes (encoder and phone names, copy guard, mail flags)
-- that share the last 12 bytes and are read only by those phones.
local QUICKTIME_UUID = {
	xmp = "\190\122\207\203\151\169\66\232\156\113\153\148\145\227\175\172",
	spherical = "\255\204\130\99\248\85\74\147\136\20\88\122\2\82\31\221",
	sony_profile = "PROF\33\210\79\206\187\136\105\92\250\201\199\64",
	sony_metadata = "USMT\33\210\79\206\187\136\105\92\250\201\199\64",
	c2pa = "\216\254\195\214\27\14\72\60\146\151\88\40\135\126\196\129",
	kddi = "\168\140\17\212\129\151\0\144\39\8\119\3",
}

-- Sample-description boxes ExifTool does not name, with the largest payload
-- their specifications allow. None has room for free text, and dfLa may hold
-- only the FLAC stream information.
local QUICKTIME_CODEC_BOXES = {
	-- HDR content light level, mastering display, ambient viewing environment
	-- and Dolby Vision configuration.
	clli = 4,
	mdcv = 24,
	amve = 8,
	dvcC = 24,
	dvvC = 24,
	dvwC = 24,
	-- AV1 and VP9 video; Opus, FLAC, AC-3, E-AC-3, Apple Lossless and PCM audio.
	av1C = 128,
	vpcC = 12,
	dOps = 268,
	dfLa = 42,
	dac3 = 3,
	dec3 = 34,
	alac = 28,
	pcmC = 6,
	-- Bit rates, named by ExifTool except in a chapter track's text entry.
	btrt = 12,
	-- Chroma sample location, which AVFoundation writes in HEVC exports.
	chrm = 2,
}

local QUICKTIME_TRACK_TAGS = {
	"TrackHeaderVersion",
	"TrackID",
	"TrackDuration",
	"TrackLayer",
	"TrackVolume",
	"MatrixStructure",
	"ImageWidth",
	"ImageHeight",
	"CleanApertureDimensions",
	"ProductionApertureDimensions",
	"EncodedPixelsDimensions",
	"MediaHeaderVersion",
	"MediaTimeScale",
	"MediaDuration",
	"MediaLanguageCode",
	"GraphicsMode",
	"OpColor",
	"Balance",
	"CompressorID",
	"VendorID",
	"SourceImageWidth",
	"SourceImageHeight",
	"XResolution",
	"YResolution",
	"CompressorName",
	"BitDepth",
	"PixelAspectRatio",
	"ColorRepresentation",
	"VideoFrameRate",
	"BufferSize",
	"MaxBitrate",
	"AverageBitrate",
	"AudioFormat",
	"AudioVendorID",
	"AudioChannels",
	"AudioBitsPerSample",
	"AudioSampleRate",
	"AVCConfiguration",
	"HEVCConfiguration",
	"AV1Configuration",
	"SyncSampleTable",
	"CompositionTimeToSample",
	"TimeToSampleTable",
	"SampleToChunk",
	"SampleSizes",
	"ChunkOffset",
	"ChunkOffset64",
	"Unknown_edts",
	-- Sample-description children: AAC decoder configuration, the MOV audio
	-- format box (ExifTool names it PurchaseFileFormat) and the iPod uuid.
	"Unknown_esds",
	"PurchaseFileFormat",
	"Unknown_uuid",
	"Unknown_mp4a",
	"LayoutFlags",
	"SampleGroupDescription",
	"SampleToGroup",
	"ColorProfiles",
	"ColorPrimaries",
	"TransferCharacteristics",
	"MatrixCoefficients",
	"VideoFullRangeFlag",
	-- Sample flags (sdtp), composition offsets (cslg), field order (fiel),
	-- MOV audio extensions (wave, frma, chan) and empty alias references.
	"IdependentAndDisposableSamples",
	"CompositionToDecodeTimelineMapping",
	"VideoFieldOrder",
	"Unknown_wave",
	"OtherFormat",
	"Unknown_chan",
	"Unknown_cios",
	"Unknown_alis",
	"Unknown_csgm",
	"Unknown_hvcC",
	"EncoderVendor",
	"EncoderVersion",
	-- Chapter tracks: the reference to them, their generic media header and
	-- the text sample description with its font table.
	"ChapterListTrackID",
	"GenMediaVersion",
	"GenFlags",
	"GenGraphicsMode",
	"GenOpColor",
	"GenBalance",
	"Text",
	"FontTable",
}

local QUICKTIME_SPEC = (function()
	local keep = with_basics({
		"QuickTime:MajorBrand",
		"QuickTime:MinorVersion",
		"QuickTime:CompatibleBrands",
		"QuickTime:MovieHeaderVersion",
		"QuickTime:TimeScale",
		"QuickTime:Duration",
		"QuickTime:PreferredRate",
		"QuickTime:PreferredVolume",
		"QuickTime:MatrixStructure",
		"QuickTime:PreviewTime",
		"QuickTime:PreviewDuration",
		"QuickTime:PosterTime",
		"QuickTime:SelectionTime",
		"QuickTime:SelectionDuration",
		"QuickTime:CurrentTime",
		"QuickTime:NextTrackID",
		"QuickTime:MediaDataSize",
		"QuickTime:MediaDataOffset",
		"QuickTime:MediaData",
		"QuickTime:MovieDataSize",
		"QuickTime:MovieDataOffset",
		"QuickTime:InitialObjectDescriptor",
		-- Movie fragment numbers and the segment index.
		"QuickTime:MovieFragmentSequence",
		"QuickTime:Unknown_sidx",
		-- Sony codec profile (PROF).
		"QuickTime:FileProfileVersion",
		"QuickTime:FileFunctionFlags",
		"QuickTime:AudioProfileVersion",
		"QuickTime:AudioTrackID",
		"QuickTime:AudioCodec",
		"QuickTime:AudioCodecInfo",
		"QuickTime:AudioAttributes",
		"QuickTime:AudioAvgBitrate",
		"QuickTime:AudioMaxBitrate",
		"QuickTime:AudioSampleRate",
		"QuickTime:AudioChannels",
		"QuickTime:VideoProfileVersion",
		"QuickTime:VideoTrackID",
		"QuickTime:VideoCodec",
		"QuickTime:VideoCodecInfo",
		"QuickTime:VideoAttributes",
		"QuickTime:VideoSize",
		"QuickTime:PixelAspectRatio",
		"QuickTime:VideoMaxBitrate",
		"QuickTime:VideoAvgBitrate",
		"QuickTime:VideoMaxFrameRate",
		"QuickTime:VideoAvgFrameRate",
		-- iTunes gapless offsets and Sound Check loudness (see quicktime_parse).
		"iTunes:iTunSMPB",
		"iTunes:VolumeNormalization",
	})
	for _, tag in ipairs(QUICKTIME_TRACK_TAGS) do
		keep[#keep + 1] = "^Track%d+$:" .. tag
	end
	for box in pairs(QUICKTIME_CODEC_BOXES) do
		keep[#keep + 1] = "^Track%d+$:Unknown_" .. box
	end
	local neutral = {
		["QuickTime:CreateDate"] = QUICKTIME_NEUTRAL_DATE,
		["QuickTime:ModifyDate"] = QUICKTIME_NEUTRAL_DATE,
	}
	for index = 1, 64 do
		for _, tag in ipairs({ "TrackCreateDate", "TrackModifyDate", "MediaCreateDate", "MediaModifyDate" }) do
			neutral["Track" .. index .. ":" .. tag] = QUICKTIME_NEUTRAL_DATE
		end
	end
	-- ExifTool reports the content of free boxes, which cleaning zero-fills.
	return metadata_spec({
		keep = keep,
		free = {
			"QuickTime:Free",
			"QuickTime:Skip",
			"QuickTime:Wide",
			"QuickTime:Unknown_free",
			"UserData:Unknown_free",
			"^Track%d+$:Unknown_free",
			-- Track defaults, fragment headers, decode times, sample runs and
			-- the random-access index, which lose a removed track's entries.
			-- The walker admits only those boxes, and a kept track's are
			-- outside every changed region.
			"QuickTime:Unknown_mvex",
			"QuickTime:Unknown_tfhd",
			"QuickTime:Unknown_tfdt",
			"QuickTime:Unknown_trun",
			"QuickTime:Unknown_mfra",
			-- A track's metadata box has a handler of its own, so handler lists
			-- shrink; FFprobe's layout compares stream types and handler names.
			"^Track%d+$:HandlerClass",
			"^Track%d+$:HandlerType",
			"^Track%d+$:HandlerDescription",
			"^Track%d+$:HandlerVendorID",
			-- The handler of a movie metadata box kept for iTunes values.
			"QuickTime:HandlerType",
			"QuickTime:HandlerVendorID",
		},
		neutral = neutral,
	})
end)()

-- Byte spans [start, finish) of a track's chunks, from its sample tables.
local function quicktime_chunk_spans(tables)
	local offsets, stsc, sizes = {}, tables.stsc, tables.stsz or tables.stz2
	local ok, spans = pcall(function()
		if tables.stco then
			for index = 1, string.unpack(">I4", tables.stco, 5) do
				offsets[index] = string.unpack(">I4", tables.stco, 5 + 4 * index)
			end
		elseif tables.co64 then
			for index = 1, string.unpack(">I4", tables.co64, 5) do
				offsets[index] = string.unpack(">I8", tables.co64, 1 + 8 * index)
			end
		end
		if not stsc or not sizes or #offsets == 0 then
			return #offsets == 0 and {} or nil
		end
		local constant, count, field = 0, 0, 32
		if tables.stsz then
			constant, count = string.unpack(">I4I4", sizes, 5)
		else
			field, count = sizes:byte(8), string.unpack(">I4", sizes, 9)
		end
		local function sample_size(index)
			if constant > 0 then
				return constant
			elseif field == 32 then
				return string.unpack(">I4", sizes, 9 + 4 * index)
			elseif field == 16 then
				return string.unpack(">I2", sizes, 11 + 2 * index)
			elseif field == 8 then
				return sizes:byte(12 + index)
			end
			local byte = sizes:byte(13 + (index - 1) // 2)
			return index % 2 == 1 and byte // 16 or byte % 16
		end
		local runs = {}
		for index = 1, string.unpack(">I4", stsc, 5) do
			local first, samples = string.unpack(">I4I4", stsc, 9 + 12 * (index - 1))
			runs[#runs + 1] = { first = first, samples = samples }
		end
		local result, sample, run = {}, 1, 1
		for chunk, offset in ipairs(offsets) do
			while runs[run + 1] and runs[run + 1].first <= chunk do
				run = run + 1
			end
			local length = 0
			for _ = 1, runs[run] and runs[run].samples or 0 do
				if sample > count then
					error("sample table overrun")
				end
				length = length + sample_size(sample)
				sample = sample + 1
			end
			result[#result + 1] = { start = offset, finish = offset + length }
		end
		return result
	end)
	return ok and spans or nil
end

-- The byte spans of each track's samples in movie fragments, by track ID.
-- A track fragment's data starts at its explicit base offset, at its movie
-- fragment box (default-base-is-moof, or the first track fragment), or after
-- the previous track fragment's data; a run without a data offset follows the
-- run before it. Sample sizes default to the fragment header, then to the
-- movie's track extends box. nil when a table is malformed.
local function quicktime_fragment_spans(state)
	local ok, spans = pcall(function()
		local defaults, result = {}, {}
		for _, trex in ipairs(state.trex) do
			defaults[trex.id] = string.unpack(">I4", trex.data, 17)
		end
		for _, moof in ipairs(state.moofs) do
			local data_end = moof.start
			for _, traf in ipairs(moof.trafs) do
				local header = assert(traf.header, "track fragment without header")
				local flags, id = string.unpack(">I4I4", header)
				flags = flags & 0xFFFFFF
				traf.id, traf.explicit = id, flags & 0x20001 ~= 0
				local at, base = 9, data_end
				if flags & 0x1 ~= 0 then
					base, at = string.unpack(">I8", header, at)
				elseif flags & 0x20000 ~= 0 then
					base = moof.start
				end
				at = at + (flags & 0x2 ~= 0 and 4 or 0) + (flags & 0x8 ~= 0 and 4 or 0)
				local default_size = flags & 0x10 ~= 0 and string.unpack(">I4", header, at) or defaults[id]
				local list = result[id] or {}
				result[id] = list
				local position = base
				for _, run in ipairs(traf.runs) do
					local run_flags, count = string.unpack(">I4I4", run)
					local cursor = 9
					if run_flags & 0x1 ~= 0 then
						position, cursor = string.unpack(">i4", run, cursor)
						position = base + position
					end
					cursor = cursor + (run_flags & 0x4 ~= 0 and 4 or 0)
					local before_size = run_flags & 0x100 ~= 0 and 4 or 0
					local width = before_size
						+ (run_flags & 0x200 ~= 0 and 4 or 0)
						+ (run_flags & 0x400 ~= 0 and 4 or 0)
						+ (run_flags & 0x800 ~= 0 and 4 or 0)
					assert(cursor - 1 + count * width <= #run, "truncated track run")
					local length = 0
					for index = 0, count - 1 do
						if run_flags & 0x200 ~= 0 then
							length = length + string.unpack(">I4", run, cursor + index * width + before_size)
						else
							length = length + assert(default_size, "track run without sample sizes")
						end
					end
					assert(position >= 0, "negative track run offset")
					list[#list + 1] = { start = position, finish = position + length }
					position = position + length
				end
				data_end = position
			end
		end
		return result
	end)
	return ok and spans or nil
end

-- Timed metadata (Apple mebx, GoPro gpmd, Google camm) and timecode tracks
-- hold detected faces, motion and location samples and the time of day; they
-- are removed whole. Playback rotation lives in the video track header.
local QUICKTIME_REMOVED_HANDLERS = as_set({ "meta", "camm", "tmcd" })

-- path may also be an open file or a string_file.
local function quicktime_parse(path)
	local file, open_err = path, nil
	if type(path) ~= "table" then
		file, open_err = io.open(path, "rb")
	end
	if not file then
		return nil, tostring(open_err or "could not open QuickTime file")
	end
	local size = file:seek("end")
	local state = {
		regions = {},
		metadata = {},
		moov = 0,
		tracks = {},
		removed_ids = {},
		chapter_targets = {},
		mdats = {},
		gaps = {},
		moofs = {},
		trex = {},
		tfra = {},
		size = size,
	}
	local count = 0
	local function read_at(offset, length)
		file:seek("set", offset)
		local data = file:read(length)
		return data and #data == length and data or nil
	end
	local function add_region(start, finish, kind, track)
		if finish > start then
			state.regions[#state.regions + 1] = { start = start, finish = finish, kind = kind, track = track }
		end
	end
	-- iTunes stores the encoder delay and padding (iTunSMPB) and Sound Check
	-- loudness (iTunNORM) only as movie metadata; without the delay, players
	-- add silence. The movie udta is rebuilt at its old size with only those
	-- items, followed by a zero-filled free box. nil when it holds neither.
	local function itunes_playback(data)
		local function boxes(from, to)
			local list, at = {}, from
			while at + 7 <= to do
				local size, kind = be_u32_at(data, at), data:sub(at + 4, at + 7)
				if not size or size < 8 or at + size - 1 > to then
					return nil
				end
				list[#list + 1] = { kind = kind, start = at, finish = at + size - 1 }
				at = at + size
			end
			return at == to + 1 and list or nil
		end
		local meta
		for _, box in ipairs(boxes(1, #data) or {}) do
			meta = box.kind == "meta" and box or meta
		end
		local children = meta and meta.finish - meta.start >= 11 and boxes(meta.start + 12, meta.finish)
		local handler, kept = nil, {}
		for _, child in ipairs(children or {}) do
			if child.kind == "hdlr" then
				handler = data:sub(child.start, child.finish)
			elseif child.kind == "ilst" then
				for _, item in ipairs(boxes(child.start + 8, child.finish) or {}) do
					local parts = item.kind == "----" and boxes(item.start + 8, item.finish) or {}
					local mean, name
					for _, part in ipairs(parts) do
						local text = data:sub(part.start + 12, part.finish)
						mean = part.kind == "mean" and text or mean
						name = part.kind == "name" and text or name
					end
					if mean == "com.apple.iTunes" and (name == "iTunSMPB" or name == "iTunNORM") then
						kept[#kept + 1] = data:sub(item.start, item.finish)
					end
				end
			end
		end
		if not handler or #kept == 0 then
			return nil
		end
		local ilst = table.concat(kept)
		ilst = u32_be_bytes(8 + #ilst) .. "ilst" .. ilst
		local body = data:sub(meta.start + 8, meta.start + 11) .. handler .. ilst
		local rebuilt = u32_be_bytes(8 + #body) .. "meta" .. body
		local rest = #data - #rebuilt
		if rest == 0 then
			return rebuilt
		end
		return rest >= 8 and rebuilt .. u32_be_bytes(rest) .. "free" .. string.rep("\0", rest - 8) or nil
	end
	local function walk(parent, start, finish, depth, prefix, track)
		if depth > LIMIT.ISOBMFF_DEPTH then
			return nil, "QuickTime nesting limit exceeded"
		end
		local offset = start
		while offset < finish do
			local header = finish - offset >= 8 and read_at(offset, 8)
			if not header then
				return nil, "truncated QuickTime box header"
			end
			local box_size, kind = be_u32_at(header, 1), header:sub(5, 8)
			local header_size = 8
			if box_size == 1 then
				local extended = finish - offset >= 16 and read_at(offset + 8, 8)
				local high, low = extended and be_u32_at(extended, 1), extended and be_u32_at(extended, 5)
				if not high or high > 0x1FFFFF then
					return nil, "unsupported QuickTime box size"
				end
				box_size, header_size = high * 4294967296 + low, 16
			elseif box_size == 0 then
				if parent ~= "" then
					return nil, "non-terminal zero-size QuickTime box"
				end
				box_size = finish - offset
			end
			local name = prefix .. kind
			if box_size < header_size or box_size > finish - offset then
				return nil, "invalid QuickTime box size: " .. name
			end
			count = count + 1
			if count > LIMIT.ISOBMFF_BOXES then
				return nil, "QuickTime box count limit exceeded"
			end
			if not QUICKTIME_CHILDREN[parent][kind] then
				return nil, "unsupported QuickTime box " .. name
			end
			local payload, box_end = offset + header_size, offset + box_size
			local length = box_end - payload
			local metadata = kind == "udta" or kind == "meta" or QUICKTIME_FRAGMENT_METADATA[kind] == true
			local data = kind == "udta" and parent == "moov" and length <= 1024 * 1024 and read_at(payload, length)
			local rebuilt = data and itunes_playback(data)
			if rebuilt then
				metadata = false
				if rebuilt ~= data then
					state.metadata[#state.metadata + 1] = name
					state.regions[#state.regions + 1] =
						{ start = payload, finish = box_end, kind = "bytes", bytes = rebuilt, track = track }
				end
			end
			if kind == "moov" then
				state.moov = state.moov + 1
			elseif kind == "uuid" then
				local user = box_size >= header_size + 16 and read_at(payload, 16)
				if
					parent == "" and (user == QUICKTIME_UUID.xmp or user == QUICKTIME_UUID.c2pa)
					or parent == "" and user and user:sub(5) == QUICKTIME_UUID.kddi
					or user == QUICKTIME_UUID.sony_metadata
				then
					metadata = true
				elseif
					not (parent == "trak" and user == QUICKTIME_UUID.spherical)
					and not (parent == "" and user == QUICKTIME_UUID.sony_profile)
				then
					return nil, "unsupported QuickTime uuid box " .. name
				end
			elseif kind == "free" or kind == "skip" then
				add_region(payload, box_end, "zero", track)
			elseif kind == "mvhd" or kind == "tkhd" or kind == "mdhd" then
				local version = read_at(payload, 1)
				local width = version == "\1" and 16 or version == "\0" and 8
				if not width or payload + 4 + width + 4 > box_end then
					return nil, "invalid QuickTime header " .. name
				end
				add_region(payload + 4, payload + 4 + width, "zero", track)
				if kind == "tkhd" then
					local id = read_at(payload + 4 + width, 4)
					track.id = id and be_u32_at(id, 1)
				end
			elseif kind == "hdlr" and parent == "mdia" then
				track.handler = length >= 12 and read_at(payload + 8, 4)
			elseif kind == "stsd" then
				track.format = length >= 16 and read_at(payload + 12, 4)
				-- A colr box in a sample entry can hold an ICC profile, which
				-- loses its display serial number in place.
				local data = length <= LIMIT.HEIF_META_BYTES and read_at(payload, length)
				local at = data and data:find("colr", 5, true)
				while at do
					local size, colour = be_u32_at(data, at - 4), data:sub(at + 4, at + 7)
					if size and size >= 12 and at + size - 5 <= #data and (colour == "prof" or colour == "rICC") then
						local cleaned = ICC.clean(data:sub(at + 8, at + size - 5))
						if cleaned then
							state.metadata[#state.metadata + 1] = name .. " ICC profile"
							state.regions[#state.regions + 1] = {
								start = payload + at + 7,
								finish = payload + at + 7 + #cleaned,
								kind = "bytes",
								bytes = cleaned,
								track = track,
							}
						end
					end
					at = data:find("colr", at + 4, true)
				end
			elseif
				track and (kind == "stco" or kind == "co64" or kind == "stsc" or kind == "stsz" or kind == "stz2")
			then
				if length > LIMIT.QUICKTIME_TABLE_BYTES then
					return nil, "QuickTime sample table limit exceeded"
				end
				track.tables[kind] = read_at(payload, length)
			elseif kind == "moof" then
				state.moofs[#state.moofs + 1] = { start = offset, trafs = {} }
			elseif kind == "traf" then
				local moof = state.moofs[#state.moofs]
				moof.trafs[#moof.trafs + 1] = { runs = {}, start = offset, payload = payload, finish = box_end }
			elseif kind == "tfhd" or kind == "trun" or kind == "trex" or kind == "tfra" then
				if length > LIMIT.QUICKTIME_TABLE_BYTES then
					return nil, "QuickTime sample table limit exceeded"
				end
				local data = read_at(payload, length)
				if not data then
					return nil, "truncated QuickTime box " .. name
				elseif kind == "trex" or kind == "tfra" then
					local id = length >= 8 and be_u32_at(data, 5)
					if not id then
						return nil, "truncated QuickTime box " .. name
					end
					state[kind][#state[kind] + 1] =
						{ data = data, id = id, start = offset, payload = payload, finish = box_end }
				else
					local trafs = state.moofs[#state.moofs].trafs
					local traf = trafs[#trafs]
					if kind == "tfhd" then
						traf.header = data
					else
						traf.runs[#traf.runs + 1] = data
					end
				end
			elseif kind == "tref" then
				local data = length <= 65536 and read_at(payload, length)
				local targets, position = {}, 1
				while data and position + 7 <= #data do
					local entry = be_u32_at(data, position)
					if not entry or entry < 8 or (entry - 8) % 4 ~= 0 or position + entry - 1 > #data then
						data = nil
						break
					end
					for at = position + 8, position + entry - 4, 4 do
						targets[#targets + 1] = be_u32_at(data, at)
						if data:sub(position + 4, position + 7) == "chap" then
							state.chapter_targets[targets[#targets]] = true
						end
					end
					position = position + entry
				end
				if not data or position ~= #data + 1 then
					return nil, "invalid QuickTime track reference"
				end
				track.reference = { start = offset, finish = box_end, targets = targets }
			elseif kind == "dref" then
				if length > 65536 then
					return nil, "unsupported QuickTime data reference"
				end
				local data = read_at(payload, length)
				local entries = data and be_u32_at(data, 5)
				if not entries then
					return nil, "invalid QuickTime data reference"
				end
				local position = 9
				for _ = 1, entries do
					local entry_size = be_u32_at(data, position)
					local flags = data:byte(position + 11)
					if not entry_size or entry_size < 12 or not flags or position + entry_size - 1 > #data then
						return nil, "invalid QuickTime data reference"
					end
					if flags & 1 ~= 1 then
						return nil, "external QuickTime data reference is unsupported"
					end
					position = position + entry_size
				end
			end
			if kind == "mdat" and parent == "" then
				state.mdats[#state.mdats + 1] = { start = payload, finish = box_end }
			end
			if metadata then
				state.metadata[#state.metadata + 1] = name
				add_region(offset + 4, offset + 8, "free", track)
				add_region(payload, box_end, "zero", track)
			elseif kind == "trak" then
				local record = { start = offset, payload = payload, finish = box_end, tables = {}, name = name }
				state.tracks[#state.tracks + 1] = record
				local ok, err = walk(kind, payload, box_end, depth + 1, name .. "/", record)
				if not ok then
					return nil, err
				end
				if not record.id or not record.handler then
					return nil, "QuickTime track without header or handler"
				end
			elseif QUICKTIME_CONTAINERS[kind] then
				local ok, err = walk(kind, payload, box_end, depth + 1, name .. "/", track)
				if not ok then
					return nil, err
				end
			end
			offset = box_end
		end
		return true
	end
	local ok, err = walk("", 0, size, 0, "")
	file:close()
	if not ok then
		return nil, err
	end
	if state.moov ~= 1 then
		return nil, "QuickTime file must contain exactly one movie box"
	end

	-- Removed tracks become zero-filled free boxes and their samples are
	-- zeroed; references to them from kept tracks go with them.
	local kept_spans, removed_spans = {}, {}
	-- A QuickTime text track that another track names as its chapters holds
	-- the chapter titles, which are kept like Matroska chapters.
	state.chapter_ids = {}
	for _, track in ipairs(state.tracks) do
		if state.chapter_targets[track.id] and track.handler == "text" and track.format == "text" then
			state.chapter_ids[track.id] = true
		end
	end
	local fragment_spans = quicktime_fragment_spans(state)
	if not fragment_spans then
		return nil, "invalid QuickTime movie fragment"
	end
	for _, track in ipairs(state.tracks) do
		track.removed = QUICKTIME_REMOVED_HANDLERS[track.handler] == true
		local spans = quicktime_chunk_spans(track.tables)
		if not spans then
			return nil, "invalid QuickTime sample table"
		end
		local fragments = fragment_spans[track.id] or {}
		track.spans = table.move(fragments, 1, #fragments, #spans + 1, spans)
		fragment_spans[track.id] = nil
	end
	if next(fragment_spans) then
		return nil, "QuickTime fragment for an unknown track"
	end
	for _, track in ipairs(state.tracks) do
		local list = track.removed and removed_spans or kept_spans
		for _, span in ipairs(track.spans) do
			if span.finish > size then
				return nil, "QuickTime sample data exceeds the file"
			end
			list[#list + 1] = span
		end
		if track.removed then
			state.removed_ids[track.id] = true
			state.metadata[#state.metadata + 1] = track.name .. " (" .. track.handler .. ")"
		end
	end
	local regions = {}
	for _, region in ipairs(state.regions) do
		if not (region.track and region.track.removed) then
			regions[#regions + 1] = region
		end
	end
	-- A removed track's fragment headers, defaults and random-access entries
	-- go too. A later track fragment without its own base offset finds its
	-- data after the removed one's, so that layout is refused.
	local fragment_boxes =
		table.move(state.tfra, 1, #state.tfra, #state.trex + 1, table.move(state.trex, 1, #state.trex, 1, {}))
	for _, moof in ipairs(state.moofs) do
		for index, traf in ipairs(moof.trafs) do
			if state.removed_ids[traf.id] then
				for later = index + 1, #moof.trafs do
					if not moof.trafs[later].explicit and not state.removed_ids[moof.trafs[later].id] then
						return nil, "QuickTime fragment layout prevents removing a track"
					end
				end
			end
			fragment_boxes[#fragment_boxes + 1] = traf
		end
	end
	for _, box in ipairs(fragment_boxes) do
		if state.removed_ids[box.id] then
			regions[#regions + 1] = { start = box.start + 4, finish = box.start + 8, kind = "free" }
			regions[#regions + 1] = { start = box.payload, finish = box.finish, kind = "zero" }
		end
	end
	for _, track in ipairs(state.tracks) do
		if track.removed then
			regions[#regions + 1] = { start = track.start + 4, finish = track.start + 8, kind = "free" }
			regions[#regions + 1] = { start = track.payload, finish = track.finish, kind = "zero" }
		elseif track.reference then
			local removed = 0
			for _, target in ipairs(track.reference.targets) do
				removed = removed + (state.removed_ids[target] and 1 or 0)
			end
			if removed == #track.reference.targets and removed > 0 then
				regions[#regions + 1] =
					{ start = track.reference.start + 4, finish = track.reference.start + 8, kind = "free" }
				regions[#regions + 1] =
					{ start = track.reference.start + 8, finish = track.reference.finish, kind = "zero" }
			elseif removed > 0 then
				return nil, "QuickTime track refers to both kept and removed tracks"
			end
		end
	end
	table.sort(kept_spans, function(a, b)
		return a.start < b.start
	end)
	table.sort(removed_spans, function(a, b)
		return a.start < b.start
	end)
	local index = 1
	for _, span in ipairs(removed_spans) do
		while kept_spans[index] and kept_spans[index].finish <= span.start do
			index = index + 1
		end
		local next_kept = kept_spans[index]
		if next_kept and next_kept.start < span.finish and span.finish > span.start then
			return nil, "QuickTime metadata samples overlap media samples"
		end
		regions[#regions + 1] = { start = span.start, finish = span.finish, kind = "zero" }
	end
	-- Bytes of a media data box that no track's samples use, such as an
	-- earlier movie box an editor left there, are zeroed too.
	local used =
		table.move(removed_spans, 1, #removed_spans, #kept_spans + 1, table.move(kept_spans, 1, #kept_spans, 1, {}))
	table.sort(used, function(a, b)
		return a.start < b.start
	end)
	local first = 1
	for _, mdat in ipairs(state.mdats) do
		local position = mdat.start
		while used[first] and used[first].finish <= mdat.start do
			first = first + 1
		end
		for at = first, #used do
			local span = used[at]
			if span.start >= mdat.finish then
				break
			elseif span.start > position then
				state.gaps[#state.gaps + 1] = { start = position, finish = span.start }
			end
			position = math.max(position, span.finish)
		end
		if position < mdat.finish then
			state.gaps[#state.gaps + 1] = { start = position, finish = mdat.finish }
		end
	end
	for _, gap in ipairs(state.gaps) do
		regions[#regions + 1] = { start = gap.start, finish = gap.finish, kind = "zero" }
	end
	table.sort(regions, function(a, b)
		return a.start < b.start
	end)
	-- Merge touching zero regions and refuse any other overlap.
	local merged = {}
	for _, region in ipairs(regions) do
		local last = merged[#merged]
		if region.finish <= region.start then
			-- Empty chunks of a removed track.
		elseif last and last.kind == "zero" and region.kind == "zero" and region.start <= last.finish then
			last.finish = math.max(last.finish, region.finish)
		elseif last and region.start < last.finish then
			return nil, "QuickTime metadata regions overlap"
		else
			merged[#merged + 1] =
				{ start = region.start, finish = region.finish, kind = region.kind, bytes = region.bytes }
		end
	end
	state.regions = merged
	return state
end

-- Streaming loops read this much at a time. Lua 5.5 allocates a buffer per
-- read that its collector frees late, so 1 MiB reads of a 1 GB file peaked
-- near 1 GB of memory; 64 KiB reads stay under 25 MB at the same speed.
local STREAM_BLOCK = 65536
local ZERO_BLOCK = string.rep("\0", STREAM_BLOCK)

-- A read-only file over a string, for parsing embedded media in memory.
local function string_file(data)
	local position = 0
	return {
		seek = function(_, whence, offset)
			position = whence == "end" and #data + (offset or 0)
				or whence == "cur" and position + (offset or 0)
				or offset
				or 0
			return position
		end,
		read = function(_, length)
			local chunk = data:sub(position + 1, position + length)
			position = position + #chunk
			return chunk
		end,
		close = function()
			return true
		end,
	}
end

-- The planned content of a region: "free" for a renamed box type, literal
-- bytes for a rebuilt box, zeros otherwise. offset is relative to the region.
local function region_expected(region, offset, length)
	if region.kind == "free" then
		return "free"
	elseif region.kind == "bytes" then
		return region.bytes:sub(offset + 1, offset + length)
	end
	return length == #ZERO_BLOCK and ZERO_BLOCK or string.rep("\0", length)
end

-- Whether every region already holds its planned content.
local function regions_hold(path, regions)
	local file = type(path) == "table" and path or io.open(path, "rb")
	if not file then
		return nil, "could not reopen file"
	end
	for _, region in ipairs(regions) do
		file:seek("set", region.start)
		local position = region.start
		while position < region.finish do
			local length = math.min(region.finish - position, #ZERO_BLOCK)
			if file:read(length) ~= region_expected(region, position - region.start, length) then
				file:close()
				return false
			end
			position = position + length
		end
	end
	file:close()
	return true
end

local function write_regions(path, regions)
	local file, open_err = io.open(path, "r+b")
	if not file then
		return nil, tostring(open_err or "could not open staged file")
	end
	for _, region in ipairs(regions) do
		file:seek("set", region.start)
		local position = region.start
		while position < region.finish do
			local length = math.min(region.finish - position, #ZERO_BLOCK)
			if not file:write(region_expected(region, position - region.start, length)) then
				file:close()
				return nil, "could not write staged file"
			end
			position = position + length
		end
	end
	local closed, close_err = file:close()
	return closed and true or nil, close_err
end

-- Compare source and staged files block by block: outside the planned regions
-- (sorted and disjoint) they must be identical, inside them they must hold
-- exactly the planned bytes.
local function verify_regions(source, staged, regions)
	local a, b = io.open(source, "rb"), io.open(staged, "rb")
	if not a or not b then
		if a then
			a:close()
		end
		if b then
			b:close()
		end
		return nil, "could not open files for byte comparison"
	end
	local size = a:seek("end")
	local result, message = true, nil
	if b:seek("end") ~= size then
		result, message = nil, "file size changed"
	end
	a:seek("set", 0)
	b:seek("set", 0)
	local position, index = 0, 1
	while result and position < size do
		local region = regions[index]
		local limit = region and region.start or size
		if position < limit then
			local length = math.min(limit - position, STREAM_BLOCK)
			if a:read(length) ~= b:read(length) then
				result, message = nil, "bytes changed outside the metadata regions"
			end
			position = position + length
		else
			local length = math.min(region.finish - position, #ZERO_BLOCK)
			a:read(length)
			if b:read(length) ~= region_expected(region, position - region.start, length) then
				result, message = nil, "metadata region was not neutralized"
			end
			position = position + length
			if position >= region.finish then
				index = index + 1
			end
		end
	end
	a:close()
	b:close()
	return result, message
end

local function quicktime_structure_clean(path, state)
	if #state.metadata > 0 then
		return false, "QuickTime metadata box " .. state.metadata[1]
	end
	local neutral, err = regions_hold(path, state.regions)
	if neutral == nil then
		return nil, err
	end
	return neutral, "QuickTime free space or date is not neutral"
end

local function quicktime_verify(source, staged, state)
	local ok, err = verify_regions(source, staged, state.regions)
	if not ok or regions_hold(source, state.gaps) then
		return ok, err
	end
	-- Unused media data held bytes, which were zeroed; the samples of every
	-- video and audio stream must still be identical.
	local function streams(path)
		return bounded_output("ffmpeg", {
			"-v",
			"error",
			"-i",
			path,
			"-map",
			"0:V?",
			"-map",
			"0:a?",
			"-c",
			"copy",
			"-f",
			"streamhash",
			"-hash",
			"sha256",
			"-",
		}, media_timeout(path))
	end
	local before, before_err = streams(source)
	if not before then
		return nil, before_err
	end
	local after, after_err = streams(staged)
	if not after then
		return nil, after_err
	end
	return before == after or nil, "QuickTime samples changed"
end

local function quicktime_static_manifest(path)
	-- Packet counting reads every sample through the demuxer without decoding.
	return bounded_output("ffprobe", {
		"-v",
		"error",
		"-bitexact",
		"-enable_drefs",
		"0",
		"-use_absolute_path",
		"0",
		"-count_packets",
		"-show_streams",
		"-show_programs",
		"-show_stream_groups",
		"-show_chapters",
		"-show_format",
		"-show_data_hash",
		"sha256",
		"-show_entries",
		"format=format_name,start_time,duration,nb_streams,nb_programs,nb_stream_groups:format_tags=major_brand,minor_version,compatible_brands:stream=index,id,codec_type,codec_name,codec_tag_string,profile,level,time_base,start_pts,start_time,duration_ts,duration,nb_frames,nb_read_packets,width,height,coded_width,coded_height,pix_fmt,sample_aspect_ratio,display_aspect_ratio,field_order,has_b_frames,color_range,color_space,color_transfer,color_primaries,chroma_location,sample_fmt,sample_rate,channels,channel_layout,initial_padding,seek_preroll,extradata_size,extradata_hash:stream_disposition:stream_tags=language,handler_name,vendor_id,timecode,mimetype:stream_side_data:chapter=id,time_base,start,end:chapter_tags:program:program_stream=index:stream_group:stream_group_stream=index",
		"-of",
		"compact=p=1:nk=0:escape=c",
		"--",
		path,
	}, media_timeout(path))
end

local QUICKTIME_TOP_SECTIONS = as_set({ "stream", "format", "program", "chapter", "stream_group" })

-- Cover art is stored in the ilst metadata that cleaning removes, and FFprobe
-- reports it as an attached-picture stream. The comparison leaves those
-- streams, the streams and track references of removed tracks, stream
-- indexes and the format's stream and group counts out; the cleaned file must have no cover art left. The
-- timecode tag of a video stream comes from a removed timecode track.
local function quicktime_layout(manifest, removed_ids)
	local lines, skipping, pictures, nested = {}, false, 0, 0
	for entry in manifest:gmatch("[^\n]+") do
		local line = entry
		local section = line:match("^([%w_]+)|") or line
		if nested > 0 then
			-- The streams of a stream group continue on the following lines
			-- and belong to the group.
			nested = nested - 1
		elseif QUICKTIME_TOP_SECTIONS[section] then
			local picture = section == "stream" and line:find("|disposition:attached_pic=1", 1, true) ~= nil
			-- FFprobe reports a track reference as a stream group with the
			-- referenced track's ID.
			local grouped = section == "stream" or section == "stream_group"
			local id = grouped and tonumber(line:match("|id=0x(%x+)") or "", 16)
			skipping = picture or (id ~= nil and removed_ids[id] == true)
			if picture then
				pictures = pictures + 1
			end
			if section == "stream_group" then
				nested = math.max((tonumber(line:match("|nb_streams=(%d+)")) or 1) - 1, 0)
			end
		end
		if not skipping then
			if section == "stream" then
				line = line:gsub("|index=%d+", ""):gsub("|tag:timecode=[^|]*", "")
			elseif section == "format" then
				-- The format's duration and start follow the longest stream,
				-- which can be a removed one; each kept stream keeps its own.
				line = line:gsub("|nb_streams=%d+", "")
					:gsub("|nb_stream_groups=%d+", "")
					:gsub("|duration=[^|]*", "")
					:gsub("|start_time=[^|]*", "")
			end
			lines[#lines + 1] = line
		end
	end
	return table.concat(lines, "\n"), pictures
end

-- streams lists the stream types of which the file must have at least one.
-- Motion-JPEG frames are whole JPEG images, and a camera may put Exif, XMP
-- or IPTC segments into them, which ExifTool does not read. FFprobe lists
-- where each frame starts; only frame headers are read. Camera tables and
-- AVI1 markers in other segments are codec data.
local function motion_jpeg_metadata(path)
	local streams, err = bounded_output("ffprobe", {
		"-v",
		"error",
		"-select_streams",
		"V",
		"-show_entries",
		"stream=index,codec_name",
		"-of",
		"csv=p=0",
		path,
	}, media_timeout(path))
	if not streams then
		return err
	end
	local file
	for index in streams:gmatch("(%d+),mjpeg") do
		local packets, packets_err = bounded_output("ffprobe", {
			"-v",
			"error",
			"-select_streams",
			index,
			"-show_entries",
			"packet=pos,size",
			"-of",
			"compact=p=0",
			path,
		}, media_timeout(path), LIMIT.INVENTORY_BYTES)
		if not packets then
			return packets_err
		end
		file = file or io.open(path, "rb")
		if not file then
			return "could not open the video"
		end
		local function read(offset, length)
			file:seek("set", offset)
			return file:read(length)
		end
		-- FFprobe prints the fields in its own order, so they go by name.
		for line in packets:gmatch("[^\n]+") do
			local start, size = tonumber(line:match("pos=(%d+)")), tonumber(line:match("size=(%d+)"))
			-- Matroska positions point at the block header before the frame.
			local finish = start and size and start + size
			local skip = finish and (read(start, 16) or ""):find("\255\216\255", 1, true)
			start = skip and start + skip - 1 or start
			local found = finish
				and jpeg_flagged_segment(read, start, finish, function(marker, id)
					if marker == 0xE1 and id:sub(1, 5) == "Exif\0" then
						return "Exif"
					elseif marker == 0xE1 and id:sub(1, 28) == "http://ns.adobe.com/xap/1.0/" then
						return "XMP"
					elseif marker == 0xED and id:sub(1, 13) == "Photoshop 3.0" then
						return "IPTC"
					end
				end)
			if found then
				file:close()
				return "Motion-JPEG frames with " .. found .. " metadata are unsupported"
			end
		end
	end
	if file then
		file:close()
	end
	return nil
end

local function quicktime_policy(streams)
	return {
		spec = QUICKTIME_SPEC,
		preflight = function(path, inventory)
			for _, key in ipairs(inventory.entries) do
				local box = key:match("^Track%d+:Unknown_(%w+)$")
				local limit = box and QUICKTIME_CODEC_BOXES[box]
				for _, value in ipairs(limit and inventory.values[key] or {}) do
					-- ExifTool prints a payload of a few bytes as text, without
					-- its NUL bytes; four bytes hold nothing identifying.
					local size = tonumber(value:match("^%(Binary data (%d+) bytes"))
						or limit <= 4 and #value <= limit and #value
					if not size or size > limit then
						return nil, "unexpected QuickTime " .. box .. " box size"
					end
				end
			end
			local state, err = quicktime_parse(path)
			if not state then
				return nil, err
			end
			local static, static_err = quicktime_static_manifest(path)
			if not static then
				return nil, static_err
			end
			local layout, pictures = quicktime_layout(static, state.removed_ids)
			local playable = false
			for _, kind in ipairs(streams) do
				playable = playable or layout:find("|codec_type=" .. kind .. "|", 1, true) ~= nil
			end
			if not playable then
				return nil, "QuickTime file has no " .. table.concat(streams, " or ") .. " stream"
			end
			for line in layout:gmatch("[^\n]+") do
				if line:find("|codec_type=data|", 1, true) then
					local id = tonumber(line:match("|id=0x(%x+)") or "", 16)
					if not (id and state.chapter_ids[id]) then
						return nil, "unsupported QuickTime data stream"
					end
				end
			end
			if layout:find("|codec_name=unknown|", 1, true) or layout:match("|codec_tag_string=enc[vas]|") then
				return nil, "unsupported encrypted or unknown QuickTime stream"
			end
			state.static, state.pictures = layout, pictures
			return state
		end,
		structure_clean = function(state, path)
			if state.pictures > 0 then
				return false, "QuickTime cover art"
			end
			return quicktime_structure_clean(path, state)
		end,
		capture = function(_, _, state)
			return { static = state.static, pictures = state.pictures }
		end,
		-- Tags of removed tracks go, and ExifTool numbers the rest anew.
		expected_inventory = function(inventory, state)
			local numbers, kept = {}, 0
			for index, track in ipairs(state.tracks) do
				if not track.removed then
					kept = kept + 1
					numbers[index] = kept
				end
			end
			if kept == #state.tracks then
				return inventory
			end
			local result = {}
			for key, value in pairs(inventory) do
				result[key] = value
			end
			result.entries, result.values = {}, {}
			for _, key in ipairs(inventory.entries) do
				local number, tag = key:match("^Track(%d+):(.+)$")
				local mapped = number and numbers[tonumber(number)]
				local new = not number and key or mapped and "Track" .. mapped .. ":" .. tag
				if new then
					result.entries[#result.entries + 1] = new
					result.values[new] = inventory.values[key]
				end
			end
			return result
		end,
		equivalent = function(before, after)
			if after.pictures > 0 then
				return nil, "QuickTime attached picture remains"
			end
			return before.static == after.static or nil, "QuickTime stream topology changed"
		end,
		transform = function(ctx)
			return write_regions(ctx.staged, ctx.state.regions)
		end,
		verify = quicktime_verify,
	}
end

-- HEIC, HEIF and AVIF ----------------------------------------------------------------

-- HEIF images store Exif and XMP as items next to the image items. Cleaning
-- rebuilds the meta box without those items and with empty item and handler
-- names, pads it with a free box to its old size, and zero-fills the removed
-- items' bytes and existing free space. No image byte moves, so the iloc
-- entries of the kept items stay byte-identical, and verification compares
-- every byte outside those regions.
local HEIF_TOP_BOXES = as_set({ "ftyp", "meta", "mdat", "free", "skip" })
local HEIF_META_BOXES = as_set({ "hdlr", "dinf", "pitm", "iinf", "iloc", "iref", "iprp", "idat" })
-- Coded and derived images. JPEG-coded items are not accepted: their
-- bitstream can carry its own APP metadata segments.
local HEIF_IMAGE_ITEMS = as_set({ "hvc1", "av01", "grid", "iovl", "iden", "tmap" })
local HEIF_REFERENCES = as_set({ "dimg", "thmb", "auxl", "cdsc", "prem", "base" })
local HEIF_PROPERTIES = as_set({
	"ispe",
	"pixi",
	"hvcC",
	"av1C",
	"colr",
	"irot",
	"imir",
	"pasp",
	"clap",
	"auxC",
	"clli",
	"mdcv",
	"cclv",
	"amve",
	"lsel",
	"a1op",
	"a1lx",
})
local HEIF_XMP = "application/rdf+xml"

-- Big-endian unsigned integer of 0 to 8 bytes at a 1-based offset.
local function be_uint(data, offset, width)
	if width == 0 then
		return 0
	end
	if offset < 1 or offset + width - 1 > #data then
		return nil
	end
	local value = 0
	for index = offset, offset + width - 1 do
		if value > LIMIT.SAFE_INTEGER // 256 then
			return nil
		end
		value = value * 256 + data:byte(index)
	end
	return value
end

local function uint_be_bytes(value, width)
	local bytes = {}
	for index = width, 1, -1 do
		bytes[index] = string.char(value % 256)
		value = value // 256
	end
	return table.concat(bytes)
end

local function iso_box(kind, payload)
	return u32_be_bytes(8 + #payload) .. kind .. payload
end

-- The boxes in data[first..last] (1-based, inclusive). Boxes inside a meta
-- box never use the zero or 64-bit size forms.
local function iso_children(data, first, last)
	local boxes, offset = {}, first
	while offset <= last do
		local size = be_uint(data, offset, 4)
		if not size or size < 8 or offset + size - 1 > last then
			return nil, "invalid HEIF box size"
		end
		if #boxes >= LIMIT.ISOBMFF_BOXES then
			return nil, "HEIF box count limit exceeded"
		end
		boxes[#boxes + 1] = {
			type = data:sub(offset + 4, offset + 7),
			start = offset,
			payload = offset + 8,
			finish = offset + size - 1,
		}
		offset = offset + size
	end
	return boxes
end

local function heif_top_level(path, state)
	local file, open_err = io.open(path, "rb")
	if not file then
		return nil, tostring(open_err or "could not open HEIF file")
	end
	local size = file:seek("end")
	local function read_at(offset, length)
		file:seek("set", offset)
		local data = file:read(length)
		return data and #data == length and data or nil
	end
	local offset, count, err = 0, 0, nil
	while offset < size do
		local header = size - offset >= 8 and read_at(offset, 8)
		if not header then
			err = "truncated HEIF box header"
			break
		end
		local box_size, kind, header_size = be_u32_at(header, 1), header:sub(5, 8), 8
		if box_size == 1 then
			local extended = size - offset >= 16 and read_at(offset + 8, 8)
			box_size, header_size = extended and be_uint(extended, 1, 8), 16
		elseif box_size == 0 then
			box_size = size - offset
		end
		count = count + 1
		if not box_size or box_size < header_size or box_size > size - offset then
			err = "invalid HEIF box size"
		elseif count > LIMIT.ISOBMFF_BOXES then
			err = "HEIF box count limit exceeded"
		elseif (count == 1) ~= (kind == "ftyp") then
			err = "HEIF file must start with a single ftyp box"
		elseif kind == "moov" then
			err = "HEIF image sequences are unsupported"
		elseif kind == "sefd" then
			-- Samsung's trailer in a box: shot data such as the capture time
			-- and mobile country code.
			local payload = box_size - header_size <= 1024 * 1024
				and read_at(offset + header_size, box_size - header_size)
			local trailer, trailer_err = payload and MPF.samsung(payload, 0)
			if not trailer then
				err = trailer_err or "unsupported Samsung HEIF trailer"
			elseif trailer.video then
				err = "Samsung HEIF Motion Photo is unsupported"
			else
				state.sefd = true
				state.renamed[#state.renamed + 1] = { start = offset + 4, finish = offset + 8, kind = "free" }
				state.free[#state.free + 1] = { start = offset + header_size, finish = offset + box_size }
			end
		elseif kind == "mpvd" then
			-- A Motion Photo video, after everything else.
			if offset + box_size ~= size then
				err = "HEIF Motion Photo video is not the last box"
			else
				state.mpvd = { start = offset, payload = offset + header_size, finish = size, header = header_size }
			end
		elseif kind == "uuid" and read_at(offset + header_size, 16) == QUICKTIME_UUID.c2pa then
			-- C2PA Content Credentials become a zero-filled free box.
			state.c2pa = true
			state.renamed[#state.renamed + 1] = { start = offset + 4, finish = offset + 8, kind = "free" }
			state.free[#state.free + 1] = { start = offset + header_size, finish = offset + box_size }
		elseif not HEIF_TOP_BOXES[kind] then
			err = "unsupported HEIF box " .. kind
		elseif kind == "meta" then
			if state.meta then
				err = "multiple HEIF meta boxes"
			elseif header_size ~= 8 or box_size < 12 or box_size > LIMIT.HEIF_META_BYTES then
				err = "unsupported HEIF meta box size"
			else
				state.meta = { start = offset, finish = offset + box_size, data = read_at(offset, box_size) }
				err = not state.meta.data and "truncated HEIF meta box" or nil
			end
		elseif kind == "free" or kind == "skip" then
			state.free[#state.free + 1] = { start = offset + header_size, finish = offset + box_size }
		end
		if err then
			break
		end
		offset = offset + box_size
	end
	file:close()
	if err then
		return nil, err
	end
	if not state.meta then
		return nil, "missing HEIF meta box"
	end
	state.size = size
	return true
end

-- Parse the meta box into items, references and property associations,
-- keeping the raw bytes of every entry that a rebuild copies.
local function heif_parse_meta(state)
	local m = state.meta.data
	local children, err = iso_children(m, 13, #m)
	if not children then
		return nil, err
	end
	local boxes = {}
	for _, box in ipairs(children) do
		if not HEIF_META_BOXES[box.type] then
			return nil, "unsupported HEIF meta box " .. box.type
		end
		if boxes[box.type] then
			return nil, "duplicate HEIF " .. box.type .. " box"
		end
		boxes[box.type] = box
	end
	for _, kind in ipairs({ "hdlr", "pitm", "iinf", "iloc", "iprp" }) do
		if not boxes[kind] then
			return nil, "missing HEIF " .. kind .. " box"
		end
	end
	state.children, state.boxes = children, boxes

	local hdlr = boxes.hdlr
	if hdlr.finish - hdlr.payload + 1 < 25 or m:sub(hdlr.payload + 8, hdlr.payload + 11) ~= "pict" then
		return nil, "HEIF handler is not pict"
	end

	if boxes.dinf then
		local dinf = iso_children(m, boxes.dinf.payload, boxes.dinf.finish)
		local dref = dinf and #dinf == 1 and dinf[1].type == "dref" and dinf[1]
		local entries = dref and iso_children(m, dref.payload + 8, dref.finish)
		if not entries or #entries ~= be_uint(m, dref.payload + 4, 4) then
			return nil, "invalid HEIF data reference"
		end
		for _, entry in ipairs(entries) do
			if entry.type ~= "url " or entry.finish - entry.start + 1 ~= 12 or m:byte(entry.payload + 3) & 1 ~= 1 then
				return nil, "external HEIF data reference is unsupported"
			end
		end
	end

	local pitm = boxes.pitm
	state.primary = be_uint(m, pitm.payload + 4, m:byte(pitm.payload) == 0 and 2 or 4)

	local items, order = {}, {}
	local iinf = boxes.iinf
	local iinf_width = m:byte(iinf.payload) == 0 and 2 or 4
	local entries
	entries, err = iso_children(m, iinf.payload + 4 + iinf_width, iinf.finish)
	if not entries then
		return nil, err
	end
	if #entries ~= be_uint(m, iinf.payload + 4, iinf_width) or #entries > LIMIT.ISOBMFF_ITEMS then
		return nil, "invalid HEIF item count"
	end
	for _, entry in ipairs(entries) do
		local version = m:byte(entry.payload)
		if entry.type ~= "infe" or (version ~= 2 and version ~= 3) then
			return nil, "unsupported HEIF item information entry"
		end
		local width = version == 2 and 2 or 4
		local position = entry.payload + 4
		local id, protection = be_uint(m, position, width), be_uint(m, position + width, 2)
		local kind = m:sub(position + width + 2, position + width + 5)
		local name_end = m:find("\0", position + width + 6, true)
		if not id or not protection or #kind ~= 4 or items[id] or not name_end or name_end > entry.finish then
			return nil, "invalid HEIF item information entry"
		end
		if protection ~= 0 then
			return nil, "protected HEIF item"
		end
		local item = {
			id = id,
			type = kind,
			header = m:sub(entry.payload, position + width + 5),
			name = m:sub(position + width + 6, name_end - 1),
			tail = m:sub(name_end + 1, entry.finish),
			extents = {},
			properties = {},
		}
		if kind == "mime" then
			item.content_type = item.tail:match("^([^%z]*)%z")
		end
		items[id], order[#order + 1] = item, id
	end
	state.items, state.order, state.iinf_width = items, order, iinf_width
	if not state.primary or not items[state.primary] then
		return nil, "missing or invalid HEIF primary item"
	end

	local iloc = boxes.iloc
	local version = m:byte(iloc.payload)
	local sizes, more = m:byte(iloc.payload + 4, iloc.payload + 5)
	if not more or version > 2 then
		return nil, "unsupported HEIF item location box"
	end
	local offset_size, length_size, base_size = sizes // 16, sizes % 16, more // 16
	local index_size = version > 0 and more % 16 or 0
	for _, width in ipairs({ offset_size, length_size, base_size, index_size }) do
		if width ~= 0 and width ~= 4 and width ~= 8 then
			return nil, "unsupported HEIF item location field size"
		end
	end
	local id_width = version < 2 and 2 or 4
	local count = be_uint(m, iloc.payload + 6, id_width)
	local position = iloc.payload + 6 + id_width
	state.iloc_header, state.iloc_width, state.iloc_order = m:sub(iloc.payload, iloc.payload + 5), id_width, {}
	for _ = 1, count or 0 do
		local start = position
		local id = be_uint(m, position, id_width)
		position = position + id_width
		local method = 0
		if version > 0 then
			method = (be_uint(m, position, 2) or 0) % 16
			position = position + 2
		end
		local reference, base = be_uint(m, position, 2), be_uint(m, position + 2, base_size)
		local extent_count = be_uint(m, position + 2 + base_size, 2)
		position = position + 4 + base_size
		local item = id and items[id]
		if not item or item.location or not reference or not base or not extent_count then
			return nil, "invalid HEIF item location"
		end
		if reference ~= 0 or method > 1 then
			return nil, "unsupported HEIF item construction"
		end
		for _ = 1, extent_count do
			position = position + index_size
			local relative, length = be_uint(m, position, offset_size), be_uint(m, position + offset_size, length_size)
			local length_at = position + offset_size - start + 1
			position = position + offset_size + length_size
			local first = relative and checked_add(base, relative)
			local last = first and length and checked_add(first, length)
			if not last or position - 1 > iloc.finish then
				return nil, "invalid HEIF item extent"
			end
			item.extents[#item.extents + 1] = {
				method = method,
				start = first,
				finish = last,
				length_at = length_at,
				length_size = length_size,
			}
		end
		item.location = m:sub(start, position - 1)
		state.iloc_order[#state.iloc_order + 1] = id
	end
	if not count or position ~= iloc.finish + 1 then
		return nil, "invalid HEIF item location box"
	end

	state.references = {}
	if boxes.iref then
		local iref = boxes.iref
		local width = m:byte(iref.payload) == 0 and 2 or 4
		if (m:byte(iref.payload) or 2) > 1 then
			return nil, "unsupported HEIF item reference box"
		end
		entries, err = iso_children(m, iref.payload + 4, iref.finish)
		if not entries then
			return nil, err
		end
		for _, entry in ipairs(entries) do
			if not HEIF_REFERENCES[entry.type] then
				return nil, "unsupported HEIF item reference " .. entry.type
			end
			local source, total = be_uint(m, entry.payload, width), be_uint(m, entry.payload + width, 2)
			local reference = { type = entry.type, source = source, targets = {} }
			if
				not source
				or not items[source]
				or not total
				or entry.payload + width + 2 + total * width ~= entry.finish + 1
			then
				return nil, "invalid HEIF item reference"
			end
			for index = 1, total do
				local target = be_uint(m, entry.payload + width + 2 + (index - 1) * width, width)
				if not items[target] or target == source then
					return nil, "invalid HEIF item reference"
				end
				reference.targets[index] = target
			end
			state.references[#state.references + 1] = reference
		end
		state.iref_header, state.iref_width = m:sub(iref.payload, iref.payload + 3), width
	end

	local iprp
	iprp, err = iso_children(m, boxes.iprp.payload, boxes.iprp.finish)
	if not iprp then
		return nil, err
	end
	local ipco, ipma
	for _, box in ipairs(iprp) do
		if box.type == "ipco" and not ipco then
			ipco = box
		elseif box.type == "ipma" and not ipma then
			ipma = box
		else
			return nil, "unsupported HEIF item property box " .. box.type
		end
	end
	local properties = ipco and iso_children(m, ipco.payload, ipco.finish)
	if not properties or not ipma then
		return nil, "invalid HEIF item properties"
	end
	for _, property in ipairs(properties) do
		if not HEIF_PROPERTIES[property.type] and property.type ~= "free" then
			return nil, "unsupported HEIF item property " .. property.type
		end
	end
	state.iprp, state.properties, state.ipma_order = iprp, properties, {}
	version = m:byte(ipma.payload)
	local large = (be_uint(m, ipma.payload + 1, 3) or 0) & 1 == 1
	count = be_uint(m, ipma.payload + 4, 4)
	position = ipma.payload + 8
	if not version or version > 1 or not count then
		return nil, "unsupported HEIF item property association box"
	end
	id_width = version == 0 and 2 or 4
	for _ = 1, count do
		local start = position
		local id, total = be_uint(m, position, id_width), m:byte(position + id_width)
		local item = id and items[id]
		if not item or not total or item.association then
			return nil, "invalid HEIF item property association"
		end
		position = position + id_width + 1
		for _ = 1, total do
			local value = be_uint(m, position, large and 2 or 1)
			local index = value and value % (large and 32768 or 128)
			-- Index 0 is a non-essential "no property" placeholder.
			if value ~= 0 and (not index or not properties[index] or properties[index].type == "free") then
				return nil, "invalid HEIF item property association"
			end
			if index ~= 0 then
				item.properties[properties[index].type] = true
			end
			position = position + (large and 2 or 1)
		end
		item.association = m:sub(start, position - 1)
		state.ipma_order[#state.ipma_order + 1] = id
	end
	if position ~= ipma.finish + 1 then
		return nil, "invalid HEIF item property association box"
	end
	state.ipma_header = m:sub(ipma.payload, ipma.payload + 3)
	return true
end

-- Decide which items go and build the replacement meta box and the regions
-- that the in-place writer and the verification use.
local function heif_plan(state)
	local m, items, primary = state.meta.data, state.items, state.primary
	local describes = {}
	for _, reference in ipairs(state.references) do
		if reference.type == "cdsc" then
			describes[reference.source] = describes[reference.source] or {}
			for _, target in ipairs(reference.targets) do
				describes[reference.source][target] = true
			end
		end
	end
	local removed, gainmap = {}, m:find("urn:com:apple:photo:2020:aux:hdrgainmap", 1, true)
	local apple
	-- Rewrite an item's payload in place; the new one must fit its extent.
	state.replacements = {}
	local function replace(item, payload)
		local extent = item.extents[1]
		if #item.extents ~= 1 or extent.method ~= 0 or extent.length_size == 0 then
			return false
		end
		if #payload > extent.finish - extent.start then
			return false
		end
		state.replacements[item.id] = payload
		return true
	end
	for _, id in ipairs(state.order) do
		local item = items[id]
		local makernote = gainmap
			and item.data
			and describes[id]
			and describes[id][primary]
			and apple_hdr_makernote(item.data:sub(5 + (be_uint(item.data, 1, 4) or #item.data)))
		local motion
		if item.content_type == HEIF_XMP and item.data and state.mpvd and describes[id] and describes[id][primary] then
			local err
			motion, err = MPF.motion_xmp(item.data, true)
			if err then
				return nil, err
			end
		end
		if makernote and not apple then
			-- Only the Apple HDR values stay, in a rebuilt Exif payload.
			apple = true
			if not replace(item, u32_be_bytes(6) .. "Exif\0\0" .. makernote_exif(makernote)) then
				removed[id] = true
			end
		elseif item.type == "Exif" then
			removed[id] = true
		elseif motion and not state.motion then
			-- The Motion Photo XMP stays, rebuilt with only what locates the
			-- video in the mpvd box.
			local length = state.mpvd.finish - state.mpvd.payload
			if
				motion.kind ~= "motion"
				or motion.length ~= length
				or motion.primary_padding ~= tostring(state.mpvd.header)
			then
				return nil, "HEIF Motion Photo XMP does not match its video"
			end
			state.motion = motion
			local xmp = MPF.primary_xmp({ motion = motion, primary_mime = "image/heic" }):sub(30)
			if not replace(item, xmp) then
				return nil, "HEIF Motion Photo XMP cannot be rebuilt in place"
			end
		elseif item.type == "mime" and item.content_type == HEIF_XMP then
			-- XMP describing an auxiliary image (an HDR gain map) stays; the
			-- allowlist then decides whether its content is acceptable.
			local targets = describes[id]
			if not targets or targets[primary] then
				removed[id] = true
			end
		elseif item.type == "mime" then
			return nil, "unsupported HEIF MIME item " .. tostring(item.content_type)
		elseif not HEIF_IMAGE_ITEMS[item.type] then
			return nil, "unsupported HEIF item " .. item.type
		end
	end
	if removed[primary] then
		return nil, "HEIF primary item is not an image"
	end
	if state.mpvd and not state.motion then
		return nil, "HEIF Motion Photo video without its XMP"
	end
	for _, reference in ipairs(state.references) do
		if not removed[reference.source] then
			for _, target in ipairs(reference.targets) do
				if removed[target] then
					return nil, "HEIF image refers to a metadata item"
				end
			end
		end
	end

	local idat = state.boxes.idat
	local idat_length = idat and idat.finish - idat.payload + 1 or 0
	local kept, zeroed, idat_zeroed = {}, {}, {}
	for _, id in ipairs(state.order) do
		for _, extent in ipairs(items[id].extents) do
			local length = extent.finish - extent.start
			if extent.method == 1 and extent.finish > idat_length then
				return nil, "HEIF item extent exceeds idat"
			elseif extent.method == 0 and extent.finish > state.size then
				return nil, "HEIF item extent exceeds the file"
			elseif length == 0 and not removed[id] then
				return nil, "HEIF item extent without a length"
			end
			if removed[id] then
				local list = extent.method == 1 and idat_zeroed or zeroed
				if length > 0 then
					list[#list + 1] = { start = extent.start, finish = extent.finish, kind = "zero" }
				end
			else
				kept[#kept + 1] = extent
			end
		end
	end
	for _, extent in ipairs(kept) do
		local others = extent.method == 1 and idat_zeroed or zeroed
		if extent.method == 0 then
			if extent.start < state.meta.finish and extent.finish > state.meta.start then
				return nil, "HEIF image data inside the meta box"
			end
			others = { table.unpack(zeroed) }
			for _, free in ipairs(state.free) do
				others[#others + 1] = free
			end
		end
		for _, other in ipairs(others) do
			if extent.start < other.finish and extent.finish > other.start then
				return nil, "HEIF image data overlaps metadata or free space"
			end
		end
	end

	local function rebuild(box)
		local kind = box.type
		if kind == "hdlr" then
			return iso_box("hdlr", m:sub(box.payload, box.payload + 23) .. string.rep("\0", 1 + (state.hdlr_pad or 0)))
		elseif kind == "iinf" then
			local parts, count = {}, 0
			for _, id in ipairs(state.order) do
				if not removed[id] then
					local item = items[id]
					parts[#parts + 1] = iso_box("infe", item.header .. "\0" .. item.tail)
					count = count + 1
				end
			end
			return iso_box(
				"iinf",
				m:sub(box.payload, box.payload + 3) .. uint_be_bytes(count, state.iinf_width) .. table.concat(parts)
			)
		elseif kind == "iloc" then
			local parts = {}
			for _, id in ipairs(state.iloc_order) do
				local location, payload = items[id].location, state.replacements[id]
				if payload then
					-- A rebuilt payload is shorter than the extent it reuses.
					local extent = items[id].extents[1]
					location = location:sub(1, extent.length_at - 1)
						.. uint_be_bytes(#payload, extent.length_size)
						.. location:sub(extent.length_at + extent.length_size)
				end
				if not removed[id] then
					parts[#parts + 1] = location
				end
			end
			return iso_box("iloc", state.iloc_header .. uint_be_bytes(#parts, state.iloc_width) .. table.concat(parts))
		elseif kind == "iref" then
			local parts, width = {}, state.iref_width
			for _, reference in ipairs(state.references) do
				if not removed[reference.source] then
					local targets = {}
					for _, target in ipairs(reference.targets) do
						targets[#targets + 1] = uint_be_bytes(target, width)
					end
					parts[#parts + 1] = iso_box(
						reference.type,
						uint_be_bytes(reference.source, width) .. uint_be_bytes(#targets, 2) .. table.concat(targets)
					)
				end
			end
			return #parts > 0 and iso_box("iref", state.iref_header .. table.concat(parts)) or ""
		elseif kind == "iprp" then
			local parts = {}
			for _, child in ipairs(state.iprp) do
				if child.type == "ipma" then
					local associations = {}
					for _, id in ipairs(state.ipma_order) do
						if not removed[id] then
							associations[#associations + 1] = items[id].association
						end
					end
					parts[#parts + 1] = iso_box(
						"ipma",
						state.ipma_header .. uint_be_bytes(#associations, 4) .. table.concat(associations)
					)
				else
					-- Padding inside the property container is zero-filled, and an
					-- ICC profile loses its display serial number in place.
					local properties = {}
					for _, property in ipairs(state.properties) do
						local bytes = property.type == "free"
								and iso_box("free", string.rep("\0", property.finish - property.payload + 1))
							or m:sub(property.start, property.finish)
						local colour = property.type == "colr" and m:sub(property.payload, property.payload + 3)
						if colour == "prof" or colour == "rICC" then
							local cleaned = ICC.clean(m:sub(property.payload + 4, property.finish))
							if cleaned then
								bytes = m:sub(property.start, property.payload + 3) .. cleaned
							end
						end
						properties[#properties + 1] = bytes
					end
					parts[#parts + 1] = iso_box("ipco", table.concat(properties))
				end
			end
			return iso_box("iprp", table.concat(parts))
		elseif kind == "idat" then
			local payload = m:sub(box.payload, box.finish)
			for _, extent in ipairs(idat_zeroed) do
				payload = payload:sub(1, extent.start)
					.. string.rep("\0", extent.finish - extent.start)
					.. payload:sub(extent.finish + 1)
			end
			return iso_box("idat", payload)
		end
		return m:sub(box.start, box.finish)
	end
	local function rebuild_meta()
		local parts = {}
		for _, box in ipairs(state.children) do
			parts[#parts + 1] = rebuild(box)
		end
		return iso_box("meta", m:sub(9, 12) .. table.concat(parts))
	end
	local meta = rebuild_meta()
	local pad = #m - #meta
	-- Too little space for a free box: the handler name takes the slack as
	-- trailing NUL bytes.
	if pad > 0 and pad < 8 then
		state.hdlr_pad, pad = pad, 0
		meta = rebuild_meta()
	end
	state.clean_meta = meta
	if pad > 0 then
		meta = meta .. iso_box("free", string.rep("\0", pad - 8))
	end

	local regions = { table.unpack(state.renamed) }
	for _, list in ipairs({ zeroed, state.free }) do
		for _, region in ipairs(list) do
			if region.finish > region.start then
				regions[#regions + 1] = { start = region.start, finish = region.finish, kind = "zero" }
			end
		end
	end
	if meta ~= m then
		regions[#regions + 1] = { start = state.meta.start, finish = state.meta.finish, kind = "bytes", bytes = meta }
	end
	for id, payload in pairs(state.replacements) do
		local extent = items[id].extents[1]
		regions[#regions + 1] = {
			start = extent.start,
			finish = extent.finish,
			kind = "bytes",
			bytes = payload .. string.rep("\0", extent.finish - extent.start - #payload),
		}
	end
	table.sort(regions, function(a, b)
		return a.start < b.start
	end)
	for index = 2, #regions do
		if regions[index].start < regions[index - 1].finish then
			return nil, "HEIF metadata regions overlap"
		end
	end
	state.removed, state.regions, state.rebuilt = removed, regions, meta ~= m
	return true
end

local function heif_parse(path)
	local state = { free = {}, renamed = {} }
	local ok, err = heif_top_level(path, state)
	if ok then
		ok, err = heif_parse_meta(state)
	end
	if ok then
		-- Exif payloads are read for the Apple HDR values.
		local file = io.open(path, "rb")
		for _, item in pairs(state.items) do
			local extent = item.extents[1]
			if
				file
				and (item.type == "Exif" or item.content_type == HEIF_XMP)
				and #item.extents == 1
				and extent.method == 0
				and extent.finish - extent.start <= 1024 * 1024
			then
				file:seek("set", extent.start)
				item.data = file:read(extent.finish - extent.start)
			end
		end
		if file then
			file:close()
		end
		ok, err = heif_plan(state)
	end
	if not ok then
		return nil, err
	end
	return state
end

local function heif_manifest(path)
	local output, err = bounded_output("ffprobe", {
		"-v",
		"error",
		"-bitexact",
		"-show_streams",
		"-show_stream_groups",
		"-show_packets",
		"-show_data_hash",
		"sha256",
		"-show_entries",
		"stream=index,id,codec_type,codec_name,profile,level,width,height,coded_width,coded_height,pix_fmt,color_range,color_space,color_transfer,color_primaries,chroma_location,extradata_size,extradata_hash:stream_disposition:stream_side_data:stream_group:packet=stream_index,size,flags,data_hash",
		"--",
		path,
	}, media_timeout(path))
	if not output then
		return nil, err
	end
	-- FFprobe exposes item names as titles and the Exif item as side data;
	-- their removal is the point. The default format has one value per line.
	local lines, block = {}, nil
	for line in output:gmatch("[^\n]+") do
		if block then
			block[#block + 1] = line
			if line == "[/SIDE_DATA]" then
				if block[2] ~= "side_data_type=EXIF metadata" then
					table.move(block, 1, #block, #lines + 1, lines)
				end
				block = nil
			end
		elseif line == "[SIDE_DATA]" then
			block = { line }
		elseif not line:find("^TAG:") then
			lines[#lines + 1] = line
		end
	end
	return table.concat(lines, "\n")
end

local HEIF_SPEC = metadata_spec({
	keep = with_basics({
		"File:ImageWidth",
		"File:ImageHeight",
		"QuickTime:MajorBrand",
		"QuickTime:MinorVersion",
		"QuickTime:CompatibleBrands",
		"QuickTime:HandlerType",
		"Meta:PrimaryItemReference",
		"Meta:MetaImageSize",
		"QuickTime:HEVCConfigurationVersion",
		"QuickTime:GeneralProfileSpace",
		"QuickTime:GeneralTierFlag",
		"QuickTime:GeneralProfileIDC",
		"QuickTime:GenProfileCompatibilityFlags",
		"QuickTime:ConstraintIndicatorFlags",
		"QuickTime:GeneralLevelIDC",
		"QuickTime:MinSpatialSegmentationIDC",
		"QuickTime:ParallelismType",
		"QuickTime:ChromaFormat",
		"QuickTime:BitDepthLuma",
		"QuickTime:BitDepthChroma",
		"QuickTime:AverageFrameRate",
		"QuickTime:ConstantFrameRate",
		"QuickTime:NumTemporalLayers",
		"QuickTime:TemporalIDNested",
		"QuickTime:AV1ConfigurationVersion",
		"QuickTime:SeqProfile",
		"QuickTime:SeqLevelIdx0",
		"QuickTime:SeqTier0",
		"QuickTime:HighBitDepth",
		"QuickTime:TwelveBit",
		"QuickTime:ChromaSamplePosition",
		"QuickTime:InitialDelaySamples",
		"QuickTime:ImageSpatialExtent",
		"QuickTime:Rotation",
		"QuickTime:Mirroring",
		"QuickTime:CleanAperture",
		"QuickTime:MaxContentLightLevel",
		"QuickTime:MaxPicAverageLightLevel",
		"QuickTime:ImagePixelDepth",
		"QuickTime:PixelAspectRatio",
		"QuickTime:AuxiliaryImageType",
		"QuickTime:MediaDataSize",
		"QuickTime:MediaDataOffset",
		"QuickTime:MediaData",
		"QuickTime:ColorProfiles",
		"QuickTime:ColorPrimaries",
		"QuickTime:TransferCharacteristics",
		"QuickTime:MatrixCoefficients",
		"QuickTime:VideoFullRangeFlag",
		"XMP-HDRGainMap:HDRGainMapVersion",
		"^ICC:*",
	}),
	free = {
		"QuickTime:Free",
		"QuickTime:Skip",
		"QuickTime:Unknown_free",
		-- Four bytes of the handler box, copied as they are.
		"QuickTime:HandlerVendorID",
		"XMP-x:XMPToolkit",
		"File:ExifByteOrder",
		"Apple:MakerNoteVersion",
		"Apple:HDRHeadroom",
		"Apple:HDRGain",
		-- A kept Motion Photo: its rebuilt XMP and the video.
		"XMP-GCamera:MotionPhoto",
		"XMP-GCamera:MotionPhotoVersion",
		"XMP-GCamera:MotionPhotoPresentationTimestampUs",
		"XMP-GContainer:*",
		"QuickTime:MotionPhotoVideo",
	},
})

local function heif_video(path, state)
	local file, err = io.open(path, "rb")
	if not file then
		return nil, tostring(err or "could not open HEIF file")
	end
	local length = state.mpvd.finish - state.mpvd.payload
	if length > LIMIT.MOTION_BYTES then
		file:close()
		return nil, "HEIF Motion Photo video size limit exceeded"
	end
	file:seek("set", state.mpvd.payload)
	local video = file:read(length)
	file:close()
	return video and #video == length and video or nil, "truncated HEIF Motion Photo video"
end

local HEIF_POLICY = {
	spec = HEIF_SPEC,
	preflight = function(path, inventory)
		local state, err = heif_parse(path)
		if not state then
			return nil, err
		end
		-- HEIF readers rotate by the irot and imir properties; an Exif
		-- orientation without them would only be honoured by some viewers.
		local primary = state.items[state.primary]
		for _, value in ipairs(inventory.values["IFD0:Orientation"] or {}) do
			if value ~= "1" and not (primary.properties.irot or primary.properties.imir) then
				return nil, "HEIF Exif orientation without an irot property"
			end
		end
		return state
	end,
	structure_clean = function(state, path)
		if next(state.removed) then
			return false, "HEIF Exif or XMP item"
		end
		local neutral, err = regions_hold(path, state.regions)
		if neutral == nil then
			return nil, err
		end
		if neutral and state.mpvd then
			local video
			video, err = heif_video(path, state)
			if not video then
				return nil, err
			end
			neutral = EMBEDDED.is_clean(video)
		end
		return neutral, "HEIF item names, free space or Motion Photo video are not neutral"
	end,
	-- ExifTool's view of the kept properties is compared through the
	-- allowlist. FFprobe adds an independent check of the image items and
	-- their bytes where it can read the source.
	capture = function(path, _, state)
		return { meta = state.clean_meta, probe = heif_manifest(path) or false }
	end,
	equivalent = function(before, after)
		if before.meta ~= after.meta then
			return nil, "HEIF meta box differs from the plan"
		end
		return not before.probe or before.probe == after.probe or nil, "HEIF image items changed"
	end,
	transform = function(ctx)
		local state = ctx.state
		if state.mpvd then
			-- The cleaned video replaces the mpvd payload; its size is unchanged.
			local video, err = heif_video(ctx.source, state)
			if not video then
				return nil, err
			end
			local directory = ctx.staged:match("^(.*)/[^/]+$")
			local source, target = directory .. "/.motion-source.mp4", directory .. "/.motion.mp4"
			local ok
			ok, err = rewrite_file(source, video)
			if ok then
				ok, err = EMBEDDED.clean(source, target)
			end
			local cleaned = ok and read_file(target, LIMIT.MOTION_BYTES, "embedded video")
			fs.remove("file", Url(source))
			fs.remove("file", Url(target))
			if not cleaned or #cleaned ~= #video then
				return nil, err or "could not read the cleaned Motion Photo video"
			end
			state.regions[#state.regions + 1] =
				{ start = state.mpvd.payload, finish = state.mpvd.finish, kind = "bytes", bytes = cleaned }
		end
		return write_regions(ctx.staged, state.regions)
	end,
	verify = function(source, staged, state)
		return verify_regions(source, staged, state.regions)
	end,
}

-- Transaction ------------------------------------------------------------------------

-- Matroska and WebM ------------------------------------------------------------------

-- Matroska is cleaned in place, like QuickTime: metadata elements become EBML
-- Void elements of the same size with zeroed payloads, the writing
-- applications become empty strings, existing Void space is zeroed and the
-- CRC-32 of every changed master is recomputed. Clusters, cues and codec data
-- are never touched, and every element outside the rules below is refused.
local MKV = {
	EBML = 0x1A45DFA3,
	SEGMENT = 0x18538067,
	SEEK_HEAD = 0x114D9B74,
	CLUSTER = 0x1F43B675,
	ATTACHMENTS = 0x1941A469,
	VOID = 0xEC,
	CRC = 0xBF,
	-- Seek targets that cleaning removes, as stored in SeekID.
	TAGS_ID = "\18\84\195\103",
	ATTACHMENTS_ID = "\25\65\164\105",
}

-- Children of an unknown-size cluster; any level-1 element ends it.
MKV.CLUSTER_CHILDREN = as_set({ 0xE7, 0x5854, 0xA7, 0xAB, 0xA3, 0xA0, 0xAF, 0xBF, 0xEC })

-- Attachments that rendering needs (subtitle fonts); others are removed.
MKV.FONTS = as_set({
	"application/x-truetype-font",
	"application/x-font",
	"application/x-font-ttf",
	"application/x-font-otf",
	"application/font-sfnt",
	"application/vnd.ms-opentype",
})

function MKV.is_font(media_type)
	media_type = media_type:lower()
	return media_type:match("^font/") ~= nil or MKV.FONTS[media_type] == true
end

MKV.HEADER = {
	[0x4286] = true,
	[0x42F7] = true,
	[0x42F2] = true,
	[0x42F3] = true,
	[0x4287] = true,
	[0x4285] = true,
	[0x4281] = true,
}

-- Segment information: timing stays, titles, dates, writing applications and
-- segment identifiers (which link split recordings) go.
MKV.INFO = {
	[0x2AD7B1] = true,
	[0x4489] = true,
	[0x7BA9] = "void title",
	[0x4D80] = "blank muxing application",
	[0x5741] = "blank writing application",
	[0x4461] = "void date",
	[0x73A4] = "void segment UID",
	[0x7384] = "void segment filename",
	[0x3CB923] = "void previous segment UID",
	[0x3C83AB] = "void previous segment filename",
	[0x3EB923] = "void next segment UID",
	[0x3E83BB] = "void next segment filename",
	[0x4444] = "void segment family",
	[0x6924] = "void chapter translation",
}

MKV.CONTENT_ENCODINGS = {
	[0x6240] = {
		[0x5031] = true,
		[0x5032] = true,
		[0x5033] = true,
		[0x5034] = true,
		[0x5035] = "refuse encrypted track",
	},
}

-- Track entries keep every playback element; names and codec descriptions go.
-- Video, audio and operation masters hold only technical values.
MKV.TRACK = {
	[0x536E] = "void track name",
	[0x258688] = "void codec name",
	[0x3A9697] = "void codec settings",
	[0x3B4040] = "void codec information URL",
	[0x26B240] = "void codec download URL",
	[0x6D80] = MKV.CONTENT_ENCODINGS,
}
for _, id in ipairs({
	0xD7,
	0x73C5,
	0x83,
	0xB9,
	0x88,
	0x55AA,
	0x55AB,
	0x55AC,
	0x55AD,
	0x55AE,
	0x55AF,
	0x9C,
	0x6DE7,
	0x6DF8,
	0x23E383,
	0x234E7A,
	0x23314F,
	0x537F,
	0x55EE,
	0x41E4,
	0x22B59C,
	0x22B59D,
	0x63A2,
	0x86,
	0x7446,
	0xAA,
	0x6FAB,
	0x56AA,
	0x56BB,
	0x6624,
	0xE0,
	0xE1,
	0xE2,
	0xC0,
	0xC1,
	0xC4,
	0xC6,
	0xC7,
}) do
	MKV.TRACK[id] = true
end

MKV.CHAPTER_ATOM = {
	[0x6E67] = "refuse chapter linked to another segment",
	[0x6EBC] = "refuse chapter linked to another segment",
	[0x6944] = "refuse chapter commands",
}
for _, id in ipairs({ 0x73C4, 0x5654, 0x91, 0x92, 0x98, 0x4598, 0x80, 0x8F, 0x4588, 0x63C3 }) do
	MKV.CHAPTER_ATOM[id] = true
end
MKV.CHAPTER_ATOM[0xB6] = MKV.CHAPTER_ATOM

MKV.CHAPTERS = {
	[0x45B9] = {
		[0x45BC] = true,
		[0x45BD] = true,
		[0x45DB] = true,
		[0x45DD] = true,
		[0x4520] = true,
		[0xB6] = MKV.CHAPTER_ATOM,
	},
}

-- A kept font keeps its name, type, data and identifier.
MKV.ATTACHED_FILE = {
	[0x466E] = true,
	[0x4660] = true,
	[0x465C] = true,
	[0x46AE] = true,
	[0x467E] = "void attachment description",
	[0x4675] = "void attachment referral",
	[0x4661] = true,
	[0x4662] = true,
}

MKV.SPEC = (function()
	local keep = with_basics({
		"Matroska:EBMLVersion",
		"Matroska:EBMLReadVersion",
		"Matroska:EBMLMaxIDLength",
		"Matroska:EBMLMaxSizeLength",
		"Matroska:DocType",
		"Matroska:DocTypeVersion",
		"Matroska:DocTypeReadVersion",
		"Matroska:CueTime",
		"Matroska:CueTrack",
		"Matroska:CueClusterPosition",
		"Matroska:CueBlockNumber",
		"Matroska:CueCodecState",
		"Matroska:CueRefTime",
		"Matroska:CueRefCluster",
		"Matroska:CueRefNumber",
		"Matroska:CueRefCodecState",
		"Info:TimecodeScale",
		"Info:Duration",
	})
	for _, tag in ipairs({
		"TrackNumber",
		"TrackUID",
		"TrackType",
		"TrackDefault",
		"TrackForced",
		"TrackLacing",
		"TrackLanguage",
		"TrackLanguageIETF",
		"TrackOffset",
		"TrackOverlay",
		"TrackTimecodeScale",
		"TrackAttachmentUID",
		"TrackTranslateCodec",
		"TrackTranslateEditionUID",
		"TrackTranslateTrackID",
		"CodecID",
		"VideoCodecID",
		"AudioCodecID",
		"CodecPrivate",
		"CodecDecodeAll",
		"DefaultDuration",
		"MinCache",
		"MaxCache",
		"MaxBlockAdditionID",
		"ContentEncodingOrder",
		"ContentEncodingScope",
		"ContentEncodingType",
		"ContentCompressionAlgorithm",
		"ContentCompressionSettings",
		"ImageWidth",
		"ImageHeight",
		"DisplayWidth",
		"DisplayHeight",
		"DisplayUnit",
		"AspectRatioType",
		"VideoFrameRate",
		"FrameRate",
		"VideoScanType",
		"Stereo3DMode",
		"CropTop",
		"CropBottom",
		"CropLeft",
		"CropRight",
		"ColorSpace",
		"Gamma",
		"ProjectionType",
		"ProjectionPrivate",
		"ProjectionPoseYaw",
		"ProjectionPosePitch",
		"ProjectionPoseRoll",
		"AudioSampleRate",
		"OutputAudioSampleRate",
		"AudioChannels",
		"AudioBitsPerSample",
		"ChannelPositions",
	}) do
		keep[#keep + 1] = "^Track%d+$:" .. tag
	end
	for _, tag in ipairs({
		"EditionUID",
		"EditionFlagHidden",
		"EditionFlagDefault",
		"EditionFlagOrdered",
		"ChapterUID",
		"ChapterTimeStart",
		"ChapterTimeEnd",
		"ChapterFlagHidden",
		"ChapterFlagEnabled",
		"ChapterTrackNumber",
		"ChapterPhysicalEquivalent",
		"ChapterString",
		"ChapterLanguage",
		"ChapterCountry",
	}) do
		keep[#keep + 1] = "^Chapter%d+$:" .. tag
		keep[#keep + 1] = "Matroska:" .. tag
	end
	return metadata_spec({
		keep = keep,
		-- Seek entries and non-font attachments go (the parser keeps only
		-- fonts); ExifTool names elements it does not know (colour, codec
		-- delay) by their ID.
		free = {
			"Matroska:AttachedFileName",
			"Matroska:AttachedFileMIMEType",
			"Matroska:AttachedFileData",
			"Matroska:AttachedFileUID",
			"Matroska:CRC-32",
			"Info:CRC-32",
			"^Track%d+$:CRC-32",
			"Matroska:SeekID",
			"Matroska:SeekPosition",
			"^Matroska$:^Matroska_0x%x+$",
			"^Track%d+$:^Matroska_0x%x+$",
			"^Chapter%d+$:^Matroska_0x%x+$",
		},
		-- Codec data loses its comments; FFprobe hashes it otherwise.
		recomputed = { "^Track%d+$:CodecPrivate" },
		neutral = { ["Info:MuxingApp"] = "", ["Info:WritingApp"] = "" },
	})
end)()

function MKV.sniff(path)
	local file = io.open(path, "rb")
	local header = file and file:read(4)
	if file then
		file:close()
	end
	return header == "\26\69\223\163"
end

function MKV.read(state, offset, length)
	state.file:seek("set", offset)
	local data = state.file:read(length)
	return data and #data == length and data or nil
end

-- The element at offset: id, header and payload bounds (finish is nil for an
-- unknown size).
function MKV.header(state, offset, finish)
	state.count = state.count + 1
	if state.count > LIMIT.EBML_ELEMENTS then
		return nil, "Matroska element count limit exceeded"
	end
	state.file:seek("set", offset)
	local data = state.file:read(math.min(12, finish - offset))
	if not data or #data < 2 then
		return nil, "truncated Matroska element"
	end
	local id, id_length = ebml_vint(data, 1, true)
	if not id then
		return nil, id_length
	end
	local size, size_length, unknown = ebml_vint(data, 1 + id_length, false)
	if not size then
		return nil, size_length
	end
	local payload = offset + id_length + size_length
	local element = { id = id, start = offset, id_length = id_length, payload = payload }
	if not unknown then
		element.finish = payload + size
		if element.finish > finish then
			return nil, string.format("Matroska element 0x%X exceeds its parent", id)
		end
	end
	return element
end

function MKV.value(state, element, limit)
	local length = element.finish - element.payload
	if length > (limit or LIMIT.EBML_VALUE) then
		return nil, "Matroska value is too large"
	end
	local data = MKV.read(state, element.payload, length)
	if not data then
		return nil, "truncated Matroska value"
	end
	return data
end

function MKV.children(state, start, finish, visit)
	local offset = start
	while offset < finish do
		local element, err = MKV.header(state, offset, finish)
		if not element then
			return nil, err
		end
		if not element.finish then
			return nil, string.format("unsupported unknown-size Matroska element 0x%X", element.id)
		end
		local ok
		ok, err = visit(element)
		if not ok then
			return nil, err
		end
		offset = element.finish
	end
	return true
end

function MKV.add(state, start, finish, kind, bytes)
	if finish > start then
		state.regions[#state.regions + 1] = { start = start, finish = finish, kind = kind, bytes = bytes }
	end
end

-- A size field of width bytes.
function MKV.size_field(size, width)
	local bytes = {}
	for index = width, 1, -1 do
		bytes[index] = size % 256
		size = size // 256
	end
	bytes[1] = bytes[1] | (1 << (8 - width))
	return string.char(table.unpack(bytes))
end

-- The header of a Void element that spans length bytes (at least 2).
function MKV.void_header(length)
	for width = 1, 8 do
		local size = length - 1 - width
		if size >= 0 and size < (1 << (7 * width)) - 1 then
			return string.char(MKV.VOID) .. MKV.size_field(size, width)
		end
	end
end

function MKV.void(state, element)
	if element.id == MKV.VOID then
		MKV.add(state, element.payload, element.finish, "zero")
		return
	end
	local header = MKV.void_header(element.finish - element.start)
	MKV.add(state, element.start, element.start + #header, "bytes", header)
	MKV.add(state, element.start + #header, element.finish, "zero")
end

-- An element with new, shorter content followed by a Void element in the rest
-- of its span. The size field takes the narrowest width that leaves either
-- nothing or room for a Void element.
function MKV.replace(state, element, content)
	local id = MKV.read(state, element.start, element.id_length)
	for width = 1, 8 do
		if #content < (1 << (7 * width)) - 1 then
			local head = id .. MKV.size_field(#content, width) .. content
			local rest = element.finish - element.start - #head
			if rest == 0 or rest >= 2 then
				head = rest == 0 and head or head .. MKV.void_header(rest)
				MKV.add(state, element.start, element.start + #head, "bytes", head)
				MKV.add(state, element.start + #head, element.finish, "zero")
				return true
			end
		end
	end
	return nil, "Matroska element cannot shrink in place"
end

-- CRC-32 of [start, finish) as planned: the regions from index first on are
-- applied (none when first is nil).
function MKV.crc(state, start, finish, first)
	local regions = {}
	for index = first or #state.regions + 1, #state.regions do
		regions[#regions + 1] = state.regions[index]
	end
	table.sort(regions, function(a, b)
		return a.start < b.start
	end)
	local value, offset, index = 0, start, 1
	while offset < finish do
		local region = regions[index]
		local chunk
		if region and region.start <= offset then
			local length = math.min(region.finish - offset, #ZERO_BLOCK)
			chunk = region_expected(region, offset - region.start, length)
			if offset + length >= region.finish then
				index = index + 1
			end
		else
			local limit = region and region.start or finish
			chunk = MKV.read(state, offset, math.min(limit - offset, STREAM_BLOCK))
			if not chunk then
				return nil
			end
		end
		value = crc32(chunk, 1, #chunk, value)
		offset = offset + #chunk
	end
	return value
end

function MKV.child(state, element, rules, depth)
	if element.id == MKV.VOID then
		MKV.void(state, element)
		return true
	end
	local action = rules[element.id]
	if action == true then
		return true
	elseif type(action) == "table" then
		return MKV.master(state, element, action, depth + 1)
	elseif type(action) == "function" then
		return action(state, element, depth)
	end
	local verb, name = tostring(action):match("^(%a+) (.+)$")
	if verb == "void" then
		state.metadata[#state.metadata + 1] = name
		MKV.void(state, element)
	elseif verb == "blank" then
		if element.finish > element.payload then
			state.metadata[#state.metadata + 1] = name
			return MKV.replace(state, element, "")
		end
	elseif verb == "refuse" then
		return nil, "unsupported Matroska " .. name
	else
		return nil, string.format("unsupported Matroska element 0x%X", element.id)
	end
	return true
end

-- Plan a master's children; a leading CRC-32 is recomputed when anything
-- inside changes.
function MKV.master(state, element, rules, depth)
	if depth > LIMIT.EBML_DEPTH then
		return nil, "Matroska nesting limit exceeded"
	end
	local first, crc = #state.regions + 1, nil
	local ok, err = MKV.children(state, element.payload, element.finish, function(child)
		if child.id == MKV.CRC then
			if child.start ~= element.payload or child.finish - child.payload ~= 4 then
				return nil, "misplaced Matroska CRC-32"
			end
			crc = child
			return true
		end
		return MKV.child(state, child, rules, depth)
	end)
	if not ok or not crc then
		return ok, err
	end
	if #state.regions >= first then
		local value = MKV.crc(state, crc.finish, element.finish, first)
		if not value then
			return nil, "truncated Matroska element"
		end
		MKV.add(state, crc.payload, crc.finish, "bytes", u32_le_bytes(value))
	end
	return true
end

-- Xiph and FLAC codec data carry comments of their own. The stripped codec
-- data, nil when there is nothing to strip, or nil and an error.
function MKV.strip_comments(codec, data)
	if codec == "A_FLAC" then
		local prefix = data:sub(1, 4) == "fLaC" and "fLaC" or ""
		local offset, blocks, dropped = #prefix + 1, {}, false
		while offset <= #data do
			local length = be_u32_at("\0" .. data:sub(offset + 1, offset + 3), 1)
			local kind = data:byte(offset) & 0x7F
			if not length or offset + 3 + length > #data then
				return nil, "truncated FLAC codec data"
			elseif kind == 0 or kind == 3 or kind == 5 then
				-- Stream information, seek table, cue sheet.
				blocks[#blocks + 1] = data:sub(offset, offset + 3 + length)
			elseif kind == 1 or kind == 2 or kind == 4 or kind == 6 then
				-- Padding, application data, comments, pictures.
				dropped = true
			else
				return nil, "unknown FLAC metadata block"
			end
			offset = offset + 4 + length
		end
		if #blocks == 0 or blocks[1]:byte(1) & 0x7F ~= 0 then
			return nil, "FLAC codec data without stream information"
		elseif not dropped then
			return nil
		end
		for index, block in ipairs(blocks) do
			blocks[index] = string.char(block:byte(1) & 0x7F | (index == #blocks and 0x80 or 0)) .. block:sub(2)
		end
		return prefix .. table.concat(blocks)
	end
	-- Xiph lacing: packet count - 1, the sizes of the first two packets, then
	-- identification, comment and setup headers.
	local offset, sizes = 2, {}
	for index = 1, 2 do
		local size, byte = 0, 255
		while byte == 255 do
			byte = data:byte(offset)
			if not byte then
				return nil, "truncated Xiph codec data"
			end
			size, offset = size + byte, offset + 1
		end
		sizes[index] = size
	end
	local identification = data:sub(offset, offset + sizes[1] - 1)
	local comment = data:sub(offset + sizes[1], offset + sizes[1] + sizes[2] - 1)
	local setup = data:sub(offset + sizes[1] + sizes[2])
	local magic = codec == "A_VORBIS" and "\3vorbis" or "\129theora"
	local vendor = le_u32(comment:sub(8, 11))
	local count = vendor and le_u32(comment:sub(12 + vendor, 15 + vendor))
	if data:byte(1) ~= 2 or #comment ~= sizes[2] or #setup == 0 or comment:sub(1, 7) ~= magic or not count then
		return nil, "unsupported Xiph codec data"
	elseif count == 0 then
		return nil
	end
	-- The vendor names the encoder library; a Vorbis comment header ends with
	-- a framing bit.
	local stripped = comment:sub(1, 11 + vendor) .. "\0\0\0\0" .. (codec == "A_VORBIS" and "\1" or "")
	local function lace(size)
		return string.rep("\255", size // 255) .. string.char(size % 255)
	end
	return "\2" .. lace(#identification) .. lace(#stripped) .. identification .. stripped .. setup
end

MKV.COMMENTED_CODECS = as_set({ "A_FLAC", "A_VORBIS", "V_THEORA" })
MKV.ASS_CODECS = as_set({ "S_TEXT/ASS", "S_TEXT/SSA", "S_ASS", "S_SSA" })
MKV.ASS_RENDERING = as_set({
	"scripttype",
	"playresx",
	"playresy",
	"playdepth",
	"layoutresx",
	"layoutresy",
	"wrapstyle",
	"scaledborderandshadow",
	"collisions",
	"timer",
	"kerning",
	"ycbcr matrix",
})

-- An ASS or SSA header with titles, authors, comments and editor data (file
-- paths) blanked with spaces, so its length stays; nil when nothing changes.
-- Rendering keys, styles and other sections stay.
function MKV.clean_ass(data)
	local lines, section, changed = {}, nil, false
	for line, ending in data:gmatch("([^\r\n]*)([\r\n]*)") do
		local header = line:match("^%s*%[(.-)%]%s*$")
		local keep = line
		if header then
			section = header:lower()
		elseif section == "script info" and line:match("%S") then
			local key = line:match("^%s*([^:;]-)%s*:")
			if not key or not MKV.ASS_RENDERING[key:lower()] then
				local prefix = key and line:match("^(%s*[^:]*:)") or line:match("^(%s*;?)")
				keep = prefix .. string.rep(" ", #line - #prefix)
			end
		elseif section and section:match("^aegisub") then
			keep = string.rep(" ", #line)
		end
		changed = changed or keep ~= line
		lines[#lines + 1] = keep .. ending
	end
	local result = table.concat(lines)
	return changed and #result == #data and result or nil
end

-- A track entry. Codec data with comments is rewritten without them.
function MKV.track(state, element, depth)
	local codec
	local ok, err = MKV.children(state, element.payload, element.finish, function(child)
		if child.id == 0x86 then
			codec = MKV.value(state, child, 256)
		end
		return true
	end)
	if not ok then
		return nil, err
	elseif codec and codec:match("^D_") then
		return nil, "unsupported Matroska data track"
	end
	local rules = setmetatable({
		[0x63A2] = function(_, child)
			if MKV.ASS_CODECS[codec] then
				local data, data_err = MKV.value(state, child, LIMIT.EBML_VALUE * 16)
				local cleaned = data and MKV.clean_ass(data)
				if cleaned then
					state.metadata[#state.metadata + 1] = "subtitle header"
					MKV.add(state, child.payload, child.finish, "bytes", cleaned)
				end
				return data ~= nil, data_err
			elseif not MKV.COMMENTED_CODECS[codec] then
				return true
			end
			local data, data_err = MKV.value(state, child)
			if not data then
				return nil, data_err
			end
			local stripped, strip_err = MKV.strip_comments(codec, data)
			if strip_err then
				return nil, "unsupported Matroska " .. strip_err
			elseif not stripped then
				return true
			end
			state.metadata[#state.metadata + 1] = "codec comments"
			return MKV.replace(state, child, stripped)
		end,
	}, { __index = MKV.TRACK })
	return MKV.master(state, element, rules, depth + 1)
end

function MKV.media_type(state, attached)
	local media_type
	local ok, err = MKV.children(state, attached.payload, attached.finish, function(child)
		if child.id == 0x4660 then
			media_type = MKV.value(state, child, 256)
		end
		return true
	end)
	if not ok then
		return nil, err
	end
	return media_type or ""
end

-- Fonts stay for subtitle rendering; cover art and other attachments go.
function MKV.attachments(state, element, depth)
	local fonts = {}
	local ok, err = MKV.children(state, element.payload, element.finish, function(child)
		if child.id == 0x61A7 then
			local media_type, type_err = MKV.media_type(state, child)
			if not media_type then
				return nil, type_err
			end
			fonts[child.start] = MKV.is_font(media_type)
		end
		return true
	end)
	if not ok then
		return nil, err
	end
	local any_font = false
	for _, font in pairs(fonts) do
		any_font = any_font or font
	end
	if not any_font then
		state.metadata[#state.metadata + 1] = "attachments"
		state.dropped[MKV.ATTACHMENTS_ID] = true
		MKV.void(state, element)
		return true
	end
	return MKV.master(state, element, {
		[0x61A7] = function(_, child)
			if fonts[child.start] then
				return MKV.master(state, child, MKV.ATTACHED_FILE, depth + 2)
			end
			state.metadata[#state.metadata + 1] = "attachment"
			MKV.void(state, child)
			return true
		end,
	}, depth + 1)
end

-- A seek entry pointing at removed elements goes with them.
function MKV.seek(state, element, depth)
	local target
	local ok, err = MKV.children(state, element.payload, element.finish, function(child)
		if child.id == 0x53AB then
			target = MKV.value(state, child, 4)
		end
		return true
	end)
	if not ok then
		return nil, err
	end
	if target and state.dropped[target] then
		state.metadata[#state.metadata + 1] = "seek entry"
		MKV.void(state, element)
		return true
	end
	return MKV.master(state, element, { [0x53AB] = true, [0x53AC] = true }, depth + 1)
end

MKV.LEVEL1 = {
	[0x1549A966] = MKV.INFO,
	[0x1654AE6B] = { [0xAE] = MKV.track },
	[0x1C53BB6B] = true,
	[MKV.CLUSTER] = true,
	[0x1254C367] = "void tags",
	[MKV.ATTACHMENTS] = MKV.attachments,
	[0x1043A770] = MKV.CHAPTERS,
	[MKV.SEEK_HEAD] = { [0x4DBB] = MKV.seek },
}

-- Where an unknown-size cluster ends: at the next level-1 element.
function MKV.cluster_end(state, cluster, finish)
	local offset = cluster.payload
	while offset < finish do
		local child, err = MKV.header(state, offset, finish)
		if not child then
			return nil, err
		end
		if MKV.LEVEL1[child.id] or child.id == MKV.EBML then
			return offset
		end
		if not MKV.CLUSTER_CHILDREN[child.id] or not child.finish then
			return nil, string.format("unsupported Matroska cluster element 0x%X", child.id)
		end
		offset = child.finish
	end
	return finish
end

function MKV.parse(path)
	local file, open_err = io.open(path, "rb")
	if not file then
		return nil, tostring(open_err or "could not open Matroska file")
	end
	local size = file:seek("end")
	local state = { file = file, regions = {}, metadata = {}, dropped = { [MKV.TAGS_ID] = true }, count = 0 }
	local function run()
		local header, err = MKV.header(state, 0, size)
		if not header or header.id ~= MKV.EBML or not header.finish then
			return nil, err or "not a Matroska file"
		end
		local rules = setmetatable({
			[0x4282] = function(_, child)
				state.doc_type = MKV.value(state, child, 64)
				return true
			end,
		}, { __index = MKV.HEADER })
		local ok
		ok, err = MKV.master(state, header, rules, 0)
		if not ok then
			return nil, err
		end
		if state.doc_type ~= "matroska" and state.doc_type ~= "webm" then
			return nil, "unsupported EBML document type"
		end
		local segment
		segment, err = MKV.header(state, header.finish, size)
		if not segment or segment.id ~= MKV.SEGMENT then
			return nil, err or "missing Matroska segment"
		end
		if segment.finish and segment.finish ~= size then
			return nil, "data after the Matroska segment"
		end
		local finish, offset, seek_heads = segment.finish or size, segment.payload, {}
		while offset < finish do
			local element
			element, err = MKV.header(state, offset, finish)
			if not element then
				return nil, err
			end
			if not element.finish then
				if element.id ~= MKV.CLUSTER then
					return nil, string.format("unsupported unknown-size Matroska element 0x%X", element.id)
				end
				element.finish, err = MKV.cluster_end(state, element, finish)
				if not element.finish then
					return nil, err
				end
			end
			-- Seek heads are planned last, once every removed target is known.
			if element.id == MKV.SEEK_HEAD then
				seek_heads[#seek_heads + 1] = element
			else
				ok, err = MKV.child(state, element, MKV.LEVEL1, 1)
				if not ok then
					return nil, err
				end
			end
			offset = element.finish
		end
		for _, element in ipairs(seek_heads) do
			ok, err = MKV.child(state, element, MKV.LEVEL1, 1)
			if not ok then
				return nil, err
			end
		end
		table.sort(state.regions, function(a, b)
			return a.start < b.start
		end)
		for index = 2, #state.regions do
			if state.regions[index].start < state.regions[index - 1].finish then
				return nil, "Matroska regions overlap"
			end
		end
		return true
	end
	local ok, err = run()
	file:close()
	state.file = nil
	if not ok then
		return nil, err
	end
	return state
end

-- FFprobe reports image attachments as attached pictures and others as
-- attachment streams. The comparison leaves them, stream indexes, durations
-- and frame counts (which come from the removed statistics tags) and the
-- stream count out; only fonts may remain. Streams whose codec data can lose
-- its comments are compared by their decoded frames instead.
MKV.DECODED = as_set({ "vorbis", "theora", "flac" })

function MKV.layout(manifest)
	local lines, removable, skipping, decoded = {}, 0, false, {}
	for entry in manifest:gmatch("[^\n]+") do
		local line = entry
		local section = line:match("^([%w_]+)|") or line
		if QUICKTIME_TOP_SECTIONS[section] then
			skipping = section == "stream"
					and (line:find("|disposition:attached_pic=1", 1, true) or line:find(
						"|codec_type=attachment|",
						1,
						true
					))
					and true
				or false
			local font = not line:find("|disposition:attached_pic=1", 1, true)
				and MKV.is_font(line:match("|tag:mimetype=([^|]*)") or "")
			if skipping and not font then
				removable = removable + 1
			end
		end
		if not skipping then
			local codec = section == "stream" and line:match("|codec_name=([^|]*)") or ""
			if MKV.DECODED[codec] then
				decoded[#decoded + 1] = line:match("|index=(%d+)")
			end
			-- Subtitle headers keep their length and are verified byte by byte.
			if MKV.DECODED[codec] or codec == "ass" or codec == "ssa" then
				line = line:gsub("|extradata_size=%d+", ""):gsub("|extradata_hash=[^|]*", "")
			end
			-- Demuxer tags are lowercase; uppercase ones come from Tags.
			line = line:gsub("|tag:[^|=]*=[^|]*", function(tag)
				local kept = section == "stream" and (tag:match("^|tag:language=") or tag:match("^|tag:mimetype="))
				return kept and tag or ""
			end)
			if section == "stream" then
				line = line:gsub("|index=%d+", "")
					:gsub("|duration_ts=[^|]*", "")
					:gsub("|duration=[^|]*", "")
					:gsub("|nb_frames=[^|]*", "")
			elseif section == "format" then
				line = line:gsub("|nb_streams=%d+", "")
			end
			lines[#lines + 1] = line
		end
	end
	return table.concat(lines, "\n"), removable, decoded
end

-- Policies that clean in place. parse(path) plans the byte regions and lists
-- the metadata it found; layout(state, static) records FFprobe's stream
-- layout and returns a reason when the file cannot be compared. The regions
-- are written to the staged copy and verified against the source.
local function region_policy(policy)
	local parse, layout = policy.parse, policy.layout
	local prefix, dirty = policy.label and policy.label .. " " or "", policy.dirty
	policy.parse, policy.layout, policy.label, policy.dirty = nil, nil, nil, nil
	policy.preflight = function(path)
		local state, err = parse(path)
		if not state then
			return nil, err
		end
		local static, static_err = quicktime_static_manifest(path)
		if not static then
			return nil, static_err
		end
		err = layout(state, static)
		if err then
			return nil, err
		end
		return state
	end
	policy.structure_clean = function(state, path)
		if #state.metadata > 0 then
			return false, prefix .. state.metadata[1]
		end
		local neutral, err = regions_hold(path, state.regions)
		if neutral == nil then
			return nil, err
		end
		return neutral, dirty or "planned regions are not neutral"
	end
	policy.transform = function(ctx)
		return write_regions(ctx.staged, ctx.state.regions)
	end
	policy.verify = function(source, staged, state)
		return verify_regions(source, staged, state.regions)
	end
	return policy
end

MKV.POLICY = region_policy({
	spec = MKV.SPEC,
	parse = MKV.parse,
	label = "Matroska",
	dirty = "Matroska free space is not neutral",
	-- Blocks are never changed, so codecs FFmpeg does not know are kept;
	-- timed-metadata tracks are not.
	layout = function(state, static)
		local layout, removable, decoded = MKV.layout(static)
		if layout:find("|codec_type=data|", 1, true) then
			return "unsupported Matroska data track"
		end
		state.static, state.removable, state.decoded = layout, removable, decoded
	end,
	capture = function(path, _, state)
		local static = { state.static }
		for _, index in ipairs(state.decoded) do
			local frames, err = decoded_hash(path, "0:" .. index)
			if not frames then
				return nil, err
			end
			static[#static + 1] = frames
		end
		return { static = table.concat(static, "\n"), removable = state.removable }
	end,
	equivalent = function(before, after)
		if after.removable > 0 then
			return nil, "Matroska attachment remains"
		end
		return before.static == after.static or nil, "Matroska stream layout changed"
	end,
})

-- MP3, FLAC, WAV and AIFF ------------------------------------------------------------

-- Audio files are rewritten as a list of pieces: byte ranges of the source and
-- a few rebuilt headers. Tags before and after the audio (ID3, APE, Lyrics3),
-- metadata blocks and chunks are left out. No audio byte changes, and
-- verification compares the output with the pieces.
local AUDIO = {
	-- Vorbis comments that change playback (channel layout, loudness).
	FLAC_COMMENTS = as_set({
		"WAVEFORMATEXTENSIBLE_CHANNEL_MASK",
		"REPLAYGAIN_TRACK_GAIN",
		"REPLAYGAIN_TRACK_PEAK",
		"REPLAYGAIN_ALBUM_GAIN",
		"REPLAYGAIN_ALBUM_PEAK",
		"REPLAYGAIN_REFERENCE_LOUDNESS",
		"R128_TRACK_GAIN",
		"R128_ALBUM_GAIN",
	}),
	-- Format, audio, sample counts, channel layout, cue and loop points, tempo.
	WAV_CHUNKS = as_set({ "fmt ", "fact", "data", "cue ", "smpl", "inst", "acid" }),
	AIFF_CHUNKS = as_set({ "COMM", "SSND", "FVER", "CHAN", "MARK", "INST" }),
	FLAC_BLOCKS = { [1] = "FLAC padding", [2] = "FLAC application data", [6] = "FLAC picture" },
}

function AUDIO.read(file, offset, length)
	file:seek("set", offset)
	local data = file:read(length)
	return data and #data == length and data or nil
end

function AUDIO.write(source, staged, pieces)
	local input, input_err = io.open(source, "rb")
	if not input then
		return nil, tostring(input_err or "could not open source")
	end
	local output, output_err = io.open(staged, "wb")
	if not output then
		input:close()
		return nil, tostring(output_err or "could not open staged file")
	end
	local ok = true
	for _, piece in ipairs(pieces) do
		if piece.bytes then
			ok = output:write(piece.bytes) ~= nil
		else
			input:seek("set", piece.start)
			local remaining = piece.finish - piece.start
			while ok and remaining > 0 do
				local chunk = input:read(math.min(remaining, STREAM_BLOCK))
				ok = chunk ~= nil and #chunk > 0 and output:write(chunk) ~= nil
				remaining = remaining - (chunk and #chunk or 0)
			end
		end
		if not ok then
			break
		end
	end
	input:close()
	local closed = output:close()
	return ok and closed and true or nil, "could not write staged file"
end

-- Whether staged holds exactly the planned pieces.
function AUDIO.verify(source, staged, pieces)
	local a, b = io.open(source, "rb"), io.open(staged, "rb")
	if not a or not b then
		if a then
			a:close()
		end
		if b then
			b:close()
		end
		return nil, "could not open files for byte comparison"
	end
	local total = 0
	for _, piece in ipairs(pieces) do
		total = total + (piece.bytes and #piece.bytes or piece.finish - piece.start)
	end
	local ok = b:seek("end") == total
	b:seek("set", 0)
	for _, piece in ipairs(pieces) do
		if not ok then
			break
		elseif piece.bytes then
			ok = b:read(#piece.bytes) == piece.bytes
		else
			a:seek("set", piece.start)
			local remaining = piece.finish - piece.start
			while ok and remaining > 0 do
				local length = math.min(remaining, STREAM_BLOCK)
				ok = a:read(length) == b:read(length)
				remaining = remaining - length
			end
		end
	end
	a:close()
	b:close()
	return ok or nil, "audio bytes differ from the plan"
end

-- The end of leading ID3v2 tags.
function AUDIO.id3v2_end(file, offset, size)
	while true do
		local header = AUDIO.read(file, offset, 10)
		if not header or header:sub(1, 3) ~= "ID3" then
			return offset
		end
		local version, flags = header:byte(4), header:byte(6)
		local a, b, c, d = header:byte(7, 10)
		if version < 2 or version > 4 or (a | b | c | d) >= 0x80 then
			return nil, "invalid ID3v2 tag"
		end
		local length = 10 + ((a * 128 + b) * 128 + c) * 128 + d + (flags & 0x10 ~= 0 and 10 or 0)
		if offset + length > size then
			return nil, "truncated ID3v2 tag"
		end
		offset = offset + length
	end
end

-- The end of the audio before trailing ID3v1, Lyrics3v2 and APEv2 tags.
function AUDIO.trailing_end(file, start, finish, metadata)
	while finish - start >= 32 do
		local tag = finish - start >= 128 and AUDIO.read(file, finish - 128, 128)
		local footer = AUDIO.read(file, finish - 32, 32)
		local lyrics = AUDIO.read(file, finish - 15, 15)
		if tag and tag:sub(1, 3) == "TAG" then
			finish = finish - 128
			if finish - start >= 227 and AUDIO.read(file, finish - 227, 4) == "TAG+" then
				finish = finish - 227
			end
			metadata[#metadata + 1] = "ID3v1 tag"
		elseif footer:sub(1, 8) == "APETAGEX" then
			local length, flags = le_u32(footer:sub(13, 16)), le_u32(footer:sub(21, 24))
			local total = length + (flags & 0x80000000 ~= 0 and 32 or 0)
			if length < 32 or total > finish - start then
				return nil, "invalid APE tag"
			end
			finish = finish - total
			metadata[#metadata + 1] = "APE tag"
		elseif lyrics:sub(7) == "LYRICS200" and lyrics:sub(1, 6):match("^%d+$") then
			local total = tonumber(lyrics:sub(1, 6)) + 15
			if total > finish - start or AUDIO.read(file, finish - total, 11) ~= "LYRICSBEGIN" then
				return nil, "invalid Lyrics3 tag"
			end
			finish = finish - total
			metadata[#metadata + 1] = "Lyrics3 tag"
		elseif footer:sub(23, 25) == "3DI" then
			-- An appended ID3v2.4 tag ends in a footer that repeats its header.
			local a, b, c, d = footer:byte(29, 32)
			local total = 20 + ((a * 128 + b) * 128 + c) * 128 + d
			local header = (a | b | c | d) < 0x80 and total <= finish - start and AUDIO.read(file, finish - total, 10)
			if not header or header:sub(1, 6) ~= "ID3" .. footer:sub(26, 28) or header:sub(7) ~= footer:sub(29) then
				return nil, "invalid ID3v2 tag after the audio"
			end
			finish = finish - total
			metadata[#metadata + 1] = "ID3v2 tag"
		else
			break
		end
	end
	return finish
end

function AUDIO.open(path, parse)
	local file, err = io.open(path, "rb")
	if not file then
		return nil, tostring(err or "could not open audio file")
	end
	local size = file:seek("end")
	local state = { metadata = {}, pieces = {} }
	local ok
	ok, err = parse(file, size, state)
	file:close()
	if not ok then
		return nil, err
	end
	return state
end

function AUDIO.mp3(file, size, state)
	local start, err = AUDIO.id3v2_end(file, 0, size)
	if not start then
		return nil, err
	end
	if start > 0 then
		state.metadata[#state.metadata + 1] = "ID3v2 tag"
		-- Some taggers leave NUL padding after the tag's declared size.
		local padding = (AUDIO.read(file, start, math.min(65536, size - start)) or ""):match("^%z*")
		start = start + #padding
	end
	local finish
	finish, err = AUDIO.trailing_end(file, start, size, state.metadata)
	if not finish then
		return nil, err
	end
	local sync = AUDIO.read(file, start, 2)
	if not sync or sync:byte(1) ~= 0xFF or sync:byte(2) & 0xE0 ~= 0xE0 then
		return nil, "no MPEG audio frame after the tags"
	end
	-- ADTS (AAC) frames share the sync word with layer bits of zero.
	state.adts = sync:byte(2) & 0xF6 == 0xF0
	state.pieces = { { start = start, finish = finish } }
	return true
end

-- A Vorbis comment block keeps only playback comments and no vendor; nil when
-- nothing is left.
function AUDIO.flac_comments(body, state)
	local vendor = le_u32(body:sub(1, 4))
	local count = vendor and le_u32(body:sub(5 + vendor, 8 + vendor))
	if not count then
		return nil, "truncated FLAC comments"
	end
	local offset, kept = 9 + vendor, {}
	for _ = 1, count do
		local length = le_u32(body:sub(offset, offset + 3))
		if not length or offset + 3 + length > #body then
			return nil, "truncated FLAC comments"
		end
		local comment = body:sub(offset + 4, offset + 3 + length)
		if AUDIO.FLAC_COMMENTS[(comment:match("^([^=]*)=") or ""):upper()] then
			kept[#kept + 1] = u32_le_bytes(#comment) .. comment
		end
		offset = offset + 4 + length
	end
	local cleaned = u32_le_bytes(0) .. u32_le_bytes(#kept) .. table.concat(kept)
	if cleaned ~= body then
		state.metadata[#state.metadata + 1] = "FLAC comments"
	end
	return #kept > 0 and cleaned or false
end

function AUDIO.flac(file, size, state)
	local start, err = AUDIO.id3v2_end(file, 0, size)
	if not start then
		return nil, err
	elseif start > 0 then
		state.metadata[#state.metadata + 1] = "ID3v2 tag"
	end
	if AUDIO.read(file, start, 4) ~= "fLaC" then
		return nil, "missing FLAC signature"
	end
	local offset, blocks, last = start + 4, {}, false
	while not last do
		local header = AUDIO.read(file, offset, 4)
		if not header or #blocks >= 1024 then
			return nil, "truncated FLAC metadata"
		end
		local length = be_u32_at("\0" .. header:sub(2, 4), 1)
		last = header:byte(1) & 0x80 ~= 0
		blocks[#blocks + 1] = { kind = header:byte(1) & 0x7F, start = offset + 4, finish = offset + 4 + length }
		offset = offset + 4 + length
		if offset > size then
			return nil, "truncated FLAC metadata"
		end
	end
	local finish
	finish, err = AUDIO.trailing_end(file, offset, size, state.metadata)
	if not finish then
		return nil, err
	end
	local sync = AUDIO.read(file, offset, 2)
	-- A stream of zero samples has no frames.
	local empty = offset == finish
		and blocks[1].finish - blocks[1].start == 34
		and AUDIO.read(file, blocks[1].start + 13, 1):byte() & 0x0F == 0
		and AUDIO.read(file, blocks[1].start + 14, 4) == "\0\0\0\0"
	if blocks[1].kind ~= 0 or not empty and (not sync or sync:byte(1) ~= 0xFF or sync:byte(2) & 0xFE ~= 0xF8) then
		return nil, "unsupported FLAC structure"
	end
	local kept = {}
	for index, block in ipairs(blocks) do
		if block.kind == 4 then
			local body = AUDIO.read(file, block.start, block.finish - block.start)
			local cleaned, comment_err = AUDIO.flac_comments(body or "", state)
			if cleaned == nil then
				return nil, comment_err
			elseif cleaned then
				kept[#kept + 1] = { kind = 4, bytes = cleaned }
			end
		elseif block.kind == 0 and index == 1 or block.kind == 3 or block.kind == 5 then
			-- Stream information, seek table and cue sheet (track positions).
			kept[#kept + 1] = block
		elseif block.kind < 127 and block.kind ~= 0 then
			state.metadata[#state.metadata + 1] = AUDIO.FLAC_BLOCKS[block.kind] or "FLAC metadata block"
		else
			return nil, "invalid FLAC metadata block"
		end
	end
	state.pieces = { { start = start, finish = start + 4 } }
	for index, block in ipairs(kept) do
		local length = block.bytes and #block.bytes or block.finish - block.start
		local header = string.char(block.kind | (index == #kept and 0x80 or 0)) .. u32_be_bytes(length):sub(2)
		state.pieces[#state.pieces + 1] = { bytes = header }
		state.pieces[#state.pieces + 1] = block.bytes and { bytes = block.bytes } or block
	end
	state.pieces[#state.pieces + 1] = { start = offset, finish = finish }
	return true
end

-- WAV (RIFF) and AIFF (FORM, big-endian) keep their format, audio and timing
-- chunks in their original order.
function AUDIO.chunks(file, size, state)
	local header = AUDIO.read(file, 0, 12) or ""
	local form, kind = header:sub(1, 4), header:sub(9, 12)
	local big = form == "FORM"
	local kept_chunks = big and AUDIO.AIFF_CHUNKS or AUDIO.WAV_CHUNKS
	local u32 = big and function(value)
		return be_u32_at(value, 1)
	end or le_u32
	if not (form == "RIFF" and kind == "WAVE" or big and (kind == "AIFF" or kind == "AIFC")) then
		return nil, "unsupported RIFF or AIFF form"
	end
	local finish = 8 + u32(header:sub(5, 8))
	if finish > size then
		return nil, "truncated " .. kind .. " file"
	elseif finish < size then
		state.metadata[#state.metadata + 1] = "data after the " .. form .. " chunk"
	end
	local offset, pieces, audio, format = 12, {}, false, false
	while offset < finish do
		local chunk = finish - offset >= 8 and AUDIO.read(file, offset, 8)
		if not chunk then
			return nil, "truncated " .. kind .. " chunk"
		end
		local id, length = chunk:sub(1, 4), u32(chunk:sub(5, 8))
		local stop = offset + 8 + length + length % 2
		if stop > finish then
			-- The pad byte of a final odd-sized chunk is often missing.
			if offset + 8 + length ~= finish then
				return nil, "truncated " .. kind .. " chunk " .. id
			end
			stop = finish
		end
		if kept_chunks[id] then
			pieces[#pieces + 1] = { start = offset, finish = stop }
			audio = audio or id == "data" or id == "SSND"
			format = format or id == "fmt " or id == "COMM"
		else
			state.metadata[#state.metadata + 1] = kind .. " chunk " .. id:gsub("[^%w ]", "?")
		end
		offset = stop
	end
	if not audio or not format then
		return nil, kind .. " file without format or audio chunk"
	end
	local total = 4
	for _, piece in ipairs(pieces) do
		total = total + piece.finish - piece.start
	end
	local size_field = big and u32_be_bytes(total) or u32_le_bytes(total)
	table.insert(pieces, 1, { bytes = form .. size_field .. kind })
	state.pieces = pieces
	return true
end

-- Tags become stream and format tags in FFprobe and cover art an attached
-- picture; durations are estimated from the file size for some MP3 files, and
-- the format's start time is rounded from a position-dependent value. An
-- MP3's ReplayGain can come from its removed ID3 tag.
function AUDIO.layout(manifest)
	local lines, pictures, skipping = {}, 0, false
	for entry in manifest:gmatch("[^\n]+") do
		local line = entry
		local section = line:match("^([%w_]+)|") or line
		if QUICKTIME_TOP_SECTIONS[section] then
			skipping = section == "stream" and line:find("|disposition:attached_pic=1", 1, true) ~= nil
			pictures = pictures + (skipping and 1 or 0)
		end
		if not skipping then
			line = line:gsub("|tag:[^|]*", "")
				:gsub("|duration_ts=[^|]*", "")
				:gsub("|duration=[^|]*", "")
				:gsub("|nb_frames=[^|]*", "")
				:gsub("|nb_streams=%d+", "")
				:gsub("|index=%d+", "")
				:gsub("|side_datum/replay_gain[^|]*", "")
			if section == "format" then
				line = line:gsub("|start_time=[^|]*", "")
			end
			lines[#lines + 1] = line
		end
	end
	return table.concat(lines, "\n"), pictures
end

-- MP3 demuxers read stray tag bytes as packets, so MP3 compares decoded
-- frames instead of packet counts.
function AUDIO.policy(parse, spec, decode)
	return {
		spec = spec,
		preflight = function(path)
			local state, err = AUDIO.open(path, parse)
			if not state then
				return nil, err
			end
			local static, static_err = quicktime_static_manifest(path)
			if not static then
				local detail = tostring(static_err):match("[^\r\n]*[^%s][^\r\n]*") or ""
				detail = detail:gsub("^%[[^%]]+%]%s*", ""):gsub("^/.-: ", "")
				return nil, "FFprobe could not read the audio: " .. detail
			end
			state.static, state.pictures = AUDIO.layout(static)
			if decode then
				state.static = state.static:gsub("|nb_read_packets=%d+", "")
			end
			if not state.static:find("|codec_type=audio|", 1, true) then
				return nil, "no audio stream"
			end
			return state
		end,
		structure_clean = function(state)
			if #state.metadata > 0 then
				return false, state.metadata[1]
			end
			return true
		end,
		capture = function(path, _, state)
			local frames, err = "", nil
			if decode then
				frames, err = decoded_hash(path, "0:a:0", true)
				if not frames then
					return nil, err
				end
			end
			return { static = state.static .. "\n" .. frames, pictures = state.pictures }
		end,
		equivalent = function(before, after)
			if after.pictures > 0 then
				return nil, "cover art remains"
			end
			return before.static == after.static or nil, "audio stream layout changed"
		end,
		transform = function(ctx)
			return AUDIO.write(ctx.source, ctx.staged, ctx.state.pieces)
		end,
		verify = function(source, staged, state)
			return AUDIO.verify(source, staged, state.pieces)
		end,
	}
end

-- Tag names in group; names that carry a group already stay as they are.
local function prefixed(group, list)
	local result = {}
	for _, tag in ipairs(list) do
		result[#result + 1] = tag:find(":", 1, true) and tag or group .. ":" .. tag
	end
	return result
end

-- MPEG frame headers and the Xing/LAME header are part of the audio. An
-- AAC (ADTS) file with an ID3 tag is an MP3 to ExifTool; without the tag it
-- reports AAC and reads the stream header, including the encoder name that
-- FFmpeg writes into the first frame.
AUDIO.AAC_TAGS = { "AAC:ProfileType", "AAC:SampleRate", "AAC:Channels" }
AUDIO.MP3 = AUDIO.policy(
	AUDIO.mp3,
	metadata_spec({
		keep = with_basics(table.move(AUDIO.AAC_TAGS, 1, #AUDIO.AAC_TAGS, 2, { "MPEG:*" })),
		defaults = AUDIO.AAC_TAGS,
		free = { "AAC:Encoder" },
	}),
	true
)
AUDIO.MP3.expected_inventory = function(inventory, state)
	if not state.adts or inventory.file_type == "AAC" then
		return inventory
	end
	local values = setmetatable({
		["File:FileType"] = { "AAC" },
		["File:FileTypeExtension"] = { "AAC" },
		["File:MIMEType"] = { "audio/aac" },
	}, { __index = inventory.values })
	return setmetatable({ file_type = "AAC", mime_type = "audio/aac", values = values }, { __index = inventory })
end
AUDIO.FLAC = AUDIO.policy(
	AUDIO.flac,
	metadata_spec({
		keep = with_basics(prefixed("FLAC", {
			"BlockSizeMin",
			"BlockSizeMax",
			"FrameSizeMin",
			"FrameSizeMax",
			"SampleRate",
			"Channels",
			"BitsPerSample",
			"TotalSamples",
			"MD5Signature",
			"SeekTable",
			"CueSheet",
		})),
		free = prefixed("Vorbis", {
			"ReplayGainTrackGain",
			"ReplayGainTrackPeak",
			"ReplayGainAlbumGain",
			"ReplayGainAlbumPeak",
		}),
		neutral = { ["Vorbis:Vendor"] = "" },
	})
)
-- Cue, sampler, instrument and tempo chunks hold only positions and values.
AUDIO.WAV = AUDIO.policy(
	AUDIO.chunks,
	metadata_spec({
		keep = with_basics(prefixed("RIFF", {
			"Encoding",
			"NumChannels",
			"SampleRate",
			"AvgBytesPerSec",
			"BitsPerSample",
			"NumberOfSamples",
		})),
		free = prefixed("RIFF", {
			"CuePoints",
			"Manufacturer",
			"Product",
			"SamplePeriod",
			"MIDIUnityNote",
			"MIDIPitchFraction",
			"SMPTEFormat",
			"SMPTEOffset",
			"NumSampleLoops",
			"SamplerDataLen",
			"SamplerData",
			"UnshiftedNote",
			"FineTune",
			"Gain",
			"LowNote",
			"HighNote",
			"LowVelocity",
			"HighVelocity",
			"AcidizerFlags",
			"RootNote",
			"Beats",
			"Meter",
			"Tempo",
		}),
	})
)
AUDIO.AIFF = AUDIO.policy(
	AUDIO.chunks,
	metadata_spec({
		keep = with_basics(prefixed("AIFF", {
			"NumChannels",
			"NumSampleFrames",
			"SampleSize",
			"SampleRate",
			"CompressionType",
			"CompressorName",
			"FormatVersionTime",
		})),
		free = { "AIFF:MarkerID" },
	})
)

-- DSF: a DSD chunk with the file size and a pointer to the ID3v2 tag at the
-- end, then the format and data chunks. The tag goes and the DSD chunk is
-- rewritten without it.
function AUDIO.dsf(file, size, state)
	local header = AUDIO.read(file, 0, 92)
	if not header or header:sub(1, 4) ~= "DSD " or header:sub(29, 32) ~= "fmt " or header:sub(81, 84) ~= "data" then
		return nil, "invalid DSF header"
	end
	local chunk, total, pointer = string.unpack("<i8i8i8", header, 5)
	local format, data = string.unpack("<i8", header, 33), string.unpack("<i8", header, 85)
	local finish = 80 + data
	if chunk ~= 28 or total ~= size or format ~= 52 or data < 12 or finish > size then
		return nil, "invalid DSF chunk sizes"
	end
	if pointer ~= 0 or finish < size then
		if pointer ~= finish or AUDIO.read(file, finish, 3) ~= "ID3" then
			return nil, "unexpected data after the DSF audio"
		end
		state.metadata[#state.metadata + 1] = "ID3v2 tag"
	end
	state.pieces = { { bytes = header:sub(1, 12) .. string.pack("<i8i8", finish, 0) }, { start = 28, finish = finish } }
	return true
end

-- WavPack sub-blocks a decoder may skip that hold no file metadata: the
-- configuration, MD5 checksums, sample rate, original file extension,
-- channel identities and block checksum.
AUDIO.WAVPACK_OPTIONAL = as_set({ 0x25, 0x26, 0x27, 0x28, 0x29, 0x2a, 0x2b, 0x2f })

-- The original WAV header WavPack stores to restore the file exactly. It
-- may hold only the format, fact, zeroed JUNK and data chunk headers.
-- A WAV header that a lossless format stores to restore the original file:
-- only format chunks and empty JUNK may come before the data chunk.
function AUDIO.stored_riff(data, format)
	if data:sub(1, 4) ~= "RIFF" or data:sub(9, 12) ~= "WAVE" then
		return nil, "unsupported " .. format .. " stored file header"
	end
	local offset = 13
	while offset + 7 <= #data do
		local id, length = data:sub(offset, offset + 3), string.unpack("<I4", data, offset + 4)
		if id == "data" then
			return offset + 8 == #data + 1 or nil, "invalid " .. format .. " stored WAV header"
		end
		local body = data:sub(offset + 8, offset + 7 + length)
		if not (id == "fmt " or id == "fact" or id == "JUNK" and not body:find("[^%z]")) then
			return nil, format .. " stored WAV header with a " .. id:gsub("[^%w ]", "?") .. " chunk"
		end
		offset = offset + 8 + length + length % 2
	end
	return nil, "invalid " .. format .. " stored WAV header"
end

-- WavPack: a chain of blocks, then APEv2 and ID3v1 tags, which go. Blocks
-- can also carry the original file's header and trailer with that file's
-- own metadata chunks; those files are refused.
function AUDIO.wavpack(file, size, state)
	local finish, err = AUDIO.trailing_end(file, 0, size, state.metadata)
	if not finish then
		return nil, err
	end
	local position = 0
	while position < finish do
		local header = AUDIO.read(file, position, 32)
		if not header or header:sub(1, 4) ~= "wvpk" then
			return nil, "invalid WavPack block"
		end
		local length = string.unpack("<I4", header, 5) + 8
		if length < 32 or length > LIMIT.BINARY_READ or position + length > finish then
			return nil, "invalid WavPack block size"
		end
		local body = AUDIO.read(file, position + 32, length - 32)
		local offset = 1
		while body and offset <= #body do
			local id = body:byte(offset)
			local large = id & 0x80 ~= 0
			local head = large and 4 or 2
			if offset + head - 1 > #body then
				return nil, "truncated WavPack sub-block"
			end
			local words = body:byte(offset + 1)
				| (large and body:byte(offset + 2) << 8 | body:byte(offset + 3) << 16 or 0)
			local start, kind = offset + head, id & 0x3f
			offset = start + words * 2
			if offset - 1 > #body then
				return nil, "truncated WavPack sub-block"
			end
			if kind == 0x21 then
				local ok, riff_err =
					AUDIO.stored_riff(body:sub(start, offset - 1 - (id & 0x40 ~= 0 and 1 or 0)), "WavPack")
				if not ok then
					return nil, riff_err
				end
			elseif kind >= 0x22 and kind <= 0x24 then
				return nil, "WavPack file that stores the original file's own header or trailer"
			elseif kind >= 0x20 and not AUDIO.WAVPACK_OPTIONAL[kind] then
				return nil, string.format("unsupported WavPack sub-block 0x%02x", kind)
			end
		end
		position = position + length
	end
	if finish == 0 then
		return nil, "WavPack file without audio"
	end
	state.pieces = { { start = 0, finish = finish } }
	return true
end

-- Monkey's Audio and Musepack SV7: the header and frames, then APEv2 and
-- ID3v1 tags, which go. A leading ID3v2 tag would move the seek offsets, so
-- those files are refused.
function AUDIO.trailing_tags(file, size, state, magic, format)
	if AUDIO.read(file, 0, 3) == "ID3" then
		return nil, "ID3v2 tag before " .. format .. " audio is unsupported"
	elseif AUDIO.read(file, 0, #magic) ~= magic then
		return nil, "invalid " .. format .. " header"
	end
	local finish, err = AUDIO.trailing_end(file, 0, size, state.metadata)
	if not finish then
		return nil, err
	end
	state.pieces = { { start = 0, finish = finish } }
	return finish
end

-- Monkey's Audio can store the original WAV file's header and trailing
-- chunks; a header with metadata chunks or any trailing data is refused.
function AUDIO.ape(file, size, state)
	local finish, err = AUDIO.trailing_tags(file, size, state, "MAC ", "Monkey's Audio")
	if not finish then
		return nil, err
	end
	local header = AUDIO.read(file, 0, 52)
	if not header then
		return nil, "truncated Monkey's Audio header"
	end
	local version, at, length, terminating = string.unpack("<I2", header, 5), nil, nil, nil
	if version >= 3980 then
		local descriptor, fields, seek, stored = string.unpack("<I4I4I4I4", header, 9)
		at, length, terminating = descriptor + fields + seek, stored, string.unpack("<I4", header, 33)
	else
		local flags = string.unpack("<I2", header, 9)
		length, terminating = string.unpack("<I4I4", header, 17)
		-- A peak level and a seek element count may follow the 32 bytes; the
		-- WAV header is stored unless the decoder is to create one.
		at = 32 + (flags & 4 ~= 0 and 4 or 0) + (flags & 16 ~= 0 and 4 or 0)
		length = flags & 32 == 0 and length or 0
	end
	if terminating > 0 then
		return nil, "Monkey's Audio file that stores the original file's trailing data"
	elseif length > 0 then
		local stored = length <= LIMIT.RIFF_BYTES and at + length <= finish and AUDIO.read(file, at, length)
		if not stored then
			return nil, "invalid Monkey's Audio stored WAV header"
		end
		local ok, riff_err = AUDIO.stored_riff(stored, "Monkey's Audio")
		if not ok then
			return nil, riff_err
		end
	end
	return true
end

function AUDIO.mpc(file, size, state)
	local finish, err = AUDIO.trailing_tags(file, size, state, "MP+", "Musepack")
	if not finish then
		return nil, err
	end
	local version = (AUDIO.read(file, 3, 1) or ""):byte()
	if not version or version & 15 ~= 7 then
		return nil, "unsupported Musepack stream version"
	end
	return true
end

AUDIO.DSF = AUDIO.policy(
	AUDIO.dsf,
	metadata_spec({
		keep = with_basics(prefixed("File", {
			"FormatVersion",
			"FormatID",
			"ChannelType",
			"ChannelCount",
			"SampleRate",
			"BitsPerSample",
			"SampleCount",
			"BlockSize",
		})),
	})
)
AUDIO.APE = AUDIO.policy(
	AUDIO.ape,
	metadata_spec({
		keep = with_basics(prefixed("MAC", {
			"APEVersion",
			"CompressionLevel",
			"BlocksPerFrame",
			"FinalFrameBlocks",
			"TotalFrames",
			"BitsPerSample",
			"Channels",
			"SampleRate",
		})),
	}),
	true
)
-- The SV7 stream header holds the encoder version and ReplayGain values.
AUDIO.MPC = AUDIO.policy(
	AUDIO.mpc,
	metadata_spec({
		keep = with_basics(prefixed("MPC", {
			"TotalFrames",
			"SampleRate",
			"Quality",
			"MaxBand",
			"ReplayGainTrackPeak",
			"ReplayGainTrackGain",
			"ReplayGainAlbumPeak",
			"ReplayGainAlbumGain",
			"FastSeek",
			"Gapless",
			"EncoderVersion",
		})),
	}),
	true
)
-- ExifTool reads the stored WAV header as RIFF tags.
AUDIO.WV = AUDIO.policy(
	AUDIO.wavpack,
	metadata_spec({
		keep = with_basics({
			"File:BytesPerSample",
			"File:AudioType",
			"File:Compression",
			"File:DataFormat",
			"File:SampleRate",
			"RIFF:Encoding",
			"RIFF:NumChannels",
			"RIFF:SampleRate",
			"RIFF:AvgBytesPerSec",
			"RIFF:BitsPerSample",
			"RIFF:NumberOfSamples",
		}),
	})
)

-- Ogg Opus, Vorbis, FLAC and Theora ----------------------------------------------

-- The comment header is rewritten in place at the same length: an empty
-- vendor, only playback comments, then zeros, which Opus defines as
-- discardable padding and Vorbis readers ignore after the framing bit, as
-- Theora and Speex readers do after the last comment. Ogg
-- FLAC comment and picture blocks become padding blocks. Multiplexed streams
-- (Theora video with Vorbis or Opus audio, an Ogg Skeleton) are cleaned
-- stream by stream. Only the CRCs of the pages that carry them change; audio
-- and video pages stay byte-identical.
local OGG = { CRC = {}, COMMENTS = as_set({ "R128_TRACK_GAIN", "R128_ALBUM_GAIN" }) }
for name in pairs(AUDIO.FLAC_COMMENTS) do
	OGG.COMMENTS[name] = true
end
for index = 0, 255 do
	local value = index << 24
	for _ = 1, 8 do
		value = (value & 0x80000000 ~= 0) and ((value << 1) ~ 0x04C11DB7) or (value << 1)
	end
	OGG.CRC[index] = value & 0xFFFFFFFF
end

-- Ogg's CRC-32: polynomial 0x04C11DB7, not reflected, no initial or final XOR.
function OGG.crc(data)
	local crc = 0
	for index = 1, #data do
		crc = ((crc << 8) & 0xFFFFFFFF) ~ OGG.CRC[((crc >> 24) ~ data:byte(index)) & 0xFF]
	end
	return crc
end

-- A comment packet with only playback comments and an empty vendor, padded
-- with zeros to its old length; nil when it is clean already.
function OGG.comments(packet, magic, framing)
	local vendor = le_u32(packet:sub(#magic + 1, #magic + 4))
	local count = vendor and le_u32(packet:sub(#magic + 5 + vendor, #magic + 8 + vendor))
	if packet:sub(1, #magic) ~= magic or not count then
		return nil, "invalid Ogg comment header"
	end
	local offset, kept = #magic + 9 + vendor, {}
	for _ = 1, count do
		local length = le_u32(packet:sub(offset, offset + 3))
		if not length or offset + 3 + length > #packet then
			return nil, "truncated Ogg comment header"
		end
		local comment = packet:sub(offset + 4, offset + 3 + length)
		if OGG.COMMENTS[(comment:match("^([^=]*)=") or ""):upper()] then
			kept[#kept + 1] = u32_le_bytes(#comment) .. comment
		end
		offset = offset + 4 + length
	end
	local cleaned = magic .. u32_le_bytes(0) .. u32_le_bytes(#kept) .. table.concat(kept) .. framing
	cleaned = cleaned .. string.rep("\0", #packet - #cleaned)
	return cleaned ~= packet and cleaned or false
end

-- A Skeleton packet after the fishead: fisbones may only describe their
-- stream's content type and role and carry an encoder's numbered track name
-- (video_1); key-frame indexes and the closing empty packet carry no text.
-- Returns false, as nothing in them is rewritten.
function OGG.skeleton(packet)
	if packet == "" or packet:sub(1, 6) == "index\0" then
		return false
	elseif packet:sub(1, 8) ~= "fisbone\0" or #packet < 52 then
		return nil, "unsupported Ogg Skeleton packet"
	end
	local headers = packet:sub(9 + le_u32(packet:sub(9, 12))):gsub("%z+$", "")
	for line in (headers .. "\r\n"):gmatch("(.-)\r\n") do
		local name = line:match("^([%w%-]+):")
		local numbered = name == "Name" and line:match("^Name: %a+_%d+$")
		if line ~= "" and not (name == "Content-Type" or name == "Role" or numbered) then
			return nil, "Ogg Skeleton header " .. (name or "without a name")
		end
	end
	return false
end

function OGG.parse(path)
	local file, open_err = io.open(path, "rb")
	if not file then
		return nil, tostring(open_err or "could not open Ogg file")
	end
	local size = file:seek("end")
	local state = { regions = {}, metadata = {} }
	local function read(offset, length)
		file:seek("set", offset)
		local data = file:read(length)
		return data and #data == length and data or nil
	end
	local function run()
		-- Multiplexed streams start with all of their first pages; a first
		-- page after other pages starts a chained stream.
		local offset, streams, order, started = 0, {}, {}, false
		while offset < size do
			local header = read(offset, 27)
			if not header or header:sub(1, 4) ~= "OggS" or header:byte(5) ~= 0 then
				return nil, "invalid Ogg page"
			end
			local flags, page_serial, count = header:byte(6), le_u32(header:sub(15, 18)), header:byte(27)
			local lacing = read(offset + 27, count)
			if not lacing then
				return nil, "truncated Ogg page"
			end
			local body = offset + 27 + count
			local position, finish = body, body
			for index = 1, count do
				finish = finish + lacing:byte(index)
			end
			if finish > size then
				return nil, "truncated Ogg page"
			end
			local stream = streams[page_serial]
			if flags & 0x02 ~= 0 then
				if stream or started then
					return nil, "unsupported chained Ogg streams"
				elseif #order == LIMIT.OGG_STREAMS then
					return nil, "too many Ogg streams"
				end
				stream = { packets = {}, wanted = 1 }
				streams[page_serial], order[#order + 1] = stream, stream
			elseif not stream then
				return nil, #order == 0 and "Ogg stream without a first page" or "Ogg page of an unknown stream"
			else
				started = true
			end
			local page = { start = offset, finish = finish }
			local packets = stream.packets
			if #packets < stream.wanted then
				if (flags & 0x01 ~= 0) ~= (stream.current ~= nil) then
					return nil, "broken Ogg packet continuation"
				end
				for index = 1, count do
					local length = lacing:byte(index)
					local current = stream.current or { spans = {}, length = 0 }
					stream.current = current
					if length > 0 then
						current.spans[#current.spans + 1] =
							{ start = position, finish = position + length, page = page }
					end
					current.length, position = current.length + length, position + length
					if current.length > LIMIT.HEIF_META_BYTES then
						return nil, "Ogg header packet is too large"
					end
					if length < 255 then
						packets[#packets + 1], stream.current = current, nil
						if #packets == 1 then
							local first = read(body, math.min(current.length, 64)) or ""
							if first:sub(1, 8) == "OpusHead" then
								stream.codec, stream.wanted = "opus", 2
							elseif first:sub(1, 7) == "\1vorbis" then
								stream.codec, stream.wanted = "vorbis", 2
							elseif first:sub(1, 5) == "\127FLAC" and #first >= 9 then
								stream.codec, stream.wanted = "flac", 1 + be_u16(first, 8)
							elseif first:sub(1, 8) == "Speex   " then
								-- The header's extra_headers field counts the packets
								-- after the comments.
								local extra = le_u32(read(body + 68, 4) or "")
								if not extra or extra > LIMIT.OGG_STREAMS then
									return nil, "invalid Ogg Speex header"
								end
								stream.codec, stream.wanted = "speex", 2 + extra
							elseif first:sub(1, 7) == "\128theora" then
								stream.codec, stream.wanted = "theora", 3
							elseif first:sub(1, 8) == "fishead\0" then
								-- Skeleton headers end with an empty packet, after a
								-- fisbone and an index for each stream.
								stream.codec, stream.wanted = "skeleton", 2 * LIMIT.OGG_STREAMS + 2
							else
								return nil, "unsupported Ogg codec"
							end
						elseif stream.codec == "skeleton" and current.length == 0 then
							stream.wanted = #packets
						end
						if #packets >= stream.wanted then
							break
						end
					end
				end
			end
			offset = finish
		end
		for _, stream in ipairs(order) do
			if
				#stream.packets < stream.wanted
				or stream.codec == "flac" and stream.wanted == 1
				or stream.codec == "skeleton" and stream.packets[#stream.packets].length > 0
			then
				return nil, "incomplete Ogg headers"
			end
			state.audio = state.audio or stream.codec ~= "theora" and stream.codec ~= "skeleton"
			state.video = state.video or stream.codec == "theora"
		end
		local dirty = {}
		local function rewrite(packet, data)
			local used = 0
			for _, span in ipairs(packet.spans) do
				local length = span.finish - span.start
				state.regions[#state.regions + 1] = {
					start = span.start,
					finish = span.finish,
					kind = "bytes",
					bytes = data:sub(used + 1, used + length),
				}
				used = used + length
				dirty[span.page] = true
			end
		end
		local function packet_data(packet)
			local parts = {}
			for _, span in ipairs(packet.spans) do
				parts[#parts + 1] = read(span.start, span.finish - span.start)
			end
			return table.concat(parts)
		end
		local magic = { opus = "OpusTags", vorbis = "\3vorbis", theora = "\129theora", speex = "" }
		for _, stream in ipairs(order) do
			for index = 2, stream.wanted do
				local packet = stream.packets[index]
				local data = packet_data(packet)
				local cleaned, err = false, nil
				if stream.codec == "flac" then
					-- One FLAC metadata block per packet.
					local kind = #data >= 4 and data:byte(1) & 0x7F or 127
					if kind == 4 or kind == 6 or kind == 2 then
						cleaned = string.char(data:byte(1) & 0x80 | 1) .. data:sub(2, 4) .. string.rep("\0", #data - 4)
						cleaned = cleaned ~= data and cleaned
					elseif not (kind == 1 and not data:sub(5):find("[^%z]") or kind == 3 or kind == 5) then
						return nil, "unsupported Ogg FLAC metadata block"
					end
				elseif stream.codec == "skeleton" then
					cleaned, err = OGG.skeleton(data)
				elseif index == 2 then
					cleaned, err = OGG.comments(data, magic[stream.codec], stream.codec == "vorbis" and "\1" or "")
				end
				if cleaned == nil then
					return nil, err
				end
				if cleaned then
					state.metadata[#state.metadata + 1] = "Ogg comments or pictures"
					rewrite(packet, cleaned)
				end
			end
			if stream.codec == "skeleton" then
				-- The fishead's UTC field dates the recording.
				local data = packet_data(stream.packets[1])
				local major = #data >= 64 and string.unpack("<I2", data, 9)
				if not major or major < 3 then
					return nil, "unsupported Ogg Skeleton version"
				elseif data:sub(45, 64):find("[^%z]") then
					state.metadata[#state.metadata + 1] = "Ogg Skeleton date"
					rewrite(stream.packets[1], data:sub(1, 44) .. string.rep("\0", 20) .. data:sub(65))
				end
			end
		end
		-- Recompute the CRC of every page that changes.
		table.sort(state.regions, function(a, b)
			return a.start < b.start
		end)
		local crcs = {}
		for page in pairs(dirty) do
			local data = read(page.start, page.finish - page.start)
			local parts, position = {}, page.start
			for _, region in ipairs(state.regions) do
				if region.start >= page.start and region.finish <= page.finish then
					parts[#parts + 1] = data:sub(position - page.start + 1, region.start - page.start)
					parts[#parts + 1] = region.bytes
					position = region.finish
				end
			end
			parts[#parts + 1] = data:sub(position - page.start + 1)
			local planned = table.concat(parts)
			planned = planned:sub(1, 22) .. "\0\0\0\0" .. planned:sub(27)
			crcs[#crcs + 1] = {
				start = page.start + 22,
				finish = page.start + 26,
				kind = "bytes",
				bytes = u32_le_bytes(OGG.crc(planned)),
			}
		end
		for _, region in ipairs(crcs) do
			state.regions[#state.regions + 1] = region
		end
		table.sort(state.regions, function(a, b)
			return a.start < b.start
		end)
		return true
	end
	local ok, err = run()
	file:close()
	if not ok then
		return nil, err
	end
	return state
end

OGG.SPEC = metadata_spec({
	keep = with_basics({
		"Opus:OpusVersion",
		"Opus:AudioChannels",
		"Opus:SampleRate",
		"Opus:OutputGain",
		"Vorbis:VorbisVersion",
		"Vorbis:AudioChannels",
		"Vorbis:SampleRate",
		"Vorbis:MaximumBitrate",
		"Vorbis:NominalBitrate",
		"Vorbis:MinimumBitrate",
		"FLAC:BlockSizeMin",
		"FLAC:BlockSizeMax",
		"FLAC:FrameSizeMin",
		"FLAC:FrameSizeMax",
		"FLAC:SampleRate",
		"FLAC:Channels",
		"FLAC:BitsPerSample",
		"FLAC:TotalSamples",
		"FLAC:MD5Signature",
		"FLAC:SeekTable",
		"FLAC:CueSheet",
		"Theora:TheoraVersion",
		"Theora:ImageWidth",
		"Theora:ImageHeight",
		"Theora:XOffset",
		"Theora:YOffset",
		"Theora:FrameRate",
		"Theora:PixelAspectRatio",
		"Theora:ColorSpace",
		"Theora:NominalVideoBitrate",
		"Theora:Quality",
		"Theora:PixelFormat",
		"Composite:ImageSize",
		"Composite:Megapixels",
	}),
	free = {
		"Vorbis:R128TrackGain",
		"Vorbis:R128AlbumGain",
		"Vorbis:ReplayGainTrackGain",
		"Vorbis:ReplayGainTrackPeak",
		"Vorbis:ReplayGainAlbumGain",
		"Vorbis:ReplayGainAlbumPeak",
		"FLAC:Padding",
	},
	neutral = { ["Vorbis:Vendor"] = "", ["Theora:Vendor"] = "" },
})

-- Vorbis and Theora codec data hold the comment header, so streams are
-- compared by their decoded frames.
OGG.POLICY = region_policy({
	spec = OGG.SPEC,
	parse = OGG.parse,
	layout = function(state, static)
		state.static, state.pictures = AUDIO.layout(static)
		state.static = state.static:gsub("|extradata_size=%d+", ""):gsub("|extradata_hash=[^|]*", "")
		if not (state.audio or state.video) then
			return "no audio or video stream"
		end
	end,
	capture = function(path, _, state)
		local hashes = {}
		for _, map in ipairs({ state.audio and "0:a", state.video and "0:V" }) do
			if map then
				local frames, err = decoded_hash(path, map)
				if not frames then
					return nil, err
				end
				hashes[#hashes + 1] = frames
			end
		end
		return { static = state.static .. "\n" .. table.concat(hashes, "\n"), pictures = state.pictures }
	end,
	equivalent = function(before, after)
		if after.pictures > 0 then
			return nil, "cover art remains"
		end
		return before.static == after.static or nil, "audio stream layout changed"
	end,
})

-- AVI ----------------------------------------------------------------------------------

-- AVI is cleaned in place: metadata chunks (INFO lists, IDIT dates, stream
-- names, camera EXIF in strd, maker chunks) become JUNK chunks of the same
-- size with zeroed payloads and existing JUNK is zeroed. Sizes and offsets
-- stay, so the indexes stay valid and no frame byte moves.
local AVI = {
	-- What playback needs in the header list and in a stream list.
	HEADER = as_set({ "avih" }),
	STREAM = as_set({ "strh", "strf", "indx", "vprp" }),
}

function AVI.parse(path)
	local file, open_err = io.open(path, "rb")
	if not file then
		return nil, tostring(open_err or "could not open AVI file")
	end
	local size = file:seek("end")
	local state = { regions = {}, metadata = {} }
	local function read(offset, length)
		file:seek("set", offset)
		local data = file:read(length)
		return data and #data == length and data or nil
	end
	local function junk(chunk, name)
		if name then
			state.metadata[#state.metadata + 1] = name
			state.regions[#state.regions + 1] =
				{ start = chunk.start, finish = chunk.start + 4, kind = "bytes", bytes = "JUNK" }
		end
		if chunk.finish > chunk.payload then
			state.regions[#state.regions + 1] = { start = chunk.payload, finish = chunk.finish, kind = "zero" }
		end
	end
	-- Children of [start, finish); visit(chunk) plans each one and returns
	-- "stop" to end the walk early.
	local function children(start, finish, visit)
		local offset, count = start, 0
		while offset < finish do
			local header = finish - offset >= 8 and read(offset, 8)
			if not header then
				return nil, "truncated AVI chunk"
			end
			local length = le_u32(header:sub(5, 8))
			local chunk = { id = header:sub(1, 4), start = offset, payload = offset + 8, finish = offset + 8 + length }
			if chunk.finish > finish then
				return nil, "AVI chunk " .. chunk.id:gsub("[^%w ]", "?") .. " exceeds its parent"
			end
			if chunk.id == "LIST" or chunk.id == "RIFF" then
				chunk.kind = length >= 4 and read(offset + 8, 4) or nil
				if not chunk.kind then
					return nil, "truncated AVI list"
				end
			end
			count = count + 1
			if count > LIMIT.RIFF_CHUNKS then
				return nil, "AVI chunk count limit exceeded"
			end
			local ok, err = visit(chunk)
			if not ok then
				return nil, err
			elseif ok == "stop" then
				return true
			end
			-- Chunks are padded to an even length.
			offset = math.min(chunk.finish + length % 2, finish)
		end
		return true
	end
	local function stream_list(chunk)
		return children(chunk.payload + 4, chunk.finish, function(child)
			if AVI.STREAM[child.id] then
				return true
			elseif child.id == "JUNK" then
				junk(child)
			elseif child.id == "strn" then
				junk(child, "AVI stream name")
			elseif child.id == "strd" then
				-- Cameras store EXIF and maker data here; codec data is refused.
				local head = read(child.payload, math.min(child.finish - child.payload, 64)) or ""
				if not (head:find("Exif", 1, true) or head:find("^AVIF") or head:find("II*\0", 1, true)) then
					return nil, "unsupported AVI codec stream data"
				end
				junk(child, "AVI camera data")
			else
				junk(child, "AVI chunk " .. child.id:gsub("[^%w ]", "?"))
			end
			return true
		end)
	end
	local function header_list(chunk)
		return children(chunk.payload + 4, chunk.finish, function(child)
			if AVI.HEADER[child.id] or child.id == "LIST" and child.kind == "odml" then
				return true
			elseif child.id == "LIST" and child.kind == "strl" then
				return stream_list(child)
			elseif child.id == "JUNK" then
				junk(child)
			else
				junk(child, "AVI chunk " .. child.id:gsub("[^%w ]", "?"))
			end
			return true
		end)
	end
	-- EXIF in the first video frame would be identity data inside the media.
	local function first_frame(chunk)
		return children(chunk.payload + 4, chunk.finish, function(child)
			if child.id:match("^%d%ddc$") then
				local head = read(child.payload, math.min(child.finish - child.payload, 65536)) or ""
				if
					head:find("\255\225", 1, true)
					and (head:find("Exif\0", 1, true) or head:find("http://ns.adobe.com/xap", 1, true))
				then
					return nil, "unsupported AVI frames with embedded EXIF or XMP"
				end
				return "stop"
			end
			return true
		end)
	end
	local function run()
		local index = 0
		local ok, err = children(0, size, function(riff)
			index = index + 1
			local expected = index == 1 and "AVI " or "AVIX"
			if riff.id ~= "RIFF" or riff.kind ~= expected then
				return nil, index == 1 and "not an AVI file" or "data after the AVI chunks"
			end
			local movi = false
			return children(riff.payload + 4, riff.finish, function(chunk)
				if chunk.id == "LIST" and chunk.kind == "movi" then
					if movi then
						return nil, "AVI with more than one movie list"
					end
					movi = true
					return index > 1 or first_frame(chunk)
				elseif index == 1 and chunk.id == "LIST" and chunk.kind == "hdrl" then
					return header_list(chunk)
				elseif index == 1 and chunk.id == "idx1" then
					return true
				elseif chunk.id == "JUNK" then
					junk(chunk)
				elseif chunk.id == "LIST" and chunk.kind == "INFO" then
					junk(chunk, "AVI INFO list")
				else
					junk(chunk, "AVI chunk " .. chunk.id:gsub("[^%w ]", "?"))
				end
				return true
			end)
		end)
		if not ok then
			return nil, err
		end
		table.sort(state.regions, function(a, b)
			return a.start < b.start
		end)
		return true
	end
	local ok, err = run()
	file:close()
	if not ok then
		return nil, err
	end
	return state
end

AVI.POLICY = region_policy({
	-- ExifTool hashes the movie data and reports the stream format's bitmap
	-- header in the File group.
	spec = metadata_spec({
		keep = with_basics(prefixed("RIFF", {
			"FrameRate",
			"MaxDataRate",
			"FrameCount",
			"StreamCount",
			"ImageWidth",
			"ImageHeight",
			"StreamType",
			"VideoCodec",
			"VideoFrameRate",
			"VideoFrameCount",
			"Quality",
			"SampleSize",
			"AudioCodec",
			"AudioSampleRate",
			"AudioSampleCount",
			"Encoding",
			"NumChannels",
			"SampleRate",
			"AvgBytesPerSec",
			"BitsPerSample",
			"TotalFrameCount",
			"File:BMPVersion",
			"File:ImageWidth",
			"File:ImageHeight",
			"File:Planes",
			"File:BitDepth",
			"File:Compression",
			"File:ImageLength",
			"File:PixelsPerMeterX",
			"File:PixelsPerMeterY",
			"File:NumColors",
			"File:NumImportantColors",
		})),
		free = { "RIFF:Unknown_indx", "RIFF:Unknown_vprp", "RIFF:Unknown_JUNK" },
	}),
	parse = AVI.parse,
	dirty = "AVI free space is not neutral",
	layout = function(state, static)
		state.static, state.pictures = AUDIO.layout(static)
		if not state.static:find("|codec_type=video|", 1, true) then
			return "AVI file has no video stream"
		end
	end,
	-- FFmpeg passes strd as codec data, so removing camera data changes it;
	-- then the decoded video of both files is compared (the original is
	-- still in place).
	capture = function(path, _, state)
		local extradata = {}
		local static = state.static:gsub("|extradata_%a+=[^|]*", function(field)
			extradata[#extradata + 1] = field
			return ""
		end)
		return { static = static, extradata = table.concat(extradata, "\n"), path = path }
	end,
	equivalent = function(before, after)
		if before.static ~= after.static then
			return nil, "AVI stream layout changed"
		elseif before.extradata == after.extradata then
			return true
		end
		local frames, err = decoded_hash(before.path, "0:v:0")
		if not frames then
			return nil, err
		end
		local cleaned
		cleaned, err = decoded_hash(after.path, "0:v:0")
		if not cleaned then
			return nil, err
		end
		return frames == cleaned or nil, "AVI decoded video changed"
	end,
})

-- ASF (WMA, WMV) -------------------------------------------------------------------

-- In place: content description, extended content description, metadata,
-- metadata library, content branding and script command objects become
-- padding objects of the same size with zeroed contents, existing padding
-- is zeroed, and the file identifier (in the file properties, data and
-- simple index objects) and creation date are zeroed. Packets, indexes and
-- stream properties stay byte-identical.
local ASF = {}

-- GUID text to its on-disk form: the first three fields are little-endian.
function ASF.guid(text)
	local hex = text:gsub("-", "")
	local bytes = hex:gsub("%x%x", function(pair)
		return string.char(tonumber(pair, 16))
	end)
	return bytes:sub(1, 4):reverse() .. bytes:sub(5, 6):reverse() .. bytes:sub(7, 8):reverse() .. bytes:sub(9)
end

ASF.PADDING = ASF.guid("1806D474-CADF-4509-A4BA-9AABCB96AAE8")
ASF.HEADER = ASF.guid("75B22630-668E-11CF-A6D9-00AA0062CE6C")
ASF.FILE_PROPERTIES = ASF.guid("8CABDCA1-A947-11CF-8EE4-00C00C205365")
ASF.EXTENSION = ASF.guid("5FBF03B5-A92E-11CF-8EE3-00C00C205365")
ASF.EXTENDED_STREAM = ASF.guid("14E6A5CB-C672-4332-8399-A96952065B5A")
ASF.DATA = ASF.guid("75B22636-668E-11CF-A6D9-00AA0062CE6C")
ASF.SIMPLE_INDEX = ASF.guid("33000890-E5B1-11CF-89F4-00A0C90349CB")

-- What happens to each known object: kept, turned into padding, or zeroed
-- padding. Anything else, such as DRM or a digital signature, is refused.
ASF.HEADER_OBJECTS, ASF.EXTENSION_OBJECTS, ASF.TOP_OBJECTS = {}, {}, {}
for list, entries in pairs({
	[ASF.HEADER_OBJECTS] = {
		{ "8CABDCA1-A947-11CF-8EE4-00C00C205365", "keep" }, -- file properties
		{ "B7DC0791-A9B7-11CF-8EE6-00C00C205365", "keep" }, -- stream properties
		{ "5FBF03B5-A92E-11CF-8EE3-00C00C205365", "keep" }, -- header extension
		{ "86D15240-311D-11D0-A3A4-00A0C90348F6", "keep" }, -- codec list
		{ "7BF875CE-468D-11D1-8D82-006097C9A2B2", "keep" }, -- stream bitrates
		{ "D6E229DC-35DA-11D1-9034-00A0C90349BE", "keep" }, -- bitrate mutual exclusion
		{ "75B22635-668E-11CF-A6D9-00AA0062CE6C", "keep" }, -- error correction
		{ "F487CD01-A951-11CF-8EE6-00C00C205365", "keep" }, -- markers (chapters)
		{ "75B22633-668E-11CF-A6D9-00AA0062CE6C", "pad", "content description" },
		{ "D2D0A440-E307-11D2-97F0-00A0C95EA850", "pad", "extended content description" },
		{ "2211B3FA-BD23-11D2-B4B7-00A0C955FC6E", "pad", "content branding" },
		{ "1EFB1A30-0B62-11D0-A39B-00A0C90348F6", "pad", "script commands" },
		{ "1806D474-CADF-4509-A4BA-9AABCB96AAE8", "zero" },
	},
	[ASF.EXTENSION_OBJECTS] = {
		{ "14E6A5CB-C672-4332-8399-A96952065B5A", "keep" }, -- extended stream properties
		{ "7C4346A9-EFE0-4BFC-B229-393EDE415C85", "keep" }, -- language list
		{ "26F18B5D-4584-47EC-9F5F-0E651F0452C9", "keep" }, -- compatibility
		{ "A08649CF-4775-4670-8A16-6E35357566CD", "keep" }, -- advanced mutual exclusion
		{ "D1465A40-5A79-4338-B71B-E36B8FD6C249", "keep" }, -- group mutual exclusion
		{ "D4FED15B-88D3-454F-81F0-ED5C45999E24", "keep" }, -- stream prioritization
		{ "A69609E6-517B-11D2-B6AF-00C04FD908E9", "keep" }, -- bandwidth sharing
		{ "D6E229DF-35DA-11D1-9034-00A0C90349BE", "keep" }, -- index parameters
		{ "D9AADE20-7C17-4F9C-BC28-8555DD98E2A2", "keep" }, -- index parameters placeholder
		{ "6B203BAD-3F11-48E4-ACA8-D7613DE2CFA7", "keep" }, -- media object index parameters
		{ "F55E496D-9797-4B5D-8C8B-604DFE9BFB24", "keep" }, -- timecode index parameters
		{ "C5F8CBEA-5BAF-4877-8467-AA8C44FA4CCA", "records", "metadata" },
		{ "44231C94-9498-49D1-A141-1D134E457054", "records", "metadata library" },
		{ "1806D474-CADF-4509-A4BA-9AABCB96AAE8", "zero" },
	},
	[ASF.TOP_OBJECTS] = {
		{ "75B22636-668E-11CF-A6D9-00AA0062CE6C", "keep" }, -- data
		{ "33000890-E5B1-11CF-89F4-00A0C90349CB", "keep" }, -- simple index
		{ "D6E229D3-35DA-11D1-9034-00A0C90349BE", "keep" }, -- index
		{ "FEB103F8-12AD-4C64-840F-2A1D2F7AD48C", "keep" }, -- media object index
		{ "3CB73FD0-0C4A-4803-953D-EDF7B6228F0C", "keep" }, -- timecode index
	},
}) do
	for _, entry in ipairs(entries) do
		list[ASF.guid(entry[1])] = { action = entry[2], name = entry[3] }
	end
end

-- Metadata records that change playback: a WMV stream's pixel aspect ratio.
ASF.RECORDS = as_set({ "AspectRatioX", "AspectRatioY" })

-- A metadata or metadata library object with only the playback records,
-- followed by a padding object over the rest; nil when nothing is kept.
function ASF.records(object, data)
	local count, position, kept = string.unpack("<I2", data, 25), 27, {}
	for _ = 1, count do
		assert(position + 11 <= #data, "truncated ASF metadata record")
		local name_length, _, value_length = string.unpack("<I2I2I4", data, position + 4)
		local finish = position + 12 + name_length + value_length
		assert(finish - 1 <= #data, "truncated ASF metadata record")
		local name = data:sub(position + 12, position + 11 + name_length):gsub("(.)%z", "%1"):gsub("%z$", "")
		if ASF.RECORDS[name] then
			kept[#kept + 1] = data:sub(position, finish - 1)
		end
		position = finish
	end
	if #kept == 0 then
		return nil
	end
	local body = table.concat(kept)
	local length = 26 + #body
	local rest = #data - length
	if rest == 0 then
		return data
	end
	assert(rest >= 24, "ASF metadata object cannot be shrunk")
	return object.id
		.. string.pack("<i8I2", length, #kept)
		.. body
		.. ASF.PADDING
		.. string.pack("<i8", rest)
		.. string.rep("\0", rest - 24)
end

function ASF.parse(path)
	local reader, err = binary_reader(path)
	if not reader then
		return nil, err
	end
	local size = reader:size()
	local state = { regions = {}, metadata = {} }
	local count = 0
	local function zero(start, finish)
		state.regions[#state.regions + 1] = { start = start, finish = finish }
	end
	-- Objects from start to finish, each looked up in known.
	local function objects(start, finish, known, visit)
		local position = start
		while position < finish do
			count = count + 1
			assert(count <= LIMIT.ISOBMFF_ITEMS, "too many ASF objects")
			assert(finish - position >= 24, "truncated ASF object")
			reader:seek(position)
			local id = assert(reader:read_exact(16))
			local length = string.unpack("<i8", assert(reader:read_exact(8)))
			assert(length >= 24 and length <= finish - position, "invalid ASF object size")
			local entry = known[id]
			if not entry then
				error("unsupported ASF object " .. id:gsub(".", function(c)
					return string.format("%02X", c:byte())
				end), 0)
			end
			local object = { id = id, start = position, finish = position + length }
			local rebuilt
			if entry.action == "records" then
				reader:seek(position)
				assert(length >= 26 and length <= LIMIT.BINARY_READ, "invalid ASF metadata object")
				local data = assert(reader:read_exact(length))
				rebuilt = ASF.records(object, data)
				if rebuilt and rebuilt ~= data then
					state.metadata[#state.metadata + 1] = "ASF " .. entry.name .. " object"
					state.regions[#state.regions + 1] =
						{ start = position, finish = object.finish, kind = "bytes", bytes = rebuilt }
				end
			end
			if entry.action == "pad" or entry.action == "records" and not rebuilt then
				state.metadata[#state.metadata + 1] = "ASF " .. entry.name .. " object"
				state.regions[#state.regions + 1] =
					{ start = position, finish = position + 16, kind = "bytes", bytes = ASF.PADDING }
				zero(position + 24, object.finish)
			elseif entry.action == "zero" then
				zero(position + 24, object.finish)
			end
			visit(object)
			position = object.finish
		end
	end
	local result, message = pcall(function()
		assert(size >= 30, "truncated ASF header")
		reader:seek(0)
		assert(reader:read_exact(16) == ASF.HEADER, "missing ASF header object")
		local header = string.unpack("<i8", assert(reader:read_exact(8)))
		assert(header >= 30 and header <= size, "invalid ASF header size")
		local seen = {}
		objects(30, header, ASF.HEADER_OBJECTS, function(object)
			seen[object.id] = true
			if object.id == ASF.FILE_PROPERTIES then
				assert(object.finish - object.start >= 104, "invalid ASF file properties")
				zero(object.start + 24, object.start + 40)
				zero(object.start + 48, object.start + 56)
			elseif object.id == ASF.EXTENSION then
				assert(object.finish - object.start >= 46, "invalid ASF header extension")
				objects(object.start + 46, object.finish, ASF.EXTENSION_OBJECTS, function(child)
					if child.id == ASF.EXTENDED_STREAM then
						reader:seek(child.start + 84)
						local names = string.unpack("<I2", assert(reader:read_exact(2)))
						assert(names == 0, "ASF stream names are unsupported")
					end
				end)
			end
		end)
		assert(seen[ASF.FILE_PROPERTIES], "ASF file without file properties")
		local data = false
		objects(header, size, ASF.TOP_OBJECTS, function(object)
			if object.id == ASF.DATA or object.id == ASF.SIMPLE_INDEX then
				assert(object.finish - object.start >= 40, "truncated ASF object")
				zero(object.start + 24, object.start + 40)
				data = data or object.id == ASF.DATA
			end
		end)
		assert(data, "ASF file without data")
	end)
	reader:close()
	if not result then
		return nil, tostring(message):gsub("^.-:%d+: ", "")
	end
	table.sort(state.regions, function(a, b)
		return a.start < b.start
	end)
	return state
end

ASF.POLICY = region_policy({
	spec = metadata_spec({
		keep = with_basics(prefixed("ASF", {
			"FileLength",
			"DataPackets",
			"Duration",
			"SendDuration",
			"Preroll",
			"Flags",
			"MinPacketSize",
			"MaxPacketSize",
			"MaxBitrate",
			"StreamType",
			"ErrorCorrectionType",
			"TimeOffset",
			"StreamNumber",
			"AudioCodecID",
			"AudioChannels",
			"AudioSampleRate",
			"AudioCodecName",
			"AudioCodecDescription",
			"VideoCodecID",
			"VideoCodecName",
			"VideoCodecDescription",
			"ImageWidth",
			"ImageHeight",
			"AspectRatioX",
			"AspectRatioY",
		})),
		neutral = {
			["ASF:FileID"] = "00000000-0000-0000-0000-000000000000",
			-- ExifTool shows a zero date as the start of the ASF epoch.
			["ASF:CreationDate"] = "1601:01:01 00:00:00Z",
		},
	}),
	parse = ASF.parse,
	dirty = "ASF identifiers or padding are not neutral",
	layout = function(state, static)
		state.static, state.pictures = AUDIO.layout(static)
	end,
	capture = function(_, _, state)
		return { static = state.static, pictures = state.pictures }
	end,
	equivalent = function(before, after)
		if after.pictures > 0 then
			return nil, "cover art remains"
		end
		return before.static == after.static or nil, "ASF stream layout changed"
	end,
})

-- MPEG-TS and AVCHD (MTS, M2TS) ----------------------------------------------------

-- AVCHD cameras write their make, model, recording time and exposure into
-- an H.264 SEI message (user data with the MDPM identifier) in every frame.
-- Cleaning fills that payload with 0xFF in place, keeping each emulation
-- prevention sequence (00 00 03), so the decoded payload keeps its declared
-- size and no start code can appear. Only those transport stream payload
-- bytes change.
local TS = {
	-- The user-data identifier of AVCHD camera metadata (MDPM, OFMD).
	UUID = "\23\238\140\96\248\77\17\217\140\214\8\0\32\12\154\102",
	-- One PES packet can hold both fields of an interlaced frame.
	FRAME_BYTES = 64 * 1024 * 1024,
}

function TS.sniff(path)
	local file = io.open(path, "rb")
	local head = file and file:read(392) or ""
	if file then
		file:close()
	end
	if head:byte(1) == 0x47 and head:byte(189) == 0x47 then
		return 188, 0
	elseif head:byte(5) == 0x47 and head:byte(197) == 0x47 then
		return 192, 4
	end
end

-- The edits that neutralize the camera metadata of every SEI NAL unit in a
-- frame, top-level or nested (MVC scalable nesting): { first, last, bytes }
-- with raw 1-based positions; nil and an error for an unreadable nesting.
function TS.clean_frame(data, state)
	local edits, search = {}, 1
	while true do
		local start = data:find("\0\0\1", search, true)
		if not start then
			break
		end
		local header = data:byte(start + 3)
		search = start + 3
		if header and header & 0x1F == 6 then
			-- The NAL unit's bytes without emulation prevention, the raw index
			-- of every byte and the raw positions of prevention bytes.
			local raw_index, rbsp, prevention, zeros = {}, {}, {}, 0
			local position = start + 4
			while position <= #data do
				local byte = data:byte(position)
				if zeros >= 2 and byte <= 3 then
					if byte ~= 3 then
						break
					end
					prevention[position], zeros = true, 0
				else
					rbsp[#rbsp + 1], raw_index[#rbsp + 1] = byte, position
					zeros = byte == 0 and zeros + 1 or 0
				end
				position = position + 1
			end
			local parts = {}
			for index = 1, #rbsp, 4096 do
				parts[#parts + 1] = string.char(table.unpack(rbsp, index, math.min(index + 4095, #rbsp)))
			end
			local text = table.concat(parts)
			local function neutralize(first, last)
				local raw_first, raw_last, bytes = raw_index[first], raw_index[last], {}
				for index = raw_first, raw_last do
					local kept = prevention[index] or prevention[index + 1] or prevention[index + 2]
					bytes[#bytes + 1] = kept and data:sub(index, index) or "\255"
				end
				edits[#edits + 1] = { first = raw_first, last = raw_last, bytes = table.concat(bytes) }
				state.metadata[#state.metadata + 1] = "camera metadata (MDPM)"
			end
			local cursor = 1
			while cursor < #rbsp do
				local kind, size = 0, 0
				repeat
					kind, cursor = kind + (rbsp[cursor] or 0), cursor + 1
				until rbsp[cursor - 1] ~= 255
				repeat
					size, cursor = size + (rbsp[cursor] or 0), cursor + 1
				until rbsp[cursor - 1] ~= 255
				if cursor + size - 1 > #rbsp then
					break
				end
				local payload = text:sub(cursor, cursor + size - 1)
				if kind == 5 and payload:sub(1, 16) == TS.UUID then
					neutralize(cursor, cursor + size - 1)
				elseif kind ~= 5 then
					-- A nested user-data message: type 5 and a one-byte size
					-- right before the identifier.
					local at = payload:find(TS.UUID, 1, true)
					while at do
						local nested = payload:byte(at - 1)
						if at < 3 or payload:byte(at - 2) ~= 5 or nested == 255 or at + nested - 1 > #payload then
							return nil, "unsupported nested camera metadata"
						end
						neutralize(cursor + at - 1, cursor + at + nested - 2)
						at = payload:find(TS.UUID, at + nested, true)
					end
				end
				cursor = cursor + size
			end
		end
	end
	return edits
end

function TS.parse(path)
	local packet, skip = TS.sniff(path)
	if not packet then
		return nil, "not an MPEG transport stream"
	end
	local file, open_err = io.open(path, "rb")
	if not file then
		return nil, tostring(open_err or "could not open transport stream")
	end
	local size = file:seek("end")
	if size % packet ~= 0 then
		file:close()
		return nil, "truncated transport stream"
	end
	local state = { regions = {}, metadata = {} }
	local frames = {}
	-- A frame's elementary stream and where each piece lies in the file:
	-- piece i holds stream bytes from es[i] (0-based) at file offset file[i].
	local function flush(pid)
		local frame = frames[pid]
		frames[pid] = nil
		if not frame then
			return
		end
		local data = table.concat(frame.parts)
		local edits, edit_err = TS.clean_frame(data, state)
		if not edits or #edits == 0 then
			return edit_err
		end
		local parts, position = {}, 1
		for _, edit in ipairs(edits) do
			parts[#parts + 1] = data:sub(position, edit.first - 1)
			parts[#parts + 1] = edit.bytes
			position = edit.last + 1
		end
		parts[#parts + 1] = data:sub(position)
		local cleaned, touched = table.concat(parts), {}
		for index = 1, #frame.es do
			local first, last = frame.es[index] + 1, (frame.es[index + 1] or #data)
			for _, edit in ipairs(edits) do
				if not touched[index] and edit.first <= last and edit.last >= first then
					touched[index] = true
					state.regions[#state.regions + 1] = {
						start = frame.file[index],
						finish = frame.file[index] + last - first + 1,
						kind = "bytes",
						bytes = cleaned:sub(first, last),
					}
				end
			end
		end
	end
	file:seek("set", 0)
	local offset, err = 0, nil
	while offset < size and not err do
		local block = file:read(packet * (STREAM_BLOCK // 188))
		if not block or #block % packet ~= 0 then
			err = "truncated transport stream"
			break
		end
		for base = 0, #block - packet, packet do
			local at = base + skip + 1
			if block:byte(at) ~= 0x47 then
				err = "lost transport stream sync"
				break
			end
			local b1, b2, b3 = block:byte(at + 1, at + 3)
			local pid, control = (b1 & 0x1F) << 8 | b2, b3 >> 4 & 3
			local payload = at + 4
			if control & 2 ~= 0 then
				payload = payload + 1 + block:byte(at + 4)
			end
			local finish = base + packet
			if control & 1 ~= 0 and payload <= finish then
				if b1 & 0x40 ~= 0 then
					err = flush(pid)
					if err then
						break
					end
					-- A video PES packet: 00 00 01, stream id E0-EF, header.
					local head = block:sub(payload, payload + 8)
					local stream = head:byte(4)
					if #head == 9 and head:sub(1, 3) == "\0\0\1" and stream >= 0xE0 and stream <= 0xEF then
						payload = payload + 9 + head:byte(9)
						frames[pid] = { parts = {}, es = {}, file = {}, length = 0 }
					end
				end
				local frame = frames[pid]
				if frame and payload <= finish then
					if frame.length > TS.FRAME_BYTES then
						err = "transport stream frame is too large"
						break
					end
					local count = #frame.parts + 1
					frame.parts[count] = block:sub(payload, finish)
					frame.es[count], frame.file[count] = frame.length, offset + payload - 1
					frame.length = frame.length + finish - payload + 1
				end
			end
		end
		offset = offset + #block
	end
	file:close()
	if err then
		return nil, err
	end
	for pid in pairs(frames) do
		err = flush(pid)
		if err then
			return nil, err
		end
	end
	table.sort(state.regions, function(a, b)
		return a.start < b.start
	end)
	return state
end

TS.POLICY = region_policy({
	spec = metadata_spec({
		keep = with_basics({
			"M2TS:VideoStreamType",
			"M2TS:AudioStreamType",
			"M2TS:Duration",
			"H264:ImageWidth",
			"H264:ImageHeight",
			"AC3:*",
			"MPEG:*",
		}),
	}),
	parse = TS.parse,
	layout = function(state, static)
		state.static = AUDIO.layout(static)
		if not state.static:find("|codec_type=video|", 1, true) then
			return "transport stream has no video"
		end
	end,
	capture = function(_, _, state)
		return { static = state.static }
	end,
	equivalent = function(before, after)
		return before.static == after.static or nil, "transport stream layout changed"
	end,
})

-- JPEG XL (ISO/IEC 18181-2). The whole image, including its ICC profile and
-- orientation, is in the codestream; decoders ignore Exif orientation. Exif,
-- XMP and JUMBF boxes (plain or Brotli-compressed) go, and so does JPEG
-- reconstruction data, which can hold the original JPEG's comments and
-- application segments. A bare codestream holds no metadata.
local JXL = {
	KEEP = as_set({ "JXL ", "ftyp", "jxll", "jxli", "jxlc", "jxlp" }),
	DROP = as_set({ "Exif", "xml ", "jumb", "jbrd", "free", "skip" }),
	BROTLI_DROP = as_set({ "Exif", "xml ", "jumb" }),
	SPEC = metadata_spec({
		keep = with_basics({
			"File:ImageWidth",
			"File:ImageHeight",
			"Jpeg2000:MajorBrand",
			"Jpeg2000:MinorVersion",
			"Jpeg2000:CompatibleBrands",
		}),
	}),
}

function JXL.parse(path)
	local reader, err = binary_reader(path)
	if not reader then
		return nil, err
	end
	local size = reader:size()
	local signature = reader:read_exact(math.min(size, 2))
	if signature == "\255\10" then
		reader:close()
		return { boxes = {}, bare = true, size = size }
	end
	reader:seek(0)
	local state = { boxes = {}, size = size }
	local result, message = pcall(function()
		local position, codestream = 0, nil
		while position < size do
			assert(#state.boxes < LIMIT.ISOBMFF_ITEMS, "too many JPEG XL boxes")
			assert(size - position >= 8, "truncated JPEG XL box")
			reader:seek(position)
			local length, kind = string.unpack(">I4c4", assert(reader:read_exact(8)))
			local header = 8
			if length == 1 then
				assert(size - position >= 16, "truncated JPEG XL box")
				length, header = string.unpack(">I8", assert(reader:read_exact(8))), 16
			elseif length == 0 then
				length = size - position
			end
			assert(length >= header and length <= size - position, "invalid JPEG XL box size")
			local box = { type = kind, start = position, finish = position + length, header = header }
			if kind == "brob" then
				assert(length >= header + 4, "invalid JPEG XL brob box")
				box.inner = reader:read_exact(4)
			end
			local index = #state.boxes + 1
			if index == 1 then
				assert(kind == "JXL " and length == 12, "missing JPEG XL signature box")
				assert(reader:read_exact(4) == "\13\10\135\10", "invalid JPEG XL signature")
			elseif index == 2 then
				assert(kind == "ftyp" and length >= header + 8, "missing JPEG XL file type box")
				assert(reader:read_exact(4) == "jxl ", "unsupported JPEG XL brand")
			end
			if kind == "jxlc" or kind == "jxlp" then
				assert(codestream == nil or codestream == kind, "mixed JPEG XL codestream boxes")
				codestream = kind
			end
			state.boxes[index] = box
			position = box.finish
		end
		assert(codestream, "JPEG XL file without a codestream")
		for _, box in ipairs(state.boxes) do
			if not (JXL.KEEP[box.type] or JXL.DROP[box.type] or box.type == "brob" and JXL.BROTLI_DROP[box.inner]) then
				local name = (box.inner and "brob " .. box.inner or box.type):gsub("[^%w ]", "?")
				error("unsupported JPEG XL box " .. name, 0)
			end
		end
	end)
	reader:close()
	if not result then
		return nil, tostring(message):gsub("^.-:%d+: ", "")
	end
	return state
end

-- Byte ranges of the boxes that are removed.
function JXL.removed(state)
	local ranges = {}
	for _, box in ipairs(state.boxes) do
		if not JXL.KEEP[box.type] then
			ranges[#ranges + 1] = { start = box.start, finish = box.finish }
		end
	end
	return ranges
end

-- The kept boxes in order, with their sizes.
function JXL.manifest(state)
	local records = { state.bare and "jxl-v1-bare" or "jxl-v1" }
	for _, box in ipairs(state.boxes) do
		if JXL.KEEP[box.type] then
			records[#records + 1] = box.type .. "=" .. tostring(box.finish - box.start)
		end
	end
	return table.concat(records, "\n")
end

local JXL_POLICY = {
	spec = JXL.SPEC,
	preflight = function(path)
		return JXL.parse(path)
	end,
	structure_clean = function(state)
		local removed = JXL.removed(state)[1]
		if removed then
			for _, box in ipairs(state.boxes) do
				if box.start == removed.start then
					return false, "JPEG XL " .. (box.inner and "brob " .. box.inner or box.type) .. " box"
				end
			end
		end
		return true
	end,
	capture = function(_, _, state)
		return { manifest = JXL.manifest(state) }
	end,
	equivalent = function(before, after)
		if before.manifest ~= after.manifest then
			return nil, "JPEG XL boxes changed"
		end
		return true
	end,
	transform = function(ctx)
		local output = io.open(ctx.staged, "wb")
		if not output then
			return nil, "could not write the staged JPEG XL file"
		end
		local ok, err = copy_excluding_ranges(ctx.source, output, JXL.removed(ctx.state))
		if not output:close() then
			return nil, "could not write the staged JPEG XL file"
		end
		return ok, err
	end,
	-- Every kept box, the codestream included, is byte-identical.
	verify = function(source, staged, state)
		local after, err = JXL.parse(staged)
		if not after then
			return nil, err
		end
		local a, b = io.open(source, "rb"), io.open(staged, "rb")
		local kept = {}
		for _, box in ipairs(state.boxes) do
			if JXL.KEEP[box.type] then
				kept[#kept + 1] = box
			end
		end
		local result = a and b and #kept == #after.boxes
		for index = 1, result and #kept or 0 do
			local box, copy = kept[index], after.boxes[index]
			result = copy.finish - copy.start == box.finish - box.start
			a:seek("set", box.start)
			b:seek("set", copy.start)
			local remaining = box.finish - box.start
			while result and remaining > 0 do
				local length = math.min(remaining, STREAM_BLOCK)
				result = a:read(length) == b:read(length)
				remaining = remaining - length
			end
			if not result then
				break
			end
		end
		if a then
			a:close()
		end
		if b then
			b:close()
		end
		return result or nil, not result and "JPEG XL image data changed" or nil
	end,
}

local POLICIES = {
	JPEG = JPEG_POLICY,
	JXL = JXL_POLICY,
	["JXL Codestream"] = JXL_POLICY,
	PNG = PNG_POLICY,
	APNG = PNG_POLICY,
	TIFF = TIFF_POLICY,
	DNG = TIFF.DNG_POLICY,
	GIF = GIF_POLICY,
	SVG = SVG_POLICY,
	BMP = BMP_POLICY,
	ICO = ICO_POLICY,
	WEBP = WEBP_POLICY,
	MP4 = quicktime_policy({ "video", "audio" }),
	MOV = quicktime_policy({ "video", "audio" }),
	M4V = quicktime_policy({ "video" }),
	M4A = quicktime_policy({ "audio" }),
	["3GP"] = quicktime_policy({ "video", "audio" }),
	["3G2"] = quicktime_policy({ "video", "audio" }),
	MKV = MKV.POLICY,
	WEBM = MKV.POLICY,
	MKA = MKV.POLICY,
	MKS = MKV.POLICY,
	MP3 = AUDIO.MP3,
	AAC = AUDIO.MP3,
	FLAC = AUDIO.FLAC,
	WAV = AUDIO.WAV,
	AIFF = AUDIO.AIFF,
	AIFC = AUDIO.AIFF,
	DSF = AUDIO.DSF,
	WV = AUDIO.WV,
	APE = AUDIO.APE,
	MPC = AUDIO.MPC,
	OGG = OGG.POLICY,
	OPUS = OGG.POLICY,
	OGV = OGG.POLICY,
	AVI = AVI.POLICY,
	ASF = ASF.POLICY,
	WMA = ASF.POLICY,
	WMV = ASF.POLICY,
	M2TS = TS.POLICY,
	M2T = TS.POLICY,
	HEIC = HEIF_POLICY,
	HEIF = HEIF_POLICY,
	AVIF = HEIF_POLICY,
}

for _, name in ipairs({ "MP4", "MOV", "M4V", "3GP", "3G2", "MKV", "WEBM", "AVI" }) do
	POLICIES[name].motion_jpeg = true
end

-- ExifTool names lossless and extended WebP variants separately.
local FILE_TYPE_ALIASES = {
	["WEBP (lossless)"] = "WEBP",
	["Extended WEBP"] = "WEBP",
	["Extended WEBP (lossless)"] = "WEBP",
}

local selected_or_hovered = ya.sync(function()
	local targets = {}
	for _, file in pairs(cx.active.selected) do
		targets[#targets + 1] = tostring(file.url)
	end
	if #targets == 0 then
		local hovered = cx.active.current.hovered
		if hovered then
			targets[1] = tostring(hovered.url)
		end
	end
	return targets
end)

-- Each worker has its own staging name, so concurrent workers never race for
-- the same directory.
local function stage_path(path, worker)
	local parent, name = path:match("^(.*)/([^/]+)$")
	if not parent or name == "" then
		return nil, "cannot determine parent directory"
	end
	local directory, err = fs.unique("dir", Url(parent .. "/.metaclean-stage-" .. tostring(worker)))
	if not directory then
		return nil, "cannot create staging directory: " .. tostring(err)
	end
	directory = tostring(directory)
	return directory, directory .. "/" .. name
end

local function remove_stage(directory)
	if
		directory and (directory:match("/%.metaclean%-stage%-%d+$") or directory:match("/%.metaclean%-stage%-%d+_%d+$"))
	then
		fs.remove("dir_all", Url(directory))
	end
end

-- An APFS clone is instant but does not carry the ACL; a full copy does. The
-- clone is tried first and replaced when its attributes differ.
local function copy_stage(source, destination, attributes)
	for _, flags in ipairs({ { "-c", "-p" }, { "-p" } }) do
		local copy_args = {}
		for _, flag in ipairs(flags) do
			copy_args[#copy_args + 1] = flag
		end
		copy_args[#copy_args + 1] = "--"
		copy_args[#copy_args + 1] = source
		copy_args[#copy_args + 1] = destination
		local output, err = command("cp", copy_args, media_timeout(source))
		if not output or not output.status.success then
			return nil, clean_error(output, err)
		end
		local copied, copied_err = file_attributes(destination)
		if not copied then
			return nil, copied_err
		end
		if copied == attributes then
			return true
		end
		fs.remove("file", Url(destination))
	end
	return nil, "staged copy does not preserve file attributes"
end

local function source_unchanged(path, fingerprint, xattrs, attributes)
	local current, err = source_fingerprint(path)
	if not current then
		return nil, err
	end
	if current ~= fingerprint then
		return nil, "source changed during processing"
	end
	local current_xattrs, identity = preserved_xattrs(path)
	if not current_xattrs then
		return nil, identity
	end
	local same, same_err = same_xattrs(xattrs, current_xattrs)
	if not same then
		return nil, same_err
	end
	if file_attributes(path) ~= attributes then
		return nil, "source attributes changed during processing"
	end
	return true, identity
end

-- Prove a cleaned staged copy: only allowlisted metadata, kept values equal,
-- a clean structure, the policy's own checks and an equivalent capture.
-- An independent backstop for the format parsers: the text values of every
-- removed tag must not survive anywhere in the cleaned file, in UTF-8 or
-- UTF-16, so identity data in a place no parser knows about is still found.
-- Values the cleaned inventory legitimately reports (kept handler names, ICC
-- descriptions) and values too short to be distinctive are not searched.
-- This Mac's own identifiers, which editors embed in project paths and
-- histories that no tag names as identity: the home folder path, the
-- account's full name and the computer name. Read once per session.
local identity_residue
do
	local personal_needles

	local function personal_identity()
		if personal_needles then
			return personal_needles
		end
		personal_needles = {}
		local function value(name, args)
			local output = command(name, args)
			return output and output.status.success and output.stdout:gsub("%s+$", "") or ""
		end
		local login = value("id", { "-un" })
		if #login >= 2 then
			personal_needles[#personal_needles + 1] = "/Users/" .. login
		end
		local full = value("id", { "-F" })
		if #full >= 6 then
			personal_needles[#personal_needles + 1] = full
		end
		local computer = value("scutil", { "--get", "ComputerName" })
		-- Default names such as "MacBook Pro" identify nobody.
		if #computer >= 6 and not computer:match("^i?Mac[%a ]*$") then
			personal_needles[#personal_needles + 1] = computer
		end
		return personal_needles
	end

	function identity_residue(path, before, after, spec)
		local kept = {}
		for _, key in ipairs(after.entries) do
			for _, value in ipairs(after.values[key]) do
				kept[#kept + 1] = value
			end
		end
		local needles, seen = {}, {}
		-- strict: searched even where a kept tag holds it (this Mac's own
		-- identifiers are never legitimate content).
		local function add(text, strict)
			if #text > 64 then
				text = text:sub(1, 64)
			end
			if seen[text] then
				return
			end
			seen[text] = true
			for _, value in ipairs(strict and {} or kept) do
				if value:find(text, 1, true) then
					return
				end
			end
			needles[#needles + 1] = text
			-- UTF-16 without the last NUL matches both byte orders, and starts
			-- with a letter rather than the NUL bytes that fill media data.
			if not text:find("[\128-\255]") then
				needles[#needles + 1] = text:gsub(".", "%0\0"):sub(1, -2)
			end
		end
		for _, key in ipairs(before.entries) do
			local neutral = spec.neutral[key]
			if #needles >= LIMIT.RESIDUE_NEEDLES then
				break
			elseif not (spec.keep(key) or spec.free(key) or spec.recomputed(key)) or neutral then
				local short = key:find("Serial") or key:find("Owner") or key:find("Artist") or key:find("Author")
				for _, value in ipairs(before.values[key]) do
					value = value:match("^%s*(.-)%s*$")
					if
						value ~= neutral
						and #value >= (short and 6 or 8)
						and not value:find("^%(Binary data")
						and value:find("[%w]")
					then
						add(value)
						local date, time = value:match("^(%d%d%d%d:%d%d:%d%d) (%d%d:%d%d:%d%d)")
						if date then
							add(date:gsub(":", "-") .. "T" .. time)
						end
					end
					if #needles >= LIMIT.RESIDUE_NEEDLES then
						break
					end
				end
			end
		end
		local personal = {}
		for _, text in ipairs(personal_identity()) do
			local count = #needles
			seen[text] = nil
			add(text, true)
			for index = count + 1, #needles do
				personal[needles[index]] = true
			end
		end
		if #needles == 0 then
			return true
		end
		local longest = 0
		for _, needle in ipairs(needles) do
			longest = math.max(longest, #needle)
		end
		local file = io.open(path, "rb")
		if not file then
			return nil, "could not open the cleaned file"
		end
		local tail, found = "", nil
		while not found do
			local block = file:read(STREAM_BLOCK)
			if not block then
				break
			end
			local window = tail .. block
			for _, needle in ipairs(needles) do
				if window:find(needle, 1, true) then
					found = needle
					break
				end
			end
			tail = longest > 1 and window:sub(1 - longest) or ""
		end
		file:close()
		if personal[found] then
			return nil, "holds this Mac's user name, full name or computer name"
		elseif found then
			return nil, "removed metadata value still present: " .. found:gsub("%z", ""):gsub("[^\32-\126]", "?")
		end
		return true
	end
end

local function prove_clean(policy, source, staged, before, state, before_capture, scan_options)
	local spec = policy.spec
	local validated = { embedded = scan_options.embedded, validate = true }
	local after, err = scan(staged, validated)
	if not after then
		return nil, err
	end
	-- Validate is "errors warnings minor". Removing metadata can create
	-- "missing required tag" warnings, so only new errors are a regression,
	-- and the original is validated only when the cleaned file has errors.
	local errors = tonumber(tostring(after.validate):match("^(%d+) %d+ %d+$"))
	if not errors then
		return nil, "ExifTool did not validate the cleaned file"
	elseif errors > 0 then
		local original
		original, err = scan(source, validated)
		if not original then
			return nil, err
		end
		if errors > (tonumber(tostring(original.validate):match("^(%d+) %d+ %d+$")) or 0) then
			return nil, "ExifTool validation regressed: " .. after.validate
		end
	end
	local clean, remaining = metadata_clean(after, spec)
	if not clean then
		return nil, "metadata outside the allowlist remains: " .. tostring(remaining)
	end
	local ok
	ok, err = metadata_equivalent(
		policy.expected_inventory and policy.expected_inventory(before, state) or before,
		after,
		spec
	)
	if not ok then
		return nil, err
	end
	local after_state
	after_state, err = policy.preflight(staged, after)
	if not after_state then
		return nil, "cleaned file failed validation: " .. tostring(err)
	end
	ok, err = policy.structure_clean(after_state, staged)
	if not ok then
		return nil, "metadata remains: " .. tostring(err)
	end
	if policy.verify then
		ok, err = policy.verify(source, staged, state)
		if not ok then
			return nil, err
		end
	end
	local after_capture
	after_capture, err = policy.capture(staged, after, after_state)
	if not after_capture then
		return nil, err
	end
	ok, err = policy.equivalent(before_capture, after_capture)
	if not ok then
		return nil, err
	end
	return identity_residue(staged, before, after, spec)
end

-- Clean the video embedded in a Motion Photo: source holds its bytes, staged
-- receives the cleaned copy. QuickTime cleaning never changes the size.
function EMBEDDED.clean(source, staged)
	local policy = POLICIES.MP4
	local before, err = scan(source)
	if not before then
		return nil, err
	end
	if not POLICIES[before.file_type] or POLICIES[before.file_type].spec ~= QUICKTIME_SPEC then
		return nil, "embedded video is not MP4 or MOV"
	end
	local state
	state, err = policy.preflight(source, before)
	if not state then
		return nil, "embedded video: " .. tostring(err)
	end
	local capture
	capture, err = policy.capture(source, before, state)
	if not capture then
		return nil, err
	end
	local data
	data, err = read_file(source, LIMIT.MOTION_BYTES, "embedded video")
	if not data then
		return nil, err
	end
	local ok
	ok, err = rewrite_file(staged, data)
	if ok then
		ok, err = policy.transform({ source = source, staged = staged, inventory = before, state = state })
	end
	if ok then
		ok, err = prove_clean(policy, source, staged, before, state, capture, {})
	end
	if not ok then
		return nil, "embedded video: " .. tostring(err)
	end
	return true
end

-- Whether an embedded video needs no cleaning: no metadata boxes or
-- tracks, zeroed dates and free space.
function EMBEDDED.is_clean(data)
	local state = quicktime_parse(string_file(data))
	return state ~= nil and #state.metadata == 0 and regions_hold(string_file(data), state.regions) == true
end

-- With preview, nothing is written: a file that needs cleaning returns
-- "preview" and what would be removed (tags, then any structural metadata).
local function process_file(path, worker, preview)
	-- Tags the cleaning removes from an inventory, in inventory order.
	local function removed_tags(inventory, spec)
		local removed = {}
		for _, key in ipairs(inventory.entries) do
			local neutral = spec.neutral[key]
			if neutral then
				for _, value in ipairs(inventory.values[key]) do
					if value ~= neutral then
						removed[#removed + 1] = key
						break
					end
				end
			elseif not (spec.keep(key) or spec.free(key) or spec.recomputed(key)) then
				removed[#removed + 1] = key
			end
		end
		return removed
	end
	if path:sub(1, 1) ~= "/" then
		return nil, "not an absolute local path"
	end
	local cha = fs.cha(Url(path), false)
	if
		not cha
		or cha.is_link
		or cha.is_dir
		or cha.is_block
		or cha.is_char
		or cha.is_fifo
		or cha.is_sock
		or (cha.nlink and cha.nlink > 1)
	then
		return nil, "not an eligible regular file"
	end
	-- An iCloud Drive file kept only in the cloud (SF_DATALESS) is downloaded
	-- by the first read; stat reads the flag without fetching it. The same
	-- call records the fingerprint's file state, before anything reads it.
	local status, status_err = command("stat", { "-f", "%f|" .. FINGERPRINT_STAT, path })
	if not status or not status.status.success then
		return nil, clean_error(status, status_err)
	end
	local flags, stat_value = status.stdout:gsub("%s+$", ""):match("^(%d+)|(.*)$")
	if (tonumber(flags) or 0) & 0x40000000 ~= 0 then
		return nil, "iCloud file not downloaded"
	end
	-- ExifTool reads Matroska past the first cluster and camera metadata in
	-- transport streams only with -ee.
	-- ExifTool takes minutes to list thousands of TIFF pages.
	if path:lower():match("%.tiff?$") then
		local pages, pages_err = TIFF.pages(path)
		if pages then
			pages.close()
		elseif pages_err == "too many TIFF pages" then
			return nil, pages_err
		end
	end
	local embedded = MKV.sniff(path) or TS.sniff(path) ~= nil
	local scan_options = { embedded = embedded }
	local before, err = scan(path, scan_options)
	if not before then
		return nil, err
	end
	local policy = POLICIES[FILE_TYPE_ALIASES[before.file_type] or before.file_type]
	if not policy then
		return nil, "unsupported format " .. tostring(before.file_type)
	end
	local spec = policy.spec
	local state
	state, err = policy.preflight(path, before)
	if not state then
		return nil, err
	end
	if policy.motion_jpeg then
		err = motion_jpeg_metadata(path)
		if err then
			return nil, err
		end
	end
	local structure_clean, structure_err = policy.structure_clean(state, path)
	if structure_clean == nil then
		return nil, structure_err
	end
	local embedded_clean = structure_clean and metadata_clean(before, spec)
	if preview then
		local clean, changes = filesystem_clean(path)
		if clean == nil then
			return nil, changes
		elseif embedded_clean then
			-- As in a real run, this Mac's identifiers make the file skip.
			local ok, residue_err = identity_residue(path, before, before, spec)
			if not ok then
				return nil, residue_err
			elseif clean then
				return true, "unchanged"
			end
		end
		local removed = removed_tags(before, spec)
		if not structure_clean then
			removed[#removed + 1] = structure_err
		end
		for _, change in ipairs(changes) do
			removed[#removed + 1] = "Filesystem:" .. change
		end
		return true, "preview", removed
	end
	if embedded_clean then
		local clean, clean_err = filesystem_clean(path)
		if clean then
			-- Nothing was removed, so only this Mac's identifiers are searched.
			local ok, residue_err = identity_residue(path, before, before, spec)
			if not ok then
				return nil, residue_err
			end
			return true, "unchanged"
		elseif clean == nil then
			return nil, clean_err
		end
	end

	local fingerprint, xattrs, attributes, before_capture
	fingerprint, err = source_fingerprint(path, stat_value)
	if not fingerprint then
		return nil, err
	end
	xattrs, err = preserved_xattrs(path)
	if not xattrs then
		return nil, err
	end
	attributes, err = file_attributes(path)
	if not attributes then
		return nil, err
	end
	local mode, flags = attributes:match("^(%S+) %d+ %d+ (%S+)")
	-- uchg, uappnd, schg and sappnd: the staged clone would inherit a flag that
	-- prevents writing it and removing it again.
	for flag in (flags or ""):gmatch("[^,]+") do
		if flag == "uchg" or flag == "uappnd" or flag == "schg" or flag == "sappnd" then
			return nil, "immutable or append-only file"
		end
	end
	if not mode then
		return nil, "immutable or append-only file"
	end
	local read_only = mode:sub(3, 3) ~= "w"
	-- The source is proven unchanged since the fingerprint just before the
	-- replacement, which also covers this capture.
	before_capture, err = policy.capture(path, before, state)
	if not before_capture then
		return nil, err
	end

	local directory, staged = stage_path(path, worker or 1)
	if not directory then
		return nil, staged
	end
	local function fail(message)
		remove_stage(directory)
		return nil, message
	end
	local ok
	ok, err = copy_stage(path, staged, attributes)
	if not ok then
		return fail(err)
	end
	-- A read-only original gets a writable staged copy until it is finished;
	-- the attribute comparison below proves the mode was restored exactly.
	local function owner_write(enabled)
		local output, chmod_err = command("chmod", { enabled and "u+w" or "u-w", staged })
		if not output or not output.status.success then
			return nil, clean_error(output, chmod_err)
		end
		return true
	end
	if read_only then
		ok, err = owner_write(true)
		if not ok then
			return fail(err)
		end
	end
	if not embedded_clean then
		ok, err = policy.transform({ source = path, staged = staged, inventory = before, state = state })
		if not ok then
			return fail(err)
		end
	end
	ok, err = prove_clean(policy, path, staged, before, state, before_capture, scan_options)
	if not ok then
		return fail(err)
	end
	ok, err = neutralize_filesystem(staged)
	if not ok then
		return fail(err)
	end
	-- The identity attributes were just removed; the attribute check below
	-- proves it.
	local clean
	clean, err = dates_neutral(staged)
	if clean == false then
		ok, err = neutralize_creation_date(staged)
		if not ok then
			return fail(err)
		end
		clean, err = dates_neutral(staged)
	end
	if not clean then
		return fail(err or "filesystem metadata could not be neutralized")
	end
	if read_only then
		ok, err = owner_write(false)
		if not ok then
			return fail(err)
		end
	end
	local staged_xattrs, staged_identity = preserved_xattrs(staged)
	if not staged_xattrs then
		return fail(staged_identity)
	elseif staged_identity then
		return fail("filesystem metadata could not be neutralized")
	end
	ok, err = same_xattrs(xattrs, staged_xattrs)
	if not ok then
		return fail(err)
	end
	if file_attributes(staged) ~= attributes then
		return fail("staged file attributes differ from the source")
	end
	local identity
	ok, identity = source_unchanged(path, fingerprint, xattrs, attributes)
	if not ok then
		return fail(identity)
	end
	if identity then
		ok, err = forget_filesystem_identity(path)
		if not ok then
			return fail(err)
		end
	end
	ok, err = fs.rename(Url(staged), Url(path))
	if not ok then
		return fail("replacement failed: " .. tostring(err))
	end
	remove_stage(directory)
	return true, "sanitized"
end

-- Checked once per run, so a missing tool is reported once instead of as a
-- failure for every file.
local function missing_tool()
	for _, tool in ipairs({ { "exiftool", "-ver" }, { "ffprobe", "-version" }, { "ffmpeg", "-version" } }) do
		local output = command(tool[1], { tool[2] }, 30)
		if not output then
			return "timeout"
		elseif not output.status.success then
			return tool[1]
		end
	end
end

local function is_package(path)
	local extension = path:match("%.([^./]+)$")
	return extension ~= nil and PACKAGE_EXTENSIONS[extension:lower()] == true
end

local function walk(path, files, seen, skipped)
	if seen[path] then
		return true
	end
	seen[path] = true
	local cha = fs.cha(Url(path), false)
	if not cha or cha.is_link then
		return true
	elseif not cha.is_dir then
		files[#files + 1] = path
		return true
	end
	local name = path:match("([^/]+)$") or ""
	if is_package(path) or name:match("^%.metaclean%-stage") then
		if skipped then
			skipped[#skipped + 1] = path
		end
		return true
	end
	local entries, err = fs.read_dir(Url(path), { resolve = false })
	if not entries then
		return nil, tostring(err)
	end
	for _, entry in ipairs(entries) do
		local ok, walk_err = walk(tostring(entry.url), files, seen, skipped)
		if not ok then
			return nil, walk_err
		end
	end
	return true
end

local function confirm(count, has_directory)
	local lines = {
		ui.Line(""),
		ui.Line(string.format("Remove identity metadata from %d file%s?", count, count == 1 and "" or "s")),
		ui.Line(""),
		ui.Line("Each original is replaced only after its cleaned copy is verified."),
	}
	if has_directory then
		lines[#lines + 1] = ui.Line("Folders are searched recursively; app packages are skipped.")
	end
	local body = ui.Text(lines):wrap(ui.Wrap.YES)
	return ya.confirm({
		pos = { "center", w = 64, h = 10 },
		title = ui.Line("MetaClean"),
		body = body,
		content = body,
	})
end

-- Preview window -------------------------------------------------------------

-- The preview's lines as { text, kind } pairs: a summary, then the files to
-- clean with their removed metadata by group, the files already clean and the
-- files that would be skipped. Paths are shown relative to base and sorted;
-- groups and tags are sorted, then come the file's Filesystem changes and
-- descriptions that are not tags.
local PREVIEW = { WIDTH = 76 }

function PREVIEW.report(base, cleaned, unchanged, skipped)
	local function shown(path)
		local relative = base and path:sub(1, #base + 1) == base .. "/" and path:sub(#base + 2)
		return relative or path
	end
	local function by_path(list)
		table.sort(list, function(a, b)
			local x, y = shown(a.path):lower(), shown(b.path):lower()
			return x < y or x == y and a.path < b.path
		end)
		return list
	end
	local lines = {}
	local function add(text, kind)
		lines[#lines + 1] = { text = text, kind = kind }
	end
	-- Words are wrapped at the window width under a hanging indent.
	local function wrapped(label, words)
		local indent = string.rep(" ", #label)
		local line = label
		for index, word in ipairs(words) do
			local piece = index < #words and word .. "," or word
			if #line > #label and #line + 1 + #piece > PREVIEW.WIDTH then
				add(line, "tags")
				line = indent .. piece
			else
				line = line .. (#line > #label and " " or "") .. piece
			end
		end
		add(line, "tags")
	end
	local parts = { string.format("%d to clean", #cleaned), string.format("%d already clean", #unchanged) }
	if #skipped > 0 then
		parts[#parts + 1] = string.format("%d would be skipped", #skipped)
	end
	add(table.concat(parts, " · "), "summary")
	if #cleaned > 0 then
		add("", "blank")
		add(string.format("To clean (%d)", #cleaned), "clean")
		for _, entry in ipairs(by_path(cleaned)) do
			add("  " .. shown(entry.path), "file")
			local groups, names, other = {}, {}, {}
			for _, key in ipairs(entry.removed or {}) do
				local group, tag = key:match("^([^:]+):(.+)$")
				if group then
					if not groups[group] then
						groups[group], names[#names + 1] = {}, group
					end
					groups[group][tag] = true
				else
					other[key] = true
				end
			end
			table.sort(names, function(a, b)
				if (a == "Filesystem") ~= (b == "Filesystem") then
					return b == "Filesystem"
				end
				return a:lower() < b:lower()
			end)
			local width = 0
			for _, group in ipairs(names) do
				width = math.max(width, #group)
			end
			for _, group in ipairs(names) do
				local tags = {}
				for tag in pairs(groups[group]) do
					tags[#tags + 1] = tag
				end
				table.sort(tags)
				wrapped("    " .. group .. string.rep(" ", width - #group + 2), tags)
			end
			local notes = {}
			for note in pairs(other) do
				notes[#notes + 1] = note
			end
			table.sort(notes)
			for _, note in ipairs(notes) do
				add("    " .. note:gsub("^%l", string.upper), "note")
			end
		end
	end
	if #unchanged > 0 then
		add("", "blank")
		add(string.format("Already clean (%d)", #unchanged), "unchanged")
		for _, entry in ipairs(by_path(unchanged)) do
			add("  " .. shown(entry.path), "file")
		end
	end
	if #skipped > 0 then
		add("", "blank")
		add(string.format("Would be skipped (%d)", #skipped), "skipped")
		for _, entry in ipairs(by_path(skipped)) do
			add("  " .. shown(entry.path), "file")
			add("    " .. entry.reason:gsub("^%l", string.upper), "reason")
		end
	end
	return lines
end

PREVIEW.KEYS = {
	{ on = "q", run = "close" },
	{ on = "<Esc>", run = "close" },
	{ on = "<Enter>", run = "close" },
	{ on = "j", run = 1 },
	{ on = "<Down>", run = 1 },
	{ on = "k", run = -1 },
	{ on = "<Up>", run = -1 },
	{ on = "<C-d>", run = "half" },
	{ on = "<PageDown>", run = "page" },
	{ on = "<Space>", run = "page" },
	{ on = "<C-u>", run = "-half" },
	{ on = "<PageUp>", run = "-page" },
	{ on = "g", run = "top" },
	{ on = "G", run = "bottom" },
}

PREVIEW.STYLES = {
	summary = function(line)
		return line:bold()
	end,
	clean = function(line)
		return line:fg("green"):bold()
	end,
	unchanged = function(line)
		return line:fg("blue"):bold()
	end,
	skipped = function(line)
		return line:fg("yellow"):bold()
	end,
	file = function(line)
		return line:bold()
	end,
	tags = function(line)
		return line
	end,
	note = function(line)
		return line:dim()
	end,
	reason = function(line)
		return line:fg("yellow")
	end,
}

PREVIEW.open = ya.sync(function(state, lines)
	state.preview_lines, state.preview_offset = lines, 0
	if not state.preview_children then
		state.preview_children = Modal:children_add(state, 10)
	end
	ui.render()
end)

PREVIEW.close = ya.sync(function(state)
	if state.preview_children then
		Modal:children_remove(state.preview_children)
	end
	state.preview_children, state.preview_lines, state.preview_offset, state.preview_body = nil, nil, nil, nil
	ui.render()
end)

-- step is a line count, a page fraction, or the top or bottom.
PREVIEW.scroll = ya.sync(function(state, step)
	local visible = state.preview_body and math.max(1, state.preview_body.h) or 1
	local last = math.max(0, #(state.preview_lines or {}) - visible)
	local pages = { half = visible // 2, ["-half"] = -(visible // 2), page = visible, ["-page"] = -visible }
	local offset = state.preview_offset or 0
	if step == "top" then
		offset = 0
	elseif step == "bottom" then
		offset = last
	else
		offset = offset + (pages[step] or step)
	end
	state.preview_offset = math.max(0, math.min(offset, last))
	ui.render()
end)

function PREVIEW.show(lines)
	PREVIEW.open(lines)
	while true do
		local index = ya.which({ cands = PREVIEW.KEYS, silent = true })
		local step = index and PREVIEW.KEYS[index].run
		if not step or step == "close" then
			break
		end
		PREVIEW.scroll(step)
	end
	PREVIEW.close()
end

-- The plugin is its own modal component while the preview is open: a window
-- sized to its content, centered, at most 60% of the terminal's height.
function M:new(area)
	self.preview_area = area
	return self
end

function M:layout(area)
	self.preview_area = area
end

function M:reflow()
	return { self }
end

function M:redraw()
	local area, lines = self.preview_area, self.preview_lines or {}
	local w = math.min(PREVIEW.WIDTH + 6, math.max(20, area.w - 4))
	local h = math.min(#lines + 4, math.max(8, area.h * 3 // 5))
	local window = ui.Rect({ x = area.x + (area.w - w) // 2, y = area.y + (area.h - h) // 2, w = w, h = h })
	local inner = window:pad(ui.Pad(1, 2, 1, 2))
	local chunks = ui.Layout()
		:direction(ui.Layout.VERTICAL)
		:constraints({ ui.Constraint.Fill(1), ui.Constraint.Length(1) })
		:split(inner)
	self.preview_body = chunks[1]
	local offset = self.preview_offset or 0
	local body = {}
	for index = offset + 1, math.min(#lines, offset + chunks[1].h) do
		local line = lines[index]
		local style = PREVIEW.STYLES[line.kind] or PREVIEW.STYLES.tags
		body[#body + 1] = style(ui.Line(ui.truncate(line.text, { max = chunks[1].w })))
	end
	local footer = "j/k scroll  g/G top/end  q close"
	if #lines > chunks[1].h then
		footer = string.format("%s  %d–%d of %d", footer, offset + 1, offset + #body, #lines)
	end
	return {
		ui.Clear(window),
		ui.Border(ui.Edge.ALL)
			:area(window)
			:type(ui.Border.ROUNDED)
			:style(ui.Style():fg("blue"))
			:title(ui.Line(" MetaClean preview "):align(ui.Align.CENTER)),
		ui.Text(body):area(chunks[1]):wrap(ui.Wrap.NO),
		ui.Line(ui.truncate(footer, { max = chunks[2].w })):area(chunks[2]):dim(),
	}
end

-- Mouse wheel scrolling.
function M:scroll(_, step)
	self.preview_offset = math.max(0, (self.preview_offset or 0) + step)
	local visible = self.preview_body and self.preview_body.h or 1
	self.preview_offset = math.min(self.preview_offset, math.max(0, #(self.preview_lines or {}) - visible))
	ui.render()
end

function M:click() end

function M:touch() end

-- `plugin metaclean preview` reports what would be removed without
-- writing anything.
function M:entry(job)
	local preview = job and job.args and job.args[1] == "preview"
	if ya.target_os() ~= "macos" then
		notify("This plugin currently supports macOS only", "error")
		return
	end
	local roots = selected_or_hovered()
	if #roots == 0 then
		notify("Nothing selected or hovered", "warn")
		return
	end
	local missing = missing_tool()
	if missing then
		notify("MetaClean needs " .. missing .. " on the PATH", "error")
		return
	end
	local files, seen, packages, has_directory = {}, {}, {}, false
	for _, root in ipairs(roots) do
		local cha = fs.cha(Url(root), false)
		has_directory = has_directory or (cha and cha.is_dir and not cha.is_link) or false
		local ok, err = walk(root, files, seen, packages)
		if not ok then
			notify("Traversal failed: " .. tostring(err), "error")
			return
		end
	end
	if #files == 0 then
		notify(#packages > 0 and "Only app packages selected; nothing to sanitize" or "No files to sanitize", "warn")
		return
	end
	if not preview and (#files > 1 or has_directory) and not confirm(#files, has_directory) then
		return
	end
	if #files > 1 then
		notify(string.format(preview and "Checking %d files…" or "Cleaning %d files…", #files))
	end
	local sanitized, unchanged, failures, removals, next_file = 0, 0, {}, {}, 1
	local clean_files = {}
	-- Large batches report progress at each quarter.
	local done, quarter = 0, #files >= 200 and 1 or 4
	-- Workers share the queue; Lua runs one of them at a time between yields.
	local function worker(id)
		return function()
			while next_file <= #files do
				local index = next_file
				next_file = index + 1
				local path = files[index]
				local name = path:match("([^/]+)$") or path
				local ok, result, removed = process_file(path, id, preview)
				if ok and result == "unchanged" then
					unchanged = unchanged + 1
					clean_files[#clean_files + 1] = { path = path }
				elseif ok then
					sanitized = sanitized + 1
					removals[#removals + 1] = { index = index, name = name, path = path, removed = removed }
				else
					failures[#failures + 1] = { index = index, name = name, path = path, reason = tostring(result) }
				end
				done = done + 1
				if quarter < 4 and done >= #files * quarter / 4 then
					quarter = quarter + 1
					ya.notify({
						title = TITLE,
						content = string.format("%d of %d files %s…", done, #files, preview and "checked" or "done"),
						timeout = 3,
					})
				end
			end
		end
	end
	local cores = command("sysctl", { "-n", "hw.ncpu" })
	cores = cores and cores.status.success and tonumber(cores.stdout:match("%d+")) or 4
	local workers = {}
	for id = 1, math.min(LIMIT.WORKERS, cores, #files) do
		workers[id] = worker(id)
	end
	ya.join(table.unpack(workers))
	if preview then
		PREVIEW.show(PREVIEW.report(roots[1]:match("^(.*)/[^/]*$"), removals, clean_files, failures))
		return
	end

	-- Entries grouped by key, the most common first, each with an example
	-- file; at most limit groups, then a count of the rest.
	local function grouped(entries, keys, limit, lines)
		table.sort(entries, function(a, b)
			return a.index < b.index
		end)
		local groups, order = {}, {}
		for _, entry in ipairs(entries) do
			local counted = {}
			for _, key in ipairs(keys(entry)) do
				local group = groups[key]
				if not group then
					group = { key = key, name = entry.name, count = 0, first = #order + 1 }
					groups[key], order[#order + 1] = group, group
				end
				if not counted[key] then
					counted[key], group.count = true, group.count + 1
				end
			end
		end
		table.sort(order, function(a, b)
			return a.count > b.count or a.count == b.count and a.first < b.first
		end)
		for index = 1, math.min(limit, #order) do
			local group = order[index]
			local example = group.count == 1 and group.name or group.name .. " and " .. (group.count - 1) .. " more"
			lines[#lines + 1] = string.format("%s (%s)", group.key, example)
		end
		if #order > limit then
			lines[#lines + 1] = string.format("and %d more reasons", #order - limit)
		end
	end
	local lines = { string.format("%d sanitized, %d already clean", sanitized, unchanged) }
	if #failures > 0 then
		lines[1] = lines[1] .. string.format(", %d skipped", #failures)
	end
	-- One file: its name and outcome.
	local name = #files == 1 and (files[1]:match("([^/]+)$") or files[1])
	local level = #failures > 0 and "warn" or "info"
	if name and #failures == 1 then
		lines = { string.format("%s skipped: %s", name, failures[1].reason) }
		failures = {}
	elseif name and unchanged == 1 then
		lines = { name .. " is already clean" }
	elseif name then
		lines = { name .. " cleaned" }
	end
	if #failures > 0 then
		grouped(failures, function(entry)
			return { entry.reason }
		end, 3, lines)
	end
	ya.notify({ title = TITLE, content = table.concat(lines, "\n"), level = level, timeout = #lines > 1 and 10 or 5 })
end

-- Laboratory-only hooks let the isolated runner drive this exact production
-- implementation through adapters for Yazi's async APIs.
M._test = {
	process_file = process_file,
	identity_residue = identity_residue,
	asf = ASF,
	icc = ICC,
	tiff = TIFF,
	file_sha256 = file_sha256,
	walk = walk,
	policies = POLICIES,
	checked_add = checked_add,
	validate_ranges = validate_ranges,
	merge_adjacent_ranges = merge_adjacent_ranges,
	binary_reader = binary_reader,
	crc32 = crc32,
	minimal_exif = minimal_exif,
	svg_parse = svg_parse,
	quicktime_parse = quicktime_parse,
	preview_report = PREVIEW.report,
	quicktime_verify = quicktime_verify,
	heif_parse = heif_parse,
	verify_regions = verify_regions,
	audio = AUDIO,
	ogg_parse = OGG.parse,
}

return M
