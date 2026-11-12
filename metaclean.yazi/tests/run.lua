-- MetaClean laboratory runner. Run from the repository root:
--   lua metaclean.yazi/tests/run.lua
-- It only creates or removes paths under metaclean.yazi/tests/working.

-- The paths below are relative to the repository root; from anywhere else
-- the runner would create a second test tree, so it stops first.
local plugin_file = io.open("metaclean.yazi/main.lua", "r")
if not plugin_file then
	io.stderr:write("run from the repository root: lua metaclean.yazi/tests/run.lua\n")
	os.exit(2)
end
plugin_file:close()

local ROOT = "metaclean.yazi/tests"
local WORKING = ROOT .. "/working"
local ORIGINALS = ROOT .. "/originals"
local REPORTS = ROOT .. "/reports"
local RUN_ID = "run-" .. os.date("!%Y%m%dT%H%M%SZ")
local RUN = WORKING .. "/" .. RUN_ID

local tests, started = {}, os.time()

local function quote(value)
	return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function execute(args)
	local command = {}
	for _, value in ipairs(args) do
		command[#command + 1] = quote(value)
	end
	local pipe = assert(io.popen(table.concat(command, " ") .. " 2>&1", "r"))
	local out = pipe:read("*a")
	local ok, _, code = pipe:close()
	return ok, out, code
end

-- The production Command API keeps stdout and stderr separate. The ordinary
-- fixture helper intentionally combines them for useful failure diagnostics,
-- but the adapter's simulated binary pipelines must not feed producer stderr
-- (for example BSD dd's transfer summary) into a SHA-256 consumer.
local function execute_stdout(args)
	local command = {}
	for _, value in ipairs(args) do
		command[#command + 1] = quote(value)
	end
	local pipe = assert(io.popen(table.concat(command, " ") .. " 2>/dev/null", "r"))
	local out = pipe:read("*a")
	local ok, _, code = pipe:close()
	return ok, out, code
end

local function inside(path, base)
	return path:sub(1, #base + 1) == base .. "/"
end

local function mkdir(path)
	assert(inside(path, ROOT) or path == ROOT, "unsafe mkdir")
	local ok, out = execute({ "mkdir", "-p", "--", path })
	assert(ok, out)
end

local function safe_remove(path)
	assert(inside(path, WORKING), "refusing cleanup outside laboratory working root")
	assert(path:find("/run%-", 1, false), "refusing cleanup without run marker")
	local ok, out = execute({ "rm", "-rf", "--", path })
	assert(ok, out)
end

-- METACLEAN_ONLY=text runs only the tests whose name contains text.
local ONLY = os.getenv("METACLEAN_ONLY")

local function record(name, fn)
	if ONLY and not name:find(ONLY, 1, true) then
		return
	end
	local began = os.clock()
	local ok, err = xpcall(fn, debug.traceback)
	tests[#tests + 1] =
		{ name = name, state = ok and "passed" or "failed", detail = ok and "" or err, seconds = os.clock() - began }
end

local function sha(path)
	local ok, out = execute({ "shasum", "-a", "256", "--", path })
	assert(ok, out)
	return assert(out:match("^(%x+)"))
end

local function absolute(path)
	local ok, cwd = execute({ "pwd", "-P" })
	assert(ok, cwd)
	return cwd:gsub("%s+$", "") .. "/" .. path
end

local function neutral_timestamp()
	local ok, out = execute({ "date", "-j", "-f", "%m/%d/%Y %I:%M:%S %p", "01/01/2001 12:00:00 AM", "+%s" })
	assert(ok, out)
	return assert(out:match("%-?%d+"))
end

local function generate()
	mkdir(ORIGINALS)
	local jpg = ORIGINALS .. "/identity.jpg"
	local oriented_jpg = ORIGINALS .. "/oriented.jpg"
	local png = ORIGINALS .. "/identity.png"
	local apng = ORIGINALS .. "/identity.apng"
	local icc_png = ORIGINALS .. "/icc.png"
	local heic = ORIGINALS .. "/identity.heic"
	local avif = ORIGINALS .. "/identity.avif"
	local gif = ORIGINALS .. "/identity.gif"
	local bmp = ORIGINALS .. "/identity.bmp"
	local ico = ORIGINALS .. "/identity.ico"
	local svg = ORIGINALS .. "/identity.svg"
	local tiff = ORIGINALS .. "/identity.tiff"
	local mp4 = ORIGINALS .. "/identity.mp4"
	local mp4_safe = ORIGINALS .. "/mp4-safe.mp4"
	local m4v_safe = ORIGINALS .. "/m4v-safe.m4v"
	local m4a_safe = ORIGINALS .. "/m4a-safe.m4a"
	local mov = ORIGINALS .. "/identity.mov"
	local mov_safe = ORIGINALS .. "/mov-safe.mov"
	if not io.open(jpg, "rb") then
		assert(execute({
			"ffmpeg",
			"-hide_banner",
			"-loglevel",
			"error",
			"-f",
			"lavfi",
			"-i",
			"testsrc2=s=96x64:r=1",
			"-frames:v",
			"1",
			"-q:v",
			"2",
			"-y",
			jpg,
		}))
		assert(execute({
			"exiftool",
			"-overwrite_original",
			"-GPSLatitude=37.3317",
			"-GPSLongitude=-122.0307",
			"-Artist=MetaClean Test User",
			"-Model=Test Camera",
			"-BodySerialNumber=SERIAL-TEST-001",
			"-DateTimeOriginal=2020:01:02 03:04:05",
			"-Comment=private comment",
			jpg,
		}))
	end
	if not io.open(oriented_jpg, "rb") then
		assert(execute({ "cp", "-c", "-p", "--", jpg, oriented_jpg }))
		assert(execute({ "exiftool", "-overwrite_original", "-Orientation#=6", oriented_jpg }))
	end
	if not io.open(png, "rb") then
		assert(execute({
			"ffmpeg",
			"-hide_banner",
			"-loglevel",
			"error",
			"-f",
			"lavfi",
			"-i",
			"color=c=red@0.5:s=32x32",
			"-frames:v",
			"1",
			"-pix_fmt",
			"rgba",
			"-y",
			png,
		}))
		assert(execute({
			"exiftool",
			"-overwrite_original",
			"-PNG:Author=MetaClean Test User",
			"-PNG:Comment=private comment",
			"-PNG:CreationTime=2020:01:02 03:04:05",
			png,
		}))
	end
	if not io.open(icc_png, "rb") then
		assert(execute({
			"sips",
			"--embedProfile",
			"/System/Library/ColorSync/Profiles/Display P3.icc",
			png,
			"--out",
			icc_png,
		}))
		assert(execute({ "exiftool", "-overwrite_original", "-PNG:Author=MetaClean Test User", icc_png }))
	end
	if not io.open(apng, "rb") then
		assert(execute({
			"ffmpeg",
			"-hide_banner",
			"-loglevel",
			"error",
			"-f",
			"lavfi",
			"-i",
			"testsrc2=s=64x48:r=4",
			"-t",
			"1",
			"-plays",
			"0",
			"-f",
			"apng",
			"-y",
			apng,
		}))
		assert(execute({
			"exiftool",
			"-overwrite_original",
			"-PNG:Author=MetaClean Test User",
			"-PNG:Comment=private comment",
			"-PNG:CreationTime=2020:01:02 03:04:05",
			apng,
		}))
	end
	if not io.open(heic, "rb") then
		assert(execute({ "sips", "-s", "format", "heic", png, "--out", heic }))
		assert(execute({
			"exiftool",
			"-overwrite_original",
			"-GPSLatitude=37.3317",
			"-GPSLongitude=-122.0307",
			"-Artist=MetaClean Test User",
			"-Model=Test Camera",
			"-BodySerialNumber=SERIAL-TEST-001",
			"-DateTimeOriginal=2020:01:02 03:04:05",
			"-Comment=private comment",
			heic,
		}))
	end
	if not io.open(avif, "rb") then
		assert(execute({
			"ffmpeg",
			"-hide_banner",
			"-loglevel",
			"error",
			"-f",
			"lavfi",
			"-i",
			"testsrc2=s=64x48",
			"-frames:v",
			"1",
			"-c:v",
			"libsvtav1",
			"-y",
			avif,
		}))
		assert(execute({
			"exiftool",
			"-overwrite_original",
			"-Artist=MetaClean Test User",
			"-Model=Test Camera",
			"-Comment=private comment",
			avif,
		}))
	end
	if not io.open(gif, "rb") then
		assert(execute({
			"ffmpeg",
			"-hide_banner",
			"-loglevel",
			"error",
			"-f",
			"lavfi",
			"-i",
			"testsrc2=s=64x48:r=4",
			"-t",
			"1",
			"-vf",
			"fps=4",
			"-loop",
			"0",
			"-y",
			gif,
		}))
		assert(execute({ "exiftool", "-overwrite_original", "-Comment=MetaClean Test User", gif }))
	end
	if not io.open(bmp, "rb") then
		assert(execute({
			"ffmpeg",
			"-hide_banner",
			"-loglevel",
			"error",
			"-f",
			"lavfi",
			"-i",
			"testsrc2=s=64x48",
			"-frames:v",
			"1",
			"-pix_fmt",
			"bgr24",
			"-y",
			bmp,
		}))
	end
	if not io.open(ico, "rb") then
		assert(execute({ "sips", "-s", "format", "ico", png, "--out", ico }))
	end
	if not io.open(svg, "rb") then
		local file = assert(io.open(svg, "wb"))
		file:write(
			'<svg xmlns="http://www.w3.org/2000/svg" width="32" height="16"><metadata>MetaClean Test User</metadata><rect width="32" height="16" fill="#f00"/></svg>'
		)
		file:close()
	end
	if not io.open(tiff, "rb") then
		assert(execute({
			"ffmpeg",
			"-hide_banner",
			"-loglevel",
			"error",
			"-f",
			"lavfi",
			"-i",
			"testsrc2=s=64x48",
			"-frames:v",
			"1",
			"-c:v",
			"tiff",
			"-y",
			tiff,
		}))
		assert(execute({
			"exiftool",
			"-overwrite_original",
			"-Artist=MetaClean Test User",
			"-Comment=private comment",
			"-Model=Test Camera",
			tiff,
		}))
	end
	if not io.open(mp4, "rb") then
		assert(execute({
			"ffmpeg",
			"-hide_banner",
			"-loglevel",
			"error",
			"-f",
			"lavfi",
			"-i",
			"testsrc2=s=96x64:r=10",
			"-f",
			"lavfi",
			"-i",
			"sine=f=440:r=48000",
			"-t",
			"1",
			"-c:v",
			"libx264",
			"-c:a",
			"aac",
			"-shortest",
			"-metadata",
			"artist=MetaClean Test User",
			"-metadata",
			"comment=private comment",
			"-y",
			mp4,
		}))
	end
	if not io.open(mp4_safe, "rb") then
		assert(execute({
			"ffmpeg",
			"-hide_banner",
			"-loglevel",
			"error",
			"-f",
			"lavfi",
			"-i",
			"testsrc2=s=96x64:r=10",
			"-f",
			"lavfi",
			"-i",
			"sine=f=500:r=48000",
			"-t",
			"1",
			"-c:v",
			"libx264",
			"-c:a",
			"aac",
			"-shortest",
			"-movflags",
			"use_metadata_tags",
			"-metadata",
			"artist=MetaClean Test User",
			"-metadata",
			"title=Private MP4 title",
			"-y",
			mp4_safe,
		}))
	end
	if not io.open(m4v_safe, "rb") then
		assert(execute({
			"ffmpeg",
			"-hide_banner",
			"-loglevel",
			"error",
			"-f",
			"lavfi",
			"-i",
			"testsrc2=s=96x64:r=10",
			"-f",
			"lavfi",
			"-i",
			"sine=f=520:r=48000",
			"-t",
			"1",
			"-c:v",
			"libx264",
			"-c:a",
			"aac",
			"-shortest",
			"-movflags",
			"use_metadata_tags",
			"-metadata",
			"artist=MetaClean Test User",
			"-metadata",
			"title=Private M4V title",
			"-f",
			"ipod",
			"-y",
			m4v_safe,
		}))
	end
	if not io.open(m4a_safe, "rb") then
		assert(execute({
			"ffmpeg",
			"-hide_banner",
			"-loglevel",
			"error",
			"-f",
			"lavfi",
			"-i",
			"sine=f=600:r=48000",
			"-t",
			"1",
			"-c:a",
			"aac",
			"-movflags",
			"use_metadata_tags",
			"-metadata",
			"artist=MetaClean Test User",
			"-metadata",
			"title=Private M4A title",
			"-f",
			"ipod",
			"-y",
			m4a_safe,
		}))
	end
	if not io.open(mov, "rb") then
		assert(execute({
			"ffmpeg",
			"-hide_banner",
			"-loglevel",
			"error",
			"-f",
			"lavfi",
			"-i",
			"testsrc2=s=96x64:r=10",
			"-f",
			"lavfi",
			"-i",
			"sine=f=660:r=48000",
			"-t",
			"1",
			"-c:v",
			"libx264",
			"-c:a",
			"aac",
			"-shortest",
			"-metadata",
			"artist=MetaClean Test User",
			"-metadata",
			"comment=private MOV comment",
			"-metadata",
			"title=Private MOV title",
			"-f",
			"mov",
			"-y",
			mov,
		}))
	end
	if not io.open(mov_safe, "rb") then
		assert(execute({
			"ffmpeg",
			"-hide_banner",
			"-loglevel",
			"error",
			"-f",
			"lavfi",
			"-i",
			"testsrc2=s=96x64:r=10",
			"-f",
			"lavfi",
			"-i",
			"sine=f=550:r=48000",
			"-t",
			"1",
			"-c:v",
			"libx264",
			"-c:a",
			"aac",
			"-shortest",
			"-metadata",
			"artist=MetaClean Test User",
			"-metadata",
			"title=Private MOV title",
			"-f",
			"mov",
			"-y",
			mov_safe,
		}))
	end
	return jpg,
		oriented_jpg,
		png,
		icc_png,
		apng,
		heic,
		avif,
		gif,
		bmp,
		ico,
		svg,
		tiff,
		mp4,
		mp4_safe,
		m4v_safe,
		m4a_safe,
		mov,
		mov_safe
end

local function framehash(path, map)
	local ok, out = execute({
		"ffmpeg",
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
		"sha256",
		"-",
	})
	assert(ok, out)
	local manifest = {}
	for line in out:gmatch("[^\r\n]+") do
		-- FFmpeg may report a pre-existing malformed metadata sidecar while
		-- still decoding the same frame. Compare its deterministic framehash
		-- records, not diagnostic text.
		if line:match("^#") or line:match("^%d+,") then
			manifest[#manifest + 1] = line
		end
	end
	assert(#manifest > 0, out)
	return table.concat(manifest, "\n")
end

local function animation_manifest(path)
	local ok, out = execute({
		"ffprobe",
		"-v",
		"error",
		"-count_frames",
		"-show_entries",
		"stream=codec_name,width,height,nb_read_frames,avg_frame_rate,time_base:frame=best_effort_timestamp_time,pkt_duration_time",
		"-of",
		"json",
		path,
	})
	assert(ok, out)
	return out
end

-- Run a command with stdout and stderr captured separately, like the
-- production Command API does.
local stderr_counter = 0
local function execute_split(args)
	local command = {}
	for _, value in ipairs(args) do
		command[#command + 1] = quote(value)
	end
	stderr_counter = stderr_counter + 1
	local stderr_path = RUN .. "/.stderr-" .. tostring(stderr_counter)
	local pipe = assert(io.popen(table.concat(command, " ") .. " 2>" .. quote(stderr_path), "r"))
	local out = pipe:read("a")
	local ok, _, code = pipe:close()
	local file = io.open(stderr_path, "rb")
	local err = file and file:read("a") or ""
	if file then
		file:close()
	end
	os.remove(stderr_path)
	return ok, out, err, code
end

-- Load main.lua with a thin adapter for the Yazi APIs. The commands it runs
-- are real installed utilities and all paths supplied by tests stay in RUN.
-- This verifies the production transaction instead of duplicating its policy.
local function production_plugin(on_command)
	local old = { Command = _G.Command, Url = _G.Url, fs = _G.fs, ya = _G.ya, cx = _G.cx, ui = _G.ui }
	local trace = {}

	_G.Url = function(path)
		return path
	end
	local command_api = { PIPED = {}, NULL = {} }
	setmetatable(command_api, {
		__call = function(_, name)
			local args = { name }
			local command = {}
			local stdin
			function command:arg(values)
				if type(values) ~= "table" then
					values = { values }
				end
				for _, value in ipairs(values) do
					args[#args + 1] = value
				end
				return self
			end
			function command:stdout()
				return self
			end
			function command:stderr()
				return self
			end
			function command:stdin(value)
				stdin = value
				return self
			end
			function command:env()
				return self
			end
			function command:output()
				trace[#trace + 1] = table.concat(args, " ")
				local injected = on_command and on_command(args, #trace)
				if injected then
					return { status = { success = injected.success }, stdout = injected.output or "", stderr = "" }
				end
				local ok, out, err = execute_split(args)
				return { status = { success = ok == true }, stdout = out, stderr = err }
			end
			function command:spawn()
				trace[#trace + 1] = table.concat(args, " ")
				local injected = on_command and on_command(args, #trace)
				local child = { args = args, stdin = stdin, injected = injected, read_offset = 1 }
				function child:run_once()
					if self.completed then
						return self.success, self.stdout
					end
					if self.killed or (self.injected and self.injected.kill) then
						self.completed, self.success, self.stdout, self.stderr =
							true, false, "", "simulated process kill"
						return false, ""
					end
					local command_args = self.args
					if type(self.stdin) == "table" and self.stdin._child then
						local parent = self.stdin._child
						local parent_ok, parent_output = parent:run_once()
						if not parent_ok then
							self.completed, self.success, self.stdout, self.stderr =
								true, false, "", parent.stderr or "manifest producer failed"
							return false, ""
						end
						stderr_counter = stderr_counter + 1
						local input = RUN .. "/.pipeline-" .. tostring(stderr_counter)
						local file = assert(io.open(input, "wb"))
						file:write(parent_output)
						file:close()
						command_args = {}
						for _, value in ipairs(self.args) do
							command_args[#command_args + 1] = value
						end
						command_args[#command_args + 1] = input
					end
					local ok, out, err
					if self.injected then
						ok, out, err = self.injected.success, self.injected.output or "", self.injected.stderr or ""
					else
						ok, out, err = execute_split(command_args)
					end
					self.completed, self.success = true, ok == true
					self.stdout, self.stderr = out, err
					return self.success, self.stdout
				end
				function child:take_stdout()
					if self.stdout_taken or (self.injected and self.injected.no_stdout) then
						return nil
					end
					self.stdout_taken = true
					return { _child = self }
				end
				function child:read(length)
					self:run_once()
					-- Like Yazi 26.9, return data as an array of byte values.
					local function bytes(text)
						return { text:byte(1, -1) }
					end
					if self.read_offset <= #self.stdout then
						local data = self.stdout:sub(self.read_offset, self.read_offset + math.min(length, 8000) - 1)
						self.read_offset = self.read_offset + #data
						return bytes(data), 0
					end
					if not self.stderr_sent and self.stderr ~= "" then
						self.stderr_sent = true
						return bytes(self.stderr:sub(1, 8000)), 1
					end
					return {}, 2
				end
				function child:wait()
					local ok = self:run_once()
					return { success = ok }, ok and nil or self.stderr
				end
				function child:wait_with_output()
					local ok = self:run_once()
					return { status = { success = ok }, stdout = self.stdout or "", stderr = self.stderr or "" },
						ok and nil or self.stderr
				end
				function child:start_kill()
					if not self.completed then
						self.killed = true
					end
					return true
				end
				return child
			end
			return command
		end,
	})
	_G.Command = command_api
	_G.ya = {
		sync = function(fn)
			return fn
		end,
		notify = function() end,
		sleep = function(seconds)
			execute({ "sleep", tostring(seconds) })
		end,
		-- Runs the functions one after another; real Yazi interleaves them.
		join = function(...)
			local results = {}
			for index, fn in ipairs({ ... }) do
				results[index] = fn()
			end
			return table.unpack(results, 1, select("#", ...))
		end,
		confirm = function()
			return true
		end,
		target_os = function()
			return "macos"
		end,
	}
	_G.ui = {
		Line = function(value)
			return value
		end,
		Text = function(lines)
			return {
				wrap = function(self)
					return self
				end,
				lines = lines,
			}
		end,
		Wrap = { YES = true },
	}
	_G.fs = {
		cha = function(path)
			local ok, out = execute({ "stat", "-f", "%HT|%l", path })
			if not ok then
				return nil, out
			end
			local kind, nlink = out:match("^([^|]+)|(%d+)")
			return {
				is_dir = kind == "Directory",
				is_link = kind == "Symbolic Link",
				is_block = kind == "Block Device",
				is_char = kind == "Character Device",
				is_fifo = kind == "FIFO",
				is_sock = kind == "Socket",
				nlink = tonumber(nlink),
			}
		end,
		unique = function(_, template)
			local candidate, suffix = template, 0
			while true do
				if execute({ "mkdir", "--", candidate }) then
					return candidate
				end
				suffix = suffix + 1
				candidate = template .. "_" .. suffix
				if suffix > 100 then
					return nil, "too many staging collisions"
				end
			end
		end,
		remove = function(_, path)
			return execute({ "rm", "-rf", "--", path })
		end,
		read_dir = function(path)
			local ok, out = execute({ "find", "-P", path, "-mindepth", "1", "-maxdepth", "1", "-print" })
			if not ok then
				return nil, out
			end
			local entries = {}
			for child in out:gmatch("[^\r\n]+") do
				entries[#entries + 1] = { url = child }
			end
			return entries
		end,
		rename = function(from, to)
			return execute({ "mv", "-f", "--", from, to })
		end,
	}

	local plugin = assert(dofile("metaclean.yazi/main.lua"))
	return plugin,
		function()
			_G.Command, _G.Url, _G.fs, _G.ya, _G.cx, _G.ui = old.Command, old.Url, old.fs, old.ya, old.cx, old.ui
		end,
		trace
end

local function json_string(value)
	return '"'
		.. tostring(value):gsub('[%c"\\]', function(c)
			local named = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
			return named[c] or string.format("\\u%04x", c:byte())
		end)
		.. '"'
end

-- Fixture helpers ----------------------------------------------------------------

local function copy_fixture(source, name)
	local destination = RUN .. "/" .. name
	assert(execute({ "cp", "-c", "--", source, destination }))
	return absolute(destination)
end

local function read_bytes(path)
	local file = assert(io.open(path, "rb"))
	local data = file:read("a")
	file:close()
	return data
end

local function write_bytes(path, data)
	local file = assert(io.open(path, "wb"))
	file:write(data)
	file:close()
end

local function exiftool(args)
	local full = { "exiftool", "-q", "-overwrite_original" }
	for _, arg in ipairs(args) do
		full[#full + 1] = arg
	end
	local ok, out = execute(full)
	assert(ok, out)
end

-- Every tag ExifTool reports outside the filesystem and ExifTool groups.
local function tags(path, extra)
	local args = { "exiftool", "-config", "", "-s", "-G1", "-a", "-u", "-n", "-api", "requestall=2" }
	for _, arg in ipairs(extra or {}) do
		args[#args + 1] = arg
	end
	args[#args + 1] = "--"
	args[#args + 1] = path
	local ok, out = execute(args)
	assert(ok, out)
	local lines = {}
	for line in out:gmatch("[^\r\n]+") do
		if not line:match("^%[System%]") and not line:match("^%[MacOS%]") and not line:match("^%[ExifTool%]") then
			lines[#lines + 1] = line
		end
	end
	return table.concat(lines, "\n")
end

local function assert_absent(text, needles)
	for _, needle in ipairs(needles) do
		assert(not text:find(needle, 1, true), "identity value remains: " .. needle .. "\n" .. text)
	end
end

local function assert_present(text, needles)
	for _, needle in ipairs(needles) do
		assert(text:find(needle, 1, true), "expected value missing: " .. needle .. "\n" .. text)
	end
end

local function no_stage_left()
	local ok, stages = execute({ "find", RUN, "-name", ".metaclean-stage*", "-print" })
	assert(ok and not stages:match("%S"), "stage directory left behind: " .. stages)
end

local function process(path, on_command)
	local plugin, restore = production_plugin(on_command)
	local ok, result, detail = pcall(plugin._test.process_file, path)
	restore()
	assert(ok, result)
	no_stage_left()
	return result, detail
end

local function assert_sanitized(path, on_command)
	local result, detail = process(path, on_command)
	assert(result == true and detail == "sanitized", "expected sanitized, got: " .. tostring(detail))
end

local function assert_skipped(path, pattern)
	local before = sha(path)
	local result, detail = process(path)
	assert(result == nil, "expected a skip, got: " .. tostring(detail))
	assert(not pattern or tostring(detail):find(pattern), "unexpected skip reason: " .. tostring(detail))
	assert(sha(path) == before, "skipped file changed")
	return detail
end

-- A cleaned file whose dates changed again (a copy, a download) only gets
-- neutral dates; its content stays byte-identical.
local function assert_redated(path)
	local data = read_bytes(path)
	assert(execute({ "touch", path }))
	assert_sanitized(path)
	assert(read_bytes(path) == data, "already clean content changed")
end

local function neutral_dates(path)
	local ok, out = execute({ "stat", "-f", "%m|%B", path })
	assert(ok, out)
	local expected = neutral_timestamp()
	assert(out:gsub("%s+$", "") == expected .. "|" .. expected, "file dates not neutral: " .. out)
end

local function png_chunks(data)
	local chunks, position = {}, 9
	while position <= #data do
		local length = string.unpack(">I4", data, position)
		chunks[#chunks + 1] = data:sub(position + 4, position + 7)
		position = position + 12 + length
	end
	return table.concat(chunks, ",")
end

local function crc_chunk(crc32, kind, payload)
	return string.pack(">I4", #payload) .. kind .. payload .. string.pack(">I4", crc32(kind .. payload))
end

-- Insert chunks before the first IDAT of a PNG.
local function png_insert(data, crc32, inserted)
	local idat = assert(data:find("IDAT", 9, true)) - 4
	local parts = {}
	for _, chunk in ipairs(inserted) do
		parts[#parts + 1] = crc_chunk(crc32, chunk[1], chunk[2])
	end
	return data:sub(1, idat - 1) .. table.concat(parts) .. data:sub(idat)
end

local function main()
	mkdir(WORKING)
	mkdir(REPORTS)
	if execute({ "test", "-d", RUN }) then
		safe_remove(RUN)
	end
	mkdir(RUN)
	local marker = assert(io.open(RUN .. "/.metaclean-lab", "w"))
	marker:write("MetaClean disposable test run\n")
	marker:close()
	local jpg, oriented_jpg, png, icc_png, apng, heic, avif, gif, bmp, ico, svg, tiff, mp4, mp4_safe, m4v_safe, m4a_safe, mov, mov_safe =
		generate()
	local helpers = production_plugin()._test
	local crc32 = helpers.crc32

	record("laboratory boundary", function()
		assert(inside(RUN, WORKING))
		assert(sha(jpg) == sha(jpg), "pristine original changed")
	end)

	record("production isolates ExifTool configuration", function()
		local path = copy_fixture(jpg, "isolated-config.jpg")
		local exiftool_calls, isolated = 0, true
		assert_sanitized(path, function(args)
			if args[5] == "exiftool" then
				exiftool_calls = exiftool_calls + 1
				isolated = isolated and args[6] == "-config" and args[7] == ""
			end
		end)
		assert(exiftool_calls > 0 and isolated, "ExifTool ran without an isolated configuration")
	end)

	-- A second top-level local of the same name silently replaces the first
	-- for all code below it.
	record("production declares each top-level local once and stays under the limit", function()
		local seen, count = {}, 0
		for line in read_bytes("metaclean.yazi/main.lua"):gmatch("[^\n]+") do
			local name = line:match("^local function ([%w_]+)") or line:match("^local ([%w_]+)")
			if name and name ~= "function" then
				assert(not seen[name], "top-level local declared twice: " .. name)
				seen[name] = true
				local names = line:match("^local function") and "" or line:match("^local ([^=]*)") or ""
				count = count + 1 + select(2, names:gsub(",", ""))
			end
		end
		-- Lua allows 200 locals in the main chunk; new helpers go into a
		-- namespace table (ICC, ASF, AUDIO, ...) well before that.
		assert(count <= 197, "top-level locals near Lua's limit of 200: " .. count)
	end)

	record("source hash covers the file content", function()
		local a, b = RUN .. "/hash-a.bin", RUN .. "/hash-b.bin"
		write_bytes(a, string.rep("a", 100000))
		write_bytes(b, string.rep("a", 99999) .. "b")
		local digest_a, digest_b = helpers.file_sha256(absolute(a)), helpers.file_sha256(absolute(b))
		local _, expected = execute({ "shasum", "-a", "256", a })
		assert(digest_a == expected:match("^(%x+)"), "file hash differs from shasum")
		assert(digest_b and digest_a ~= digest_b, "file hash ignores the content")
		local path = copy_fixture(jpg, "hashed.jpg")
		local hashes = 0
		assert_sanitized(path, function(args)
			if args[5] == "/sbin/sha256" or args[5] == "shasum" then
				hashes = hashes + 1
				assert(args[#args]:sub(1, 1) == "/", "hash command without a file path")
			end
		end)
		assert(hashes > 0, "the source was not hashed")
	end)

	-- JPEG ---------------------------------------------------------------------

	record("JPEG transaction removes all identity metadata", function()
		local path = copy_fixture(jpg, "identity.jpg")
		local mn = RUN .. "/makernote.bin"
		write_bytes(mn, "Nikon\0\2\0\0\0MM\0*\0\0\0\8\0\1\0\1\0\2\0\0\0\4ABC\0\0\0\0\0")
		exiftool({
			"-Make=NIKON",
			"-MakerNotes<=" .. mn,
			"-EXIF:LensMake=Lens Maker",
			"-XMP-photoshop:City=Secret City",
			"-IPTC:Keywords=secret keyword",
			"-XMP-exif:DateTimeDigitized=2020:01:02 03:04:05",
			"-EXIF:OffsetTimeOriginal=+02:00",
			path,
		})
		local before = framehash(path)
		assert_present(tags(path), { "MakerNoteVersion", "Secret City", "Test Camera" })
		assert_sanitized(path)
		local after = tags(path)
		assert_absent(after, {
			"MetaClean Test User",
			"Test Camera",
			"SERIAL-TEST-001",
			"NIKON",
			"MakerNote",
			"Lens Maker",
			"Secret City",
			"secret keyword",
			"2020:01:02",
			"+02:00",
			"GPS",
			"private comment",
		})
		assert(framehash(path) == before, "decoded JPEG changed")
		neutral_dates(path)
	end)

	record("JPEG keeps orientation, ICC and colour metadata", function()
		local path = copy_fixture(oriented_jpg, "oriented.jpg")
		local icc_path = RUN .. "/icc.jpg"
		assert(execute({
			"sips",
			"--embedProfile",
			"/System/Library/ColorSync/Profiles/Display P3.icc",
			path,
			"--out",
			icc_path,
		}))
		icc_path = absolute(icc_path)
		exiftool({ "-Artist=MetaClean Test User", "-Orientation#=6", icc_path })
		local ok, icc_before = execute({ "exiftool", "-b", "-ICC_Profile", icc_path })
		assert(ok and #icc_before > 100, icc_before)
		assert_sanitized(icc_path)
		local _, icc_after = execute({ "exiftool", "-b", "-ICC_Profile", icc_path })
		assert(icc_after == icc_before, "ICC profile changed")
		local after = tags(icc_path)
		assert_present(after, { "[IFD0]          Orientation                     : 6" })
		assert_absent(after, { "MetaClean Test User" })
	end)

	record("JPEG ICC profile split into several segments is kept", function()
		local path = copy_fixture(jpg, "split-icc.jpg")
		exiftool({ "-ICC_Profile=", "-Artist=MetaClean Test User", path })
		local profile = read_bytes("/System/Library/ColorSync/Profiles/sRGB Profile.icc")
		local segments, count = {}, math.ceil(#profile / 1000)
		for index = 1, count do
			local chunk = profile:sub(index * 1000 - 999, index * 1000)
			segments[index] = "\255\226"
				.. string.pack(">I2", #chunk + 16)
				.. "ICC_PROFILE\0"
				.. string.char(index, count)
				.. chunk
		end
		local data = read_bytes(path)
		write_bytes(path, data:sub(1, 2) .. table.concat(segments) .. data:sub(3))
		assert(count > 1, "profile fits one segment")
		assert_sanitized(path)
		local ok, out = execute({ "exiftool", "-b", "-ICC_Profile", path })
		assert(ok and out == profile, "ICC profile changed")
		assert(not read_bytes(path):find("MetaClean", 1, true), "identity remains")
	end)

	record("CMYK JPEG keeps its Adobe colour transform", function()
		if not execute({ "which", "magick" }) then
			return
		end
		local path = RUN .. "/cmyk.jpg"
		assert(
			execute({ "magick", "-size", "32x32", "gradient:red-blue", "-colorspace", "CMYK", "-quality", "90", path })
		)
		path = absolute(path)
		exiftool({ "-Artist=MetaClean Test User", path })
		local before = framehash(path)
		assert_sanitized(path)
		assert_present(tags(path), { "[Adobe]", "ColorTransform" })
		assert(framehash(path) == before, "decoded CMYK JPEG changed")
	end)

	record("JPEG with a lone MPF index is cleaned", function()
		local path = copy_fixture(jpg, "mpf.jpg")
		local data = read_bytes(path)
		local payload = "MPF\0MM\0*\0\0\0\8\0\0\0\0\0\0"
		write_bytes(path, data:sub(1, 2) .. "\255\226" .. string.pack(">I2", #payload + 2) .. payload .. data:sub(3))
		assert_sanitized(path)
		assert(not read_bytes(path):find("MPF\0", 1, true), "MPF segment remains")
	end)

	-- MPF images are built by hand: a primary, an MPF index right after its
	-- SOI marker, and the appended images.
	local function jpeg_segment(marker, payload)
		return "\255" .. string.char(marker) .. string.pack(">I2", #payload + 2) .. payload
	end

	local function xmp_segment(body)
		return jpeg_segment(
			0xE1,
			"http://ns.adobe.com/xap/1.0/\0"
				.. '<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">'
				.. body
				.. "</rdf:RDF></x:xmpmeta>"
		)
	end

	local function mpf_fixture(name, primary, images)
		local count = 1 + #images
		local total = #primary + 4 + 4 + 50 + 16 * count
		local header = 2 + 8
		local entries, offset = { string.pack(">I4I4I4I2I2", 0x030000, total, 0, 0, 0) }, total
		for _, image in ipairs(images) do
			entries[#entries + 1] = string.pack(">I4I4I4I2I2", image.attributes, #image.data, offset - header, 0, 0)
			offset = offset + #image.data
		end
		local index = "MM\0*"
			.. string.pack(">I4I2", 8, 3)
			.. string.pack(">I2I2I4", 0xB000, 7, 4)
			.. "0100"
			.. string.pack(">I2I2I4I4", 0xB001, 4, 1, count)
			.. string.pack(">I2I2I4I4", 0xB002, 7, 16 * count, 50)
			.. string.pack(">I4", 0)
			.. table.concat(entries)
		local parts = { primary:sub(1, 2), jpeg_segment(0xE2, "MPF\0" .. index), primary:sub(3) }
		for _, image in ipairs(images) do
			parts[#parts + 1] = image.data
		end
		local path = RUN .. "/" .. name
		write_bytes(path, table.concat(parts))
		return absolute(path)
	end

	-- A small greyscale JPEG with identity metadata, for gain maps and previews.
	local function secondary_jpeg(name, segments)
		local path = RUN .. "/" .. name
		assert(execute({
			"ffmpeg",
			"-hide_banner",
			"-loglevel",
			"error",
			"-f",
			"lavfi",
			"-i",
			"testsrc2=s=48x32,format=gray",
			"-frames:v",
			"1",
			"-y",
			path,
		}))
		exiftool({ "-Artist=Gain Map Owner", "-Comment=private gain map comment", path })
		local data = read_bytes(path)
		return data:sub(1, 2) .. (segments or "") .. data:sub(3)
	end

	local function mpf_image(path, index)
		local ok, out = execute({ "exiftool", "-b", "-MPImage" .. index, path })
		assert(ok, out)
		return out
	end

	local function mpf_image_hash(path, index)
		local file = path .. ".mpf" .. index .. ".jpg"
		write_bytes(file, mpf_image(path, index))
		local hash = framehash(file)
		os.remove(file)
		return hash
	end

	local GAINMAP_XMP = '<rdf:Description rdf:about="" xmlns:hdrgm="http://ns.adobe.com/hdr-gain-map/1.0/"'
		.. ' hdrgm:Version="1.0" hdrgm:GainMapMax="2.5" hdrgm:HDRCapacityMax="2.5"/>'

	record("JPEG Ultra HDR gain map is kept and cleaned", function()
		local gainmap = secondary_jpeg("ultrahdr-gainmap.jpg", xmp_segment(GAINMAP_XMP))
		local primary = read_bytes(jpg)
		primary = primary:sub(1, 2)
			.. xmp_segment(
				'<rdf:Description rdf:about="" xmlns:hdrgm="http://ns.adobe.com/hdr-gain-map/1.0/"'
					.. ' xmlns:dc="http://purl.org/dc/elements/1.1/"'
					.. ' xmlns:Container="http://ns.google.com/photos/1.0/container/"'
					.. ' xmlns:Item="http://ns.google.com/photos/1.0/container/item/" hdrgm:Version="1.0">'
					.. "<dc:creator><rdf:Seq><rdf:li>Secret Creator</rdf:li></rdf:Seq></dc:creator>"
					.. "<Container:Directory><rdf:Seq>"
					.. '<rdf:li rdf:parseType="Resource"><Container:Item Item:Semantic="Primary" Item:Mime="image/jpeg"/></rdf:li>'
					.. '<rdf:li rdf:parseType="Resource"><Container:Item Item:Semantic="GainMap" Item:Mime="image/jpeg" Item:Length="'
					.. #gainmap
					.. '"/></rdf:li></rdf:Seq></Container:Directory></rdf:Description>'
			)
			.. primary:sub(3)
		local path = mpf_fixture("ultrahdr.jpg", primary, { { attributes = 0, data = gainmap } })
		local needles = { "MetaClean Test User", "Secret Creator", "Gain Map Owner", "private gain map comment" }
		local pixels, gainmap_pixels = framehash(path), mpf_image_hash(path, 2)
		write_bytes(RUN .. "/ultrahdr-gainmap-before.jpg", mpf_image(path, 2))
		assert_present(tags(path) .. tags(RUN .. "/ultrahdr-gainmap-before.jpg"), needles)
		assert_sanitized(path)
		local cleaned_gainmap = RUN .. "/ultrahdr-gainmap-after.jpg"
		write_bytes(cleaned_gainmap, mpf_image(path, 2))
		local after, after_gainmap = tags(path), tags(cleaned_gainmap)
		assert_absent(after .. after_gainmap, needles)
		assert(after:match("%[XMP%-hdrgm%]%s+Version%s+: ([^\n]+)") == "1.0", "hdrgm:Version lost")
		assert(after:match("NumberOfImages%s+: (%d+)") == "2", "MPF index lost")
		assert(
			tonumber(after:match("DirectoryItemLength%s+: (%d+)")) == #read_bytes(cleaned_gainmap),
			"Ultra HDR directory length is wrong"
		)
		assert(after_gainmap:match("GainMapMax%s+: ([^\n]+)") == "2.5", "gain map parameters lost")
		assert(framehash(path) == pixels, "primary image changed")
		assert(mpf_image_hash(path, 2) == gainmap_pixels, "gain map image changed")
		assert(select(2, process(path)) == "unchanged", "cleaned Ultra HDR file is not reported clean")
		local ok, out = execute({ "jpeginfo", "-c", path })
		assert(ok and out:find("OK", 1, true), out)
	end)

	record("JPEG Apple gain map keeps only the HDR maker note values", function()
		local apdi = '<rdf:Description rdf:about="" xmlns:apdi="http://ns.apple.com/pixeldatainfo/1.0/">'
			.. "<apdi:AuxiliaryImageType>urn:com:apple:photo:2020:aux:hdrgainmap</apdi:AuxiliaryImageType>"
			.. "</rdf:Description>"
		local gainmap = secondary_jpeg("apple-gainmap.jpg", xmp_segment(apdi))
		local primary_path = copy_fixture(jpg, "apple-primary.jpg")
		-- An Apple maker note with the HDR values and a photo identifier.
		local base = 14 + 2 + 4 * 12 + 4
		local note = "Apple iOS\0\0\1MM"
			.. string.pack(">I2", 4)
			.. string.pack(">I2I2I4i4", 0x0001, 9, 1, 14)
			.. string.pack(">I2I2I4I4", 0x000B, 2, 12, base)
			.. string.pack(">I2I2I4I4", 0x0021, 10, 1, base + 12)
			.. string.pack(">I2I2I4I4", 0x0030, 10, 1, base + 20)
			.. string.pack(">I4", 0)
			.. "SECRET-UUID\0"
			.. string.pack(">i4i4i4i4", 3, 2, 1, 100)
		write_bytes(RUN .. "/apple-makernote.bin", note)
		exiftool({ "-Make=Apple", "-MakerNotes<=" .. RUN .. "/apple-makernote.bin", primary_path })
		local path = mpf_fixture("apple-hdr.jpg", read_bytes(primary_path), { { attributes = 0, data = gainmap } })
		local before = tags(path)
		assert_present(before, { "[Apple]         HDRHeadroom                     : 1.5", "SECRET-UUID" })
		assert_sanitized(path)
		local after = tags(path)
		assert_present(after, {
			"[Apple]         HDRHeadroom                     : 1.5",
			"[Apple]         HDRGain                         : 0.01",
			"[Apple]         MakerNoteVersion                : 14",
		})
		assert_absent(after, { "SECRET-UUID", "MetaClean Test User", "[IFD0]          Make" })
		assert(select(2, process(path)) == "unchanged", "cleaned Apple HDR file is not reported clean")
		assert_redated(path)
	end)

	record("JPEG previews are dropped and other MPF images are skipped", function()
		local preview = secondary_jpeg("preview.jpg")
		local path = mpf_fixture("preview.jpg", read_bytes(jpg), { { attributes = 0x010001, data = preview } })
		local pixels = framehash(path)
		assert_sanitized(path)
		local data = read_bytes(path)
		assert(not data:find("MPF\0", 1, true), "MPF index remains")
		assert(select(2, data:gsub("\255\216", "")) == 1, "appended image remains")
		assert(framehash(path) == pixels, "primary image changed")
		local stereo = mpf_fixture("stereo.jpg", read_bytes(jpg), { { attributes = 0x020002, data = preview } })
		assert_skipped(stereo, "MPF image type")
		local extra = mpf_fixture("mpf-trailing.jpg", read_bytes(jpg), { { attributes = 0x010001, data = preview } })
		write_bytes(extra, read_bytes(extra) .. "appended private data")
		assert_sanitized(extra)
		assert(not read_bytes(extra):find("appended private data", 1, true), "trailing data remains")
		-- Padding and a JPEG appended without an MPF index, as older cameras
		-- write them, are removed too.
		local padded = copy_fixture(jpg, "padded.jpg")
		write_bytes(padded, read_bytes(padded) .. string.rep("\0", 300) .. preview .. string.rep("\255", 20))
		assert_sanitized(padded)
		assert(read_bytes(padded):sub(-2) == "\255\217", "trailing data remains")
		assert(framehash(padded) == pixels, "primary image changed")
	end)

	record("JPEG trailing data is removed unless it is a Motion Photo", function()
		local path = copy_fixture(jpg, "trailer.jpg")
		local pixels = framehash(path)
		write_bytes(path, read_bytes(path) .. string.rep("\0", 40) .. "file://localhost/C:/Private/Notes.txt")
		assert_sanitized(path)
		assert(not read_bytes(path):find("Private", 1, true), "trailing data remains")
		assert(read_bytes(path):sub(-2) == "\255\217", "file does not end at the end marker")
		assert(framehash(path) == pixels, "primary image changed")
		local samsung = copy_fixture(jpg, "samsung.jpg")
		write_bytes(samsung, read_bytes(samsung) .. "\0\0MotionPhoto_Data\0\0\0\0SEFHSEFT")
		assert_skipped(samsung, "Samsung")
		local motion = copy_fixture(jpg, "motion.jpg")
		write_bytes(motion, read_bytes(motion) .. "\0\0\0\24ftypmp42\0\0\0\0mp42isom")
		assert_skipped(motion, "video")
	end)

	record("JPEG without an end marker is cleaned and gets one", function()
		local path = copy_fixture(jpg, "no-eoi.jpg")
		local data = read_bytes(path)
		assert(data:sub(-2) == "\255\217", "fixture lacks an end marker")
		write_bytes(path, data:sub(1, -3))
		local pixels = framehash(path)
		assert_sanitized(path)
		local cleaned = read_bytes(path)
		assert(not cleaned:find("MetaClean Test User", 1, true), "Artist remains")
		assert(cleaned:sub(-2) == "\255\217", "end marker not added")
		assert(framehash(path) == pixels, "image changed")
		assert(select(2, process(path)) == "unchanged", "cleaned JPEG is not reported clean")
		-- A scan cut inside a marker is refused.
		write_bytes(path, data:sub(1, -2))
		assert_skipped(path, "truncated JPEG scan")
	end)

	record("JPEG JFXX thumbnails are removed", function()
		local path = copy_fixture(jpg, "jfxx.jpg")
		local data = read_bytes(path)
		assert(data:sub(7, 11) == "JFIF\0", "fixture lacks a leading JFIF segment")
		local jfif_end = 4 + string.unpack(">I2", data, 5)
		local thumbnail = read_bytes(jpg)
		local payload = "JFXX\0\16" .. thumbnail
		write_bytes(
			path,
			data:sub(1, jfif_end) .. "\255\224" .. string.pack(">I2", #payload + 2) .. payload .. data:sub(jfif_end + 1)
		)
		assert_present(tags(path), { "[JFXX]" })
		assert_sanitized(path)
		assert_absent(tags(path), { "[JFXX]", "ThumbnailImage" })
	end)

	record("JPEG JFIF thumbnail is removed", function()
		-- A JFIF thumbnail is raw pixels that may show the image before a crop.
		local path = copy_fixture(jpg, "jfif-thumbnail.jpg")
		local data = read_bytes(path)
		assert(data:sub(3, 4) == "\255\224" and data:sub(7, 11) == "JFIF\0", "fixture lacks JFIF")
		local length = string.unpack(">I2", data, 5)
		local thumbnail = string.rep("\200\10\10", 4)
		local payload = data:sub(7, 18) .. "\2\2" .. thumbnail
		write_bytes(
			path,
			data:sub(1, 2) .. "\255\224" .. string.pack(">I2", #payload + 2) .. payload .. data:sub(5 + length)
		)
		assert_present(tags(path), { "ThumbnailWidth" })
		local pixels = framehash(path)
		assert_sanitized(path)
		local cleaned = read_bytes(path)
		assert(not cleaned:find(thumbnail, 1, true), "JFIF thumbnail remains")
		assert_present(tags(path), { "JFIFVersion" })
		assert_absent(tags(path), { "ThumbnailWidth", "ThumbnailTIFF" })
		assert(framehash(path) == pixels, "primary image changed")
		assert(select(2, process(path)) == "unchanged", "cleaned file is not reported clean")
	end)

	record("JPEG without ColorSpace does not gain one", function()
		local path = copy_fixture(jpg, "no-colorspace.jpg")
		exiftool({ "-ExifIFD:ColorSpace=", path })
		assert_present(tags(path), { "[ExifIFD]" })
		assert_sanitized(path)
		assert_absent(tags(path), { "ColorSpace" })
	end)

	record("already-clean JPEG is reported unchanged", function()
		local path = copy_fixture(jpg, "neutral.jpg")
		assert_sanitized(path)
		local before = sha(path)
		local result, detail = process(path)
		assert(result == true and detail == "unchanged", tostring(detail))
		assert(sha(path) == before, "already-clean file was rewritten")
	end)

	record("malformed input is skipped unchanged", function()
		local path = RUN .. "/broken.jpg"
		write_bytes(path, "\255\216\255\225\0\16Exif\0\0broken")
		assert_skipped(absolute(path))
		local text = RUN .. "/not-an-image.bin"
		write_bytes(text, "plain text, not media\n")
		assert_skipped(absolute(text), "unsupported format")
	end)

	record("wrong extension is classified by content", function()
		local path = copy_fixture(png, "actually-png.jpg")
		assert_sanitized(path)
		assert_absent(tags(path), { "MetaClean Test User" })
	end)

	-- PNG ----------------------------------------------------------------------

	record("PNG transaction drops every non-rendering chunk", function()
		local path = copy_fixture(icc_png, "chunks.png")
		exiftool({ "-PNG:Comment=private comment", "-XMP-dc:Creator=MetaClean Test User", "-EXIF:Artist=Artist", path })
		local data = read_bytes(path)
		data = png_insert(data, crc32, {
			{ "gAMA", string.pack(">I4", 45455) },
			{ "tIME", "\7\228\1\2\3\4\5" },
			{ "iDOT", string.rep("\0", 20) },
			{ "prVt", "private vendor data" },
		})
		write_bytes(path, data)
		local before = framehash(path)
		local _, icc_before = execute({ "exiftool", "-b", "-ICC_Profile", path })
		assert_sanitized(path)
		local cleaned = read_bytes(path)
		local chunks = png_chunks(cleaned)
		for _, kind in ipairs({ "tEXt", "zTXt", "iTXt", "eXIf", "tIME", "iDOT", "prVt" }) do
			assert(not chunks:find(kind, 1, true), "chunk remains: " .. kind .. " in " .. chunks)
		end
		assert(chunks:find("iCCP", 1, true) and chunks:find("gAMA", 1, true) and chunks:find("cICP", 1, true), chunks)
		assert(not cleaned:find("private", 1, true), "private bytes remain")
		local _, icc_after = execute({ "exiftool", "-b", "-ICC_Profile", path })
		assert(icc_after == icc_before, "ICC profile changed")
		assert(framehash(path) == before, "decoded PNG changed")
		assert_absent(tags(path), { "MetaClean Test User", "private comment", "Artist" })
	end)

	record("PNG orientation is rebuilt as a minimal eXIf chunk", function()
		local path = copy_fixture(png, "oriented.png")
		exiftool({ "-EXIF:Orientation#=6", "-EXIF:Artist=MetaClean Test User", "-EXIF:Model=Test Camera", path })
		assert_sanitized(path)
		local after = tags(path)
		assert_present(after, { "[IFD0]          Orientation                     : 6" })
		assert_absent(after, { "MetaClean Test User", "Test Camera" })
	end)

	record("APNG transaction keeps the animation timeline", function()
		local path = copy_fixture(apng, "identity.apng")
		local before = framehash(path)
		local timeline = animation_manifest(path)
		assert_sanitized(path)
		assert(framehash(path) == before, "decoded APNG changed")
		assert(animation_manifest(path) == timeline, "APNG timeline changed")
		local after = tags(path)
		assert_present(after, { "AnimationFrames" })
		assert_absent(after, { "MetaClean Test User", "private comment", "2020:01:02" })
	end)

	record("PNG with an unknown critical chunk is skipped unchanged", function()
		local path = copy_fixture(png, "critical.png")
		write_bytes(path, png_insert(read_bytes(path), crc32, { { "ABCD", "x" } }))
		assert_skipped(path, "critical PNG chunk")
	end)

	record("PNG with a corrupt chunk CRC is skipped unchanged", function()
		local path = copy_fixture(png, "bad-crc.png")
		local data = read_bytes(path)
		local chunk = crc_chunk(crc32, "tEXt", "Author\0x")
		chunk = chunk:sub(1, -2) .. string.char((chunk:byte(-1) + 1) % 256)
		local idat = assert(data:find("IDAT", 9, true)) - 4
		write_bytes(path, data:sub(1, idat - 1) .. chunk .. data:sub(idat))
		assert_skipped(path, "CRC")
	end)

	-- TIFF, GIF, BMP, ICO ------------------------------------------------------

	record("TIFF keeps its ICC profile and compares it", function()
		local srgb = "/System/Library/ColorSync/Profiles/sRGB Profile.icc"
		local generic = "/System/Library/ColorSync/Profiles/Generic RGB Profile.icc"
		local path = copy_fixture(tiff, "icc.tiff")
		local other = copy_fixture(tiff, "other-icc.tiff")
		exiftool({ "-ICC_Profile<=" .. srgb, "-Artist=MetaClean Test User", path })
		exiftool({ "-ICC_Profile<=" .. generic, other })
		local capture = helpers.policies.TIFF.capture
		local a, b = assert(capture(path)), assert(capture(other))
		assert(a.icc == read_bytes(srgb), "TIFF capture does not hold the ICC profile")
		assert(a.icc ~= b.icc, "TIFF capture ignores the ICC profile")
		assert(not helpers.policies.TIFF.equivalent(a, b), "a changed ICC profile passed")
		assert_sanitized(path)
		local ok, out = execute({ "exiftool", "-b", "-ICC_Profile", path })
		assert(ok and out == read_bytes(srgb), "ICC profile changed")
	end)

	record("display serial numbers in ICC profiles are removed", function()
		-- The system sRGB profile with an Apple mmod tag, as display profiles
		-- in Mac screenshots carry it: vendor, model, serial, date.
		local base = read_bytes("/System/Library/ColorSync/Profiles/sRGB Profile.icc")
		local count = string.unpack(">I4", base, 129)
		local entries = {}
		for index = 0, count - 1 do
			local signature, offset, length = string.unpack(">c4I4I4", base, 133 + 12 * index)
			entries[#entries + 1] = string.pack(">c4I4I4", signature, offset + 12, length)
		end
		local body = base:sub(133 + 12 * count)
		body = body .. string.rep("\0", (4 - (132 + 12 * (count + 1) + #body) % 4) % 4)
		local mmod_at = 132 + 12 * (count + 1) + #body
		local serial = "\222\173\190\239\1\2\3\4"
		local mmod = "mmod\0\0\0\0" .. string.pack(">I4I4", 0x610, 0xa063) .. serial .. string.rep("\0", 16)
		entries[#entries + 1] = string.pack(">c4I4I4", "mmod", mmod_at, #mmod)
		local profile = base:sub(5, 128) .. string.pack(">I4", count + 1) .. table.concat(entries) .. body .. mmod
		profile = string.pack(">I4", #profile + 4) .. profile
		local expected = profile:sub(1, 84)
			.. string.rep("\0", 16)
			.. profile:sub(101, mmod_at + 16)
			.. string.rep("\0", 8)
			.. profile:sub(mmod_at + 25)
		local icc = RUN .. "/display.icc"
		write_bytes(icc, profile)

		local cases = {}
		for _, case in ipairs({
			{ jpg, "display.jpg" },
			{ png, "display.png" },
			{ tiff, "display.tiff" },
			{ gif, "display.gif" },
		}) do
			local path = copy_fixture(case[1], case[2])
			exiftool({ "-ICC_Profile<=" .. icc, path })
			cases[#cases + 1] = path
		end
		-- An MP4 whose video sample entry carries the profile in its colr box.
		local mp4_path = absolute(RUN .. "/display.mp4")
		assert(execute({
			"ffmpeg",
			"-v",
			"error",
			"-f",
			"lavfi",
			"-i",
			"testsrc2=s=64x48:d=1",
			"-c:v",
			"libx264",
			"-color_primaries",
			"bt709",
			"-color_trc",
			"bt709",
			"-colorspace",
			"bt709",
			"-movflags",
			"+write_colr",
			"-y",
			mp4_path,
		}))
		local data = read_bytes(mp4_path)
		local colr = assert(data:find("colr", 1, true)) - 4
		local box = string.pack(">I4", 12 + #profile) .. "colrprof" .. profile
		local delta = #box - string.unpack(">I4", data, colr)
		local skip = { moov = 0, trak = 0, mdia = 0, minf = 0, stbl = 0, stsd = 8, avc1 = 78 }
		local function grow(position, finish)
			while position < finish do
				local size, kind = string.unpack(">I4c4", data, position)
				if position < colr and colr < position + size then
					data = data:sub(1, position - 1) .. string.pack(">I4", size + delta) .. data:sub(position + 4)
					return grow(position + 8 + assert(skip[kind], kind), position + size)
				end
				position = position + size
			end
		end
		grow(1, #data + 1)
		data = data:sub(1, colr - 1) .. box .. data:sub(colr + #box - delta)
		write_bytes(mp4_path, data)
		local function mp4_profile(path)
			local bytes = read_bytes(path)
			local at = bytes:find("colrprof", 1, true)
			return bytes:sub(at + 8, at + 7 + #profile)
		end
		assert(mp4_profile(mp4_path) == profile, "MP4 fixture lacks the display profile")
		local frames = framehash(mp4_path)
		assert_sanitized(mp4_path)
		assert(mp4_profile(mp4_path) == expected, "display serial number remains in the MP4")
		assert(framehash(mp4_path) == frames, "MP4 frames changed")
		assert(select(2, process(mp4_path)) == "unchanged", "cleaned MP4 is not reported clean")

		local webp = absolute(RUN .. "/display.webp")
		assert(execute({ "cwebp", "-quiet", "-metadata", "icc", cases[2], "-o", webp }))
		local heic = absolute(RUN .. "/display.heic")
		assert(execute({ "heif-enc", "-q", "60", cases[2], "-o", heic }))
		cases[#cases + 1], cases[#cases + 2] = webp, heic
		local function pixels(path)
			if not path:match("%.heic$") then
				return framehash(path)
			end
			local decoded = path .. ".decoded.png"
			assert(execute({ "heif-dec", path, decoded }))
			local hash = framehash(decoded)
			os.remove(decoded)
			return hash
		end
		for _, path in ipairs(cases) do
			local ok, before = execute({ "exiftool", "-b", "-ICC_Profile", path })
			assert(ok and before == profile, "fixture lacks the display profile: " .. path)
			local decoded = pixels(path)
			assert_sanitized(path)
			local _, after = execute({ "exiftool", "-b", "-ICC_Profile", path })
			assert(after == expected, "display serial number remains: " .. path)
			assert(pixels(path) == decoded, "pixels changed: " .. path)
			assert(select(2, process(path)) == "unchanged", "cleaned file is not reported clean: " .. path)
		end
	end)

	record("EDID serial numbers in calibrated display profiles are removed", function()
		-- DisplayCAL and ArgyllCMS keep the display's EDID in a meta dict.
		local function utf16(text)
			return (text:gsub(".", "\0%0"))
		end
		local entries = { { "EDID_model", "DELL U2720Q" }, { "EDID_serial", "8XKJ123" }, { "EDID_hash", "4f1a9c" } }
		local strings, records, at = {}, {}, 16 + 16 * #entries
		for _, entry in ipairs(entries) do
			local name, value = utf16(entry[1]), utf16(entry[2])
			records[#records + 1] = string.pack(">I4I4I4I4", at, #name, at + #name, #value)
			strings[#strings + 1] = name .. value
			at = at + #name + #value
		end
		local dict = "dict\0\0\0\0"
			.. string.pack(">I4I4", #entries, 16)
			.. table.concat(records)
			.. table.concat(strings)
		local header = string.rep("\0", 36)
			.. "acsp"
			.. string.rep("\0", 44)
			.. string.rep("\7", 16)
			.. string.rep("\0", 28)
		local profile = header .. string.pack(">I4", 1) .. string.pack(">c4I4I4", "meta", 144, #dict) .. dict
		profile = string.pack(">I4", #profile) .. profile:sub(5)
		local cleaned = assert(helpers.icc.clean(profile), "profile not patched")
		assert(#cleaned == #profile, "profile length changed")
		assert(not cleaned:find(utf16("8XKJ123"), 1, true), "EDID serial remains")
		assert(not cleaned:find(utf16("4f1a9c"), 1, true), "EDID hash remains")
		assert(cleaned:find(utf16("DELL U2720Q"), 1, true), "EDID model was changed")
		assert(cleaned:find(utf16("0000000"), 1, true), "serial is not zero digits")
		assert(cleaned:sub(85, 100) == string.rep("\0", 16), "profile ID not cleared")
		assert(helpers.icc.clean(cleaned) == false, "cleaned profile is not stable")

		-- The same dictionary in the system sRGB profile, embedded in files.
		local base = read_bytes("/System/Library/ColorSync/Profiles/sRGB Profile.icc")
		local count = string.unpack(">I4", base, 129)
		local table_entries = {}
		for index = 0, count - 1 do
			local signature, offset, length = string.unpack(">c4I4I4", base, 133 + 12 * index)
			table_entries[#table_entries + 1] = string.pack(">c4I4I4", signature, offset + 12, length)
		end
		local body = base:sub(133 + 12 * count)
		body = body .. string.rep("\0", (4 - (132 + 12 * (count + 1) + #body) % 4) % 4)
		table_entries[#table_entries + 1] = string.pack(">c4I4I4", "meta", 132 + 12 * (count + 1) + #body, #dict)
		local real = base:sub(5, 128) .. string.pack(">I4", count + 1) .. table.concat(table_entries) .. body .. dict
		real = string.pack(">I4", #real + 4) .. real
		local icc = RUN .. "/calibrated.icc"
		write_bytes(icc, real)
		for _, case in ipairs({ { png, "calibrated.png" }, { jpg, "calibrated.jpg" }, { tiff, "calibrated.tiff" } }) do
			local path = copy_fixture(case[1], case[2])
			exiftool({ "-ICC_Profile<=" .. icc, path })
			assert_present(tags(path), { "EDID_serial", "8XKJ123" })
			local pixels = framehash(path)
			assert_sanitized(path)
			local after = tags(path)
			assert_absent(after, { "8XKJ123", "4f1a9c" })
			assert_present(after, { "DELL U2720Q" })
			assert(framehash(path) == pixels, "pixels changed: " .. case[2])
			assert(select(2, process(path)) == "unchanged", "cleaned file is not reported clean: " .. case[2])
		end
	end)

	record("fax-compressed and multi-page TIFF scans are cleaned", function()
		local mono = RUN .. "/scan-mono.tif"
		assert(execute({
			"ffmpeg",
			"-v",
			"error",
			"-f",
			"lavfi",
			"-i",
			"testsrc2=s=64x48",
			"-frames:v",
			"1",
			"-pix_fmt",
			"monob",
			"-y",
			mono,
		}))
		for _, compression in ipairs({ "g3", "g4" }) do
			local path = absolute(RUN .. "/scan-" .. compression .. ".tif")
			assert(execute({ "tiffcp", "-c", compression, mono, path }))
			exiftool({ "-Artist=MetaClean Test User", "-Software=Scanner 1.0", path })
			local pixels = framehash(path)
			assert_sanitized(path)
			assert_absent(tags(path), { "MetaClean Test User", "Scanner 1.0" })
			assert(framehash(path) == pixels, "decoded scan changed: " .. compression)
		end

		-- A three-page document: every page names the scanner and the author.
		local pages = {}
		for index = 1, 3 do
			local page = absolute(RUN .. "/page" .. index .. ".tif")
			assert(execute({ "tiffcp", "-c", "g4", mono, page }))
			exiftool({ "-Software=Scanner " .. index, "-Artist=MetaClean Test User", "-PageName=Secret page", page })
			pages[#pages + 1] = page
		end
		local document = absolute(RUN .. "/document.tif")
		local reference = absolute(RUN .. "/document-reference.tif")
		assert(execute({ "tiffcp", pages[1], pages[2], pages[3], document }))
		assert(execute({ "tiffcp", pages[1], pages[2], pages[3], reference }))
		assert_present(tags(document), { "[IFD2]", "Scanner 3", "Secret page" })
		assert_sanitized(document)
		local cleaned = read_bytes(document)
		for _, needle in ipairs({ "Scanner", "MetaClean", "Secret" }) do
			assert(not cleaned:find(needle, 1, true), "page identity remains: " .. needle)
		end
		assert_present(tags(document), { "PageCount                       : 3" })
		local ok, out = execute({ "tiffcmp", "-t", reference, document })
		assert(not out:find("differ", 1, true) and not out:find("Scanline", 1, true), "page pixels changed:\n" .. out)
		local _, info = execute({ "tiffinfo", document })
		assert(not info:find("Warning", 1, true), "libtiff warns about the cleaned pages:\n" .. info)
		assert(select(2, process(document)) == "unchanged", "cleaned document is not reported clean")
		assert(ok ~= nil)

		-- One changed byte in the last page's image data is caught.
		local parsed = assert(helpers.tiff.pages(document))
		local strip = helpers.tiff.numbers(parsed, parsed[3].tags[0x111])[1]
		parsed.close()
		local damaged = absolute(RUN .. "/document-damaged.tif")
		write_bytes(
			damaged,
			cleaned:sub(1, strip) .. string.char(cleaned:byte(strip + 1) ~ 0xFF) .. cleaned:sub(strip + 2)
		)
		local verified, err = helpers.tiff.verify(document, damaged)
		assert(not verified and tostring(err):find("image data", 1, true), "damaged page passed: " .. tostring(err))
	end)

	record("DNG keeps its raw data, previews and rendering tags", function()
		-- A preview JPEG with its own Exif, as cameras and phones embed them.
		local preview = RUN .. "/dng-preview.jpg"
		assert(execute({
			"ffmpeg",
			"-v",
			"error",
			"-f",
			"lavfi",
			"-i",
			"testsrc2=s=64x48",
			"-frames:v",
			"1",
			"-y",
			preview,
		}))
		exiftool({ "-Model=MetaClean Preview Camera", "-DateTimeOriginal=2020:01:02 03:04:05", preview })
		-- ProRAW previews carry an Apple gain map and the HDR maker note values.
		local base = 14 + 2 + 4 * 12 + 4
		local note = "Apple iOS\0\0\1MM"
			.. string.pack(">I2", 4)
			.. string.pack(">I2I2I4i4", 0x0001, 9, 1, 14)
			.. string.pack(">I2I2I4I4", 0x000B, 2, 12, base)
			.. string.pack(">I2I2I4I4", 0x0021, 10, 1, base + 12)
			.. string.pack(">I2I2I4I4", 0x0030, 10, 1, base + 20)
			.. string.pack(">I4", 0)
			.. "SECRET-UUID\0"
			.. string.pack(">i4i4i4i4", 3, 2, 1, 100)
		write_bytes(RUN .. "/dng-makernote.bin", note)
		exiftool({ "-Make=Apple", "-MakerNotes<=" .. RUN .. "/dng-makernote.bin", preview })
		local apdi = '<rdf:Description rdf:about="" xmlns:apdi="http://ns.apple.com/pixeldatainfo/1.0/">'
			.. "<apdi:AuxiliaryImageType>urn:com:apple:photo:2020:aux:hdrgainmap</apdi:AuxiliaryImageType>"
			.. "</rdf:Description>"
		local gainmap = secondary_jpeg("dng-gainmap.jpg", xmp_segment(apdi))
		local jpeg =
			read_bytes(mpf_fixture("dng-preview-hdr.jpg", read_bytes(preview), { { attributes = 0, data = gainmap } }))
		-- A minimal little-endian DNG: an RGB thumbnail in IFD0, a 16-bit CFA
		-- raw image and the JPEG preview in SubIFDs.
		local blobs, entries = {}, {}
		local function ifd(list)
			table.sort(list, function(a, b)
				return a[1] < b[1]
			end)
			return list
		end
		local types = { byte = 1, ascii = 2, short = 3, long = 4, rational = 5, srational = 10 }
		local function entry(tag, kind, values)
			return { tag, types[kind], values }
		end
		local raw = {}
		for index = 0, 64 * 64 - 1 do
			raw[#raw + 1] = string.pack("<I2", (index * 37) % 4096)
		end
		local thumbnail = string.rep("\200\100\50", 16)
		local main = ifd({
			entry(254, "long", { 1 }),
			entry(256, "short", { 4 }),
			entry(257, "short", { 4 }),
			entry(258, "short", { 8, 8, 8 }),
			entry(259, "short", { 1 }),
			entry(262, "short", { 2 }),
			entry(271, "ascii", "MetaClean"),
			entry(272, "ascii", "Test Camera"),
			entry(273, "long", { "thumbnail" }),
			entry(274, "short", { 1 }),
			entry(277, "short", { 3 }),
			entry(278, "short", { 4 }),
			entry(279, "long", { #thumbnail }),
			entry(284, "short", { 1 }),
			entry(305, "ascii", "MetaClean Converter 1.0"),
			entry(330, "long", { "raw ifd", "preview ifd" }),
			entry(50706, "byte", { 1, 4, 0, 0 }),
			entry(50707, "byte", { 1, 1, 0, 0 }),
			entry(50708, "ascii", "MetaClean Test Camera"),
			entry(50721, "srational", { 1, 1, 0, 1, 0, 1, 0, 1, 1, 1, 0, 1, 0, 1, 0, 1, 1, 1 }),
			entry(50728, "rational", { 1, 2, 1, 1, 1, 2 }),
			entry(50735, "ascii", "SERIAL-DNG-0042"),
			entry(50778, "short", { 21 }),
		})
		local raw_ifd = ifd({
			entry(254, "long", { 0 }),
			entry(256, "short", { 64 }),
			entry(257, "short", { 64 }),
			entry(258, "short", { 16 }),
			entry(259, "short", { 1 }),
			entry(262, "short", { 32803 }),
			entry(273, "long", { "raw" }),
			entry(277, "short", { 1 }),
			entry(278, "short", { 64 }),
			entry(279, "long", { 64 * 64 * 2 }),
			entry(284, "short", { 1 }),
			entry(33421, "short", { 2, 2 }),
			entry(33422, "byte", { 0, 1, 1, 2 }),
			entry(50714, "short", { 0 }),
			entry(50717, "short", { 4095 }),
		})
		local preview_ifd = ifd({
			entry(254, "long", { 1 }),
			entry(256, "short", { 64 }),
			entry(257, "short", { 48 }),
			entry(258, "short", { 8, 8, 8 }),
			entry(259, "short", { 7 }),
			entry(262, "short", { 6 }),
			entry(273, "long", { "preview" }),
			entry(277, "short", { 3 }),
			entry(278, "short", { 48 }),
			entry(279, "long", { #jpeg }),
		})
		blobs.thumbnail, blobs.raw, blobs.preview = thumbnail, table.concat(raw), jpeg
		-- Layout: header, the three IFDs, then their out-of-line values and data.
		local directories = { { "main", main }, { "raw ifd", raw_ifd }, { "preview ifd", preview_ifd } }
		local offsets, position = {}, 8
		for _, directory in ipairs(directories) do
			offsets[directory[1]] = position
			position = position + 2 + 12 * #directory[2] + 4
		end
		for _, name in ipairs({ "thumbnail", "raw", "preview" }) do
			offsets[name] = position
			position = position + #blobs[name] + #blobs[name] % 2
		end
		local extra, tables = {}, {}
		for _, directory in ipairs(directories) do
			local parts = { string.pack("<I2", #directory[2]) }
			for _, item in ipairs(directory[2]) do
				local tag, kind, values = item[1], item[2], item[3]
				local data
				if kind == 2 then
					data = values .. "\0"
				else
					local format = ({ [1] = "B", [3] = "I2", [4] = "I4", [5] = "I4", [10] = "i4" })[kind]
					local packed = {}
					for _, value in ipairs(values) do
						packed[#packed + 1] =
							string.pack("<" .. format, type(value) == "string" and offsets[value] or value)
					end
					data = table.concat(packed)
				end
				local count = kind == 2 and #data or (kind == 5 or kind == 10) and #values // 2 or #values
				local field
				if #data <= 4 then
					field = data .. string.rep("\0", 4 - #data)
				else
					field = string.pack("<I4", position)
					extra[#extra + 1] = data .. string.rep("\0", #data % 2)
					position = position + #extra[#extra]
				end
				parts[#parts + 1] = string.pack("<I2I2I4", tag, kind, count) .. field
			end
			parts[#parts + 1] = string.pack("<I4", 0)
			tables[#tables + 1] = table.concat(parts)
		end
		local data = { "II*\0", string.pack("<I4", 8), table.concat(tables) }
		for _, name in ipairs({ "thumbnail", "raw", "preview" }) do
			data[#data + 1] = blobs[name] .. string.rep("\0", #blobs[name] % 2)
		end
		data[#data + 1] = table.concat(extra)
		local path = absolute(RUN .. "/identity.dng")
		write_bytes(path, table.concat(data))
		exiftool({
			"-ExifIFD:SerialNumber=SERIAL-DNG-0042",
			"-ExifIFD:DateTimeOriginal=2020:01:02 03:04:05",
			"-GPSLatitude=48.85",
			"-GPSLatitudeRef=N",
			"-XMP-dc:Creator=MetaClean Test User",
			path,
		})
		local before = tags(path)
		assert_present(before, { "DNG", "SERIAL-DNG-0042", "MetaClean Test User", "48.85" })
		local function render(file)
			local ok, out = execute_stdout({ "dcraw_emu", "-6", "-Z", "-", file })
			assert(ok and #out > 1000, "LibRaw could not render the DNG")
			return out
		end
		local rendered = render(path)
		assert_sanitized(path)
		local cleaned = read_bytes(path)
		for _, needle in ipairs({
			"SERIAL-DNG",
			"MetaClean Converter",
			"MetaClean Test User",
			"Preview Camera",
			"SECRET-UUID",
			"2020:01:02",
		}) do
			assert(not cleaned:find(needle, 1, true), "DNG identity remains: " .. needle)
		end
		local after = tags(path)
		assert_absent(after, { "48.85", "GPSLatitude" })
		assert_present(after, { "UniqueCameraModel", "ColorMatrix1", "AsShotNeutral", "MetaClean Test Camera" })
		assert(cleaned:find(blobs.raw, 1, true), "raw data changed")
		assert(cleaned:find(thumbnail, 1, true), "thumbnail changed")
		assert(render(path) == rendered, "rendered raw image changed")
		local cleaned_preview = RUN .. "/dng-preview-cleaned.jpg"
		write_bytes(cleaned_preview, cleaned:sub(cleaned:find("\255\216\255", 1, true), -1):sub(1, #jpeg))
		assert(framehash(cleaned_preview) == framehash(RUN .. "/dng-preview-hdr.jpg"), "preview image changed")
		assert(
			mpf_image_hash(cleaned_preview, 2) == mpf_image_hash(RUN .. "/dng-preview-hdr.jpg", 2),
			"preview gain map changed"
		)
		local preview_tags = tags(cleaned_preview)
		assert_present(preview_tags, {
			"[Apple]         HDRHeadroom                     : 1.5",
			"[Apple]         HDRGain                         : 0.01",
		})
		assert_absent(preview_tags, { "SECRET-UUID", "Preview Camera", "Gain Map Owner", "[IFD0]          Make" })
		assert(select(2, process(path)) == "unchanged", "cleaned DNG is not reported clean")
	end)

	record("TIFF transaction deletes metadata tags and keeps image structure", function()
		local path = copy_fixture(tiff, "identity.tiff")
		-- Sensor levels, as DJI multispectral cameras store them, are kept.
		exiftool({
			"-GPSLatitude=1",
			"-XMP-dc:Creator=MetaClean Test User",
			"-IFD0:BlackLevelRepeatDim=1 1",
			"-IFD0:BlackLevel=4096",
			"-IFD0:WhiteLevel=65535",
			path,
		})
		local before = framehash(path)
		assert_sanitized(path)
		local after = tags(path)
		assert_absent(after, { "MetaClean Test User", "Test Camera", "Lavc", "GPS", "private comment" })
		assert_present(after, {
			"Compression",
			"PhotometricInterpretation",
			"[IFD0]          BlackLevel                      : 4096",
			"[IFD0]          WhiteLevel                      : 65535",
		})
		assert(framehash(path) == before, "decoded TIFF changed")
	end)

	record("files on an exFAT camera card get neutral creation dates", function()
		-- exFAT keeps the creation date when touch moves the modification date
		-- back, unlike APFS, so it is set separately.
		local image, mount = RUN .. "/card.dmg", absolute(RUN) .. "/card"
		assert(execute({ "hdiutil", "create", "-size", "16m", "-fs", "ExFAT", "-volname", "MCCARD", "-o", image }))
		assert(execute({ "hdiutil", "attach", "-nobrowse", "-mountpoint", mount, image }))
		local ok, err = pcall(function()
			local path = mount .. "/identity.jpg"
			assert(execute({ "cp", jpg, path }))
			assert(execute({ "xattr", "-w", "com.apple.metadata:kMDItemWhereFroms", "https://example.invalid/", path }))
			assert_sanitized(path)
			local _, dates = execute({ "stat", "-f", "%m|%B", path })
			local _, epoch = execute({ "date", "-j", "-f", "%Y%m%d%H%M.%S", "200101010000.00", "+%s" })
			epoch = epoch:match("%d+")
			assert(dates:match("^%d+|%d+") == epoch .. "|" .. epoch, "dates not neutral: " .. dates)
			local _, names = execute({ "xattr", path })
			assert(not names:find("WhereFroms", 1, true), "download source remains")
			assert_absent(tags(path), { "MetaClean Test User" })
			assert(select(2, process(path)) == "unchanged", "cleaned file on exFAT is not reported clean")
		end)
		execute({ "hdiutil", "detach", "-force", mount })
		assert(ok, err)
	end)

	record("iCloud files that are not downloaded are skipped without reading them", function()
		local path = copy_fixture(jpg, "dataless.jpg")
		local seen = {}
		local result, detail = process(path, function(args)
			-- args[5] is the tool; the first four run it under timeout.
			seen[#seen + 1] = args[5]
			if args[5] == "stat" and args[7]:sub(1, 3) == "%f|" then
				return { success = true, output = tostring(0x40000000) .. "|1|2|3|4.0|5.0|6.0\n" }
			end
		end)
		assert(result == nil and detail == "iCloud file not downloaded", tostring(detail))
		assert(table.concat(seen, ",") == "stat", "commands ran before the skip: " .. table.concat(seen, ","))
	end)

	record("TIFF JPEG strips are cleaned only without their own metadata", function()
		-- libtiff writes abbreviated JPEG strips with shared tables: cleaned.
		local rgb, plain = RUN .. "/rgb.tiff", absolute(RUN .. "/jpeg-strips.tiff")
		assert(execute({
			"ffmpeg",
			"-v",
			"error",
			"-f",
			"lavfi",
			"-i",
			"testsrc2=s=64x48",
			"-frames:v",
			"1",
			"-pix_fmt",
			"rgb24",
			"-y",
			rgb,
		}))
		assert(execute({ "tiffcp", "-c", "jpeg", "-r", "16", rgb, plain }))
		exiftool({ "-Artist=MetaClean Test User", plain })
		local before = framehash(plain)
		assert_sanitized(plain)
		assert(framehash(plain) == before, "decoded JPEG TIFF changed")
		-- One libtiff strip with an Exif segment added after its SOI, which
		-- ExifTool does not see. The strip comes first, so the IFD offset and
		-- every out-of-line value move by the segment's length.
		local single = absolute(RUN .. "/jpeg-strip-exif.tiff")
		assert(execute({ "tiffcp", "-c", "jpeg", "-r", "48", rgb, single }))
		local data = read_bytes(single)
		local exif = "Exif\0\0MM\0*" .. string.pack(">I4", 8) .. "\0\0" .. "Strip Owner!"
		local segment = "\255\225" .. string.pack(">I2", #exif + 2) .. exif
		local shift, sizes = #segment, { [1] = 1, [2] = 1, [3] = 2, [4] = 4, [5] = 8, [7] = 1, [10] = 8 }
		local ifd = string.unpack("<I4", data, 5)
		local strip
		local parts = { "II*\0", string.pack("<I4", ifd + shift) }
		local entries = {}
		for index = 0, string.unpack("<I2", data, ifd + 1) - 1 do
			local at = ifd + 1 + 2 + 12 * index
			local tag, kind, count, value = string.unpack("<I2I2I4I4", data, at)
			if tag == 273 then
				strip = value
			elseif tag == 279 then
				value = value + shift
			elseif (sizes[kind] or 1) * count > 4 then
				value = value + shift
			end
			entries[#entries + 1] = string.pack("<I2I2I4I4", tag, kind, count, value)
		end
		local after = data:sub(9, ifd)
		after = after:sub(1, strip - 8 + 2) .. segment .. after:sub(strip - 8 + 3)
		parts[#parts + 1] = after
		parts[#parts + 1] = string.pack("<I2", #entries) .. table.concat(entries)
		parts[#parts + 1] = data:sub(ifd + 3 + 12 * #entries)
		local path = single
		write_bytes(path, table.concat(parts))
		local ok, out = execute({ "tiffinfo", "-D", path })
		assert(ok and out:find("Compression Scheme: JPEG", 1, true), out)
		assert(read_bytes(path):find("Strip Owner", 1, true), "fixture lacks the strip's Exif")
		assert_skipped(path, "JPEG metadata segment")
	end)

	record("TIFF with Photoshop layers is skipped unchanged", function()
		local path = copy_fixture(tiff, "layers.tiff")
		local layers = RUN .. "/layers.bin"
		write_bytes(layers, "Adobe Photoshop Document Data Block\0" .. "8BIMLayr" .. string.pack(">I4i2", 2, 0))
		exiftool({ "-ImageSourceData<=" .. layers, path })
		assert_present(tags(path), { "LayerCount" })
		assert_skipped(path, "Photoshop layers")
	end)

	record("GIF transaction removes comments, XMP and unknown application blocks", function()
		local path = copy_fixture(gif, "identity.gif")
		exiftool({ "-XMP-dc:Creator=MetaClean Test User", path })
		local data = read_bytes(path)
		local trailer = #data
		local block = "\33\255\11MGKIPTC0000\5owner\0"
		write_bytes(path, data:sub(1, trailer - 1) .. block .. data:sub(trailer))
		local before = framehash(path)
		local timeline = animation_manifest(path)
		assert_sanitized(path)
		local cleaned = read_bytes(path)
		assert(
			not cleaned:find("MetaClean", 1, true) and not cleaned:find("owner", 1, true),
			"GIF identity bytes remain"
		)
		assert(cleaned:find("NETSCAPE2.0", 1, true), "GIF loop extension removed")
		assert(framehash(path) == before, "decoded GIF changed")
		assert(animation_manifest(path) == timeline, "GIF timeline changed")
	end)

	record("GIF plain-text extensions are skipped unchanged", function()
		local path = copy_fixture(gif, "plain-text.gif")
		local data = read_bytes(path)
		local block = "\33\1\12" .. string.rep("\0", 12) .. "\4text\0"
		write_bytes(path, data:sub(1, #data - 1) .. block .. data:sub(#data))
		assert_skipped(path, "plain%-text")
	end)

	record("BMP transaction keeps every byte and neutralizes the file", function()
		local path = copy_fixture(bmp, "identity.bmp")
		local before = sha(path)
		assert(execute({ "xattr", "-w", "com.apple.metadata:kMDItemWhereFroms", "https://example.invalid/", path }))
		assert_sanitized(path)
		assert(sha(path) == before, "BMP bytes changed")
		neutral_dates(path)
		-- Older writers put other values in the file size field.
		local stale = copy_fixture(bmp, "stale-size.bmp")
		local data = read_bytes(stale)
		write_bytes(stale, data:sub(1, 2) .. string.pack("<I4", 54) .. data:sub(7))
		local stale_sha = sha(stale)
		assert(execute({ "xattr", "-w", "com.apple.metadata:kMDItemWhereFroms", "https://example.invalid/", stale }))
		assert_sanitized(stale)
		assert(sha(stale) == stale_sha, "BMP bytes changed")
	end)

	record("ICO transaction cleans embedded PNG entries", function()
		-- One BMP entry from the sips fixture plus one PNG entry carrying text.
		local path = copy_fixture(ico, "identity.ico")
		local data = read_bytes(path)
		local bmp_length, bmp_offset = string.unpack("<I4I4", data, 15)
		local dib = data:sub(bmp_offset + 1, bmp_offset + bmp_length)
		local image = png_insert(read_bytes(png), crc32, { { "tEXt", "Author\0MetaClean Test User" } })
		local first = 6 + 2 * 16
		write_bytes(
			path,
			string.pack("<I2I2I2", 0, 1, 2)
				.. data:sub(7, 14)
				.. string.pack("<I4I4", #dib, first)
				.. data:sub(7, 14)
				.. string.pack("<I4I4", #image, first + #dib)
				.. dib
				.. image
		)
		local before = framehash(path, "0:v")
		assert_sanitized(path)
		assert(not read_bytes(path):find("MetaClean", 1, true), "ICO identity bytes remain")
		assert(framehash(path, "0:v") == before, "decoded ICO changed")
	end)

	-- SVG ----------------------------------------------------------------------

	record("SVG transaction removes metadata, comments and editor data", function()
		local path = RUN .. "/editor.svg"
		write_bytes(
			path,
			'<?xml version="1.0" encoding="UTF-8"?>\n'
				.. "<!-- Generator: Adobe Illustrator 27.0.0 -->\n"
				.. '<svg xmlns="http://www.w3.org/2000/svg" xmlns:inkscape="http://www.inkscape.org/namespaces/inkscape" '
				.. 'xmlns:sodipodi="http://sodipodi.sourceforge.net/DTD/sodipodi-0.dtd" width="32" height="16" '
				.. 'sodipodi:docname="secret-name.svg" inkscape:export-filename="/Users/secret/out.png">'
				.. '<sodipodi:namedview id="view" inkscape:zoom="2"/>'
				.. "<metadata><rdf:RDF>MetaClean Test User</rdf:RDF></metadata>"
				.. '<defs><linearGradient id="g"><stop offset="0" stop-color="#f00"/></linearGradient></defs>'
				.. "<title>Chart</title>"
				.. '<rect width="32" height="16" fill="url(#g)" inkscape:label="Layer by secret"/></svg>\n'
		)
		path = absolute(path)
		assert_sanitized(path)
		local cleaned = read_bytes(path)
		assert_absent(cleaned, { "secret", "MetaClean", "Illustrator", "namedview", "<metadata" })
		assert_present(cleaned, { '<?xml version="1.0"', 'fill="url(#g)"', "<title>Chart</title>", "</svg>" })
	end)

	record("SVG with the standard DOCTYPE and an XMP packet is cleaned", function()
		-- Illustrator writes the W3C document type and wraps XMP in packet
		-- markers inside <metadata>.
		local path = absolute(RUN .. "/illustrator.svg")
		write_bytes(
			path,
			'<?xml version="1.0" encoding="UTF-8"?>\n'
				.. "<!DOCTYPE svg PUBLIC '-//W3C//DTD SVG 1.1//EN' "
				.. "'http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd'>\n"
				.. '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><metadata>'
				.. '<?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?><x:xmpmeta xmlns:x="adobe:ns:meta/">'
				.. 'MetaClean Test User</x:xmpmeta><?xpacket end="w"?></metadata>'
				.. '<rect width="10" height="10"/></svg>\n'
		)
		assert_sanitized(path)
		local cleaned = read_bytes(path)
		assert_absent(cleaned, { "MetaClean", "xpacket", "<metadata" })
		assert_present(cleaned, { "<!DOCTYPE svg PUBLIC", "<rect" })
		assert(select(2, process(path)) == "unchanged", "cleaned SVG is not reported clean")
	end)

	record("active or external SVG content is skipped unchanged", function()
		local cases = {
			{ "script.svg", '<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>', "active" },
			{ "onload.svg", '<svg xmlns="http://www.w3.org/2000/svg" onload="x()"></svg>', "active" },
			{
				"external.svg",
				'<svg xmlns="http://www.w3.org/2000/svg"><image href="https://example.invalid/a.png"/></svg>',
				"external",
			},
			{
				"data.svg",
				'<svg xmlns="http://www.w3.org/2000/svg"><image href="data:image/png;base64,AA"/></svg>',
				"external",
			},
			{
				"css.svg",
				'<svg xmlns="http://www.w3.org/2000/svg"><rect style="fill:url(http://x/y)"/></svg>',
				"external",
			},
			{
				"doctype.svg",
				'<!DOCTYPE svg [ <!ENTITY who "Secret"> ]><svg xmlns="http://www.w3.org/2000/svg">&who;</svg>',
				"DOCTYPE",
			},
			{
				"late-doctype.svg",
				'<svg xmlns="http://www.w3.org/2000/svg"><!DOCTYPE svg></svg>',
				"DOCTYPE",
			},
			{
				"instruction.svg",
				'<svg xmlns="http://www.w3.org/2000/svg"><?php echo 1 ?></svg>',
				"processing",
			},
			{ "nested.svg", '<svg xmlns="http://www.w3.org/2000/svg"><g></svg>', "nesting" },
		}
		-- ExifTool classifies some tiny SVGs as text, so the parser's reason is
		-- checked directly and the transaction only has to leave them alone.
		for _, case in ipairs(cases) do
			local path = absolute(RUN .. "/" .. case[1])
			write_bytes(path, case[2])
			local parsed, err = helpers.svg_parse(path)
			assert(parsed == nil and tostring(err):find(case[3]), case[1] .. ": " .. tostring(err))
			assert_skipped(path)
		end
	end)

	-- WebP ---------------------------------------------------------------------

	-- An RGBA source makes cwebp write a separate ALPH chunk for lossy output.
	local function webp_fixture(name, args, rgba)
		local source = RUN .. "/" .. name .. ".png"
		assert(execute({
			"ffmpeg",
			"-hide_banner",
			"-loglevel",
			"error",
			"-f",
			"lavfi",
			"-i",
			rgba and "testsrc2=s=37x23,format=rgba,colorchannelmixer=aa=0.5" or "testsrc2=s=37x23",
			"-frames:v",
			"1",
			"-pix_fmt",
			rgba and "rgba" or "rgb24",
			"-y",
			source,
		}))
		local path = RUN .. "/" .. name .. ".webp"
		local full = { "cwebp", "-quiet" }
		for _, arg in ipairs(args) do
			full[#full + 1] = arg
		end
		full[#full + 1] = source
		full[#full + 1] = "-o"
		full[#full + 1] = path
		assert(execute(full))
		return absolute(path)
	end

	record("WebP transaction drops EXIF, XMP and unknown chunks", function()
		for _, variant in ipairs({
			{ "lossless", { "-lossless" } },
			{ "lossy", { "-q", "80" } },
			{ "lossless-alpha", { "-lossless" }, true },
			{ "lossy-alpha", { "-q", "80" }, true },
		}) do
			local path = webp_fixture("webp-" .. variant[1], variant[2], variant[3])
			if variant[1] == "lossy-alpha" then
				assert(read_bytes(path):find("ALPH", 1, true), "lossy alpha fixture has no ALPH chunk")
			end
			exiftool({ "-Artist=MetaClean Test User", "-XMP-dc:Creator=MetaClean Test User", "-GPSLatitude=1", path })
			local data = read_bytes(path)
			data = data .. "PRIV" .. string.pack("<I4", 5) .. "owner\0"
			write_bytes(path, "RIFF" .. string.pack("<I4", #data - 8) .. data:sub(9))
			local before = framehash(path)
			assert_sanitized(path)
			local cleaned = read_bytes(path)
			assert(
				not cleaned:find("MetaClean", 1, true) and not cleaned:find("owner", 1, true),
				"WebP identity bytes remain"
			)
			assert(
				not cleaned:find("EXIF", 1, true) and not cleaned:find("XMP ", 1, true),
				"WebP metadata chunk remains"
			)
			assert(framehash(path) == before, "decoded WebP changed: " .. variant[1])
		end
	end)

	record("WebP orientation is kept as a minimal EXIF chunk", function()
		local path = webp_fixture("webp-oriented", { "-q", "80" })
		exiftool({ "-EXIF:Orientation#=6", "-Artist=MetaClean Test User", "-GPSLatitude=1", path })
		local before = framehash(path)
		assert_sanitized(path)
		local after = tags(path)
		assert_present(after, { "[IFD0]          Orientation                     : 6" })
		assert_absent(after, { "MetaClean Test User", "GPS", "Artist" })
		assert(read_bytes(path):sub(-34) == "EXIF" .. string.pack("<I4", 26) .. helpers.minimal_exif(6), "EXIF chunk")
		assert(framehash(path) == before, "decoded WebP changed")
		assert(select(2, process(path)) == "unchanged", "cleaned oriented WebP is not reported clean")
		-- An Exif header before the TIFF data, which only some viewers read.
		local prefixed = webp_fixture("webp-exif-header", { "-q", "80" })
		exiftool({ "-EXIF:Orientation#=6", prefixed })
		local data = read_bytes(prefixed)
		local at = assert(data:find("EXIF", 13, true), "EXIF chunk not found")
		local length = string.unpack("<I4", data, at + 4)
		local payload = "Exif\0\0" .. data:sub(at + 8, at + 7 + length)
		data = data:sub(1, at - 1) .. "EXIF" .. string.pack("<I4", #payload) .. payload .. data:sub(at + 8 + length)
		write_bytes(prefixed, "RIFF" .. string.pack("<I4", #data - 8) .. data:sub(9))
		assert_skipped(prefixed, "viewers may read differently")
	end)

	record("JPEG XL keeps its codestream and drops Exif, XMP and reconstruction data", function()
		local function pixels(path)
			local ok, out = execute_stdout({ "djxl", path, "-", "--output_format=ppm", "--quiet" })
			assert(ok, out)
			return out
		end
		local source = RUN .. "/jxl-source.png"
		assert(execute({
			"ffmpeg",
			"-v",
			"error",
			"-f",
			"lavfi",
			"-i",
			"testsrc2=s=64x48",
			"-frames:v",
			"1",
			"-y",
			source,
		}))
		local comment = RUN .. "/jxl-source.jpg"
		assert(execute({ "ffmpeg", "-v", "error", "-i", source, "-y", comment }))
		exiftool({ "-Comment=MetaClean Test Comment", "-Artist=MetaClean Test User", comment })
		for _, case in ipairs({
			{ "lossy.jxl", source, { "-d", "1", "--container=1" } },
			{ "recompressed.jxl", comment, { "--lossless_jpeg=1" } },
		}) do
			local path = RUN .. "/" .. case[1]
			local args = { "cjxl", case[2], path, "--quiet" }
			table.move(case[3], 1, #case[3], #args + 1, args)
			assert(execute(args))
			exiftool({ "-Model=MetaClean Test Camera", "-XMP-dc:Creator=MetaClean Test User", "-GPSLatitude=1", path })
			local before = pixels(path)
			assert_sanitized(absolute(path))
			local cleaned = read_bytes(path)
			for _, needle in ipairs({ "MetaClean", "Exif", "xml ", "jbrd" }) do
				assert(not cleaned:find(needle, 1, true), "JPEG XL metadata remains: " .. needle)
			end
			assert(pixels(path) == before, "decoded JPEG XL changed: " .. case[1])
			local result, detail = process(absolute(path))
			assert(result and detail == "unchanged", "JPEG XL rerun was not clean: " .. tostring(detail))
		end

		local path = RUN .. "/unknown-box.jxl"
		assert(execute({ "cjxl", source, path, "--quiet", "--container=1" }))
		write_bytes(path, read_bytes(path) .. string.pack(">I4", 13) .. "priv" .. "owner")
		assert_skipped(absolute(path), "unsupported JPEG XL box priv")
	end)

	record("animated WebP keeps its frames and drops EXIF and XMP", function()
		local frames = RUN .. "/anim.gif"
		assert(execute({
			"ffmpeg",
			"-hide_banner",
			"-loglevel",
			"error",
			"-f",
			"lavfi",
			"-i",
			"testsrc2=s=24x16:r=4",
			"-t",
			"1",
			"-y",
			frames,
		}))
		for _, variant in ipairs({ { "lossless" }, { "lossy", "-lossy", "-mixed" } }) do
			local path = absolute(RUN .. "/anim-" .. variant[1] .. ".webp")
			local args = { "gif2webp", "-quiet" }
			table.move(variant, 2, #variant, 3, args)
			args[#args + 1] = frames
			args[#args + 1] = "-o"
			args[#args + 1] = path
			assert(execute(args))
			local original, before = read_bytes(path), framehash(path)
			exiftool({ "-Artist=MetaClean Test User", "-XMP-dc:Creator=MetaClean Test User", "-GPSLatitude=1", path })
			assert_sanitized(path)
			assert(read_bytes(path) == original, "animated WebP is not the original animation: " .. variant[1])
			assert(framehash(path) == before, "decoded animation changed: " .. variant[1])
		end

		-- An unknown chunk inside a frame would be copied along with it.
		local path = absolute(RUN .. "/anim-lossless.webp")
		local data = read_bytes(path)
		local anmf = assert(data:find("ANMF", 13, true))
		local size = string.unpack("<I4", data, anmf + 4)
		local finish = anmf + 8 + size + size % 2
		data = data:sub(1, anmf + 3)
			.. string.pack("<I4", size + size % 2 + 14)
			.. data:sub(anmf + 8, finish - 1)
			.. "PRIV"
			.. string.pack("<I4", 6)
			.. "owner\0"
			.. data:sub(finish)
		write_bytes(path, "RIFF" .. string.pack("<I4", #data - 8) .. data:sub(9))
		assert_skipped(path, "frame chunks")
	end)

	-- QuickTime ----------------------------------------------------------------

	local function quicktime_identity(path)
		exiftool({
			"-Keys:GPSCoordinates=48.85 N, 2.35 E",
			"-XMP-dc:Creator=MetaClean Test User",
			"-QuickTime:CreateDate=2020:01:02 03:04:05",
			"-QuickTime:TrackCreateDate=2020:01:02 03:04:05",
			path,
		})
	end

	for _, case in ipairs({
		{ "MP4", mp4_safe, "mp4" },
		{ "M4V", m4v_safe, "m4v" },
		{ "M4A", m4a_safe, "m4a" },
		{ "MOV", mov_safe, "mov" },
	}) do
		record(case[1] .. " transaction neutralizes metadata in place", function()
			local path = copy_fixture(case[2], "identity." .. case[3])
			quicktime_identity(path)
			assert_present(tags(path), { "MetaClean Test User", "2020:01:02" })
			local size = #read_bytes(path)
			local ok, packets_before =
				execute({ "ffprobe", "-v", "error", "-show_packets", "-show_data_hash", "sha256", path })
			assert(ok, packets_before)
			assert_sanitized(path)
			local after = tags(path)
			assert_absent(after, { "MetaClean Test User", "Private", "48.85", "2020:01:02", "Lavf" })
			assert(#read_bytes(path) == size, "QuickTime file size changed")
			local _, packets_after =
				execute({ "ffprobe", "-v", "error", "-show_packets", "-show_data_hash", "sha256", path })
			assert(packets_after == packets_before, "QuickTime packets changed")
			neutral_dates(path)
		end)
	end

	record("QuickTime codec boxes are kept and audio-only files are cleaned", function()
		for _, case in ipairs({
			{ "opus.mp4", { "-c:a", "libopus" } },
			{ "flac.mp4", { "-c:a", "flac", "-strict", "-2" } },
			{ "recording.mov", { "-c:a", "pcm_s16le" } },
		}) do
			local path = RUN .. "/" .. case[1]
			local args = { "ffmpeg", "-v", "error", "-f", "lavfi", "-i", "sine=d=1:sample_rate=48000" }
			table.move(case[2], 1, #case[2], #args + 1, args)
			args[#args + 1] = "-y"
			args[#args + 1] = path
			assert(execute(args))
			path = absolute(path)
			quicktime_identity(path)
			local _, packets_before =
				execute({ "ffprobe", "-v", "error", "-show_packets", "-show_data_hash", "sha256", path })
			assert_sanitized(path)
			assert_absent(tags(path), { "MetaClean Test User", "48.85", "2020:01:02" })
			local _, packets_after =
				execute({ "ffprobe", "-v", "error", "-show_packets", "-show_data_hash", "sha256", path })
			assert(packets_after == packets_before, "QuickTime packets changed: " .. case[1])
		end

		-- A dfLa box larger than the stream information holds other FLAC blocks,
		-- such as Vorbis comments.
		local key = "Track1:Unknown_dfLa"
		local ok, err = helpers.policies.MP4.preflight(absolute(RUN .. "/flac.mp4"), {
			entries = { key },
			values = { [key] = { "(Binary data 60 bytes, use -b option to extract)" } },
		})
		assert(not ok and tostring(err):find("dfLa box size", 1, true), "oversized dfLa box was accepted")
		-- ExifTool prints a two-byte chroma location as text.
		key = "Track1:Unknown_chrm"
		for value, accepted in pairs({ [""] = true, ["\1"] = true, ["abc"] = false }) do
			ok, err = helpers.policies.MP4.preflight(absolute(RUN .. "/flac.mp4"), {
				entries = { key },
				values = { [key] = { value } },
			})
			assert((ok ~= nil) == accepted, "chrm value " .. value .. ": " .. tostring(err))
		end
	end)

	record("AVFoundation HEVC export is cleaned", function()
		-- avconvert writes the chroma location (chrm) in its HEVC sample entry.
		local path = absolute(RUN .. "/avconvert.mp4")
		local ok, out = execute({ "avconvert", "-s", mp4_safe, "-o", path, "-p", "PresetHEVC1920x1080" })
		assert(ok, out)
		assert(tags(path, { "-u" }):find("Unknown_chrm", 1, true), "export lacks a chrm box")
		local frames = framehash(path)
		assert_sanitized(path)
		assert(framehash(path) == frames, "decoded video changed")
		assert(select(2, process(path)) == "unchanged", "cleaned export is not reported clean")
	end)

	record("QuickTime media data no sample uses is zeroed", function()
		-- Editors can leave an earlier movie box inside the media data.
		local path = RUN .. "/stale.mp4"
		assert(execute({
			"ffmpeg",
			"-v",
			"error",
			"-f",
			"lavfi",
			"-i",
			"testsrc2=s=64x48:d=1",
			"-c:v",
			"libx264",
			"-movflags",
			"+faststart",
			"-y",
			path,
		}))
		local data = read_bytes(path)
		local at = assert(data:find("mdat", 1, true)) - 4
		assert(string.unpack(">I4", data, at) == #data - at + 1, "media data is not the last box")
		local stale = "udta" .. "\0\0\0\0" .. "MetaClean Stale Camera"
		data = data:sub(1, at - 1) .. string.pack(">I4", #data - at + 1 + #stale) .. data:sub(at + 4) .. stale
		write_bytes(path, data)
		path = absolute(path)
		local ok, packets_before =
			execute({ "ffprobe", "-v", "error", "-show_packets", "-show_data_hash", "sha256", path })
		assert(ok, packets_before)
		assert_sanitized(path)
		local cleaned = read_bytes(path)
		assert(#cleaned == #data and not cleaned:find("MetaClean", 1, true), "unused media data remains")
		local _, packets_after =
			execute({ "ffprobe", "-v", "error", "-show_packets", "-show_data_hash", "sha256", path })
		assert(packets_after == packets_before, "QuickTime packets changed")
		assert(select(2, process(path)) == "unchanged", "cleaned file is not reported clean")
	end)

	record("preview window lists files sorted, with removed tags by group", function()
		local lines = helpers.preview_report("/media", {
			{
				path = "/media/b.jpg",
				removed = {
					"IFD0:Model",
					"Filesystem:Finder tags",
					"GPS:GPSLatitude",
					"File:Comment",
					"IFD0:Make",
					"JPEG comment segment",
				},
			},
			{ path = "/media/A/c.mov", removed = { "Track1:Encoder", "ItemList:Title" } },
		}, { { path = "/media/clean.png" } }, {
			{ path = "/media/z.pdf", reason = "unsupported format PDF" },
			{ path = "/elsewhere/y.txt", reason = "unsupported format TXT" },
		})
		local text, kinds = {}, {}
		for index, line in ipairs(lines) do
			text[index], kinds[index] = line.text, line.kind
		end
		local expected = {
			"2 to clean · 1 already clean · 2 would be skipped",
			"",
			"To clean (2)",
			"  A/c.mov",
			"    ItemList  Title",
			"    Track1    Encoder",
			"  b.jpg",
			"    File        Comment",
			"    GPS         GPSLatitude",
			"    IFD0        Make, Model",
			"    Filesystem  Finder tags",
			"    JPEG comment segment",
			"",
			"Already clean (1)",
			"  clean.png",
			"",
			"Would be skipped (2)",
			"  /elsewhere/y.txt",
			"    Unsupported format TXT",
			"  z.pdf",
			"    Unsupported format PDF",
		}
		assert(table.concat(text, "\n") == table.concat(expected, "\n"), "report:\n" .. table.concat(text, "\n"))
		assert(kinds[1] == "summary" and kinds[3] == "clean" and kinds[17] == "skipped" and kinds[19] == "reason")
		-- Long tag lists wrap under their group with a hanging indent.
		local tags = {}
		for index = 1, 30 do
			tags[index] = string.format("XMP-test:LongTagName%02d", index)
		end
		lines = helpers.preview_report("/media", { { path = "/media/x.jpg", removed = tags } }, {}, {})
		assert(#lines > 5 and lines[5].text:find("^    XMP%-test  LongTagName01,"), "long tag list was not wrapped")
		for index = 5, #lines do
			assert(#lines[index].text <= 76, "line too wide: " .. lines[index].text)
			assert(
				index == 5 or lines[index].text:find("^" .. string.rep(" ", 14) .. "%S"),
				"wrapped line not indented"
			)
		end
	end)

	record("preview reports removals and changes nothing", function()
		local path = copy_fixture(jpg, "preview-identity.jpg")
		exiftool({ "-Artist=MetaClean Test User", "-GPSLatitude=1", "-GPSLatitudeRef=N", path })
		local before = sha(path)
		local plugin, restore = production_plugin()
		local ok, result, detail, removed = pcall(plugin._test.process_file, path, 1, true)
		restore()
		assert(ok, result)
		no_stage_left()
		assert(result == true and detail == "preview", "expected a preview, got: " .. tostring(detail))
		local listed = table.concat(removed, "\n")
		assert_present(listed, { "IFD0:Artist", "GPS:GPSLatitude" })
		assert(sha(path) == before, "preview changed the file")
		assert_sanitized(path)
		plugin, restore = production_plugin()
		ok, result, detail = pcall(plugin._test.process_file, path, 1, true)
		restore()
		assert(ok and result == true and detail == "unchanged", "clean file preview: " .. tostring(detail))

		-- A file whose kept bytes hold this Mac's home folder path is skipped
		-- by both, never reported clean.
		local wav = absolute(RUN .. "/home-path.wav")
		assert(
			execute({ "ffmpeg", "-v", "error", "-f", "lavfi", "-i", "anullsrc=d=1", "-fflags", "+bitexact", "-y", wav })
		)
		local _, login = execute({ "id", "-un" })
		local text = "/Users/" .. login:gsub("%s+$", "") .. "/Music/take.wav"
		local data = read_bytes(wav)
		write_bytes(wav, data:sub(1, -#text - 1) .. text)
		assert(execute({ "touch", "-t", "200101010000.00", wav }))
		plugin, restore = production_plugin()
		ok, result, detail = pcall(plugin._test.process_file, wav, 1, true)
		restore()
		assert(ok and result == nil and tostring(detail):find("user name", 1, true), "preview: " .. tostring(detail))
		assert_skipped(wav, "user name")
	end)

	record("iTunes gapless and loudness values survive in M4A", function()
		-- iTunes keeps the encoder delay only in a freeform iTunSMPB item; a
		-- player that loses it plays the priming samples as silence.
		local path = RUN .. "/itunes.m4a"
		assert(execute({
			"ffmpeg",
			"-v",
			"error",
			"-f",
			"lavfi",
			"-i",
			"sine=d=1",
			"-c:a",
			"aac",
			"-metadata",
			"title=Private audio title",
			"-metadata",
			"artist=MetaClean Test User",
			"-y",
			path,
		}))
		local function freeform(name, value)
			local mean = string.pack(">I4", 28) .. "mean\0\0\0\0com.apple.iTunes"
			local label = string.pack(">I4", 12 + #name) .. "name\0\0\0\0" .. name
			local data = string.pack(">I4", 16 + #value) .. "data\0\0\0\1\0\0\0\0" .. value
			return string.pack(">I4", 8 + #mean + #label + #data) .. "----" .. mean .. label .. data
		end
		local smpb = " 00000000 00000840 000001C0 000000000000AC44 00000000 00000000"
		local items = freeform("iTunSMPB", smpb) .. freeform("iTunNORM", " 000009D0 00000C06")
		local data = read_bytes(path)
		local ilst = assert(data:find("ilst", 1, true)) - 4
		local skip = { moov = 0, udta = 0, meta = 4, ilst = 0 }
		local function grow(position, finish)
			while position < finish do
				local size, kind = string.unpack(">I4c4", data, position)
				if position <= ilst and ilst < position + size then
					data = data:sub(1, position - 1) .. string.pack(">I4", size + #items) .. data:sub(position + 4)
					if kind == "ilst" then
						return
					end
					return grow(position + 8 + assert(skip[kind], kind), position + size)
				end
				position = position + size
			end
		end
		grow(1, #data + 1)
		data = data:sub(1, ilst + 7) .. items .. data:sub(ilst + 8)
		write_bytes(path, data)
		path = absolute(path)
		assert_present(tags(path), { "iTunSMPB", "Private audio title" })
		local audio = framehash(path, "0:a:0")
		local size = #read_bytes(path)
		assert_sanitized(path)
		local after = tags(path)
		assert_absent(after, { "Private audio title", "MetaClean Test User", "Lavf" })
		assert_present(after, { "iTunSMPB", "000001C0", "VolumeNormalization" })
		assert(#read_bytes(path) == size, "M4A size changed")
		assert(framehash(path, "0:a:0") == audio, "decoded audio changed")
		assert(select(2, process(path)) == "unchanged", "cleaned M4A is not reported clean")
	end)

	record("C2PA Content Credentials boxes are removed from MP4 and HEIC", function()
		local c2pa = "\216\254\195\214\27\14\72\60\146\151\88\40\135\126\196\129"
		local manifest = "\0\0\0\0manifest\0" .. "MetaClean Test Creator"
		local box = string.pack(">I4", 8 + 16 + #manifest) .. "uuid" .. c2pa .. manifest
		local video = copy_fixture(mp4_safe, "c2pa.mp4")
		write_bytes(video, read_bytes(video) .. box)
		local image = absolute(RUN .. "/c2pa.heic")
		assert(execute({ "heif-enc", "-q", "60", png, "-o", image }))
		write_bytes(image, read_bytes(image) .. box)
		for _, path in ipairs({ video, image }) do
			local size = #read_bytes(path)
			assert_sanitized(path)
			local data = read_bytes(path)
			assert(#data == size, "file size changed: " .. path)
			assert(not data:find("MetaClean Test Creator", 1, true), "C2PA manifest remains: " .. path)
			assert(not data:find(c2pa, 1, true), "C2PA box remains: " .. path)
			assert(select(2, process(path)) == "unchanged", "cleaned file is not reported clean: " .. path)
		end
	end)

	record("KDDI phone uuid boxes are removed from 3GPP video", function()
		local suffix = "\168\140\17\212\129\151\0\144\39\8\119\3"
		local payload = "\0\0\0\0" .. "KDDI-MetaClean-Phone\0"
		local box = string.pack(">I4", 8 + 16 + #payload) .. "uuid" .. "enci" .. suffix .. payload
		local path = copy_fixture(mp4_safe, "kddi.3g2")
		write_bytes(path, read_bytes(path) .. box)
		assert_present(tags(path), { "UUID-Unknown" })
		local size = #read_bytes(path)
		assert_sanitized(path)
		local data = read_bytes(path)
		assert(#data == size, "file size changed")
		assert(not data:find("KDDI-MetaClean-Phone", 1, true), "KDDI encoder box remains")
		assert(select(2, process(path)) == "unchanged", "cleaned file is not reported clean")
	end)

	record("removed values left in kept data are found", function()
		-- Action cameras repeat their model in H.264 SEI user data, which no
		-- format parser removes.
		local path = RUN .. "/sei.mp4"
		assert(execute({
			"ffmpeg",
			"-v",
			"error",
			"-f",
			"lavfi",
			"-i",
			"testsrc2=s=64x48:d=1",
			"-c:v",
			"libx264",
			"-bsf:v",
			"h264_metadata=sei_user_data=086f3693-b7b3-4f2c-9653-21492feee5b8+MetaClean Action Cam 4K",
			"-y",
			path,
		}))
		exiftool({ "-XMP-tiff:Model=MetaClean Action Cam 4K", path })
		assert_skipped(absolute(path), "removed metadata value still present: MetaClean Action Cam 4K")

		local residue = helpers.identity_residue
		local spec = helpers.policies.PNG.spec
		local function inventory(values)
			local result = { entries = {}, values = {} }
			for key, value in pairs(values) do
				result.entries[#result.entries + 1] = key
				result.values[key] = { value }
			end
			return result
		end
		local file = RUN .. "/residue.bin"
		write_bytes(file, "\0\0" .. ("Owner Name"):gsub(".", "%0\0") .. "\0Apple\0" .. "Kept Model 7")
		local before = inventory({ ["IFD0:Artist"] = "Owner Name" })
		local ok, err = residue(absolute(file), before, inventory({}), spec)
		assert(not ok and err:find("Owner Name", 1, true), "UTF-16 residue was not found")
		write_bytes(file, "\0\0" .. ("Owner Name"):gsub(".", "\0%0") .. "\0\0")
		ok, err = residue(absolute(file), before, inventory({}), spec)
		assert(not ok and err:find("Owner Name", 1, true), "UTF-16BE residue was not found")
		-- A value split by the 64 KiB read boundary.
		write_bytes(file, string.rep("\0", 65536 - 4) .. "Owner Name")
		ok, err = residue(absolute(file), before, inventory({}), spec)
		assert(not ok and err:find("Owner Name", 1, true), "residue across a read boundary was not found")
		write_bytes(file, "\0\0" .. ("Owner Name"):gsub(".", "%0\0") .. "\0Apple\0" .. "Kept Model 7")
		before = inventory({ ["IFD0:Make"] = "Apple", ["XMP-tiff:Model"] = "Kept Model 7" })
		ok, err =
			residue(absolute(file), before, inventory({ ["ICC_Profile:ProfileDescription"] = "Kept Model 7" }), spec)
		assert(ok, "short or kept values were searched: " .. tostring(err))
		-- This Mac's home folder path is found even with nothing removed.
		local _, login = execute({ "id", "-un" })
		write_bytes(file, "project=/Users/" .. login:gsub("%s+$", "") .. "/Movies/edit.prproj")
		ok, err = residue(absolute(file), inventory({}), inventory({}), spec)
		assert(not ok and err:find("user name", 1, true), "home folder path was not found")
		-- Even when a kept tag, such as a track handler name, holds it.
		local home = "/Users/" .. login:gsub("%s+$", "")
		ok, err = residue(absolute(file), inventory({}), inventory({ ["Track1:HandlerDescription"] = home }), spec)
		assert(not ok and err:find("user name", 1, true), "home folder path in a kept tag was not found")
	end)

	record("QuickTime chapter tracks are kept", function()
		local chapters = RUN .. "/chapters.txt"
		write_bytes(
			chapters,
			";FFMETADATA1\nartist=MetaClean Test User\n"
				.. "[CHAPTER]\nTIMEBASE=1/1000\nSTART=0\nEND=1000\ntitle=Opening\n"
				.. "[CHAPTER]\nTIMEBASE=1/1000\nSTART=1000\nEND=2000\ntitle=Second\n"
		)
		local function show_chapters(path)
			local ok, out = execute({ "ffprobe", "-v", "error", "-show_chapters", "-of", "compact", path })
			assert(ok, out)
			return out
		end
		for _, case in ipairs({
			{ "book.m4b", { "-f", "lavfi", "-i", "sine=d=2" }, { "-c:a", "aac" } },
			{ "chapters.mp4", { "-f", "lavfi", "-i", "testsrc2=s=64x48:d=2" }, { "-c:v", "libx264" } },
		}) do
			local path = RUN .. "/" .. case[1]
			local args = { "ffmpeg", "-v", "error" }
			table.move(case[2], 1, #case[2], #args + 1, args)
			for _, arg in ipairs({ "-i", chapters, "-map_metadata", "1", "-map_chapters", "1" }) do
				args[#args + 1] = arg
			end
			table.move(case[3], 1, #case[3], #args + 1, args)
			args[#args + 1] = "-y"
			args[#args + 1] = path
			assert(execute(args))
			path = absolute(path)
			local before = show_chapters(path)
			assert(before:find("title=Second", 1, true), "fixture has no chapters: " .. case[1])
			assert_sanitized(path)
			assert(show_chapters(path) == before, "chapters changed: " .. case[1])
			assert(not read_bytes(path):find("MetaClean", 1, true), "identity remains: " .. case[1])
		end

		-- A chapter track whose samples are not QuickTime text is not kept.
		local path = absolute(RUN .. "/book.m4b")
		local data, at = read_bytes(path), 0
		repeat
			at = assert(data:find("stsd", at + 1, true), "no text sample description")
		until data:sub(at + 16, at + 19) == "text"
		write_bytes(path, data:sub(1, at + 15) .. "txtx" .. data:sub(at + 20))
		assert_skipped(path, "data stream")
	end)

	record("MOV track names are removed", function()
		local path = RUN .. "/track-name.mov"
		assert(execute({
			"ffmpeg",
			"-hide_banner",
			"-loglevel",
			"error",
			"-f",
			"lavfi",
			"-i",
			"testsrc2=s=64x48:r=5",
			"-t",
			"1",
			"-c:v",
			"libx264",
			"-metadata:s:v:0",
			"title=Secret track",
			"-y",
			path,
		}))
		path = absolute(path)
		assert_present(tags(path), { "Secret track" })
		assert_sanitized(path)
		assert_absent(tags(path), { "Secret track" })
	end)

	record("M4A and MP4 cover art is removed", function()
		local cover = RUN .. "/cover.png"
		assert(execute({
			"ffmpeg",
			"-hide_banner",
			"-loglevel",
			"error",
			"-f",
			"lavfi",
			"-i",
			"color=c=blue:s=64x64",
			"-frames:v",
			"1",
			"-y",
			cover,
		}))
		for _, case in ipairs({ { m4a_safe, "cover.m4a", "0:a" }, { mp4_safe, "cover.mp4", "0:a" } }) do
			local path = RUN .. "/" .. case[2]
			assert(execute({
				"ffmpeg",
				"-hide_banner",
				"-loglevel",
				"error",
				"-i",
				case[1],
				"-i",
				cover,
				"-map",
				"0",
				"-map",
				"1",
				"-c",
				"copy",
				"-disposition:v:" .. (case[2] == "cover.mp4" and "1" or "0"),
				"attached_pic",
				"-y",
				path,
			}))
			path = absolute(path)
			local _, before =
				execute({ "ffprobe", "-v", "error", "-show_entries", "stream_disposition=attached_pic", path })
			assert(before:find("attached_pic=1", 1, true), "fixture has no cover art: " .. before)
			local _, packets = execute({
				"ffprobe",
				"-v",
				"error",
				"-select_streams",
				"a",
				"-show_packets",
				"-show_data_hash",
				"sha256",
				path,
			})
			assert_sanitized(path)
			local _, after =
				execute({ "ffprobe", "-v", "error", "-show_entries", "stream_disposition=attached_pic", path })
			assert(not after:find("attached_pic=1", 1, true), "cover art remains: " .. after)
			local _, packets_after = execute({
				"ffprobe",
				"-v",
				"error",
				"-select_streams",
				"a",
				"-show_packets",
				"-show_data_hash",
				"sha256",
				path,
			})
			assert(packets_after == packets, "audio packets changed")
		end
	end)

	local function media_frames(path)
		local ok, out = execute({
			"ffmpeg",
			"-hide_banner",
			"-loglevel",
			"error",
			"-i",
			path,
			"-map",
			"0:v",
			"-map",
			"0:a?",
			"-f",
			"framemd5",
			"-",
		})
		assert(ok, out)
		return (out:gsub("#[^\n]*\n", ""))
	end

	local function stream_entries(path, entries)
		local ok, out = execute({ "ffprobe", "-v", "error", "-show_entries", entries, "-of", "csv=p=0", path })
		assert(ok, out)
		return out
	end

	record("MOV timecode and timed metadata tracks are removed", function()
		for _, variant in ipairs({ "tmcd", "mebx" }) do
			local path = RUN .. "/timed-" .. variant .. ".mov"
			assert(execute({
				"ffmpeg",
				"-hide_banner",
				"-loglevel",
				"error",
				"-i",
				mov_safe,
				"-c",
				"copy",
				"-timecode",
				"01:00:00:00",
				"-y",
				path,
			}))
			if variant == "mebx" then
				-- Turn the timecode track into a timed-metadata track like
				-- Apple's: media handler "meta", sample entry "mebx".
				local data = read_bytes(path)
				local handlers, entries
				data, handlers = data:gsub("mhlrtmcd", "mhlrmeta", 1)
				data, entries = data:gsub("stsd(............)tmcd", "stsd%1mebx", 1)
				assert(handlers == 1 and entries == 1, "fixture lacks a timecode track")
				write_bytes(path, data)
			end
			path = absolute(path)
			assert(stream_entries(path, "stream=codec_tag_string"):find(variant, 1, true), "fixture lacks the track")
			local frames = media_frames(path)
			assert_sanitized(path)
			assert(not stream_entries(path, "stream=codec_type"):find("data", 1, true), "data track remains")
			assert(not stream_entries(path, "stream_tags=timecode"):find("01:00", 1, true), "timecode remains")
			assert_absent(tags(path), { "TimeCode", "mebx" })
			assert(media_frames(path) == frames, "media frames changed")
			assert(select(2, process(path)) == "unchanged", "cleaned MOV is not reported clean")
		end
	end)

	record("fragmented MP4 and MOV are cleaned in place", function()
		-- Base offsets in each fragment header, from the fragment box, or
		-- implied by the data before; wall-clock reference times; a timecode
		-- track, whose fragment headers go with it.
		local variants = {
			{ "mp4", "frag_keyframe+empty_moov" },
			{ "mp4", "frag_keyframe+empty_moov+default_base_moof" },
			{ "mp4", "empty_moov+separate_moof", "-frag_duration", "200000" },
			{ "mp4", "empty_moov+omit_tfhd_offset", "-frag_duration", "500000" },
			{ "mp4", "frag_keyframe+empty_moov", "-write_prft", "wallclock" },
			{ "mov", "frag_keyframe+empty_moov", "-timecode", "01:00:00:00" },
		}
		local first
		for index, variant in ipairs(variants) do
			local path = RUN .. "/fragmented-" .. index .. "." .. variant[1]
			local command = { "ffmpeg", "-hide_banner", "-loglevel", "error", "-i", mp4_safe, "-c", "copy" }
			for _, arg in ipairs({ "-metadata", "title=Private fragment title", "-movflags", variant[2] }) do
				command[#command + 1] = arg
			end
			for at = 3, #variant do
				command[#command + 1] = variant[at]
			end
			command[#command + 1] = "-y"
			command[#command + 1] = path
			assert(execute(command))
			path = absolute(path)
			first = first or read_bytes(path)
			local data = read_bytes(path)
			assert(data:find("moof", 1, true), "fixture is not fragmented: " .. path)
			assert(data:find("Private fragment title", 1, true), "fixture lacks its title: " .. path)
			local prft = data:find("prft", 1, true)
			local frames = media_frames(path)
			assert_sanitized(path)
			local cleaned = read_bytes(path)
			assert(#cleaned == #data, "file size changed: " .. path)
			assert(not cleaned:find("Private fragment title", 1, true), "title remains: " .. path)
			assert(not prft or not cleaned:find("prft", 1, true), "producer reference time remains: " .. path)
			assert(not stream_entries(path, "stream=codec_type"):find("data", 1, true), "data track remains: " .. path)
			assert(media_frames(path) == frames, "media frames changed: " .. path)
			assert(select(2, process(path)) == "unchanged", "cleaned file is not reported clean: " .. path)
		end
		-- A fragment of a track the movie does not have is refused.
		local at = first:find("tfhd", 1, true)
		local path = absolute(RUN .. "/fragmented-unknown.mp4")
		write_bytes(path, first:sub(1, at + 7) .. string.pack(">I4", 9) .. first:sub(at + 12))
		assert_skipped(path, "fragment for an unknown track")
	end)

	record("3GP transaction neutralizes metadata in place", function()
		local path = RUN .. "/identity.3gp"
		assert(execute({
			"ffmpeg",
			"-hide_banner",
			"-loglevel",
			"error",
			"-i",
			mp4_safe,
			"-c",
			"copy",
			"-f",
			"3gp",
			"-y",
			path,
		}))
		path = absolute(path)
		quicktime_identity(path)
		assert_present(tags(path), { "MetaClean Test User", "2020:01:02" })
		local frames = media_frames(path)
		assert_sanitized(path)
		assert_absent(tags(path), { "MetaClean Test User", "48.85", "2020:01:02" })
		assert(media_frames(path) == frames, "media frames changed")
	end)

	-- Samsung trailer blocks, then the SEFH directory, its length and SEFT.
	local function samsung_trailer(blocks)
		local parts, entries, offset = {}, {}, 0
		for _, block in ipairs(blocks) do
			parts[#parts + 1] = string.pack("<I2I2I4", 0, block[1], #block[2]) .. block[2] .. block[3]
		end
		local total = #table.concat(parts)
		for index, block in ipairs(blocks) do
			local size = #parts[index]
			entries[#entries + 1] = string.pack("<I2I2I4I4", 0, block[1], total - offset, size)
			offset = offset + size
		end
		local directory = "SEFH" .. string.pack("<I4I4", 106, #blocks) .. table.concat(entries)
		return table.concat(parts) .. directory .. string.pack("<I4", #directory) .. "SEFT"
	end

	record("Samsung Motion Photo keeps only its cleaned video", function()
		local video_path = copy_fixture(mp4_safe, "samsung-motion.mp4")
		quicktime_identity(video_path)
		local video = read_bytes(video_path)
		local frames = media_frames(video_path)
		local path = copy_fixture(jpg, "samsung-motion.jpg")
		local pixels = framehash(path)
		write_bytes(path, read_bytes(path) .. samsung_trailer({
			{ 0x0a01, "Image_UTC_Data", "1521282093573" },
			{ 0x0aa1, "MCC_Data", "234" },
			{ 0x0a30, "MotionPhoto_Data", video },
		}))
		assert_present(tags(path), { "MCCData", "TimeStamp", "EmbeddedVideoFile" })
		assert_sanitized(path)
		local after = tags(path)
		assert_absent(after, { "MCCData", "TimeStamp", "MetaClean Test User" })
		assert_present(after, { "EmbeddedVideoFile" })
		local cleaned = RUN .. "/samsung-motion-after.mp4"
		write_bytes(cleaned, select(2, execute({ "exiftool", "-b", "-EmbeddedVideoFile", path })))
		assert(#read_bytes(cleaned) == #video, "Motion Photo video size changed")
		assert_absent(tags(cleaned), { "MetaClean Test User", "48.85", "2020:01:02" })
		assert(media_frames(cleaned) == frames, "Motion Photo video frames changed")
		assert(framehash(path) == pixels, "primary image changed")
		assert(select(2, process(path)) == "unchanged", "cleaned Motion Photo is not reported clean")
		assert_redated(path)
		-- A trailer with only shot data goes; Selective Focus images are refused.
		local shot = copy_fixture(jpg, "samsung-shot.jpg")
		local plain = read_bytes(shot)
		write_bytes(shot, plain .. samsung_trailer({ { 0x0a01, "Image_UTC_Data", "1521282093573" } }))
		assert_sanitized(shot)
		assert(not read_bytes(shot):find("SEFT", 1, true), "Samsung trailer remains")
		local focus = copy_fixture(jpg, "samsung-focus.jpg")
		write_bytes(focus, plain .. samsung_trailer({ { 0x0840, "FocusShot_Meta_Info", "FCSS" } }))
		assert_skipped(focus, "FocusShot_Meta_Info")
	end)

	record("Google Motion Photo keeps only its cleaned video", function()
		local video_path = copy_fixture(mp4_safe, "google-motion.mp4")
		quicktime_identity(video_path)
		local video = read_bytes(video_path)
		local frames = media_frames(video_path)
		local function motion_photo(name, description, extra)
			local path = copy_fixture(jpg, name)
			local data = read_bytes(path)
			write_bytes(path, data:sub(1, 2) .. xmp_segment(description) .. data:sub(3) .. (extra or "") .. video)
			return path
		end
		local container = '<rdf:Description rdf:about="" xmlns:GCamera="http://ns.google.com/photos/1.0/camera/"'
			.. ' xmlns:dc="http://purl.org/dc/elements/1.1/"'
			.. ' xmlns:Container="http://ns.google.com/photos/1.0/container/"'
			.. ' xmlns:Item="http://ns.google.com/photos/1.0/container/item/"'
			.. ' GCamera:MotionPhoto="1" GCamera:MotionPhotoVersion="1"'
			.. ' GCamera:MotionPhotoPresentationTimestampUs="1133745">'
			.. "<dc:creator><rdf:Seq><rdf:li>Secret Creator</rdf:li></rdf:Seq></dc:creator>"
			.. "<Container:Directory><rdf:Seq>"
			.. '<rdf:li rdf:parseType="Resource"><Container:Item Item:Mime="image/jpeg" Item:Semantic="Primary"'
			.. ' Item:Length="0" Item:Padding="0"/></rdf:li>'
			.. '<rdf:li rdf:parseType="Resource"><Container:Item Item:Mime="video/mp4" Item:Semantic="MotionPhoto"'
			.. ' Item:Length="'
			.. #video
			.. '" Item:Padding="0"/></rdf:li>'
			.. "</rdf:Seq></Container:Directory></rdf:Description>"
		local micro = '<rdf:Description rdf:about="" xmlns:GCamera="http://ns.google.com/photos/1.0/camera/"'
			.. ' xmlns:dc="http://purl.org/dc/elements/1.1/" GCamera:MicroVideo="1" GCamera:MicroVideoVersion="1"'
			.. ' GCamera:MicroVideoOffset="'
			.. #video
			.. '" GCamera:MicroVideoPresentationTimestampUs="-1">'
			.. "<dc:creator><rdf:Seq><rdf:li>Secret Creator</rdf:li></rdf:Seq></dc:creator></rdf:Description>"
		for _, case in ipairs({
			{ "google-motion.jpg", container, "MotionPhotoVideo", "DirectoryItemLength%s+: (%d+)" },
			{ "google-micro.jpg", micro, "MicroVideo", "MicroVideoOffset%s+: (%d+)" },
		}) do
			local path = motion_photo(case[1], case[2], string.rep("\0", 64))
			local pixels = framehash(path)
			assert_present(tags(path), { "Secret Creator", case[3] })
			assert_sanitized(path)
			local after = tags(path)
			assert_absent(after, { "Secret Creator", "MetaClean Test User" })
			assert(tonumber(after:match(case[4])) == #video, case[1] .. ": video length lost")
			local data = read_bytes(path)
			local cleaned = RUN .. "/" .. case[1] .. ".mp4"
			write_bytes(cleaned, data:sub(-#video))
			assert(data:sub(-#video + 4, -#video + 7) == "ftyp", case[1] .. ": video not at the end")
			assert_absent(tags(cleaned), { "MetaClean Test User", "48.85", "2020:01:02" })
			assert(media_frames(cleaned) == frames, case[1] .. ": video frames changed")
			assert(framehash(path) == pixels, case[1] .. ": primary image changed")
			assert(select(2, process(path)) == "unchanged", case[1] .. ": cleaned file is not reported clean")
		end
		-- Pixel 8 and later: Ultra HDR gain map and Motion Photo together.
		local gainmap = secondary_jpeg("motion-gainmap.jpg", xmp_segment(GAINMAP_XMP))
		local primary = read_bytes(jpg)
		primary = primary:sub(1, 2)
			.. xmp_segment(
				'<rdf:Description rdf:about="" xmlns:hdrgm="http://ns.adobe.com/hdr-gain-map/1.0/"'
					.. ' xmlns:GCamera="http://ns.google.com/photos/1.0/camera/"'
					.. ' xmlns:Container="http://ns.google.com/photos/1.0/container/"'
					.. ' xmlns:Item="http://ns.google.com/photos/1.0/container/item/" hdrgm:Version="1.0"'
					.. ' GCamera:MotionPhoto="1" GCamera:MotionPhotoVersion="1"'
					.. ' GCamera:MotionPhotoPresentationTimestampUs="500000"><Container:Directory><rdf:Seq>'
					.. '<rdf:li rdf:parseType="Resource"><Container:Item Item:Semantic="Primary" Item:Mime="image/jpeg"/></rdf:li>'
					.. '<rdf:li rdf:parseType="Resource"><Container:Item Item:Semantic="GainMap" Item:Mime="image/jpeg"'
					.. ' Item:Length="'
					.. #gainmap
					.. '"/></rdf:li><rdf:li rdf:parseType="Resource"><Container:Item Item:Semantic="MotionPhoto"'
					.. ' Item:Mime="video/mp4" Item:Length="'
					.. #video
					.. '"/></rdf:li></rdf:Seq></Container:Directory></rdf:Description>'
			)
			.. primary:sub(3)
		local both = mpf_fixture("motion-ultrahdr.jpg", primary, { { attributes = 0, data = gainmap } })
		write_bytes(both, read_bytes(both) .. video)
		local gainmap_pixels = mpf_image_hash(both, 2)
		assert_sanitized(both)
		local after = tags(both)
		assert(after:match("NumberOfImages%s+: (%d+)") == "2", "MPF index lost")
		assert(after:match("MotionPhoto%s+: (%d+)") == "1", "Motion Photo flag lost")
		assert(mpf_image_hash(both, 2) == gainmap_pixels, "gain map image changed")
		local both_video = RUN .. "/motion-ultrahdr.mp4"
		write_bytes(both_video, read_bytes(both):sub(-#video))
		assert(media_frames(both_video) == frames, "Motion Photo video frames changed")
		assert(select(2, process(both)) == "unchanged", "cleaned Ultra HDR Motion Photo is not reported clean")
		assert_redated(both)
		-- The XMP must say where the video is.
		local misplaced = motion_photo("google-misplaced.jpg", container, "")
		write_bytes(misplaced, read_bytes(misplaced) .. "tail")
		assert_skipped(misplaced, "Motion Photo video not found")
	end)

	record("QuickTime verification rejects bytes changed outside metadata", function()
		local path = copy_fixture(mp4_safe, "verify.mp4")
		local copy = copy_fixture(mp4_safe, "verify-copy.mp4")
		local state = assert(helpers.quicktime_parse(path))
		assert(helpers.quicktime_verify(path, copy, state) == nil, "unneutralized copy passed verification")
		local data = read_bytes(copy)
		local mdat = assert(data:find("mdat", 1, true))
		write_bytes(copy, data:sub(1, mdat + 10) .. "X" .. data:sub(mdat + 12))
		local ok, err = helpers.quicktime_verify(path, copy, state)
		assert(ok == nil and err, "changed media bytes passed verification")
	end)

	record("cleaned files pass independent validators", function()
		local cases = {
			{ jpg, "valid.jpg", { "jpeginfo", "-c" }, "OK" },
			{ icc_png, "valid.png", { "pngcheck" }, "OK" },
			{ apng, "valid.apng", { "pngcheck" }, "OK" },
			{ gif, "valid.gif", { "gifsicle", "--info" }, "images" },
			{ tiff, "valid.tiff", { "tiffinfo" }, "TIFF Directory" },
			{ mp4_safe, "valid.mp4", { "mp4dump" }, "moov" },
			{ mov_safe, "valid.mov", { "mp4dump" }, "moov" },
			{ m4a_safe, "valid.m4a", { "mp4dump" }, "moov" },
			{ svg, "valid.svg", { "xmllint", "--noout" }, nil },
		}
		for _, case in ipairs(cases) do
			local path = copy_fixture(case[1], case[2])
			if case[1] ~= svg and case[1] ~= gif then
				exiftool({ "-XMP-dc:Creator=MetaClean Test User", path })
			end
			assert_sanitized(path)
			local args = {}
			for _, arg in ipairs(case[3]) do
				args[#args + 1] = arg
			end
			args[#args + 1] = path
			local ok, out = execute(args)
			assert(ok and (not case[4] or out:find(case[4], 1, true)), case[2] .. ": " .. out)
		end
		local webp = webp_fixture("valid", { "-q", "80" }, true)
		exiftool({ "-Artist=MetaClean Test User", webp })
		assert_sanitized(webp)
		local ok, out = execute({ "webpinfo", webp })
		assert(ok and out:find("No error detected", 1, true), out)
	end)

	-- HEIC, HEIF and AVIF ----------------------------------------------------------

	local heif_identity = {
		"-GPSLatitude=37.3317",
		"-GPSLongitude=-122.0307",
		"-Artist=MetaClean Test User",
		"-Model=Test Camera",
		"-SerialNumber=SERIAL-TEST-001",
		"-DateTimeOriginal=2020:01:02 03:04:05",
		"-XMP-dc:Creator=MetaClean Test User",
		"-XMP-photoshop:City=Secret City",
	}
	local function add_heif_identity(path)
		local args = { table.unpack(heif_identity) }
		args[#args + 1] = path
		exiftool(args)
	end
	local heif_needles =
		{ "MetaClean Test User", "Test Camera", "SERIAL-TEST-001", "2020:01:02", "Secret City", "37.33" }

	-- Encode the JPEG fixture (or a given source) with libheif or libavif and
	-- add identity metadata with ExifTool.
	local function heif_fixture(name, tool, args, source)
		local path = RUN .. "/" .. name
		local full = { tool }
		for _, arg in ipairs(args) do
			full[#full + 1] = arg
		end
		full[#full + 1] = source or jpg
		if tool == "heif-enc" then
			full[#full + 1] = "-o"
		end
		full[#full + 1] = path
		local ok, out = execute(full)
		assert(ok, out)
		add_heif_identity(path)
		return absolute(path)
	end

	-- A half-transparent PNG for alpha auxiliary images.
	local function alpha_source()
		local alpha_png = RUN .. "/alpha-source.png"
		if not io.open(alpha_png, "rb") then
			assert(execute({
				"ffmpeg",
				"-hide_banner",
				"-loglevel",
				"error",
				"-f",
				"lavfi",
				"-i",
				"testsrc2=s=64x48,format=rgba,colorchannelmixer=aa=0.5",
				"-frames:v",
				"1",
				"-y",
				alpha_png,
			}))
		end
		return alpha_png
	end

	-- Decoded pixels of the primary image, with irot and imir applied.
	local function heif_pixels(path)
		local png = path .. ".decoded.png"
		local ok, out = execute({ "heif-dec", path, png })
		assert(ok, out)
		local pixels = framehash(png)
		os.remove(png)
		return pixels
	end

	local function assert_heif_cleaned(path)
		local pixels, before = heif_pixels(path), tags(path)
		assert_present(before, heif_needles)
		assert_sanitized(path)
		assert_absent(tags(path), heif_needles)
		assert(heif_pixels(path) == pixels, "decoded HEIF image changed")
		local ok, out = execute({ "heif-info", path })
		assert(ok, out)
		assert(select(2, process(path)) == "unchanged", "cleaned HEIF file is not reported clean")
		neutral_dates(path)
		return before
	end

	record("HEIC transaction removes Exif and XMP items", function()
		local path = copy_fixture(heic, "identity.heic")
		exiftool({ "-XMP-dc:Creator=MetaClean Test User", path })
		local pixels = heif_pixels(path)
		add_heif_identity(path)
		assert_present(tags(path), heif_needles)
		assert_sanitized(path)
		assert_absent(tags(path), heif_needles)
		assert(heif_pixels(path) == pixels, "decoded HEIF image changed")
		local parsed = assert(helpers.heif_parse(path))
		for _, id in ipairs(parsed.order) do
			assert(parsed.items[id].type ~= "Exif" and parsed.items[id].type ~= "mime", "metadata item remains")
			assert(parsed.items[id].name == "", "item name remains")
		end
	end)

	record("HEIC grid, thumbnail, alpha and rotation survive", function()
		local grid = heif_fixture(
			"grid.heic",
			"heif-enc",
			{ "-q", "60", "--cut-tiles", "32", "-t", "32", "--rotate-cw", "90", "--clli", "1000,400" }
		)
		local before = assert_heif_cleaned(grid)
		local after = tags(grid)
		for _, needle in ipairs({ "Rotation", "MaxContentLightLevel", "ImageSpatialExtent" }) do
			assert(
				before:match("%]%s+" .. needle .. "%s+: ([^\n]+)") == after:match("%]%s+" .. needle .. "%s+: ([^\n]+)"),
				needle
			)
		end
		local alpha = heif_fixture("alpha.heic", "heif-enc", { "-q", "60" }, alpha_source())
		assert_heif_cleaned(alpha)
		assert(tags(alpha):find("urn:mpeg:hevc:2015:auxid:1", 1, true), "alpha auxiliary image lost")
	end)

	record("AVIF transaction removes Exif and XMP items", function()
		local path = copy_fixture(avif, "identity.avif")
		add_heif_identity(path)
		assert_heif_cleaned(path)
		local exif, xmp = RUN .. "/avif-exif.bin", RUN .. "/avif-xmp.xml"
		local source = copy_fixture(jpg, "avif-source.jpg")
		add_heif_identity(source)
		write_bytes(exif, select(2, execute({ "exiftool", "-b", "-Exif", source })))
		write_bytes(xmp, select(2, execute({ "exiftool", "-b", "-XMP", source })))
		local y4m = RUN .. "/avif-source.y4m"
		assert(execute({ "ffmpeg", "-hide_banner", "-loglevel", "error", "-i", jpg, "-pix_fmt", "yuv444p", "-y", y4m }))
		local props = RUN .. "/props.avif"
		assert(execute({
			"avifenc",
			"-q",
			"60",
			"--exif",
			exif,
			"--xmp",
			xmp,
			"--irot",
			"1",
			"--imir",
			"1",
			"--clli",
			"1000,400",
			"--cicp",
			"1/13/6",
			y4m,
			props,
		}))
		assert_heif_cleaned(absolute(props))
		local after = tags(absolute(props))
		assert_present(after, { "Rotation", "Mirroring", "MaxContentLightLevel", "ColorPrimaries" })
	end)

	record("HEIF XMP describing an auxiliary image goes through the allowlist", function()
		-- iPhone HDR gain maps carry their own XMP, which is kept when its
		-- content is allowlisted. Point the XMP item at the alpha image instead
		-- of the primary: its Creator must block cleaning.
		local path = heif_fixture("aux-xmp.heic", "heif-enc", { "-q", "60" }, alpha_source())
		local state = assert(helpers.heif_parse(path))
		local xmp, alpha
		for _, id in ipairs(state.order) do
			local item = state.items[id]
			if item.type == "mime" then
				xmp = id
			elseif id ~= state.primary and item.type == "hvc1" then
				alpha = id
			end
		end
		assert(xmp and alpha, "fixture lacks an XMP item or an alpha image")
		local reference = "cdsc" .. string.pack(">I2I2I2", xmp, 1, state.primary)
		local data = read_bytes(path)
		local at = assert(data:find(reference, 1, true), "XMP reference not found")
		write_bytes(path, data:sub(1, at - 1) .. "cdsc" .. string.pack(">I2I2I2", xmp, 1, alpha) .. data:sub(at + 10))
		local retargeted = assert(helpers.heif_parse(path))
		assert(not retargeted.removed[xmp], "auxiliary XMP item was planned for removal")
		assert_skipped(path, "allowlist remains: XMP")
	end)

	-- Turn the alpha auxiliary image of a heif-enc file into an Apple HDR gain map:
	-- the longer auxC type grows auxC, ipco, iprp and meta, and every item offset
	-- after it moves.
	local function apple_gainmap_heif(path)
		local data = read_bytes(path)
		local alpha, apple = "urn:mpeg:hevc:2015:auxid:1\0", "urn:com:apple:photo:2020:aux:hdrgainmap\0"
		local at = assert(data:find("auxC\0\0\0\0" .. alpha, 1, true), "alpha auxC not found")
		local delta = #apple - #alpha
		local parts, cursor = {}, 1
		local function walk(start, finish)
			local position = start
			while position + 7 <= finish do
				local size, kind = string.unpack(">I4c4", data, position)
				if position < at and at < position + size then
					parts[#parts + 1] = { position, string.pack(">I4", size + delta) }
					local header = kind == "meta" and 12 or 8
					if kind == "meta" or kind == "iprp" or kind == "ipco" then
						walk(position + header, position + size - 1)
					end
				elseif kind == "iloc" then
					local p = position + 8
					local version = data:byte(p)
					local sizes, more = data:byte(p + 4, p + 5)
					local offset_size, length_size, base_size = sizes >> 4, sizes & 15, more >> 4
					local index_size = version > 0 and more & 15 or 0
					local width = version == 2 and 4 or 2
					local count
					count, p = string.unpack(">I" .. width, data, p + 6)
					local function shift(field_size)
						if field_size > 0 then
							local value = string.unpack(">I" .. field_size, data, p)
							if value >= at then
								parts[#parts + 1] = { p, string.pack(">I" .. field_size, value + delta) }
							end
						end
						p = p + field_size
					end
					for _ = 1, count do
						local method = 0
						p = p + width
						if version > 0 then
							method = string.unpack(">I2", data, p) & 15
							p = p + 2
						end
						p = p + 2
						assert(method == 0, "item stored outside the file")
						shift(base_size)
						local extents
						extents, p = string.unpack(">I2", data, p)
						for _ = 1, extents do
							p = p + index_size
							shift(offset_size)
							p = p + length_size
						end
					end
				end
				position = position + size
			end
		end
		walk(1, #data)
		table.sort(parts, function(x, y)
			return x[1] < y[1]
		end)
		local out = {}
		for _, part in ipairs(parts) do
			out[#out + 1] = data:sub(cursor, part[1] - 1) .. part[2]
			cursor = part[1] + #part[2]
		end
		out[#out + 1] = data:sub(cursor, at + 7) .. apple .. data:sub(at + 8 + #alpha)
		write_bytes(path, table.concat(out))
	end

	record("HEIC Apple gain map keeps only the HDR maker note values", function()
		local path = heif_fixture("apple-hdr.heic", "heif-enc", { "-q", "60" }, alpha_source())
		local base = 14 + 2 + 4 * 12 + 4
		local note = "Apple iOS\0\0\1MM"
			.. string.pack(">I2", 4)
			.. string.pack(">I2I2I4i4", 0x0001, 9, 1, 14)
			.. string.pack(">I2I2I4I4", 0x000B, 2, 12, base)
			.. string.pack(">I2I2I4I4", 0x0021, 10, 1, base + 12)
			.. string.pack(">I2I2I4I4", 0x0030, 10, 1, base + 20)
			.. string.pack(">I4", 0)
			.. "SECRET-UUID\0"
			.. string.pack(">i4i4i4i4", 3, 2, 1, 100)
		write_bytes(RUN .. "/heic-makernote.bin", note)
		exiftool({ "-Make=Apple", "-MakerNotes<=" .. RUN .. "/heic-makernote.bin", path })
		apple_gainmap_heif(path)
		local before = tags(path)
		assert_present(before, {
			"urn:com:apple:photo:2020:aux:hdrgainmap",
			"[Apple]         HDRHeadroom                     : 1.5",
			"SECRET-UUID",
		})
		local function gainmap_bytes(file)
			local state = assert(helpers.heif_parse(file))
			for _, id in ipairs(state.order) do
				if id ~= state.primary and state.items[id].type == "hvc1" then
					local extent = state.items[id].extents[1]
					local handle = assert(io.open(file, "rb"))
					handle:seek("set", extent.start)
					local bytes = handle:read(extent.finish - extent.start)
					handle:close()
					return bytes
				end
			end
		end
		local gainmap, pixels = assert(gainmap_bytes(path), "gain map item not found"), heif_pixels(path)
		assert_sanitized(path)
		local after = tags(path)
		assert_present(after, {
			"urn:com:apple:photo:2020:aux:hdrgainmap",
			"[Apple]         HDRHeadroom                     : 1.5",
			"[Apple]         HDRGain                         : 0.01",
			"[Apple]         MakerNoteVersion                : 14",
		})
		assert_absent(after, { "SECRET-UUID", "[IFD0]          Make" })
		assert_absent(after, heif_needles)
		assert(heif_pixels(path) == pixels, "decoded HEIF image changed")
		assert(gainmap_bytes(path) == gainmap, "gain map image changed")
		assert(select(2, process(path)) == "unchanged", "cleaned Apple HDR HEIC is not reported clean")
	end)

	record("HEIC Motion Photo keeps a rebuilt XMP and its cleaned video", function()
		local video_path = copy_fixture(mp4_safe, "heic-motion.mp4")
		exiftool({ "-XMP-dc:Creator=MetaClean Test User", "-QuickTime:CreateDate=2020:01:02 03:04:05", video_path })
		local video = read_bytes(video_path)
		local path = heif_fixture("motion.heic", "heif-enc", { "-q", "60" })
		local xmp = RUN .. "/heic-motion.xmp"
		write_bytes(
			xmp,
			'<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">'
				.. '<rdf:Description rdf:about="" xmlns:GCamera="http://ns.google.com/photos/1.0/camera/"'
				.. ' xmlns:dc="http://purl.org/dc/elements/1.1/"'
				.. ' xmlns:Container="http://ns.google.com/photos/1.0/container/"'
				.. ' xmlns:Item="http://ns.google.com/photos/1.0/container/item/"'
				.. ' GCamera:MotionPhoto="1" GCamera:MotionPhotoVersion="1"'
				.. ' GCamera:MotionPhotoPresentationTimestampUs="0">'
				.. "<dc:creator><rdf:Seq><rdf:li>Secret Creator</rdf:li></rdf:Seq></dc:creator>"
				.. '<Container:Directory><rdf:Seq><rdf:li rdf:parseType="Resource"><Container:Item'
				.. ' Item:Mime="image/heic" Item:Semantic="Primary" Item:Length="0" Item:Padding="16"/></rdf:li>'
				.. '<rdf:li rdf:parseType="Resource"><Container:Item Item:Mime="video/mp4"'
				.. ' Item:Semantic="MotionPhoto" Item:Length="'
				.. #video
				.. '" Item:Padding="0"/></rdf:li></rdf:Seq></Container:Directory></rdf:Description>'
				.. "</rdf:RDF></x:xmpmeta>"
		)
		exiftool({ "-XMP<=" .. xmp, path })
		write_bytes(
			path,
			read_bytes(path) .. string.pack(">I4", 1) .. "mpvd" .. string.pack(">I8", 16 + #video) .. video
		)
		assert_present(tags(path), { "Secret Creator", "MotionPhotoVideo", "SERIAL-TEST-001" })
		local pixels = heif_pixels(path)
		local frames = media_frames(video_path)
		assert_sanitized(path)
		local after = tags(path)
		assert_absent(after, { "Secret Creator", "SERIAL-TEST-001", "MetaClean Test User" })
		assert(tonumber(after:match("DirectoryItemLength%s+: (%d+)")) == #video, "Motion Photo length lost")
		assert(heif_pixels(path) == pixels, "decoded HEIF image changed")
		local cleaned = RUN .. "/heic-motion-after.mp4"
		write_bytes(cleaned, read_bytes(path):sub(-#video))
		assert_absent(tags(cleaned), { "MetaClean Test User", "2020:01:02" })
		assert(media_frames(cleaned) == frames, "Motion Photo video frames changed")
		assert(select(2, process(path)) == "unchanged", "cleaned HEIC Motion Photo is not reported clean")
		assert_redated(path)
	end)

	record("Samsung HEIF trailer box is neutralized", function()
		local path = heif_fixture("samsung.heic", "heif-enc", { "-q", "60" })
		local trailer = samsung_trailer({
			{ 0x0a01, "Image_UTC_Data", "1593487679058" },
			{ 0x0aa1, "MCC_Data", "466" },
		})
		write_bytes(path, read_bytes(path) .. string.pack(">I4", 8 + #trailer) .. "sefd" .. trailer)
		local size = #read_bytes(path)
		assert_present(tags(path), { "MCCData", "TimeStamp" })
		assert_sanitized(path)
		assert_absent(tags(path), { "MCCData", "TimeStamp", "MetaClean Test User" })
		assert(#read_bytes(path) == size, "HEIF file size changed")
		local motion = heif_fixture("samsung-motion.heic", "heif-enc", { "-q", "60" })
		local video_trailer = samsung_trailer({ { 0x0a30, "MotionPhoto_Data", read_bytes(mp4_safe) } })
		write_bytes(motion, read_bytes(motion) .. string.pack(">I4", 8 + #video_trailer) .. "sefd" .. video_trailer)
		assert_skipped(motion, "Samsung HEIF Motion Photo")
	end)

	record("HEIF with an Exif orientation but no irot is skipped", function()
		local path = heif_fixture("oriented.heic", "heif-enc", { "-q", "60" })
		exiftool({ "-Orientation#=6", path })
		assert_skipped(path, "orientation")
	end)

	record("HEIF with unknown items or properties is skipped", function()
		local base = heif_fixture("unknown.heic", "heif-enc", { "-q", "60" })
		local data = read_bytes(base)
		local item = RUN .. "/unknown-item.heic"
		write_bytes(item, (data:gsub("Exif", "zzzz", 1)))
		assert_skipped(absolute(item), "unsupported HEIF item zzzz")
		local property = RUN .. "/unknown-property.heic"
		write_bytes(property, (data:gsub("pixi", "zzzz", 1)))
		assert_skipped(absolute(property), "unsupported HEIF item property zzzz")
		local sequence = RUN .. "/sequence.avif"
		assert(execute({
			"ffmpeg",
			"-hide_banner",
			"-loglevel",
			"error",
			"-f",
			"lavfi",
			"-i",
			"testsrc2=s=64x48:r=2",
			"-frames:v",
			"2",
			"-c:v",
			"libsvtav1",
			"-y",
			sequence,
		}))
		-- ExifTool reports an animated AVIF as MP4; either policy must refuse it.
		assert_skipped(absolute(sequence))
	end)

	record("HEIF parser survives corrupted meta boxes", function()
		local path = heif_fixture("fuzz.heic", "heif-enc", { "-q", "60", "--cut-tiles", "32", "-t", "32" })
		local data = read_bytes(path)
		local state = assert(helpers.heif_parse(path))
		local first, last = state.meta.start + 1, state.meta.finish
		local mutated = RUN .. "/fuzz-mutated.heic"
		local seed = 12345
		local function random(limit)
			seed = (seed * 1103515245 + 12345) % 2147483648
			return seed % limit
		end
		for _ = 1, 400 do
			local at = first + random(last - first)
			local value = random(256)
			write_bytes(mutated, data:sub(1, at - 1) .. string.char(value) .. data:sub(at + 1))
			local ok, result, err = pcall(helpers.heif_parse, mutated)
			assert(ok, "parser raised at byte " .. at .. ": " .. tostring(result))
			assert(result or err, "parser returned neither a state nor an error")
		end
	end)

	record("HEIF verification rejects bytes changed outside metadata", function()
		local path = heif_fixture("verify.heic", "heif-enc", { "-q", "60" })
		local copy = RUN .. "/verify-copy.heic"
		local state = assert(helpers.heif_parse(path))
		assert(execute({ "cp", path, copy }))
		assert(helpers.verify_regions(path, copy, state.regions) == nil, "uncleaned copy passed verification")
		assert(helpers.policies.HEIC.transform({ staged = copy, state = state }))
		assert(helpers.verify_regions(path, copy, state.regions), "cleaned copy failed verification")
		local data = read_bytes(copy)
		local mdat = assert(data:find("mdat", 1, true))
		write_bytes(copy, data:sub(1, #data - 10) .. (data:sub(-10, -10) == "X" and "Y" or "X") .. data:sub(-9))
		assert(mdat < #data - 10)
		local ok, err = helpers.verify_regions(path, copy, state.regions)
		assert(ok == nil and err, "changed image bytes passed verification")
	end)

	-- Transaction and filesystem -----------------------------------------------

	record("ACL, flags, mode and extended attributes survive cleaning", function()
		for _, source in ipairs({ jpg, png, mp4_safe }) do
			local path = copy_fixture(source, "attributes-" .. source:match("([^/]+)$"))
			if source == mp4_safe then
				quicktime_identity(path)
			end
			assert(execute({ "chmod", "640", path }))
			assert(execute({ "chmod", "+a", "everyone allow read", path }))
			assert(execute({ "chflags", "hidden", path }))
			assert(execute({ "xattr", "-w", "com.example.keep", "kept value", path }))
			assert(execute({ "xattr", "-w", "com.apple.metadata:kMDItemWhereFroms", "https://example.invalid/", path }))
			assert(execute({ "xattr", "-w", "com.apple.metadata:_kMDItemUserTags", "Red", path }))
			-- Inspect the staged file at the moment it replaces the source: a sync
			-- daemon (sfync) may later merge removed attributes back.
			local plugin, restore = production_plugin()
			local rename, after, attrs = _G.fs.rename, nil, nil
			_G.fs.rename = function(from, to)
				local listed, listed_attrs
				listed, after = execute({ "ls", "-lOe", from })
				listed_attrs, attrs = execute({ "xattr", "-l", from })
				assert(listed and listed_attrs, "could not inspect staged file")
				neutral_dates(from)
				return rename(from, to)
			end
			local ok, result, detail = pcall(plugin._test.process_file, path)
			restore()
			assert(ok and result == true and detail == "sanitized", tostring(result) .. " " .. tostring(detail))
			no_stage_left()
			assert(after:find("everyone allow read", 1, true), "ACL lost: " .. after)
			assert(after:find("hidden", 1, true), "file flag lost: " .. after)
			assert(after:match("^%-rw%-r%-%-%-%-%-"), "mode changed: " .. after)
			assert(attrs:find("com.example.keep: kept value", 1, true), "custom xattr lost: " .. attrs)
			assert(not attrs:find("kMDItemWhereFroms", 1, true) and not attrs:find("UserTags", 1, true), attrs)
		end
	end)

	record("read-only files are cleaned and stay read-only", function()
		local path = copy_fixture(jpg, "read-only.jpg")
		assert(execute({ "chmod", "444", path }))
		assert_sanitized(path)
		local _, listing = execute({ "ls", "-l", path })
		assert(listing:match("^%-r%-%-r%-%-r%-%-"), "mode changed: " .. listing)
		assert_absent(tags(path), { "MetaClean Test User" })
	end)

	record("immutable files are skipped without leaving a stage", function()
		local path = copy_fixture(jpg, "immutable.jpg")
		assert(execute({ "chflags", "uchg", path }))
		assert_skipped(path, "immutable")
		assert(execute({ "chflags", "nouchg", path }))
	end)

	-- Spotlight re-applies download attributes to files replaced by rename.
	-- Reproducing it needs the file indexed first and a wait afterwards.
	if os.getenv("METACLEAN_SLOW") == "1" then
		record("Spotlight does not restore download attributes after replacement", function()
			local path = copy_fixture(jpg, "spotlight.jpg")
			assert(execute({ "xattr", "-w", "com.apple.metadata:kMDItemWhereFroms", "https://example.invalid/", path }))
			assert(execute({ "xattr", "-w", "com.apple.metadata:kMDItemDownloadedDate", "2020-01-01", path }))
			assert(execute({ "sleep", "10" }))
			assert_sanitized(path)
			assert(execute({ "sleep", "45" }))
			local _, attrs = execute({ "xattr", path })
			assert(not attrs:find("WhereFroms", 1, true) and not attrs:find("DownloadedDate", 1, true), attrs)
		end)
	end

	record("symlinks and hard links are skipped", function()
		local target = copy_fixture(jpg, "link-target.jpg")
		local link = RUN .. "/symlink.jpg"
		assert(execute({ "ln", "-s", target, link }))
		local result, detail = process(absolute(link))
		assert(result == nil and tostring(detail):find("eligible"), tostring(detail))
		local hard = RUN .. "/hard-link.jpg"
		assert(execute({ "ln", target, hard }))
		assert_skipped(target, "eligible")
		assert(execute({ "rm", "-f", "--", hard }))
	end)

	record("source mutation blocks replacement", function()
		local path = copy_fixture(jpg, "source-changed.jpg")
		local mutated = false
		local result, detail = process(path, function(args)
			-- Mutate after staging, while the cleaned copy is being finished.
			if not mutated and args[5] == "touch" then
				mutated = true
				assert(execute({ "xattr", "-w", "com.example.concurrent-change", "changed", path }))
			end
		end)
		assert(mutated and result == nil and tostring(detail):find("source changed", 1, true), tostring(detail))
		assert_present(tags(path), { "MetaClean Test User" })
	end)

	record("replacement failure leaves the original intact", function()
		local path = copy_fixture(jpg, "replace-failure.jpg")
		local before = sha(path)
		local plugin, restore = production_plugin()
		_G.fs.rename = function()
			return nil, "simulated rename failure"
		end
		local ok, result, detail = pcall(plugin._test.process_file, path)
		restore()
		assert(ok, result)
		assert(result == nil and tostring(detail):find("replacement failed", 1, true), tostring(detail))
		assert(sha(path) == before, "original changed after replacement failure")
		no_stage_left()
	end)

	record("failed writer leaves the original intact", function()
		local path = copy_fixture(jpg, "writer-failure.jpg")
		local before = sha(path)
		local result, detail = process(path, function(args)
			if args[5] == "exiftool" and args[8] == "-overwrite_original_in_place" then
				return { success = false }
			end
		end)
		assert(result == nil, tostring(detail))
		assert(sha(path) == before, "original changed after writer failure")
	end)

	record("TIFF first-page image data that changes during cleaning is refused", function()
		local path = copy_fixture(tiff, "page-one.tiff")
		exiftool({ "-Artist=MetaClean Test User", path })
		local before, written, flipped = sha(path), false, false
		local result, detail = process(path, function(args)
			if args[5] == "exiftool" and args[8] == "-overwrite_original_in_place" then
				written = true
			elseif written and not flipped and args[5] == "exiftool" then
				-- The re-scan of the staged copy: flip one byte of its pixel data.
				local staged = args[#args]
				local _, offset = execute({ "exiftool", "-s3", "-n", "-IFD0:StripOffsets", staged })
				offset = tonumber(offset:match("%d+"))
				local data = read_bytes(staged)
				write_bytes(
					staged,
					data:sub(1, offset + 10) .. string.char(data:byte(offset + 11) ~ 0xFF) .. data:sub(offset + 12)
				)
				flipped = true
			end
		end)
		assert(flipped, "the staged copy was not modified")
		assert(result == nil and tostring(detail):find("TIFF page image data changed", 1, true), tostring(detail))
		assert(sha(path) == before, "original changed after a refused cleaning")
	end)

	record("ExifTool validation is checked on the cleaned file against the original", function()
		-- Runs each validating scan and reports the given Validate value
		-- ("errors warnings minor") for the staged copy and the original.
		local function validating(cleaned, original)
			local scans = {}
			return scans,
				function(args)
					if args[5] ~= "exiftool" or args[#args - 2] ~= "-validate" then
						return nil
					end
					local staged = args[#args] ~= scans.path
					scans[#scans + 1] = staged and "cleaned" or "original"
					local _, out = execute(table.move(args, 5, #args, 1, {}))
					local value = staged and cleaned or original
					return { success = true, output = out:gsub("(%[ExifTool%]%s+Validate%s+: )[^\n]*", "%1" .. value) }
				end
		end
		for _, case in ipairs({
			{ "0 0 0", "0 0 0", "cleaned" },
			{ "0 3 1", "0 0 0", "cleaned" },
			{ "1 2 0", "1 0 0", "cleaned original" },
			{ "1 0 0", "0 3 0", "cleaned original", "validation regressed: 1 0 0" },
			{ "", "0 0 0", "cleaned", "did not validate" },
		}) do
			local path = copy_fixture(jpg, "validated.jpg")
			exiftool({ "-Artist=MetaClean Test User", path })
			local scans, hook = validating(case[1], case[2])
			scans.path = path
			local result, detail = process(path, hook)
			assert(table.concat(scans, " ") == case[3], table.concat(scans, " "))
			if case[4] then
				assert(result == nil and tostring(detail):find(case[4], 1, true), tostring(detail))
			else
				assert(result == true and detail == "sanitized", tostring(detail))
			end
		end
	end)

	record("traversal skips packages, stage folders and symlink escapes", function()
		local root = RUN .. "/walk-root"
		for _, dir in ipairs({ "/nested", "/Photos Library.photoslibrary/originals", "/.metaclean-stage_3" }) do
			assert(execute({ "mkdir", "-p", "--", root .. dir }))
		end
		assert(execute({ "cp", "-c", "--", jpg, root .. "/top.jpg" }))
		assert(execute({ "cp", "-c", "--", png, root .. "/nested/child.png" }))
		assert(execute({ "cp", "-c", "--", jpg, root .. "/Photos Library.photoslibrary/originals/a.jpg" }))
		assert(execute({ "cp", "-c", "--", jpg, root .. "/.metaclean-stage_3/left.jpg" }))
		assert(execute({ "ln", "-s", absolute(ORIGINALS), root .. "/escape" }))
		local plugin, restore = production_plugin()
		local files, skipped = {}, {}
		local ok, err = plugin._test.walk(absolute(root), files, {}, skipped)
		restore()
		assert(ok, err)
		table.sort(files)
		assert(#files == 2 and files[1]:match("child%.png$") and files[2]:match("top%.jpg$"), table.concat(files, "\n"))
		assert(#skipped == 2, "packages not reported: " .. table.concat(skipped, "\n"))
		assert(execute({ "rm", "-rf", "--", root .. "/.metaclean-stage_3" }))
	end)

	-- Matroska and WebM -------------------------------------------------------

	local function ebml_vint(data, position, identifier)
		local first, length = data:byte(position), 1
		while length < 8 and first < (0x80 >> (length - 1)) do
			length = length + 1
		end
		local marker = 0x80 >> (length - 1)
		local value = identifier and first or first & (marker - 1)
		local unknown = not identifier and value == marker - 1
		for index = 1, length - 1 do
			value = value * 256 + data:byte(position + index)
			unknown = unknown and data:byte(position + index) == 255
		end
		return value, length, unknown
	end

	-- Checks every CRC-32 of the masters that can hold one; returns the count.
	local EBML_MASTERS = {}
	for _, id in ipairs({
		0x18538067,
		0x114D9B74,
		0x4DBB,
		0x1549A966,
		0x1654AE6B,
		0xAE,
		0x1254C367,
		0x7373,
		0x1941A469,
		0x61A7,
		0x1043A770,
		0x45B9,
		0xB6,
	}) do
		EBML_MASTERS[id] = true
	end
	local function matroska_crcs(path)
		local data, checked = read_bytes(path), 0
		local function walk(start, finish)
			local position = start
			while position < finish do
				local id, id_length = ebml_vint(data, position, true)
				local size, size_length, unknown = ebml_vint(data, position + id_length, false)
				local payload = position + id_length + size_length
				local stop = unknown and finish or payload + size
				if id == 0xBF and position == start then
					local stored = string.unpack("<I4", data, payload)
					assert(stored == crc32(data, stop, finish - 1), "Matroska CRC-32 mismatch")
					checked = checked + 1
				elseif EBML_MASTERS[id] then
					walk(payload, stop)
				end
				position = stop
			end
		end
		walk(1, #data + 1)
		return checked
	end

	-- Packets of the video and audio streams (a removed cover is a packet too).
	-- FFprobe stays quiet: complaints about removed metadata share the output.
	local function packets(path)
		local result = {}
		for _, kind in ipairs({ "V", "a" }) do
			local ok, out = execute({
				"ffprobe",
				"-v",
				"quiet",
				"-select_streams",
				kind,
				"-show_packets",
				"-show_data_hash",
				"sha256",
				path,
			})
			assert(ok, out)
			result[#result + 1] = out
		end
		return table.concat(result)
	end

	local function assert_unchanged_rerun(path)
		local result, detail = process(path)
		assert(result == true and detail == "unchanged", "expected unchanged, got: " .. tostring(detail))
	end

	record("MKV transaction neutralizes metadata in place", function()
		local font
		for name in io.popen("ls /System/Library/Fonts/Supplemental/*.ttf 2>/dev/null"):lines() do
			font = font or name
		end
		assert(font, "no TrueType font to attach")
		local cover, chapters = RUN .. "/mkv-cover.png", RUN .. "/chapters.txt"
		assert(execute({
			"ffmpeg",
			"-hide_banner",
			"-loglevel",
			"error",
			"-f",
			"lavfi",
			"-i",
			"color=c=red:s=32x32",
			"-frames:v",
			"1",
			"-y",
			cover,
		}))
		write_bytes(chapters, ";FFMETADATA1\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=0\nEND=500\ntitle=Opening\n")
		local path = RUN .. "/identity.mkv"
		assert(execute({
			"ffmpeg",
			"-hide_banner",
			"-loglevel",
			"error",
			"-f",
			"lavfi",
			"-i",
			"testsrc2=s=96x64:r=10",
			"-f",
			"lavfi",
			"-i",
			"sine=f=500:r=48000",
			"-i",
			chapters,
			"-t",
			"1",
			"-map",
			"0",
			"-map",
			"1",
			"-map_chapters",
			"2",
			"-c:v",
			"libx264",
			"-c:a",
			"libopus",
			"-metadata",
			"title=Private MKV title",
			"-metadata",
			"artist=MetaClean Test User",
			"-metadata",
			"creation_time=2020-01-02T03:04:05Z",
			"-metadata:s:v:0",
			"title=Secret track",
			"-attach",
			cover,
			"-metadata:s:t:0",
			"mimetype=image/png",
			"-attach",
			font,
			"-metadata:s:t:1",
			"mimetype=font/ttf",
			"-y",
			path,
		}))
		path = absolute(path)
		local identity = { "MetaClean Test User", "Private MKV title", "Secret track", "mkv-cover.png" }
		assert_present(tags(path, { "-ee" }), identity)
		assert_present(tags(path, { "-ee" }), { "2020:01:02" })
		local size, before = #read_bytes(path), packets(path)
		assert_sanitized(path)
		local after = tags(path, { "-ee" })
		assert_absent(after, identity)
		assert_absent(after, { "2020:01:02", "Lavf" })
		assert_present(after, { "Opening", "font/ttf" })
		for _, needle in ipairs(identity) do
			assert(not read_bytes(path):find(needle, 1, true), "identity bytes remain: " .. needle)
		end
		assert(#read_bytes(path) == size, "Matroska file size changed")
		assert(packets(path) == before, "Matroska packets changed")
		assert(matroska_crcs(path) > 0, "FFmpeg wrote no CRC-32 elements")
		assert_unchanged_rerun(path)
	end)

	record("WebM with unknown element sizes is cleaned in place", function()
		local ok, data = execute({
			"ffmpeg",
			"-hide_banner",
			"-loglevel",
			"error",
			"-f",
			"lavfi",
			"-i",
			"testsrc2=s=96x64:r=10",
			"-t",
			"2",
			"-c:v",
			"libvpx-vp9",
			"-deadline",
			"realtime",
			"-metadata",
			"title=Private WebM title",
			"-f",
			"webm",
			"pipe:1",
		})
		assert(ok, data)
		-- A piped segment has an unknown size; recorders also leave cluster
		-- sizes unknown, which the fixture imitates.
		local position = 1
		local _, id_length = ebml_vint(data, position, true)
		local size, size_length = ebml_vint(data, position + id_length, false)
		position = position + id_length + size_length + size
		local _, segment_id_length = ebml_vint(data, position, true)
		local _, segment_size_length, unknown = ebml_vint(data, position + segment_id_length, false)
		assert(unknown, "piped WebM segment has a known size")
		position = position + segment_id_length + segment_size_length
		local clusters = 0
		while position <= #data do
			local id, length = ebml_vint(data, position, true)
			local element_size, element_size_length = ebml_vint(data, position + length, false)
			if id == 0x1F43B675 then
				local field = string.char(0xFF >> (element_size_length - 1))
					.. string.rep("\255", element_size_length - 1)
				data = data:sub(1, position + length - 1) .. field .. data:sub(position + length + element_size_length)
				clusters = clusters + 1
			end
			position = position + length + element_size_length + element_size
		end
		assert(clusters > 0, "WebM fixture has no clusters")
		local path = RUN .. "/unknown-size.webm"
		write_bytes(path, data)
		path = absolute(path)
		assert_present(tags(path, { "-ee" }), { "Private WebM title" })
		local before = packets(path)
		assert_sanitized(path)
		assert_absent(tags(path, { "-ee" }), { "Private WebM title", "Lavf" })
		assert(packets(path) == before, "WebM packets changed")
		assert_unchanged_rerun(path)
	end)

	record("Matroska codec comments and subtitle headers are removed", function()
		local flac, ass, path = RUN .. "/commented.flac", RUN .. "/editor.ass", RUN .. "/commented.mkv"
		assert(execute({
			"ffmpeg",
			"-hide_banner",
			"-loglevel",
			"error",
			"-f",
			"lavfi",
			"-i",
			"sine=f=500:r=48000",
			"-t",
			"1",
			"-c:a",
			"flac",
			"-metadata",
			"artist=MetaClean Test User",
			"-y",
			flac,
		}))
		write_bytes(
			ass,
			table.concat({
				"[Script Info]",
				"; Script generated by Aegisub 3.2.2",
				"Title: Private subtitle title",
				"Original Script: MetaClean Test User",
				"ScriptType: v4.00+",
				"PlayResX: 640",
				"PlayResY: 480",
				"",
				"[Aegisub Project Garbage]",
				"Video File: /Users/metaclean/private.mkv",
				"",
				"[V4+ Styles]",
				"Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, "
					.. "Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, "
					.. "Shadow, Alignment, MarginL, MarginR, MarginV, Encoding",
				"Style: Default,Arial,20,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,2,2,"
					.. "10,10,10,1",
				"",
				"[Events]",
				"Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text",
				"Dialogue: 0,0:00:00.00,0:00:01.00,Default,,0,0,0,,Hello",
				"",
			}, "\n")
		)
		assert(execute({ "mkvmerge", "-q", "-o", path, flac, ass }))
		path = absolute(path)
		local identity = { "MetaClean Test User", "Private subtitle title", "/Users/metaclean", "Aegisub 3.2.2" }
		for _, needle in ipairs(identity) do
			assert(read_bytes(path):find(needle, 1, true), "fixture lacks " .. needle)
		end
		local function audio(file)
			local ok, out = execute({ "ffmpeg", "-v", "error", "-i", file, "-map", "0:a", "-f", "framemd5", "-" })
			assert(ok, out)
			return out
		end
		local before = audio(path)
		assert_sanitized(path)
		for _, needle in ipairs(identity) do
			assert(not read_bytes(path):find(needle, 1, true), "identity bytes remain: " .. needle)
		end
		assert(read_bytes(path):find("PlayResX: 640", 1, true), "subtitle rendering header lost")
		assert(audio(path) == before, "decoded audio changed")
		assert_unchanged_rerun(path)
	end)

	-- MP3, FLAC, WAV and AIFF -------------------------------------------------

	-- Decoded frame records. Decoder complaints about stray tag bytes would
	-- share the output, so FFmpeg stays quiet.
	local function decoded_audio(path)
		local ok, out = execute({ "ffmpeg", "-v", "quiet", "-i", path, "-map", "0:a", "-f", "framemd5", "-" })
		assert(ok, out)
		local records = {}
		for line in out:gmatch("[^\n]+") do
			if line:match("^%d+,") then
				records[#records + 1] = line
			end
		end
		assert(#records > 0, "no decoded audio frames")
		return table.concat(records, "\n")
	end

	local AUDIO_IDENTITY = { "MetaClean Test User", "Private audio title", "private comment" }

	local function audio_fixture(name, args)
		local path = RUN .. "/" .. name
		local command = {
			"ffmpeg",
			"-hide_banner",
			"-loglevel",
			"error",
			"-f",
			"lavfi",
			"-i",
			"sine=f=500:r=44100",
		}
		for _, arg in ipairs(args) do
			command[#command + 1] = arg
		end
		for _, arg in ipairs({
			"-t",
			"1",
			"-metadata",
			"artist=MetaClean Test User",
			"-metadata",
			"title=Private audio title",
			"-metadata",
			"comment=private comment",
			"-metadata",
			"date=2020-01-02",
			"-y",
			path,
		}) do
			command[#command + 1] = arg
		end
		assert(execute(command))
		return absolute(path)
	end

	local function assert_audio_cleaned(path, present)
		local data = read_bytes(path)
		for _, needle in ipairs(AUDIO_IDENTITY) do
			assert(data:find(needle, 1, true), "fixture lacks " .. needle)
		end
		local before = decoded_audio(path)
		assert_sanitized(path)
		data = read_bytes(path)
		for _, needle in ipairs(AUDIO_IDENTITY) do
			assert(not data:find(needle, 1, true), "identity bytes remain: " .. needle)
		end
		local after = tags(path)
		assert_absent(after, { "2020", "Lavf", "Picture" })
		assert_present(after, present)
		assert(decoded_audio(path) == before, "decoded audio changed")
		assert_unchanged_rerun(path)
	end

	local function audio_cover()
		local cover = RUN .. "/audio-cover.png"
		assert(execute({
			"ffmpeg",
			"-hide_banner",
			"-loglevel",
			"error",
			"-f",
			"lavfi",
			"-i",
			"color=c=green:s=16x16",
			"-frames:v",
			"1",
			"-y",
			cover,
		}))
		return cover
	end

	record("MP3 transaction removes ID3, APE and ID3v1 tags", function()
		local path = audio_fixture("identity.mp3", {
			"-i",
			audio_cover(),
			"-map",
			"0",
			"-map",
			"1",
			"-c:a",
			"libmp3lame",
			"-c:v",
			"png",
			"-id3v2_version",
			"3",
			"-write_id3v1",
			"1",
		})
		-- An APEv2 tag goes between the audio and the ID3v1 tag.
		local item = string.pack("<I4I4", 19, 0) .. "Artist\0MetaClean Test User"
		local ape = item .. "APETAGEX" .. string.pack("<I4I4I4I4", 2000, #item + 32, 1, 0) .. string.rep("\0", 8)
		local data = read_bytes(path)
		write_bytes(path, data:sub(1, -129) .. ape .. data:sub(-128))
		assert_present(tags(path), { "APE" })
		assert_audio_cleaned(path, { "MPEGAudioVersion" })
	end)

	record("FLAC transaction keeps stream information and playback comments", function()
		local path = audio_fixture("identity.flac", {
			"-i",
			audio_cover(),
			"-map",
			"0",
			"-map",
			"1",
			"-c:a",
			"flac",
			"-c:v",
			"png",
			"-disposition:v",
			"attached_pic",
			"-metadata",
			"REPLAYGAIN_TRACK_GAIN=-3.00 dB",
		})
		assert_audio_cleaned(path, { "MD5Signature", "ReplayGainTrackGain" })
	end)

	record("WAV transaction removes Broadcast WAV and INFO chunks", function()
		local path = audio_fixture("identity.wav", {
			"-c:a",
			"pcm_s16le",
			"-write_bext",
			"1",
			"-metadata",
			"originator=MetaClean Test User",
			"-metadata",
			"origination_date=2020-01-02",
		})
		assert_present(tags(path), { "Originator" })
		assert_audio_cleaned(path, { "AvgBytesPerSec" })
		assert_absent(tags(path), { "Originator" })
	end)

	record("AIFF transaction removes NAME, ANNO and ID3 chunks", function()
		local path = audio_fixture("identity.aiff", { "-c:a", "pcm_s16be", "-write_id3v2", "1" })
		assert_audio_cleaned(path, { "NumSampleFrames" })
	end)

	record("AAC loses its ID3 and APE tags and keeps its audio", function()
		-- ExifTool calls an AAC file with an ID3 tag MP3, and AAC without it.
		local args = { "-c:a", "aac", "-f", "adts", "-write_id3v2", "1", "-write_apetag", "1" }
		assert_audio_cleaned(audio_fixture("identity.aac", args), { "ProfileType", "audio/aac" })
	end)

	record("Monkey's Audio and Musepack lose trailing tags and refuse stored WAV metadata", function()
		-- No encoder for either is packaged, so the parser is checked on built
		-- headers: an APEv2 tag (with header) and an ID3v1 tag follow the audio.
		local item = string.pack("<I4I4", 19, 0) .. "Artist\0" .. "MetaClean Test User"
		local footer = function(flags)
			return "APETAGEX" .. string.pack("<I4I4I4I4", 2000, #item + 32, 1, flags) .. string.rep("\0", 8)
		end
		local tags = footer(0xA0000000) .. item .. footer(0x80000000) .. "TAG" .. string.rep("\0", 125)
		local wav = "RIFF"
			.. string.pack("<I4", 36)
			.. "WAVE"
			.. "fmt "
			.. string.pack("<I4", 16)
			.. string.rep("\1", 16)
		local function ape(stored, terminating)
			-- A 3.99 descriptor and header, an empty seek table, the stored WAV
			-- header and fake frame data.
			local descriptor = "MAC "
				.. string.pack("<I2I2I4I4I4I4I4I4I4", 3990, 0, 52, 24, 0, #stored, 64, 0, terminating or 0)
				.. string.rep("\0", 16)
			return descriptor .. string.rep("\0", 24) .. stored .. string.rep("\7", 64)
		end
		local function parse(name, data, parser)
			local path = RUN .. "/" .. name
			write_bytes(path, data)
			return helpers.audio.open(path, helpers.audio[parser])
		end
		local data_chunk = "data" .. string.pack("<I4", 0)
		local audio = ape(wav .. data_chunk)
		local state = assert(parse("tagged.ape", audio .. tags, "ape"))
		assert(state.pieces[1].start == 0 and state.pieces[1].finish == #audio, "Monkey's Audio tags not planned")
		assert(table.concat(state.metadata, ","):find("APE tag", 1, true), "APE tag not reported")
		local listed = wav .. "LIST" .. string.pack("<I4", 8) .. "INFOIART" .. data_chunk
		for _, case in ipairs({
			{ ape(listed), "stored WAV header with a LIST chunk" },
			{ ape(wav .. data_chunk, 12), "trailing data" },
			{ "ID3\3\0\0\0\0\0\0" .. audio, "ID3v2 tag before" },
		}) do
			local result, err = parse("refused.ape", case[1], "ape")
			assert(not result and err:find(case[2], 1, true), tostring(err))
		end
		-- Before 3.98 the header is 32 bytes; flag 4 adds a peak level, flag 32
		-- means no stored WAV header.
		local old = "MAC " .. string.pack("<I2I2I2I2I4I4I4I4I4", 3960, 2000, 4 | 32, 2, 44100, 44, 0, 1, 1)
		assert(parse("old.ape", old .. "\0\0\0\0" .. string.rep("\7", 64) .. tags, "ape"), "old header refused")
		local old_listed = "MAC " .. string.pack("<I2I2I2I2I4I4I4I4I4", 3960, 2000, 4, 2, 44100, #listed, 0, 1, 1)
		local result, err = parse("old-listed.ape", old_listed .. "\0\0\0\0" .. listed .. "\7\7", "ape")
		assert(not result and err:find("LIST chunk", 1, true), tostring(err))
		local mpc = "MP+\7" .. string.rep("\9", 60)
		state = assert(parse("tagged.mpc", mpc .. tags, "mpc"))
		assert(state.pieces[1].finish == #mpc, "Musepack tags not planned")
		result, err = parse("sv8.mpc", "MP+\8" .. string.rep("\9", 60), "mpc")
		assert(not result and err:find("stream version", 1, true), tostring(err))
	end)

	record("WavPack and WMA lose their tags and keep their audio", function()
		assert_audio_cleaned(audio_fixture("identity.wv", { "-c:a", "wavpack" }), { "BytesPerSample" })
		-- ASF strings are UTF-16.
		local path = audio_fixture("identity.wma", { "-c:a", "wmav2" })
		local identity = ("MetaClean Test User"):gsub(".", "%0\0")
		assert(read_bytes(path):find(identity, 1, true), "fixture lacks the artist")
		local before = decoded_audio(path)
		assert_sanitized(path)
		assert(not read_bytes(path):find(identity, 1, true), "ASF artist remains")
		local after = tags(path)
		assert_absent(after, { "Private audio title", "private comment", "Lavf" })
		assert_present(after, { "AudioCodecName", "00000000-0000-0000-0000-000000000000", "1601:01:01 00:00:00Z" })
		assert(decoded_audio(path) == before, "decoded WMA audio changed")
		assert_unchanged_rerun(path)
	end)

	record("WMV keeps its aspect ratio records and video", function()
		local path = RUN .. "/identity.wmv"
		assert(execute({
			"ffmpeg",
			"-v",
			"error",
			"-f",
			"lavfi",
			"-i",
			"testsrc2=s=64x48:d=1",
			"-c:v",
			"wmv2",
			"-metadata",
			"artist=MetaClean Test User",
			"-y",
			path,
		}))
		local frames = media_frames(path)
		assert_sanitized(absolute(path))
		local after = tags(path)
		assert_absent(after, { "MetaClean Test User", "Lavf" })
		assert_present(after, { "AspectRatioX", "AspectRatioY" })
		assert(media_frames(path) == frames, "WMV frames changed")

		-- A metadata object with other records shrinks to the playback
		-- records and a padding object over the rest.
		local asf = helpers.asf
		local function record_bytes(name, value)
			local utf16 = (name .. "\0"):gsub(".", "%0\0")
			return string.pack("<I2I2I2I2I4", 0, 1, #utf16, 3, #value) .. utf16 .. value
		end
		local records = record_bytes("AspectRatioX", string.pack("<I4", 4))
			.. record_bytes("WM/Secret", "MetaClean Test User")
			.. record_bytes("AspectRatioY", string.pack("<I4", 3))
		local id = asf.guid("C5F8CBEA-5BAF-4877-8467-AA8C44FA4CCA")
		local data = id .. string.pack("<i8I2", 26 + #records, 3) .. records
		local object = { id = id }
		local rebuilt = assert(asf.records(object, data))
		assert(#rebuilt == #data and not rebuilt:find("MetaClean", 1, true), "metadata object not shrunk")
		local kept = string.unpack("<i8", rebuilt, 17)
		assert(rebuilt:sub(kept + 1, kept + 16) == asf.PADDING, "no padding object after the records")
		assert(asf.records(object, rebuilt:sub(1, kept)) == rebuilt:sub(1, kept), "shrunk object is not stable")
		assert(asf.records(object, id .. string.pack("<i8I2", 26, 0)) == nil, "empty object kept")
	end)

	record("DSF loses its ID3v2 tag and keeps its audio", function()
		local path = absolute(RUN .. "/identity.dsf")
		local samples = string.rep("\105", 4096)
		local frame = "TIT2" .. string.pack(">I4", 20) .. "\0\0\3Private audio title"
		local tag = "ID3\4\0\0" .. string.char(0, 0, 0, #frame) .. frame
		local finish = 80 + 12 + #samples
		write_bytes(
			path,
			"DSD "
				.. string.pack("<I8I8I8", 28, finish + #tag, finish)
				.. "fmt "
				.. string.pack("<I8I4I4I4I4I4I4I8I4I4", 52, 1, 0, 1, 1, 2822400, 1, #samples * 8, 4096, 0)
				.. "data"
				.. string.pack("<I8", 12 + #samples)
				.. samples
				.. tag
		)
		assert_present(tags(path), { "Private audio title" })
		local before = decoded_audio(path)
		assert_sanitized(path)
		local data = read_bytes(path)
		assert(#data == finish and not data:find("ID3", 1, true), "DSF tag remains")
		assert(string.unpack("<I8I8", data, 13) == finish, "DSF file size not updated")
		assert(string.unpack("<I8", data, 21) == 0, "DSF tag pointer not cleared")
		assert(decoded_audio(path) == before, "decoded DSF audio changed")
		assert_unchanged_rerun(path)
		write_bytes(path, data .. "trailing")
		assert_skipped(path, "invalid DSF chunk sizes")
	end)

	-- Every Ogg page's CRC (polynomial 0x04C11DB7, not reflected).
	local function ogg_pages_valid(path)
		local data, offset, pages = read_bytes(path), 1, 0
		while offset <= #data do
			assert(data:sub(offset, offset + 3) == "OggS", "invalid Ogg page")
			local count, length = data:byte(offset + 26), 0
			for index = 1, count do
				length = length + data:byte(offset + 26 + index)
			end
			local finish = offset + 27 + count + length
			local page = data:sub(offset, offset + 21) .. "\0\0\0\0" .. data:sub(offset + 26, finish - 1)
			local crc = 0
			for index = 1, #page do
				crc = crc ~ (page:byte(index) << 24)
				for _ = 1, 8 do
					crc = (crc & 0x80000000 ~= 0) and (((crc << 1) ~ 0x04C11DB7) & 0xFFFFFFFF)
						or (crc << 1) & 0xFFFFFFFF
				end
			end
			assert(crc == string.unpack("<I4", data, offset + 22), "Ogg page CRC mismatch")
			pages, offset = pages + 1, finish
		end
		return pages
	end

	for _, case in ipairs({
		{ "Opus", "identity.opus", { "-c:a", "libopus" }, "R128TrackGain" },
		{ "Vorbis", "identity.ogg", { "-ac", "2", "-c:a", "vorbis", "-strict", "-2" }, "R128TrackGain" },
		{ "FLAC", "identity.oga", { "-c:a", "flac" }, "MD5Signature" },
	}) do
		record("Ogg " .. case[1] .. " comment header is cleaned in place", function()
			local args = { table.unpack(case[3]) }
			args[#args + 1] = "-metadata"
			args[#args + 1] = "R128_TRACK_GAIN=-512"
			local path = audio_fixture(case[2], args)
			local size = #read_bytes(path)
			assert_audio_cleaned(path, { case[4] })
			assert(#read_bytes(path) == size, "Ogg file size changed")
			assert(ogg_pages_valid(path) > 2, "Ogg file has too few pages")
		end)
	end

	record("Multiplexed Ogg streams are each cleaned and chained streams are skipped", function()
		local path = audio_fixture("multiplexed.ogg", {
			"-f",
			"lavfi",
			"-i",
			"sine=f=700:r=48000",
			"-map",
			"0",
			"-map",
			"1",
			"-c:a:0",
			"libopus",
			"-c:a:1",
			"vorbis",
			"-strict",
			"-2",
			"-ac",
			"2",
			"-metadata:s:a:1",
			"title=Second stream title",
		})
		local data = read_bytes(path)
		assert(data:find("OpusTags", 1, true) and data:find("\3vorbis", 1, true), "fixture is not multiplexed")
		assert(data:find("Second stream title", 1, true), "fixture lacks the second stream's comment")
		local size = #data
		assert_audio_cleaned(path, { "SampleRate" })
		assert(not read_bytes(path):find("Second stream title", 1, true), "second stream comment remains")
		assert(#read_bytes(path) == size, "Ogg file size changed")
		assert(ogg_pages_valid(path) > 4, "Ogg file has too few pages")
		local single = audio_fixture("chain-a.opus", { "-c:a", "libopus" })
		local chained = RUN .. "/chained.opus"
		write_bytes(chained, read_bytes(single) .. read_bytes(single))
		assert_skipped(absolute(chained), "chained Ogg streams")
	end)

	-- One Ogg page holding whole packets; flags 2 starts a stream, 4 ends it.
	local function ogg_page(serial, sequence, flags, packets)
		local lacing, body = {}, {}
		for _, packet in ipairs(packets) do
			for _ = 1, #packet // 255 do
				lacing[#lacing + 1] = "\255"
			end
			lacing[#lacing + 1] = string.char(#packet % 255)
			body[#body + 1] = packet
		end
		local page = "OggS\0"
			.. string.char(flags)
			.. string.pack("<i8I4I4", 0, serial, sequence)
			.. "\0\0\0\0"
			.. string.char(#lacing)
			.. table.concat(lacing)
			.. table.concat(body)
		local crc = 0
		for index = 1, #page do
			crc = crc ~ (page:byte(index) << 24)
			for _ = 1, 8 do
				crc = (crc & 0x80000000 ~= 0) and (((crc << 1) ~ 0x04C11DB7) & 0xFFFFFFFF) or (crc << 1) & 0xFFFFFFFF
			end
		end
		return page:sub(1, 22) .. string.pack("<I4", crc) .. page:sub(27)
	end

	record("Ogg Theora with a Skeleton loses its comments and Skeleton date", function()
		-- An ffmpeg2theora-style file: Skeleton and Theora first pages, the
		-- fisbone and the other Theora headers, the Skeleton's closing page,
		-- then a video page.
		local function file(name, track, unterminated)
			local fishead = "fishead\0"
				.. string.pack("<I2I2i8i8i8i8", 4, 0, 0, 1000, 0, 1000)
				.. "2020-01-02T03:04:05Z"
				.. string.pack("<I8I8", 0, 0)
			local fisbone = "fisbone\0"
				.. string.pack("<I4I4I4i8i8i8I4B", 44, 2, 3, 25, 1, 0, 0, 6)
				.. "\0\0\0"
				.. "Content-Type: video/theora\r\nRole: video/main\r\nName: "
				.. track
				.. "\r\n"
			local identification = "\128theora"
				.. string.char(3, 2, 1)
				.. string.pack(">I2I2", 4, 3)
				.. string.pack(">I3I3BB", 64, 48, 0, 0)
				.. string.pack(">I4I4I3I3B", 25, 1, 1, 1, 0)
				.. string.pack(">I3I2", 0, 48 << 10 | 6 << 5)
			local comments = { "ENCODER=MetaClean Encoder", "SOURCE_OSHASH=3e2b0eb8e3864207" }
			local comment = "\129theora" .. string.pack("<s4I4", "Secret Vendor", #comments)
			for _, value in ipairs(comments) do
				comment = comment .. string.pack("<s4", value)
			end
			local path = RUN .. "/" .. name
			write_bytes(
				path,
				ogg_page(1, 0, 2, { fishead })
					.. ogg_page(2, 0, 2, { identification })
					.. ogg_page(1, 1, 0, { fisbone })
					.. ogg_page(2, 1, 0, { comment, "\130theora" .. string.rep("\1", 40) })
					.. (unterminated and "" or ogg_page(1, 2, 4, { "" }))
					.. ogg_page(2, 2, 4, { string.rep("\0", 20) })
			)
			return path
		end
		local path = file("theora.ogv", "video_1")
		local state = assert(helpers.ogg_parse(path))
		assert(state.video and not state.audio, "Theora stream not recognized")
		local metadata = table.concat(state.metadata, ",")
		assert(metadata:find("Ogg comments", 1, true) and metadata:find("Skeleton date", 1, true), metadata)
		local data = read_bytes(path)
		local parts, position = {}, 0
		for _, region in ipairs(state.regions) do
			parts[#parts + 1] = data:sub(position + 1, region.start)
			parts[#parts + 1] = region.bytes
			position = region.finish
		end
		parts[#parts + 1] = data:sub(position + 1)
		write_bytes(path, table.concat(parts))
		local cleaned = read_bytes(path)
		assert(#cleaned == #data, "Ogg file size changed")
		assert(ogg_pages_valid(path) == 6, "Ogg page CRCs are wrong")
		for _, needle in ipairs({ "Secret Vendor", "MetaClean Encoder", "3e2b0eb8", "2020-01-02" }) do
			assert(not cleaned:find(needle, 1, true), "Theora identity remains: " .. needle)
		end
		assert(cleaned:find("Name: video_1", 1, true), "Skeleton track name lost")
		local again = assert(helpers.ogg_parse(path))
		assert(#again.metadata == 0 and #again.regions == 0, "cleaned Theora file is not clean")
		local named = file("theora-named.ogv", "Grandma")
		local result, err = helpers.ogg_parse(named)
		assert(not result and err:find("Skeleton header Name", 1, true), tostring(err))
		-- Skeleton headers that never close could hide later fisbones.
		result, err = helpers.ogg_parse(file("theora-open.ogv", "video_1", true))
		assert(not result and err == "incomplete Ogg headers", tostring(err))
	end)

	record("Ogg Speex comments are cleaned after the header's extra packets", function()
		-- A Speex header announcing one extra header packet after the comments.
		local header = "Speex   "
			.. string.rep("\0", 20)
			.. string.pack("<i4i4i4i4i4i4i4i4i4i4i4i4i4", 1, 80, 16000, 1, 4, 1, -1, 320, 0, 1, 1, 0, 0)
		local comment = string.pack("<s4I4s4", "Secret Speex Vendor", 1, "ARTIST=MetaClean Test User")
		local path = RUN .. "/speex.spx"
		write_bytes(
			path,
			ogg_page(5, 0, 2, { header })
				.. ogg_page(5, 1, 0, { comment, "extra header" })
				.. ogg_page(5, 2, 4, { string.rep("\0", 20) })
		)
		local state = assert(helpers.ogg_parse(path))
		assert(state.audio and #state.metadata == 1, "Speex comments not planned")
		local planned = {}
		for _, region in ipairs(state.regions) do
			planned[#planned + 1] = region.bytes
		end
		planned = table.concat(planned)
		assert(not planned:find("MetaClean Test User", 1, true), "Speex comment kept")
		-- The count sits 68 bytes into the packet, after a 28-byte page header.
		local data = read_bytes(path)
		write_bytes(path, data:sub(1, 96) .. "\200" .. data:sub(98))
		assert(select(2, helpers.ogg_parse(path)) == "invalid Ogg Speex header", "Speex header count not checked")
	end)

	record("MP3 loses ID3v2 and APE tags appended after the audio", function()
		-- The LAME header's end padding is applied only when FFmpeg finds the
		-- end of the audio, which the unknown trailing tag hides.
		local path = RUN .. "/trailing-id3.mp3"
		assert(execute({
			"ffmpeg",
			"-hide_banner",
			"-loglevel",
			"error",
			"-f",
			"lavfi",
			"-i",
			"sine=f=500:r=44100",
			"-t",
			"1",
			"-c:a",
			"libmp3lame",
			"-id3v2_version",
			"0",
			"-y",
			path,
		}))
		path = absolute(path)
		local audio = read_bytes(path)
		local frame = "TPE1" .. string.pack(">I4", 20) .. "\0\0\3MetaClean Test User"
		local size = string.char(0, 0, 0, #frame)
		local id3 = "ID3\4\0\16" .. size .. frame .. "3DI\4\0\16" .. size
		local item = string.pack("<I4I4", 15, 0) .. "Title\0Private audio title"
		local ape = item .. "APETAGEX" .. string.pack("<I4I4I4I4", 2000, #item + 32, 1, 0) .. string.rep("\0", 8)
		write_bytes(path, audio .. id3 .. ape)
		assert_sanitized(path)
		assert(read_bytes(path) == audio, "cleaned MP3 is not the original audio")
		assert_unchanged_rerun(path)
		-- A footer whose header is not where its size says is refused.
		write_bytes(path, audio .. "ID3\4\0\16" .. string.char(0, 0, 0, #frame + 1) .. frame .. "3DI\4\0\16" .. size)
		assert_skipped(path, "invalid ID3v2 tag after the audio")
	end)

	record("MP3 that ExifTool reads as MPEG video is scanned without its extension", function()
		local path = audio_fixture("start-code.mp3", { "-c:a", "libmp3lame", "-b:a", "320k" })
		-- An MPEG audio start code in the unused part of the LAME header frame,
		-- past the first 256 bytes, sends ExifTool to its MPEG video parser
		-- once the ID3v2 tag before it is gone.
		local data = read_bytes(path)
		local a, b, c, d = data:byte(7, 10)
		local at = 10 + ((a * 128 + b) * 128 + c) * 128 + d + 400
		assert(data:sub(at + 1, at + 4) == "\0\0\0\0", "LAME header frame is shorter than expected")
		write_bytes(path, data:sub(1, at) .. "\0\0\1\192" .. data:sub(at + 5))
		local before = decoded_audio(path)
		assert_sanitized(path)
		local ok, out = execute({ "exiftool", "--", path })
		assert(not ok and out:find("File format error", 1, true), "ExifTool reads the cleaned file: " .. out)
		assert(not read_bytes(path):find("MetaClean Test User", 1, true), "ID3v2 artist remains")
		assert(decoded_audio(path) == before, "decoded audio changed")
		assert_unchanged_rerun(path)
		local listed, links =
			execute({ "find", os.getenv("TMPDIR") or "/tmp", "-maxdepth", "1", "-name", "metaclean-scan*" })
		assert(listed and not links:match("%S"), "scan link left behind: " .. tostring(links))
	end)

	record("FLAC of zero samples needs no audio frames", function()
		local info = string.pack(">I2I2I3I3I4I4", 4608, 4608, 0, 0, 44100 << 12 | 15 << 4, 0)
			.. "\212\29\140\217\143\0\178\4\233\128\9\152\236\248\66\126"
		local comment = "TITLE=Private audio title"
		local comments = string.pack("<I4I4I4", 0, 1, #comment) .. comment
		local function flac(stream)
			return "fLaC\0"
				.. string.pack(">I3", #stream)
				.. stream
				.. "\132"
				.. string.pack(">I3", #comments)
				.. comments
		end
		local path = absolute(RUN .. "/empty.flac")
		write_bytes(path, flac(info))
		assert_sanitized(path)
		assert(not read_bytes(path):find("Private audio title", 1, true), "FLAC title remains")
		assert_unchanged_rerun(path)
		-- Samples without frames are a truncated stream.
		write_bytes(path, flac(info:sub(1, 17) .. "\1" .. info:sub(19)))
		assert_skipped(path, "unsupported FLAC structure")
	end)

	record("Motion-JPEG frames with their own Exif are skipped in every container", function()
		-- Camera clips store each frame as a JPEG; ExifTool reads none of them.
		local frames = {}
		for index = 1, 3 do
			frames[index] = RUN .. "/mjpeg-frame" .. index .. ".jpg"
			assert(execute({
				"ffmpeg",
				"-v",
				"error",
				"-f",
				"lavfi",
				"-i",
				"testsrc2=s=64x48",
				"-frames:v",
				"1",
				"-y",
				frames[index],
			}))
		end
		local function clip(name)
			local path = RUN .. "/" .. name
			assert(execute({
				"ffmpeg",
				"-v",
				"error",
				"-framerate",
				"5",
				"-i",
				RUN .. "/mjpeg-frame%d.jpg",
				"-c:v",
				"copy",
				"-y",
				path,
			}))
			return absolute(path)
		end
		-- Frames without metadata segments clean as before.
		local plain = clip("mjpeg-plain.avi")
		assert_sanitized(plain)
		exiftool({ "-Artist=Frame Owner", frames[2] })
		for _, extension in ipairs({ "avi", "mov", "mkv" }) do
			local path = clip("mjpeg-exif." .. extension)
			assert(read_bytes(path):find("Frame Owner", 1, true), "fixture lacks the frame's Exif: " .. extension)
			assert_skipped(path, "Motion%-JPEG frames with Exif")
		end
	end)

	-- AVI ----------------------------------------------------------------------

	-- An FFmpeg AVI whose reserved JUNK chunks are turned into camera data:
	-- the video stream's into strd (EXIF here, unless strd is given) and the
	-- header list's into an IDIT date.
	local function avi_fixture(name, strd)
		local path = RUN .. "/" .. name
		assert(execute({
			"ffmpeg",
			"-hide_banner",
			"-loglevel",
			"error",
			"-f",
			"lavfi",
			"-i",
			"testsrc2=s=96x64:r=10",
			"-f",
			"lavfi",
			"-i",
			"sine=f=500:r=44100",
			"-t",
			"1",
			"-c:v",
			"mjpeg",
			"-c:a",
			"pcm_s16le",
			"-metadata",
			"title=Private AVI title",
			"-metadata",
			"artist=MetaClean Test User",
			"-metadata:s:v:0",
			"title=Private stream name",
			"-y",
			path,
		}))
		local data, junks, position = read_bytes(path), {}, 1
		while true do
			local found = data:find("JUNK", position, true)
			if not found then
				break
			end
			junks[#junks + 1], position = found, found + 4
		end
		assert(#junks >= 3, "FFmpeg AVI lacks reserved JUNK chunks")
		local function replace(at, id, payload)
			local length = string.unpack("<I4", data, at + 4)
			assert(#payload <= length, "AVI fixture payload too large")
			payload = payload .. string.rep("\0", length - #payload)
			data = data:sub(1, at - 1) .. id .. data:sub(at + 4, at + 7) .. payload .. data:sub(at + 8 + length)
		end
		replace(junks[1], "strd", strd or "AVIF\0\0Exif\0\0MM\0*MetaClean Camera Serial")
		replace(junks[3], "IDIT", "2020/01/02 03:04:05\0")
		write_bytes(path, data)
		return absolute(path)
	end

	record("AVI transaction turns metadata chunks into JUNK in place", function()
		local path = avi_fixture("identity.avi")
		local identity = {
			"MetaClean Test User",
			"Private AVI title",
			"Private stream name",
			"MetaClean Camera Serial",
			"2020/01/02",
		}
		for _, needle in ipairs(identity) do
			assert(read_bytes(path):find(needle, 1, true), "fixture lacks " .. needle)
		end
		local size, before = #read_bytes(path), packets(path)
		assert_sanitized(path)
		for _, needle in ipairs(identity) do
			assert(not read_bytes(path):find(needle, 1, true), "identity bytes remain: " .. needle)
		end
		assert_absent(tags(path), { "Lavf", "2020" })
		assert(#read_bytes(path) == size, "AVI file size changed")
		assert(packets(path) == before, "AVI packets changed")
		assert_unchanged_rerun(path)
	end)

	record("AVI with unknown codec stream data is skipped unchanged", function()
		assert_skipped(avi_fixture("codec-data.avi", "\1\2\3\4"), "codec stream data")
	end)

	-- MPEG-TS and AVCHD -------------------------------------------------------

	local function decoded_video(path)
		local ok, out = execute({ "ffmpeg", "-v", "quiet", "-i", path, "-map", "0:v", "-f", "framemd5", "-" })
		assert(ok, out)
		return out
	end

	for _, case in ipairs({ { "TS", "camera.ts", "0" }, { "M2TS", "camera.m2ts", "1" } }) do
		record(case[1] .. " camera metadata in H.264 SEI is neutralized in place", function()
			local path = RUN .. "/" .. case[2]
			assert(execute({
				"ffmpeg",
				"-hide_banner",
				"-loglevel",
				"error",
				"-f",
				"lavfi",
				"-i",
				"testsrc2=s=96x64:r=25",
				"-f",
				"lavfi",
				"-i",
				"sine=f=500:r=48000",
				"-t",
				"1",
				"-c:v",
				"libx264",
				"-bsf:v",
				"h264_metadata=sei_user_data=17ee8c60-f84d-11d9-8cd6-0800200c9a66+MDPM MetaClean Camera Serial",
				"-c:a",
				"ac3",
				"-mpegts_m2ts_mode",
				case[3],
				"-y",
				path,
			}))
			path = absolute(path)
			assert(read_bytes(path):find("MetaClean Camera Serial", 1, true), "fixture lacks camera metadata")
			local size, before = #read_bytes(path), decoded_video(path)
			assert_sanitized(path)
			assert(not read_bytes(path):find("MDPM", 1, true), "camera metadata remains")
			assert(#read_bytes(path) == size, "transport stream size changed")
			assert(decoded_video(path) == before, "decoded video changed")
			assert_unchanged_rerun(path)
		end)
	end

	-- Laboratory parsers retained for the next formats --------------------------

	record("bounded binary reader and range helpers reject unsafe input", function()
		assert(helpers.checked_add(1, 2) == 3)
		assert(helpers.checked_add(9007199254740991, 1) == nil)
		assert(helpers.validate_ranges({ { start = 0, finish = 4 }, { start = 2, finish = 6 } }, 0, 10) == nil)
		local merged =
			assert(helpers.merge_adjacent_ranges({ { start = 0, finish = 2 }, { start = 2, finish = 4 } }, 0, 10))
		assert(#merged == 1 and merged[1].finish == 4)
		local path = RUN .. "/reader.bin"
		write_bytes(path, "0123456789")
		local reader = assert(helpers.binary_reader(path))
		assert(reader:read_exact(4) == "0123")
		assert(reader:read_exact(100) == nil)
		reader:close()
	end)

	local json = assert(io.open(REPORTS .. "/" .. RUN_ID .. ".json", "w"))
	json:write('{"run":', json_string(RUN_ID), ',"seconds":', tostring(os.time() - started), ',"tests":[\n')
	for i, test in ipairs(tests) do
		json:write(
			'{"name":',
			json_string(test.name),
			',"state":',
			json_string(test.state),
			string.format(',"seconds":%.6f,"detail":', test.seconds),
			json_string(test.detail),
			"}",
			i == #tests and "" or ",",
			"\n"
		)
	end
	json:write("]}\n")
	json:close()

	local failed = 0
	for _, test in ipairs(tests) do
		io.write(string.format("%-7s %s\n", test.state, test.name))
		if test.state == "failed" then
			io.write(test.detail .. "\n")
			failed = failed + 1
		end
	end
	if failed > 0 then
		io.write("Run files kept for inspection: " .. RUN .. "\n")
		os.exit(1)
	end
	-- A clean run leaves only its report behind.
	safe_remove(RUN)
end

main()
