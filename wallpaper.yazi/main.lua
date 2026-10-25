--- @since 26.5.6

local hovered = ya.sync(function()
	local file = cx.active.current.hovered
	if not file then
		return nil
	end
	return tostring(file.url), file.cha.is_dir
end)

local function notify(content, level)
	ya.notify({ title = "Wallpaper", content = content, level = level, timeout = 3 })
end

local function set_awww(path, namespace)
	return Command("awww"):arg({
		"img",
		path,
		"--namespace",
		namespace,
		"--transition-type",
		"grow",
		"--transition-pos",
		"0.5,0.5",
		"--transition-duration",
		"1.2",
		"--transition-fps",
		"60",
	}):output()
end

local function save_last(path)
	local home = os.getenv("HOME")
	if not home or home == "" then
		return false, "HOME is not set"
	end

	local state_dir = os.getenv("XDG_STATE_HOME")
	if not state_dir or state_dir == "" then
		state_dir = home .. "/.local/state"
	end
	state_dir = state_dir .. "/awww"

	local ok, err = fs.create("dir_all", Url(state_dir))
	if not ok then
		return false, tostring(err)
	end

	ok, err = fs.write(Url(state_dir .. "/last"), path)
	return ok, err and tostring(err)
end

return {
	entry = function()
		if ya.target_os() ~= "linux" then
			notify("This plugin only supports Linux/Wayland", "error")
			return
		end

		local path, is_dir = hovered()
		if not path then
			notify("No file hovered", "warn")
			return
		end
		if is_dir then
			notify("Directories are not supported", "warn")
			return
		end

		local wallpaper, wallpaper_err = set_awww(path, "wallpaper")
		if not wallpaper or not wallpaper.status.success then
			local detail = wallpaper and wallpaper.stderr or wallpaper_err
			notify("wallpaper daemon: " .. tostring(detail), "error")
			return
		end

		local backdrop, backdrop_err = set_awww(path, "backdrop")
		if not backdrop or not backdrop.status.success then
			local detail = backdrop and backdrop.stderr or backdrop_err
			notify("backdrop daemon: " .. tostring(detail), "error")
			return
		end

		local saved, save_err = save_last(path)
		if saved then
			notify("Set " .. (path:match("([^/]+)$") or path), "info")
		else
			notify("Wallpaper set, but could not save state: " .. tostring(save_err), "warn")
		end
	end,
}
