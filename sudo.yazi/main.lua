--- sudo.yazi/main.lua
--- All-Lua sudo helper for Yazi 26.5.6+
---
--- Commands kept:
---   paste                 sudo cp -a / sudo mv
---   paste --force         sudo cp -af / sudo mv -f
---   rename                sudo mv
---   create                sudo touch / sudo mkdir -p
---   remove --permanently  sudo rm -rf
---   chmod                 sudo chmod
---   hx                    sudo hx selected/hovered files using user's Helix config
---
--- Notes:
---   - No Python/Ruby/Nushell helpers.
---   - No custom password handling. sudo owns the password prompt.
---   - hx loads the user's Helix config with --config.
---   - hx also gets XDG_CONFIG_HOME so user themes/config-adjacent files can resolve.

local function notify(message, level)
	ya.notify({
		title = "sudo.yazi",
		content = message,
		level = level or "info",
		timeout = 3.0,
	})
end

local function q(value)
	return ya.quote(tostring(value))
end

local function command_path(cmd)
	if not cmd or cmd == "" then
		return nil
	end

	local f = io.popen("command -v " .. q(cmd) .. " 2>/dev/null", "r")
	if not f then
		return nil
	end

	local result = f:read("*a")
	f:close()

	if not result then
		return nil
	end

	result = result:gsub("%s+$", "")
	if result == "" then
		return nil
	end

	return result
end

local function exists(path)
	local f = io.open(path, "r")
	if f then
		f:close()
		return true
	end
	return false
end

local function home()
	return os.getenv("HOME") or ""
end

local function expand_home(path)
	if not path or path == "" then
		return path
	end

	if path == "~" then
		return home()
	end

	if path:sub(1, 2) == "~/" then
		return home() .. path:sub(2)
	end

	return path
end

local function xdg_config_home()
	local override = os.getenv("YAZI_SUDO_HX_XDG_CONFIG_HOME")
	if override and override ~= "" then
		return expand_home(override)
	end

	local xdg = os.getenv("XDG_CONFIG_HOME")
	if xdg and xdg ~= "" then
		return expand_home(xdg)
	end

	return home() .. "/.config"
end

local function helix_config()
	local override = os.getenv("YAZI_SUDO_HX_CONFIG")
	if override and override ~= "" then
		return expand_home(override)
	end

	return xdg_config_home() .. "/helix/config.toml"
end

local function helix_runtime()
	local override = os.getenv("YAZI_SUDO_HELIX_RUNTIME")
	if override and override ~= "" then
		return expand_home(override)
	end

	local runtime = os.getenv("HELIX_RUNTIME")
	if runtime and runtime ~= "" then
		return expand_home(runtime)
	end

	return nil
end

local function join_path(dir, name)
	if dir:sub(-1) == "/" then
		return dir .. name
	end
	return dir .. "/" .. name
end

local function basename(path)
	local stripped = tostring(path):gsub("/+$", "")
	return stripped:match("([^/]+)$") or stripped
end

local function ends_with(path, suffix)
	return suffix == "" or path:sub(-#suffix) == suffix
end

local function simple_name(name)
	if not name or name == "" then
		return false
	end

	if name == "." or name == ".." then
		return false
	end

	return not name:find("/")
end

local function simple_create_name(name)
	if not name or name == "" then
		return false
	end

	local stripped = name:gsub("/+$", "")

	if stripped == "" or stripped == "." or stripped == ".." then
		return false
	end

	return not stripped:find("/")
end

local function sudo_cmd()
	return { "sudo", "-E", "-k", "--" }
end

local function push(list, value)
	table.insert(list, value)
end

local function pushq(list, value)
	table.insert(list, q(value))
end

local function push_env(list, key, value)
	if value and value ~= "" then
		table.insert(list, q(key .. "=" .. value))
	end
end

local function execute(command)
	ya.emit("shell", {
		table.concat(command, " "),
		block = true,
		confirm = true,
	})
end

local function selected_or_hovered()
	local targets = {}

	if #cx.active.selected ~= 0 then
		for _, url in pairs(cx.active.selected) do
			table.insert(targets, tostring(url))
		end
	else
		local hovered = cx.active.current.hovered
		if hovered and hovered.url then
			table.insert(targets, tostring(hovered.url))
		end
	end

	return targets
end

local function yanked_files()
	local yanked = {}

	for _, url in pairs(cx.yanked) do
		table.insert(yanked, tostring(url))
	end

	return yanked
end

local get_state = ya.sync(function(_, cmd)
	local current = cx.active.current
	local cwd = current and current.cwd and tostring(current.cwd) or nil

	if cmd == "paste" then
		return {
			kind = "paste",
			value = {
				cwd = cwd,
				is_cut = cx.yanked.is_cut,
				yanked = yanked_files(),
			},
		}
	end

	if cmd == "rename" then
		local hovered = current and current.hovered
		if not hovered or not hovered.url then
			return { kind = "none" }
		end

		return {
			kind = "rename",
			value = {
				cwd = cwd,
				hovered = tostring(hovered.url),
			},
		}
	end

	if cmd == "create" then
		return {
			kind = "create",
			value = {
				cwd = cwd,
			},
		}
	end

	if cmd == "remove" then
		return {
			kind = "remove",
			value = {
				targets = selected_or_hovered(),
			},
		}
	end

	if cmd == "chmod" then
		return {
			kind = "chmod",
			value = {
				targets = selected_or_hovered(),
			},
		}
	end

	if cmd == "hx" then
		return {
			kind = "hx",
			value = {
				cwd = cwd,
				targets = selected_or_hovered(),
			},
		}
	end

	return { kind = "none" }
end)

local function sudo_paste(value)
	if not value.cwd or value.cwd == "" then
		notify("Could not determine current directory", "error")
		return
	end

	if not value.yanked or #value.yanked == 0 then
		notify("Nothing yanked", "warn")
		return
	end

	local args = sudo_cmd()

	if value.is_cut then
		push(args, "mv")
		if value.force then
			push(args, "-f")
		end
		push(args, "--")
	else
		push(args, "cp")
		push(args, value.force and "-af" or "-a")
		push(args, "--")
	end

	for _, path in ipairs(value.yanked) do
		pushq(args, path)
	end

	pushq(args, value.cwd)

	execute(args)
end

local function sudo_rename(value)
	if not value.cwd or value.cwd == "" then
		notify("Could not determine current directory", "error")
		return
	end

	if not value.hovered or value.hovered == "" then
		notify("Nothing hovered", "warn")
		return
	end

	local new_name, event = ya.input({
		title = "sudo rename:",
		pos = { "top-center", y = 2, w = 40 },
		value = basename(value.hovered),
	})

	if event ~= 1 then
		return
	end

	if not simple_name(new_name) then
		notify("Rename only accepts a plain file name, not a path", "error")
		return
	end

	local new_path = join_path(value.cwd, new_name)

	local args = sudo_cmd()
	push(args, "mv")
	push(args, "--")
	pushq(args, value.hovered)
	pushq(args, new_path)

	execute(args)
end

local function sudo_create(value)
	if not value.cwd or value.cwd == "" then
		notify("Could not determine current directory", "error")
		return
	end

	local name, event = ya.input({
		title = "sudo create:",
		pos = { "top-center", y = 2, w = 40 },
	})

	if event ~= 1 then
		return
	end

	if not simple_create_name(name) then
		notify("Create only accepts a plain name, or a trailing / for directories", "error")
		return
	end

	local is_dir = ends_with(name, "/")
	local clean_name = name:gsub("/+$", "")
	local path = join_path(value.cwd, clean_name)

	local args = sudo_cmd()

	if is_dir then
		push(args, "mkdir")
		push(args, "-p")
		push(args, "--")
		pushq(args, path)
	else
		push(args, "touch")
		push(args, "--")
		pushq(args, path)
	end

	execute(args)
end

local function sudo_remove(value)
	if not value.permanently then
		notify("Trash support was removed. Use remove --permanently.", "error")
		return
	end

	if not value.targets or #value.targets == 0 then
		notify("Nothing selected or hovered", "warn")
		return
	end

	local args = sudo_cmd()
	push(args, "rm")
	push(args, "-rf")
	push(args, "--")

	for _, path in ipairs(value.targets) do
		pushq(args, path)
	end

	execute(args)
end

local function sudo_chmod(value)
	if not value.targets or #value.targets == 0 then
		notify("Nothing selected or hovered", "warn")
		return
	end

	local mode, event = ya.input({
		title = "sudo chmod:",
		pos = { "top-center", y = 2, w = 40 },
	})

	if event ~= 1 then
		return
	end

	if not mode or mode == "" then
		notify("No chmod mode entered", "warn")
		return
	end

	local args = sudo_cmd()
	push(args, "chmod")
	pushq(args, mode)
	push(args, "--")

	for _, path in ipairs(value.targets) do
		pushq(args, path)
	end

	execute(args)
end

local function sudo_hx(value)
	if not value.cwd or value.cwd == "" then
		notify("Could not determine current directory", "error")
		return
	end

	if not value.targets or #value.targets == 0 then
		notify("Nothing selected or hovered", "warn")
		return
	end

	local hx_cmd = os.getenv("YAZI_SUDO_HX")
	if not hx_cmd or hx_cmd == "" then
		hx_cmd = "hx"
	end

	local hx = command_path(hx_cmd)
	if not hx then
		notify("hx not found in PATH", "error")
		return
	end

	local config = helix_config()
	if not exists(config) then
		notify("User Helix config not found: " .. config, "error")
		return
	end

	local args = sudo_cmd()

	push(args, "env")

	-- Make root-run hx read the user's Helix config area.
	-- Do not set HOME; that avoids root writing normal cache/log files into the user's home.
	push_env(args, "XDG_CONFIG_HOME", xdg_config_home())

	-- Helpful for helix-git/source installs where runtime may be custom.
	local runtime = helix_runtime()
	if runtime then
		push_env(args, "HELIX_RUNTIME", runtime)
	end

	-- Usually preserved by sudo -E, but explicit env keeps terminal behavior less fragile.
	push_env(args, "TERM", os.getenv("TERM"))
	push_env(args, "COLORTERM", os.getenv("COLORTERM"))

	pushq(args, hx)

	push(args, "--config")
	pushq(args, config)

	push(args, "--working-dir")
	pushq(args, value.cwd)

	push(args, "--")

	for _, path in ipairs(value.targets) do
		pushq(args, path)
	end

	execute(args)
end

return {
	entry = function(_, job)
		local cmd = job.args[1]
		local state = get_state(cmd)

		-- Same behavior as the original plugin: leave visual mode before acting.
		-- See original comment/reference in the upstream-style file.
		ya.emit("escape", { visual = true })

		if state.kind == "paste" then
			state.value.force = job.args.force
			sudo_paste(state.value)
		elseif state.kind == "rename" then
			sudo_rename(state.value)
		elseif state.kind == "create" then
			sudo_create(state.value)
		elseif state.kind == "remove" then
			state.value.permanently = job.args.permanently
			sudo_remove(state.value)
		elseif state.kind == "chmod" then
			sudo_chmod(state.value)
		elseif state.kind == "hx" then
			sudo_hx(state.value)
		else
			notify("Unknown sudo command: " .. tostring(cmd), "error")
		end
	end,
}
