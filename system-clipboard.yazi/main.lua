local selected_or_hovered = ya.sync(function()
	local tab, paths = cx.active, {}
	for _, url in pairs(tab.selected) do
		paths[#paths + 1] = tostring(url)
	end
	if #paths == 0 and tab.current.hovered then
		paths[1] = tostring(tab.current.hovered.url)
	end
	return paths
end)

return {
	entry = function()
		if ya.target_os() ~= "macos" then
			return ya.notify({ title = "System Clipboard", content = "This plugin only supports macOS", level = "error", timeout = 5 })
		end

		ya.emit("escape", { visual = true })
		local paths = selected_or_hovered()
		if #paths == 0 then
			return ya.notify({ title = "System Clipboard", content = "No file selected", level = "warn", timeout = 5 })
		end

		local script = "on run argv\n"
			.. "  set fileList to {}\n"
			.. "  repeat with p in argv\n"
			.. "    set end of fileList to POSIX file p\n"
			.. "  end repeat\n"
			.. "  set the clipboard to fileList\n"
			.. "end run"
		local command = Command("osascript"):arg("-e"):arg(script)
		for _, path in ipairs(paths) do
			command = command:arg(path)
		end

		local child, spawn_err = command:spawn()
		if not child then
			return ya.notify({ title = "System Clipboard", content = "Could not start osascript: " .. tostring(spawn_err), level = "error", timeout = 5 })
		end
		local status, err = child:wait()
		if status and status.success then
			ya.notify({ title = "System Clipboard", content = "Copied file(s) to the system clipboard", level = "info", timeout = 5 })
		else
			ya.notify({ title = "System Clipboard", content = "Could not copy selected file(s): " .. (status and tostring(status.code) or tostring(err)), level = "error", timeout = 5 })
		end
	end,
}
