--- @since 26.9.1
-- Prefixes notes in a configured directory with a lowercase timestamp and
-- appends ".md" to extensionless names, either automatically (preloader) or
-- on demand for the hovered file.

local M = {}

function M:setup(opts)
	opts = opts or {}

	assert(opts.dir, "ts-note: dir is required in setup()")
	assert(opts.dir:sub(1, 1) == "/", "ts-note: dir must be an absolute path, got: " .. tostring(opts.dir))

	self.dir = opts.dir
	self.format = opts.format or "%y%m%d%H%M"
	-- Matches an already-stamped name. Must stay in sync with `format` above --
	-- this is a text-shape check, not derived automatically from the format string.
	-- Captures (year, month, day, hour, minute) so already_stamped() can validate
	-- real values, not just "10 digits" shape -- otherwise a slug like
	-- "1234567890-idea.md" reads as already-stamped and never gets a real timestamp.
	self.pattern = opts.pattern or "^(%d%d)(%d%d)(%d%d)(%d%d)(%d%d)%-"
end

local get_state = ya.sync(function(self)
	local h = cx.active.current.hovered
	local cwd = tostring(cx.active.current.cwd)
	return h and tostring(h.url), cwd, self.dir, self.format, self.pattern
end)

local get_config = ya.sync(function(self)
	return self.format, self.pattern
end)

local function in_dir(cwd, dir)
	return cwd == dir or cwd:sub(1, #dir + 1) == dir .. "/"
end

local function already_stamped(name, pattern)
	local _, mo, day, hr, mi = name:match(pattern)
	if _ == nil then
		return false
	end
	-- Custom `opts.pattern` without (year, month, day) captures: shape match only.
	if mo == nil then
		return true
	end

	local mo_n, day_n = tonumber(mo), tonumber(day)
	if not mo_n or not day_n or mo_n < 1 or mo_n > 12 or day_n < 1 or day_n > 31 then
		return false
	end
	-- Date-only custom patterns stop here; the default also checks the time.
	if hr == nil then
		return true
	end

	local hr_n, mi_n = tonumber(hr), tonumber(mi)
	return hr_n ~= nil and mi_n ~= nil and hr_n <= 23 and mi_n <= 59
end

-- Extensionless, non-hidden names get ".md" appended so new notes can be
-- created by typing just the slug. Anything else that isn't .md is left alone.
local function note_name(name)
	if name:sub(1, 1) == "." then
		return nil
	end
	if not name:find("%.%w+$") then
		return name .. ".md"
	end
	if name:lower():sub(-3) == ".md" then
		return name
	end
	return nil
end

local function unique_target(parent, name)
	local candidate = parent:join(name)
	if not fs.cha(candidate) then
		return candidate
	end

	local stem, ext = name:match("^(.*)(%.[^.]*)$")
	stem, ext = stem or name, ext or ""

	local n = 1
	repeat
		candidate = parent:join(stem .. "_" .. n .. ext)
		n = n + 1
	until not fs.cha(candidate)
	return candidate
end

-- Manual fallback, bound to a key.
function M:entry()
	local url, cwd, dir, format, pattern = get_state()
	if not in_dir(cwd, dir) then
		return ya.notify({ title = "ts-note", content = "Not inside " .. dir, level = "warn" })
	end
	if not url then
		return ya.notify({ title = "ts-note", content = "Nothing hovered", level = "warn" })
	end

	local u = Url(url)
	local name = note_name(u.name)
	if not name then
		return
	end
	if already_stamped(name, pattern) then
		if name == u.name then
			return
		end
	else
		name = os.date(format):lower() .. "-" .. name
	end

	local target = unique_target(u.parent, name)
	if fs.rename(u, target) then
		ya.emit("reveal", { target })
	end
end

-- Automatic path, registered as a preloader.
function M:preload(job)
	local file = job.file
	if not file or file.cha.is_dir then
		return true, nil
	end

	local format, pattern = get_config()
	local url = file.url
	local name = note_name(url.name)
	if not name then
		return true, nil
	end

	if already_stamped(name, pattern) then
		if name == url.name then
			return true, nil
		end
	else
		name = os.date(format):lower() .. "-" .. name
	end

	local target = unique_target(url.parent, name)
	local ok, err = fs.rename(url, target)
	if ok then
		ya.emit("reveal", { target })
	end
	return true, (ok and nil or err)
end

return M
