--- @since 26.9.1
-- Archive info: previews an archive's stats and tests its integrity with
-- 7-Zip, in the same layout as mediainfo.yazi. A multi-volume set is opened
-- from its first volume and every volume is checked for gaps and size
-- mismatches, so a broken set names the bad part.

local M = {}

local BINS = { "7zz", "7z" }
local POLL_MS = 250
local MAX_ITEMS = 2000
local MAX_ERR = 200
local MAX_SHOWN = 10

-- Single-stream compressors whose one member may be a tar worth listing.
local STREAM = {
	gzip = true,
	bzip2 = true,
	xz = true,
	zstd = true,
	lzma = true,
	lz4 = true,
	lzip = true,
	brotli = true,
	Z = true,
}

local hovered = ya.sync(function()
	local h = cx.active.current.hovered
	return h and tostring(h.url)
end)

local load = ya.sync(function(st, key)
	return st.cache and st.cache[key]
end)

local save = ya.sync(function(st, key, value)
	st.cache, st.order = st.cache or {}, st.order or {}
	if not st.cache[key] then
		st.order[#st.order + 1] = key
	end
	st.cache[key] = value
	while #st.order > 128 do
		st.cache[table.remove(st.order, 1)] = nil
	end
end)

local function has(s, sub)
	return s:find(sub, 1, true) ~= nil
end

local function human(n)
	if not n then
		return "?"
	end
	local units, i = { "B", "KiB", "MiB", "GiB", "TiB" }, 1
	while n >= 1024 and i < #units do
		n, i = n / 1024, i + 1
	end
	return i == 1 and string.format("%d B", n) or string.format("%.1f %s", n, units[i])
end

local function bytes(n)
	return n and n >= 1024 and string.format("%s (%d bytes)", human(n), n) or human(n)
end

-- Volume sets -----------------------------------------------------------------

-- Recognizes a volume name: returns the set kind, base name, part number and
-- digit width. A bare .zip is a set's last volume (-1), a bare .rar its first.
local function classify(name)
	local l = name:lower()
	local base, n = name:match("^(.+)%.(%d%d%d+)$")
	if base then
		return "split", base, tonumber(n), #n
	end
	base, n = l:match("^(.+)%.part(%d+)%.rar$")
	if base then
		return "rarpart", name:sub(1, #base), tonumber(n), #n
	end
	base, n = l:match("^(.+)%.z(%d%d+)$")
	if base then
		return "zip", name:sub(1, #base), tonumber(n), #n
	end
	if l:match("%.zip$") then
		return "zip", name:sub(1, -5), -1, 0
	end
	base, n = l:match("^(.+)%.r(%d%d+)$")
	if base then
		return "rar", name:sub(1, #base), tonumber(n) + 1, #n
	end
	if l:match("%.rar$") then
		return "rar", name:sub(1, -5), 0, 0
	end
end

local function volume_name(kind, base, i, w)
	if kind == "split" then
		return string.format("%s.%0" .. w .. "d", base, i)
	elseif kind == "rarpart" then
		return string.format("%s.part%0" .. w .. "d.rar", base, i)
	elseif kind == "zip" then
		return i < 0 and base .. ".zip" or string.format("%s.z%02d", base, i)
	end
	return i == 0 and base .. ".rar" or string.format("%s.r%02d", base, i - 1)
end

-- Finds every sibling volume of `file` in order, with placeholders for gaps.
-- Returns nil for a file that isn't part of a multi-volume set. A bare .zip
-- or .rar is far more common than a set, so without `force` one stat of its
-- first sibling decides whether the folder is read at all.
local function scan(file, force)
	local kind, base, idx, width = classify(file.name)
	if not kind then
		return
	end
	local dir = file.url.parent
	if not force and idx <= 0 and kind ~= "split" and not fs.cha(dir:join(volume_name(kind, base, 1, 2))) then
		return
	end

	local found, w = {}, nil
	for _, f in ipairs(fs.read_dir(dir, {}) or {}) do
		local k, b, i, fw = classify(f.name)
		if k == kind and b == base and (kind ~= "split" or fw == width) and not f.cha.is_dir then
			-- read_dir's entries carry no size, so stat each volume.
			local cha = fs.cha(f.url, true)
			found[i] = { name = f.name, size = cha and cha.len or 0 }
			w = i > 0 and (w or fw) or w
		end
	end

	local last = kind == "zip" and (found[-1] or { name = base .. ".zip", missing = true })
	found[-1] = nil
	local hi = -1
	for i in pairs(found) do
		hi = math.max(hi, i)
	end
	if hi < 0 or (kind == "rar" and hi == 0) then
		return
	end

	local vols = {}
	for i = (kind == "rar" or (kind == "split" and found[0])) and 0 or 1, hi do
		vols[#vols + 1] = found[i] or { name = volume_name(kind, base, i, w or 2), missing = true }
	end
	vols[#vols + 1] = last or nil
	local target = vols[kind == "zip" and #vols or 1]
	return { kind = kind, vols = vols, target = not target.missing and target.name or nil }
end

-- 7-Zip output ----------------------------------------------------------------

local function spawn(args, stdin, bin)
	for _, b in ipairs(bin and { bin } or BINS) do
		local cmd = Command(b):arg(args):stdout(Command.PIPED):stderr(Command.PIPED)
		local child = (stdin and cmd:stdin(stdin) or cmd):spawn()
		if child then
			return child, b
		end
	end
end

-- Streams a child's stdout to `feed` until it exits. Returns nil, after
-- stopping the child and `upstream`, if the hover moves away first.
local function collect(child, url, feed, upstream)
	local err = {}
	while true do
		local line, ev = child:read_line_with({ timeout = POLL_MS })
		line = line and line:gsub("\r?\n$", "")
		if ev == 0 then
			feed(line)
		elseif ev == 1 then
			err[#err + 1] = #err < MAX_ERR and line or nil
		elseif ev ~= 3 then
			break
		elseif hovered() ~= url then
			child:start_kill()
			if upstream then
				upstream:start_kill()
			end
			return
		end
	end
	local status = child:wait()
	return { err = err, code = status and status.code }
end

-- Parses `7z l -slt` output into archive layers, item stats and messages.
-- `fallback` names an item 7-Zip lists without a path, like an .xz stream.
local function parser(fallback)
	local p = {
		layers = {},
		msgs = {},
		items = {},
		where = {},
		methods = {},
		s = { total = 0, files = 0, dirs = 0, size = 0, enc_files = 0 },
	}
	local layer, block, item, in_items

	function p.finish()
		local it, s = item, p.s
		item = nil
		if not it then
			return
		end
		it.Path = it.Path or fallback or ""
		local dir = it.Folder == "+" or (it.Attributes or ""):sub(1, 1) == "D"
		local size, enc = tonumber(it.Size), it.Encrypted == "+"
		s.total = s.total + 1
		if dir then
			s.dirs = s.dirs + 1
		else
			s.files, s.size = s.files + 1, s.size + (size or 0)
			s.enc_files = s.enc_files + (enc and 1 or 0)
			if size and size > (s.largest or -1) then
				s.largest, s.largest_path = size, it.Path
			end
		end
		if it.Method and it.Method ~= "" then
			p.methods[it.Method] = true
		end
		local mtime = (it.Modified or ""):sub(1, 16)
		if mtime ~= "" then
			s.oldest = (not s.oldest or mtime < s.oldest) and mtime or s.oldest
			s.newest = (not s.newest or mtime > s.newest) and mtime or s.newest
		end
		if (it["Volume Index"] or "") ~= "" then
			p.where[it.Path] =
				{ vol = tonumber(it["Volume Index"]), off = tonumber(it.Offset), len = tonumber(it["Packed Size"]) }
		end
		if #p.items < MAX_ITEMS then
			p.items[#p.items + 1] = { path = it.Path, size = size, dir = dir, enc = enc }
		end
	end

	function p.feed(line)
		local k, v = line:match("^(.-) = (.*)$")
		if line == "----------" then
			in_items = true
		elseif in_items then
			-- Items are separated by blank lines.
			if line == "" or (k == "Path" and item and item.Path) then
				p.finish()
			end
			if k then
				item = item or {}
				item[k] = v
			end
		elseif line == "--" then
			layer, block = {}, nil
			p.layers[#p.layers + 1] = layer
		elseif line == "----" then
			layer, block = nil, nil
		elseif layer and k then
			block = nil
			layer[#layer + 1] = { k, v }
			if k == "ERROR" then
				p.msgs[#p.msgs + 1] = { "error", v }
			end
		elseif layer and (line == "WARNINGS:" or line == "ERRORS:") then
			block = line == "ERRORS:" and "error" or "warn"
		elseif block and line ~= "" then
			p.msgs[#p.msgs + 1] = { block, line }
		end
	end

	return p
end

local function prop(layer, key)
	for _, kv in ipairs(layer or {}) do
		if kv[1] == key then
			return kv[2]
		end
	end
end

-- Reduces 7-Zip's stderr to messages. Item errors ("ERROR: <msg> : <file>")
-- go to `items`; everything else, such as open failures, to the return value.
local function messages(lines, path, items)
	local out, seen, name = {}, {}, path:match("([^/]+)$")
	for _, m in ipairs(lines) do
		if m:sub(1, 7) == "ERROR: " then
			m = m:sub(8)
			if m:sub(1, #path) == path then
				m = m:sub(#path + 1):gsub("^ : ", "")
			elseif items and m:match("^.- : .+$") then
				local msg, file = m:match("^(.-) : (.+)$")
				items[#items + 1] = { msg = msg, file = file }
				m = ""
			end
		end
		m = m:gsub("^Open ERROR: ", "")
		if has(m, " ") and not m:match("^[%a' ]+: %d+$") and m ~= path and m ~= name and not seen[m] then
			seen[m] = true
			out[#out + 1] = m
		end
	end
	return out
end

-- Analysis --------------------------------------------------------------------

-- Adds a problem once; 7-Zip repeats some messages across its outputs.
local function problem(r, level, text)
	text = text:gsub(" : ", ": ")
	for _, pr in ipairs(r.problems) do
		if pr[2] == text then
			return
		end
	end
	r.problems[#r.problems + 1] = { level, text }
	r.vol_errors = r.vol_errors + (r.in_volumes and level == "error" and 1 or 0)
end

local function check_volumes(r, set)
	r.vols, r.disk, r.in_volumes = set.vols, 0, true
	local present = {}
	for _, v in ipairs(set.vols) do
		r.disk = r.disk + (v.size or 0)
		if v.missing then
			problem(r, "error", "Missing volume: " .. v.name)
		else
			present[#present + 1] = v
		end
	end

	-- Every volume but the last is written at the same size.
	local ref, last = present[1] and present[1].size, present[#present]
	for i = 2, #present - 1 do
		local v = present[i]
		if v.size ~= ref then
			v.note = string.format("%s, others %s", human(v.size), human(ref))
			local level = set.kind == "rar" and "warn" or "error"
			problem(r, level, string.format("%s is %s, the other volumes are %s", v.name, human(v.size), human(ref)))
		end
	end
	if #present > 1 and last.size > ref then
		last.note = "larger than the others"
		problem(r, "warn", last.name .. " is larger than the other volumes")
	elseif #present > 1 and set.kind == "split" and last.size == ref then
		r.full_last = last.name
	end
	r.in_volumes = nil
end

-- Names the volumes that hold a damaged file's data, when 7-Zip records where
-- the file starts. Offsets can't be placed once a volume is missing.
local function locate(r, w)
	if not r.vols or not w or not w.vol or r.vol_errors > 0 then
		return
	end
	local vols, starts, at = r.vols, {}, 0
	for i, v in ipairs(vols) do
		starts[i], at = at, at + v.size
	end
	local first = vols[w.vol + 1]
	if not first then
		return
	elseif not w.off or not w.len then
		first.bad = true
		return "starts in " .. first.name
	end

	local lo = starts[w.vol + 1] + w.off
	local hi = lo + math.max(w.len, 1) - 1
	local a, b
	for i, v in ipairs(vols) do
		if starts[i] <= hi and starts[i] + v.size > lo then
			a, b, v.bad = a or v, v, true
		end
	end
	return a and (a == b and "data in " .. a.name or string.format("data in %s to %s", a.name, b.name))
end

local function encryption(p, header)
	if header then
		return "contents and file names"
	elseif p.s.enc_files == 0 then
		return "none"
	end
	local zc, aes = false, false
	for m in pairs(p.methods) do
		zc, aes = zc or has(m, "ZipCrypto"), aes or (has(m, "AES") and not has(m, "ZipCrypto"))
	end
	local kinds = (aes and ", AES" or "") .. (zc and ", ZipCrypto (weak)" or "")
	local s = p.s
	return (s.enc_files == s.files and "all files" or string.format("%d of %d files", s.enc_files, s.files)) .. kinds
end

-- Takes over a parser's results: stats, layers and messages.
local function absorb(r, p)
	local methods = {}
	for m in pairs(p.methods) do
		methods[#methods + 1] = m
	end
	table.sort(methods)
	r.s, r.items, r.methods = p.s, p.items, table.concat(methods, ", ")
	for _, layer in ipairs(p.layers) do
		r.layers[#r.layers + 1] = layer
	end
	for _, m in ipairs(p.msgs) do
		problem(r, m[1], m[2])
	end
end

-- 7-Zip reports "Headers Error" for the extended-attribute records macOS tar
-- writes. When bsdtar reads every header cleanly, that is only a note.
local function cross_check_tar(r, path)
	for i, pr in ipairs(r.problems) do
		if pr[2] == "Headers Error" and pr[1] == "warn" and has(r.format, "tar") then
			local status = Command("bsdtar"):arg({ "-tf", path }):status()
			if status and status.success then
				r.problems[i] =
					{ "info", "7-Zip flags extended tar headers (macOS attributes); bsdtar reads them all cleanly" }
			end
			return
		end
	end
end

-- Returns the status label, its level and a one-line summary.
local function judge(r)
	local hard, warn, locked, failed = 0, 0, 0, 0
	for _, pr in ipairs(r.problems) do
		hard, warn = hard + (pr[1] == "error" and 1 or 0), warn + (pr[1] == "warn" and 1 or 0)
	end
	for _, e in ipairs(r.failures or {}) do
		if has(e.msg, "Wrong password") then
			locked = locked + 1
		else
			failed = failed + 1
		end
	end
	local first, files = r.problems[1] and r.problems[1][2], r.s and r.s.files or 0

	if not r.opened then
		if r.header_encrypted then
			return "LOCKED", "warn", "File names are encrypted: nothing can be checked without the password"
		end
		return r.vol_errors > 0 and "INCOMPLETE" or "BROKEN", "error", first or "7-Zip can't open it"
	elseif r.vol_errors > 0 then
		return "INCOMPLETE",
			"error",
			first .. (r.vol_errors > 1 and string.format(" (+%d more)", r.vol_errors - 1) or "")
	elseif r.stream_error then
		return "BROKEN", "error", "The compressed stream is damaged"
	elseif failed > 0 then
		return "BROKEN", "error", string.format("%d of %d files failed the test", failed, files)
	elseif hard > 0 then
		return "BROKEN", "error", first
	elseif locked >= files and locked > 0 then
		return "ENCRYPTED", "warn", "Structure OK; contents can't be verified without the password"
	elseif locked > 0 then
		return "PARTLY OK",
			"warn",
			string.format("%d files OK; %d encrypted files not verified", files - locked, locked)
	elseif r.no_checksum then
		return "NO CHECKSUM", "warn", r.no_checksum
	elseif warn > 0 then
		return "OK", "warn", "Test passed with warnings"
	end
	return "OK", "ok", r.ok_text or string.format("All %d files passed the test", files)
end

-- Rendering -------------------------------------------------------------------

local LEVEL_LABEL = { error = "Error", warn = "Warning", info = "Note" }

-- 7-Zip prints flags as +/- and sizes in bytes.
local function prop_value(k, v)
	if v == "+" or v == "-" then
		return v == "+" and "Yes" or "No"
	end
	return has(k, "Size") and v:match("^%d+$") and bytes(tonumber(v)) or v
end

-- Turns a result into plain rows: { l = label?, v = value, s = style? }.
-- Rows are what gets cached, so scrolling only restyles them.
local function rows_of(r)
	local rows = {}
	local function line(l, v, s, bold)
		rows[#rows + 1] = { l = l, v = tostring(v), s = s, b = bold }
	end
	local function title(t)
		rows[#rows + 1] = { v = "" }
		rows[#rows + 1] = { v = t, s = "title" }
	end

	local label, level, summary = "TESTING", "info", "Testing integrity…"
	if r.done then
		label, level, summary = judge(r)
	end
	local s = r.opened and r.s
	line("Status", label, level, true)
	line("Summary", summary, level)
	line("Format", r.format)
	line(r.vols and "Total size" or "File size", bytes(r.disk))
	if s then
		line("Unpacked size", bytes(s.size))
		if s.size > 0 then
			line("Compression ratio", string.format("%.1f%%", r.disk / s.size * 100))
		end
		line("Files", s.files)
		line("Folders", s.dirs)
		if r.methods ~= "" then
			line("Methods", r.methods)
		end
	end
	line("Encryption", r.encryption, r.encryption ~= "none" and r.encryption ~= "?" and "warn" or nil)
	if s and s.largest_path then
		line("Largest file", string.format("%s (%s)", s.largest_path, human(s.largest)))
	end
	if s and s.oldest then
		line("Modified", s.oldest == s.newest and s.oldest or s.oldest .. " to " .. s.newest)
	end

	if #r.problems > 0 then
		title("Problems")
		for _, pr in ipairs(r.problems) do
			line(LEVEL_LABEL[pr[1]], pr[2], pr[1])
		end
	end

	if r.vols then
		title(string.format("Volumes (%d)", #r.vols))
		for _, v in ipairs(r.vols) do
			if v.missing then
				line(v.name, "missing", "error")
			elseif v.bad then
				line(v.name, human(v.size) .. ", holds part of a damaged file", "error")
			else
				line(v.name, v.note or human(v.size), v.note and "warn" or nil)
			end
		end
	end

	for _, layer in ipairs(r.layers) do
		title(prop(layer, "Type") or "Archive")
		for _, kv in ipairs(layer) do
			if kv[1] ~= "Type" and kv[1] ~= "Path" and kv[2] ~= "" then
				line(kv[1], prop_value(kv[1], kv[2]))
			end
		end
	end

	if s and #r.items > 0 then
		title(string.format("Contents (%d)", s.total))
		local failed = {}
		for _, e in ipairs(r.failures or {}) do
			failed[e.file] = not has(e.msg, "Wrong password") and e.msg or nil
		end
		for _, it in ipairs(r.items) do
			if failed[it.path] then
				line(it.path, failed[it.path], "error")
			elseif it.dir then
				line(it.path .. "/", "folder")
			else
				line(it.path, human(it.size) .. (it.enc and ", encrypted" or ""), it.enc and "warn" or nil)
			end
		end
		if s.total > #r.items then
			line(nil, string.format("… %d more", s.total - #r.items), "title")
		end
	end
	return rows
end

-- Same look as mediainfo.yazi: section titles, then "Label: value" lines with
-- a bold label and the value in the theme's table colour.
local function render(job, rows)
	local st = {
		title = th.spot.title or ui.Style():fg("green"),
		label = ui.Style():fg("reset"):bold(),
		value = th.spot.tbl_col or ui.Style():fg("blue"),
		ok = ui.Style():fg("green"),
		warn = ui.Style():fg("yellow"),
		error = ui.Style():fg("red"),
		info = ui.Style():fg("cyan"),
	}
	local wrap = rt.preview.wrap == "yes" or rt.preview.wrap == ui.Wrap.YES
	local w, h = math.max(1, job.area.w), job.area.h

	-- Skip is counted in screen rows, so a wrapped line scrolls as a block.
	local lines, at, full = {}, 0, false
	for _, row in ipairs(rows) do
		local text = row.l and row.l .. ": " .. row.v or row.v
		local height = wrap and math.max(1, math.ceil(ui.width(text) / w)) or 1
		full = full or (at >= job.skip and at - job.skip + height > h)
		if at >= job.skip and not full then
			local style = row.s and st[row.s] or st.value
			style = row.b and style:bold() or style
			lines[#lines + 1] = row.l
					and ui.Line({ ui.Span(row.l .. ": "):style(st.label), ui.Span(row.v):style(style) })
				or ui.Line(row.v):style(style)
		end
		at = at + height
	end

	if job.skip > 0 and at - job.skip < h then
		return ya.emit("peek", { math.max(0, at - h), only_if = job.file.url, upper_bound = true })
	end
	ya.preview_widget(job, {
		ui.Clear(job.area),
		ui.Text(lines):area(job.area):wrap(wrap and ui.Wrap.YES or ui.Wrap.NO),
	})
end

-- Checking --------------------------------------------------------------------

-- Lists a compressed tar through a pipe: the decompressor checks the stream's
-- checksum while the lister reads the tar headers. Returns false if the hover
-- moved away.
local function test_tar(r, url, path, kind, bin)
	local up = spawn({ "x", "-so", "-bd", "-bsp0", "-p", "--", path }, nil, bin)
	local down = up and spawn({ "l", "-slt", "-ttar", "-si", "-sccUTF-8", "-bsp0" }, up:take_stdout(), bin)
	if not down then
		problem(r, "error", "Couldn't start 7-Zip to read the tar inside")
		return true
	end
	local q = parser()
	local inner = collect(down, url, q.feed, up)
	if not inner then
		return false
	end
	q.finish()

	-- The decompressor's errors are about the stream, not a file in the tar,
	-- and the lister failing on a cut-off stream adds nothing.
	local out, up_err, stream = up:wait_with_output(), {}, {}
	for l in ((out and out.stderr) or ""):gmatch("[^\r\n]+") do
		up_err[#up_err + 1] = l
	end
	messages(up_err, path, stream)
	if stream[1] then
		r.stream_error = true
		problem(r, "error", stream[1].msg .. " in the " .. kind .. " stream: it is truncated or damaged")
	else
		for _, m in ipairs(messages(inner.err, "-", r.failures)) do
			problem(r, "error", m)
		end
	end
	absorb(r, q)
	r.format, r.encryption = r.format .. " > tar", encryption(q)
	r.ok_text = string.format("Stream checksum OK, %d tar entries read", q.s.total)
	return true
end

-- Returns false if the hover moved away.
local function test(r, url, path, kind, bin)
	if kind == "tar" then
		-- The listing already read every header, and tar has nothing else to test.
		r.ok_text = "Tar headers OK (tar stores no data checksums)"
		return true
	end
	local t = spawn({ "t", "-bd", "-bso0", "-bsp0", "-sccUTF-8", "-p", "--", path }, nil, bin)
	local res = t and collect(t, url, function() end)
	if t and not res then
		return false
	end
	local other = messages(res and res.err or {}, path, r.failures)
	for _, m in ipairs(other) do
		problem(r, "error", m)
	end
	if res and res.code ~= 0 and #r.failures == 0 and #other == 0 then
		problem(r, "error", "7-Zip's test exited with code " .. tostring(res.code))
	end
	if kind == "Split" then
		r.no_checksum = "Volumes are complete, but split data carries no checksum"
	elseif STREAM[kind] then
		r.ok_text = "Stream checksum OK"
	end
	return true
end

-- Reports each damaged file and, where possible, the volumes holding it.
local function report_failures(r, where)
	local shown, placed = 0, false
	for _, e in ipairs(r.failures) do
		if not has(e.msg, "Wrong password") then
			local at = locate(r, where[e.file])
			placed, shown = placed or at ~= nil, shown + 1
			-- With a volume missing, every unreadable file is the same problem.
			if r.vol_errors == 0 and shown <= MAX_SHOWN then
				problem(r, "error", string.format("%s: %s%s", e.msg, e.file, at and "  (" .. at .. ")" or ""))
			end
		end
	end
	if r.vol_errors > 0 and shown > 0 then
		problem(r, "error", string.format("%d files can't be read until the set is complete", shown))
	elseif shown > MAX_SHOWN then
		problem(r, "error", string.format("… and %d more damaged files", shown - MAX_SHOWN))
	end
	if r.vols and shown > 0 and r.vol_errors == 0 and not placed then
		problem(r, "info", "This format doesn't record where each file sits, so the damaged volume can't be named")
	end
end

-- Returns display rows, or nil if the hover moved away first.
local function check(job, url, set, target)
	local file, path = job.file, tostring(target.path)
	local r = { problems = {}, layers = {}, failures = {}, vol_errors = 0, disk = file.cha.len, done = true }
	r.format, r.encryption = "?", "?"
	if set then
		check_volumes(r, set)
		if not set.target then
			return rows_of(r)
		end
	end

	local p = parser(((target.name or ""):gsub("%.[^.]+$", "")))
	local child, bin = spawn({ "l", "-slt", "-sccUTF-8", "-bsp0", "-p", "--", path })
	if not child then
		problem(r, "error", "7-Zip isn't installed: neither 7zz nor 7z could start")
		return rows_of(r)
	end
	local res = collect(child, url, p.feed)
	if not res then
		return
	end
	p.finish()

	-- 7-Zip found volumes the quick check in scan() skipped, like a set whose
	-- .z01 is missing.
	local last = p.layers[#p.layers]
	if not set and (prop(last, "Multivolume") == "+" or tonumber(prop(last, "Volumes") or 1) > 1) then
		set = scan(file, true)
		if set then
			check_volumes(r, set)
		end
	end

	local open = messages(res.err, path)
	for _, m in ipairs(open) do
		r.header_encrypted = r.header_encrypted or has(m, "Wrong password")
		problem(r, r.header_encrypted and "warn" or "error", m)
	end
	if r.full_last and #open > 0 then
		problem(r, "warn", "Later volumes may be missing: " .. r.full_last .. " is full-sized")
	end
	r.opened = #open == 0 and #p.layers > 0
	local types = {}
	for _, layer in ipairs(p.layers) do
		types[#types + 1] = prop(layer, "Type")
	end
	r.format = table.concat(types, " > ")
	if r.format == "" then
		-- A split volume's own extension is its number; use the one before.
		local name = set and set.kind == "split" and target.stem or target.name
		r.format = ((name or ""):match("%.([^.]+)$") or "?") .. " (by extension)"
	end
	r.encryption = (r.header_encrypted or #open == 0) and encryption(p, r.header_encrypted) or "?"
	absorb(r, p)
	if not r.opened then
		return rows_of(r)
	end

	r.done = false
	render(job, rows_of(r))
	r.done = true

	local kind = prop(last, "Type")
	local tar_inside = STREAM[kind] and p.s.total == 1 and p.items[1].path:lower():match("%.tar$")
	if not (tar_inside and test_tar or test)(r, url, path, kind, bin) then
		return
	end
	report_failures(r, p.where)
	cross_check_tar(r, path)
	return rows_of(r)
end

-- Results are cached under the hovered file, and under its volume set so
-- every part of a set shares one test. The folder's mtime catches volumes
-- being added or removed.
function M:peek(job)
	local file, url = job.file, tostring(job.file.url)
	local dir = fs.cha(file.url.parent)
	local key = table.concat({ url, file.cha.len, tostring(file.cha.mtime), tostring(dir and dir.mtime) }, "\0")
	local rows = load(key)

	if not rows then
		local set = scan(file)
		local target = set and set.target and file.url.parent:join(set.target) or file.url
		local set_key = set and tostring(target) .. "\0" .. key:match("[^\0]*$")
		for _, v in ipairs(set and set.vols or {}) do
			set_key = set_key .. "\0" .. v.name .. "=" .. tostring(v.size)
		end
		rows = set_key and load(set_key) or check(job, url, set, target)
		if not rows then
			return
		end
		save(key, rows)
		if set_key then
			save(set_key, rows)
		end
		if hovered() ~= url then
			return
		end
	end
	render(job, rows)
end

function M:seek(job)
	require("code"):seek(job)
end

return M
