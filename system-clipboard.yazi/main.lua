-- macOS equivalent of wl-clipboard.yazi: copies selected/hovered files onto
-- the system clipboard as real file references (via NSPasteboard through
-- osascript), so pasting into Finder or any other app works, not just text.

local selected_or_hovered = ya.sync(function()
	local tab, paths = cx.active, {}
	for _, u in pairs(tab.selected) do
		paths[#paths + 1] = tostring(u)
	end
	if #paths == 0 and tab.current.hovered then
		paths[1] = tostring(tab.current.hovered.url)
	end
	return paths
end)

return {
	entry = function()
		ya.emit("escape", { visual = true })

		local urls = selected_or_hovered()

		if #urls == 0 then
			return ya.notify({ title = "System Clipboard", content = "No file selected", level = "warn", timeout = 5 })
		end

		local script = "on run argv\n"
			.. "  set fileList to {}\n"
			.. "  repeat with p in argv\n"
			.. "    set end of fileList to POSIX file p\n"
			.. "  end repeat\n"
			.. "  set the clipboard to fileList\n"
			.. "end run"

		local cmd = Command("osascript"):arg("-e"):arg(script)
		for _, path in ipairs(urls) do
			cmd = cmd:arg(path)
		end
		local status, err = cmd:spawn():wait()

		if status and status.success then
			ya.notify({
				title = "System Clipboard",
				content = "Successfully copied the file(s) to system clipboard",
				level = "info",
				timeout = 5,
			})
		else
			ya.notify({
				title = "System Clipboard",
				content = string.format("Could not copy selected file(s) %s", status and status.code or err),
				level = "error",
				timeout = 5,
			})
		end
	end,
}
