--- @since 26.9.1
--- @sync entry
-- Subtitle and translate the hovered video with on-device Apple speech and translation models,
-- detecting the spoken language.

local M = {}

local HOME = os.getenv("HOME")
local CONFIG = os.getenv("YAZI_CONFIG_HOME") or (HOME .. "/.config/yazi")
local PLUGIN = CONFIG .. "/plugins/translate-macos.yazi"
local SOURCES = { "translate.swift", "speech-spi.swiftinterface", "build.sh" }
local CACHE = HOME .. "/Library/Caches/translate-macos"
local HELPER = CACHE .. "/translate"

local DEFAULT_LANGUAGES = { "ja", "ko", "zh", "es", "fr", "de", "it", "pt", "ru" }
local DEFAULT_TARGET = "en"
local KEYS = "123456789abcdefghijklmnopqrstuvwxyz"

-- The task's progress bar runs over this many units, all of them the helper's.
-- Building the helper on first use takes no share; the task log says so.
local UNITS = 1000

local NAMES = {
	ar = "Arabic",
	ca = "Catalan",
	cs = "Czech",
	da = "Danish",
	de = "German",
	el = "Greek",
	en = "English",
	es = "Spanish",
	fi = "Finnish",
	fr = "French",
	he = "Hebrew",
	hi = "Hindi",
	hr = "Croatian",
	hu = "Hungarian",
	id = "Indonesian",
	it = "Italian",
	ja = "Japanese",
	ko = "Korean",
	ms = "Malay",
	nb = "Norwegian",
	nl = "Dutch",
	pl = "Polish",
	pt = "Portuguese",
	ro = "Romanian",
	ru = "Russian",
	sk = "Slovak",
	sv = "Swedish",
	th = "Thai",
	tr = "Turkish",
	uk = "Ukrainian",
	vi = "Vietnamese",
	yue = "Cantonese",
	zh = "Chinese",
}

local VIDEO_EXTS = {
	mp4 = true,
	mkv = true,
	avi = true,
	mov = true,
	webm = true,
	flv = true,
	wmv = true,
	m4v = true,
	ts = true,
	mts = true,
	mpg = true,
	mpeg = true,
	ogv = true,
	f4v = true,
}

local function notify(content, level, timeout)
	ya.notify({
		title = "Translate",
		content = content,
		level = level,
		timeout = timeout,
	})
end

local function paths(path)
	local dir, file = path:match("^(.+)/([^/]+)$")
	dir, file = dir or ".", file or path

	local stem = file:gsub("%.[^%.]+$", "")
	return file, dir .. "/" .. stem .. ".srt"
end

local function trim(s)
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function name(code)
	local lang = code:match("^(%a+)")
	return lang and NAMES[lang:lower()] or code
end

-- Feeds the task's progress bar a fraction of the whole. Yazi adds up what it is
-- sent, so only the difference from the last report goes out.
local function meter(task)
	local sent = 0
	return function(fraction)
		local units = math.min(math.floor(fraction * UNITS), UNITS)
		if units > sent then
			task:progress({ processed = units - sent })
			sent = units
		end
	end
end

-- Compiles the Swift helper on first use, and again whenever the plugin is updated.
local function ensure_helper(task, id)
	local newest = 0
	for _, name in ipairs(SOURCES) do
		local cha = fs.cha(Url(PLUGIN .. "/" .. name))
		if not cha then
			error("Missing " .. PLUGIN .. "/" .. name)
		end
		newest = math.max(newest, cha.mtime or 0)
	end

	local helper = fs.cha(Url(HELPER))
	if helper and (helper.mtime or 0) >= newest then
		return
	end

	task:log("Building the speech helper")
	fs.create("dir_all", Url(CACHE))

	local temp = HELPER .. "." .. tostring(id)
	local output, err = Command("/bin/sh"):arg({ PLUGIN .. "/build.sh", temp }):output()
	if not output then
		error("Failed to build the helper: " .. tostring(err))
	end
	if output.status.code ~= 0 then
		local msg = trim(output.stderr):match("error: ([^\n]+)") or trim(output.stderr)
		error("Building the helper failed (needs the Xcode Command Line Tools): " .. msg)
	end

	local ok, rename_err = fs.rename(Url(temp), Url(HELPER))
	if not ok then
		error("Failed to install the helper: " .. tostring(rename_err))
	end
end

-- Runs the helper and follows its output: `progress <0-1>`, `stage <text>`, `cue` for
-- every subtitle written, `done <summary>` at the end, and a `tick` every quarter
-- second, which lets a cancel from the task manager be noticed promptly. Returns the
-- summary, or nil when the task was cancelled.
local function translate(task, args, progress)
	local srt = args[2]
	local existed = fs.cha(Url(srt)) ~= nil
	local child, err = Command(HELPER):arg(args):stdout(Command.PIPED):stderr(Command.PIPED):spawn()
	if not child then
		error("Failed to run translator: " .. tostring(err))
	end

	local summary, errors, wrote = nil, {}, false
	while true do
		-- Cancelled from the task manager: `acquire` turns false. Stop the helper, and
		-- remove the subtitles it had started, as a failed run would. (`read_line_with`
		-- loses lines after a timeout in Yazi 26.9, hence the helper's ticks.)
		if not task:acquire() then
			child:start_kill()
			child:wait()
			if wrote or not existed then
				fs.remove("file", Url(srt))
			end
			return nil
		end

		local line, event = child:read_line()
		if event == 0 then
			line = trim(line)
			local fraction = line:match("^progress ([%d.]+)$")
			if fraction then
				progress(tonumber(fraction))
			elseif line == "cue" then
				wrote = true
				task:progress({ success = 1 })
			elseif line:sub(1, 6) == "stage " then
				task:log(line:sub(7))
			elseif line:sub(1, 5) == "done " then
				summary = line:sub(6)
			end
		elseif event == 1 then
			errors[#errors + 1] = trim(line)
		else
			break
		end
	end

	local status = child:wait()
	if not status or not status.success then
		local msg = table.concat(errors, "\n")
		error(msg ~= "" and msg or ("Translator exited with code " .. tostring(status and status.code)))
	end
	return summary or "Subtitles written"
end

-- In the task manager, a translation's bar shows the subtitles written so far and has
-- its percentage on the right, where other tasks show a count.
local function show_percent()
	if Tasks._translate_percent then
		return
	end
	Tasks._translate_percent = true

	local progress = Tasks.progress
	function Tasks:progress(snap)
		local label, count, failed = progress(self, snap)
		if snap.prog.kind == "Custom" and snap.percent and snap.title:sub(1, 10) == "Translate " then
			local written = snap.prog.success == 1 and "1 subtitle" or snap.prog.success .. " subtitles"
			return written, string.format("%d%%", math.floor(snap.percent)), failed
		end
		return label, count, failed
	end
end

---@param opts? {languages?: string[], target?: string}
function M:setup(opts)
	show_percent()

	if opts and type(opts) ~= "table" then
		return
	end

	local languages = (opts and opts.languages) or DEFAULT_LANGUAGES
	local target = (opts and opts.target) or DEFAULT_TARGET
	if type(languages) ~= "table" or #languages == 0 or #languages > #KEYS then
		return
	end
	if type(target) ~= "string" or target == "" then
		return
	end

	self.languages = languages
	self.target = target
end

-- Runs from the picker on: asks for the language if needed, then translates as a task
-- of its own in the task manager.
local function start(path, source, languages, target)
	if source == "pick" then
		local cands = {}
		for i, code in ipairs(languages) do
			cands[i] = { on = KEYS:sub(i, i), desc = name(code) }
		end

		local choice = ya.which({ cands = cands })
		if not choice then
			return
		end
		source = languages[choice]
	end

	-- No scope: a cancel then reaches `translate` through `acquire` instead of
	-- dropping it, so it can stop the helper and clean up.
	local filename, srt = paths(path)
	local task =
		ya.task("custom", { pool = "plugin", track = true, progress = true }):name("Translate " .. filename):spawn()
	if not task:acquire() then
		return
	end

	local from = source == "auto" and "Detecting language" or name(source)
	notify(filename .. ": " .. from .. " → " .. name(target), "info", 2)

	-- Yazi 26.9 only shows the bar once `total` is set. The count beside it is the
	-- subtitles written, and `total` grows with it.
	local progress = meter(task)
	task:progress({ workload = UNITS, total = 1 })

	local ok, result = pcall(function()
		ensure_helper(task, task.id)
		return translate(task, { path, srt, source, target }, progress)
	end)
	if ok and not result then
		return
	elseif not ok then
		local msg = tostring(result):gsub("^.-:%d+: ", "")
		notify(msg, "error", 6)
		task:fail(msg)
		return
	end

	progress(1)
	notify(result, "info", 3)
	task:succeed({ Url(srt) })
end

-- A sync entry, so the plugin itself doesn't sit in the task manager; the work runs
-- in `start`.
function M:entry(job)
	if ya.target_os() ~= "macos" then
		notify("This plugin only supports macOS", "error", 3)
		return
	end

	local hovered = cx.active.current.hovered
	if not hovered then
		notify("No file hovered", "error", 3)
		return
	end

	local path = tostring(hovered.url)
	local ext = (path:match("%.([^%.]+)$") or ""):lower()
	if not VIDEO_EXTS[ext] then
		notify("Not a video file", "error", 3)
		return
	end

	if not self.languages then
		self:setup()
	end

	-- The spoken language is detected unless one is given (`-- ja`), or asked for (`-- pick`).
	local source = job.args[1] or "auto"
	local languages, target = self.languages, self.target
	ya.async(function()
		start(path, source, languages, target)
	end)
end

return M
