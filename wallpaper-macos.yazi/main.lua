--- @since 26.5.6
-- Set the hovered file as the wallpaper on every connected macOS display.

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

local function set_wallpaper(path)
	for _, binary in ipairs({ "desktoppr", "/opt/homebrew/bin/desktoppr" }) do
		local output = Command(binary):arg({ "all", path }):output()
		if output then
			return output
		end
	end
	return nil
end

return {
	entry = function()
		if ya.target_os() ~= "macos" then
			notify("This plugin only supports macOS", "error")
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

		local output = set_wallpaper(path)
		if not output or not output.status.success then
			notify("desktoppr could not set the wallpaper", "error")
			return
		end

		notify("Set " .. (path:match("([^/]+)$") or path), "info")
	end,
}
