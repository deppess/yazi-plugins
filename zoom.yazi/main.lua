--- @since 26.1.22

local get = ya.sync(function(st, url) return st.last == url and st.level end)

local save = ya.sync(function(st, url, new)
	local h = cx.active.current.hovered
	if h and h.url == url then
		st.last, st.level = url, new
		return true
	end
end)

local lock = ya.sync(function(st, url, old, new)
	if st.last == url and st.level == old then
		st.level = new
		return true
	end
end)

local move = ya.sync(function(st)
	local h = cx.active.current.hovered
	if not h then
		return
	end

	if st.last ~= h.url then
		st.last, st.level = Url(h.url), 0
	end

	return { url = h.url, level = st.level }
end)

-- Track the most recently shown scratch file (sync state, since peek() runs
-- in an async context but file lifetime needs to span calls).
local get_prev_tmp = ya.sync(function(st) return st.prev_tmp end)
local set_prev_tmp = ya.sync(function(st, path) st.prev_tmp = path end)

local function end_(job, err)
	if not job.old_level then
		ya.preview_widget(job, err and ui.Text(err):area(job.area):wrap(ui.Wrap.YES))
	elseif err then
		ya.notify { title = "Zoom", content = tostring(err), timeout = 5, level = "error" }
	end
end

local function canvas(area)
	local cw, ch = rt.term.cell_size()
	if not cw then
		return rt.preview.max_width, rt.preview.max_height
	end

	return math.min(rt.preview.max_width, math.floor(area.w * cw)),
		math.min(rt.preview.max_height, math.floor(area.h * ch))
end

-- Build a tmpfs-backed scratch path for the resized JPEG rather than relying
-- on os.tmpname(), which drops into the shared, world-readable /tmp pool.
-- $XDG_RUNTIME_DIR is per-user and 0700 on virtually every modern Linux setup.
local function scratch_path()
	local runtime_dir = os.getenv("XDG_RUNTIME_DIR") or os.getenv("TMPDIR") or "/tmp"
	return string.format("%s/yazi-zoom-%d-%d.jpg", runtime_dir, ya.uid and ya.uid() or 0, math.random(100000, 999999))
end

local function peek(_, job)
	local url = job.file.url
	local info, err = ya.image_info(url)
	if not info then
		return end_(job, Err("Failed to get image info: %s", err))
	end

	local level = ya.clamp(-10, job.new_level or get(Url(url)) or tonumber(job.args[1]) or 0, 10)
	local sync = function()
		if job.old_level then
			return lock(url, job.old_level, level)
		else
			return save(url, level)
		end
	end

	local max_w, max_h = canvas(job.area)
	local min_w, min_h = math.min(max_w, info.w), math.min(max_h, info.h)
	local new_w = min_w + math.floor(min_w * level * 0.1)
	local new_h = min_h + math.floor(min_h * level * 0.1)
	if new_w > max_w or new_h > max_h then
		if job.old_level then
			return sync() -- Image larger than available preview area after zooming
		else
			new_w, new_h = max_w, max_h -- Run as a previewer, render the image anyway
		end
	end

	local tmp = scratch_path()
	-- stylua: ignore
	local output, err = Command("magick"):arg {
		tostring(job.file.path),
		"-auto-orient", "-strip",
		"-sample", string.format("%dx%d", new_w, new_h),
		"-quality", rt.preview.image_quality,
		string.format("JPG:%s", tmp),
	}:output()

	if not output then
		os.remove(tmp)
		return end_(job, Err("Failed to start `magick`, error: %s", err))
	elseif not output.status.success then
		os.remove(tmp)
		return end_(job, Err("`magick` exited with error code %s: %s", output.status.code, output.stderr))
	elseif sync() then
		ya.image_show(Url(tmp), job.area)

		-- Don't delete `tmp` here -- some terminal image protocols read the
		-- file asynchronously after image_show() returns, so removing it
		-- immediately can race the renderer and show a blank/broken preview.
		-- Instead, clean up the *previous* scratch file now that we know
		-- it's no longer the one on screen, and remember this one for next
		-- time. Worst case there is exactly one extra file left behind in
		-- $XDG_RUNTIME_DIR, which is tmpfs and cleared on logout/reboot.
		local prev = get_prev_tmp()
		if prev and prev ~= tmp then
			os.remove(prev)
		end
		set_prev_tmp(tmp)
	else
		os.remove(tmp)
	end
	end_(job)
end

local function entry(self, job)
	local st = move()
	if not st then
		return
	end

	local motion = tonumber(job.args[1]) or 0
	local new = ya.clamp(-10, st.level + motion, 10)
	if new ~= st.level then
		peek(self, {
			area = ui.area("preview"),
			args = {},
			file = File { url = st.url, cha = Cha { mode = tonumber("100644", 8) } },
			skip = 0,
			new_level = new,
			old_level = st.level,
		})
	end
end

return { peek = peek, entry = entry }
