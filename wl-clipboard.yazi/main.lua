--- @since 26.8.15

-- Meant to run at async context. (yazi system-clipboard)

local selected_or_hovered = ya.sync(function()
	local tab, paths = cx.active, {}
	for _, file in pairs(tab.selected) do
		paths[#paths + 1] = tostring(file.url)
	end
	if #paths == 0 and tab.current.hovered then
		paths[1] = tostring(tab.current.hovered.url)
	end
	return paths
end)

return {
	entry = function()
		if ya.target_os() ~= "linux" or not os.getenv("WAYLAND_DISPLAY") then
			return ya.notify({
				title = "System Clipboard",
				content = "This plugin requires a Linux Wayland session",
				level = "error",
				timeout = 5,
			})
		end

		ya.emit("escape", { visual = true })

		local urls = selected_or_hovered()

		if #urls == 0 then
			return ya.notify({ title = "System Clipboard", content = "No file selected", level = "warn", timeout = 5 })
		end

		-- Format the URLs for `text/uri-list` specification
		local function encode_uri(uri)
			return uri:gsub("([^%w%-%._~:/])", function(c)
				return string.format("%%%02X", string.byte(c))
			end)
		end

		local file_list_formatted = ""
		for _, path in ipairs(urls) do
			-- Each file path must be URI-encoded and prefixed with "file://"
			file_list_formatted = file_list_formatted .. "file://" .. encode_uri(path) .. "\r\n"
		end

		local child, spawn_err = Command("wl-copy")
			:arg({ "--type", "text/uri-list" })
			:stdin(Command.PIPED)
			:spawn()
		if not child then
			return ya.notify({
				title = "System Clipboard",
				content = "Could not start wl-copy: " .. tostring(spawn_err),
				level = "error",
				timeout = 5,
			})
		end

		local wrote, write_err = child:write_all(file_list_formatted)
		if wrote then
			wrote, write_err = child:flush()
		end
		local status, wait_err = child:wait()

		-- NOTE: status.success is the documented field. The previous version
		-- of this check used "status.succes" (typo) combined with `status or`
		-- instead of `status and`, which meant the success notification could
		-- fire any time the command merely spawned, regardless of whether
		-- wl-copy actually succeeded.
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
				content = string.format(
					"Could not copy selected file(s): %s",
					not wrote and tostring(write_err) or status and tostring(status.code) or tostring(wait_err)
				),
				level = "error",
				timeout = 5,
			})
		end
	end,
}
