--- @since 25.5.31
-- Encrypted volume manager using gocryptfs

local M = {}

-- State management using ya.sync
local set_state = ya.sync(function(state, key, value)
	if not state then
		state = {}
	end
	state[key] = value
end)

local get_state = ya.sync(function(state, key)
	return state and state[key]
end)

---@enum STATE
local STATE = {
	LOCKED_PATH = "locked_path",
	OPEN_PATH = "open_path",
	MAX_RETRIES = "max_retries",
	INITIALIZED = "initialized",
}

-- Function to send notifications
local function notify(message, level)
	ya.notify({
		title = "Crypter",
		content = message,
		level = level or "info",
		timeout = 2.0,
	})
end

-- Check if command is available
local function is_command_available(cmd)
	local stat_cmd = string.format("command -v %s >/dev/null 2>&1", cmd)
	local cmd_exists = os.execute(stat_cmd)
	return cmd_exists == true or cmd_exists == 0
end

-- Expand ~ in path to full home directory
local function expand_path(path)
	if path:sub(1, 1) == "~" then
		local home = os.getenv("HOME")
		return home .. path:sub(2)
	end
	return path
end

-- Check if a path exists
local function path_exists(path)
	local expanded = expand_path(path)
	local status = Command("test")
		:arg({ "-e", expanded })
		:spawn()
		:wait()
	return status and status.success
end

-- Check if a path is currently mounted
local function is_mounted(path)
	local expanded = expand_path(path)

	-- First check if mountpoint command exists
	if not is_command_available("mountpoint") then
		-- Fallback: check /proc/mounts
		local result = Command("grep")
			:arg({ "-q", expanded, "/proc/mounts" })
			:spawn()
			:wait()
		return result and result.success
	end

	-- Use mountpoint command
	local result = Command("mountpoint")
		:arg({ "-q", expanded })
		:stdout(Command.PIPED)
		:stderr(Command.PIPED)
		:spawn()
		:wait()

	return result and result.success
end

-- Parse gocryptfs error messages
local function parse_gocryptfs_error(stderr_output)
	if not stderr_output or stderr_output == "" then
		return "Unknown error occurred"
	end

	-- Common gocryptfs error patterns
	if stderr_output:match("Password incorrect") or stderr_output:match("DecryptMasterKey") then
		return "incorrect_password"
	elseif stderr_output:match("Unable to open gocryptfs.conf") then
		return "Invalid or corrupted encrypted directory"
	elseif stderr_output:match("CIPHERDIR is not a directory") then
		return "Encrypted directory path is not valid"
	elseif stderr_output:match("Missing required argument") then
		return "Configuration error"
	elseif stderr_output:match("permission denied") then
		return "Permission denied - check directory permissions"
	elseif stderr_output:match("not empty") then
		return "Mount point is not empty"
	else
		-- Return first non-empty line of error
		for line in stderr_output:gmatch("[^\r\n]+") do
			if line:match("%S") then
				return line
			end
		end
		return "Encryption operation failed"
	end
end

-- Lock (unmount) encrypted volume
local function lock(open_path)
	local expanded_path = expand_path(open_path)

	-- Check if path exists
	if not path_exists(expanded_path) then
		notify(string.format("Mount point does not exist: %s", open_path), "error")
		return false
	end

	-- Check if already locked
	if not is_mounted(expanded_path) then
		notify("Already locked", "info")
		return true
	end

	-- Check if fusermount is available
	if not is_command_available("fusermount") then
		notify("fusermount not available", "error")
		return false
	end

	-- Unmount with better error handling
	local result = Command("fusermount")
		:arg({ "-u", expanded_path })
		:stdout(Command.PIPED)
		:stderr(Command.PIPED)
		:spawn()
		:wait()

	if result and result.success then
		notify("Locked successfully", "info")
		return true
	else
		-- Try with -z flag (lazy unmount)
		local lazy_result = Command("fusermount")
			:arg({ "-uz", expanded_path })
			:stdout(Command.PIPED)
			:stderr(Command.PIPED)
			:spawn()
			:wait()

		if lazy_result and lazy_result.success then
			notify("Locked successfully", "info")
			return true
		else
			notify("Failed to unmount - volume may be in use", "error")
			return false
		end
	end
end

-- Write the password to a fresh, user-only scratch file and return its path.
-- Uses the native fs.access() API instead of shelling out through `sh -c`:
--   - create_new(true) atomically fails if the path already exists, so there
--     is no window where a pre-existing file/symlink at that path could be
--     reused or raced.
--   - The file is opened directly by this process, never passed through an
--     intermediate shell, so there's nothing for `ya.quote` to need to
--     protect in the first place.
-- Falls back to $XDG_RUNTIME_DIR (per-user, 0700, usually tmpfs) and only
-- drops to /tmp if that's unset.
local function write_passfile(password)
	local runtime_dir = os.getenv("XDG_RUNTIME_DIR") or "/tmp"

	for _ = 1, 5 do
		local candidate = string.format("%s/crypter-passfile-%d", runtime_dir, math.random(100000, 999999))
		local url = Url(candidate)

		local fd, err = fs.access():write(true):create_new(true):open(url)
		if fd then
			local ok, werr = fd:write_all(password)
			fd:flush()
			if not ok then
				fs.remove("file", url)
				return nil, werr
			end
			return candidate
		elseif err and err.kind ~= "AlreadyExists" then
			return nil, err
		end
		-- AlreadyExists: extremely unlikely collision on the random suffix,
		-- just try again with a new name.
	end

	return nil, Err("Failed to allocate a scratch passfile after 5 attempts")
end

-- Unlock (mount) encrypted volume with password retry
local function unlock(locked_path, open_path, max_retries)
	local expanded_locked = expand_path(locked_path)
	local expanded_open = expand_path(open_path)

	-- Check if locked path exists
	if not path_exists(expanded_locked) then
		notify(string.format("Encrypted directory does not exist: %s", locked_path), "error")
		return false
	end

	-- Check if mount point exists
	if not path_exists(expanded_open) then
		notify(string.format("Mount point does not exist: %s", open_path), "error")
		return false
	end

	-- Check if already unlocked
	if is_mounted(expanded_open) then
		notify("Already unlocked", "info")
		return true
	end

	-- Check if gocryptfs is installed
	if not is_command_available("gocryptfs") then
		notify("gocryptfs not installed", "error")
		return false
	end

	local attempts = 0

	while attempts < max_retries do
		-- Show password input with cleaner UI
		local title = attempts == 0
			and "Unlock Encrypted Volume"
			or string.format("Invalid Password (%d/%d)", attempts, max_retries)

		local password, event = ya.input({
			title = title,
			value = "",
			placeholder = "Enter password",
			obscure = true,
			pos = { "center", w = 60 },
		})

		-- User cancelled
		if event ~= 1 then
			notify("Unlock cancelled", "warn")
			return false
		end

		attempts = attempts + 1

		local temp_file, write_err = write_passfile(password)
		if not temp_file then
			notify(string.format("Failed to create secure password file: %s", tostring(write_err)), "error")
			return false
		end

		-- Try to mount with password file
		local result = Command("gocryptfs")
			:arg({ "--passfile", temp_file, expanded_locked, expanded_open })
			:stdout(Command.PIPED)
			:stderr(Command.PIPED)
			:spawn()
			:wait()

		-- Always remove the temp file immediately
		fs.remove("file", Url(temp_file))

		if result and result.success then
			notify("Unlocked successfully", "info")
			return true
		else
			-- Parse and handle the error
			local error_msg = parse_gocryptfs_error(result.stderr)

			-- If it's not a password error, show the error and exit
			if error_msg ~= "incorrect_password" then
				notify(error_msg, "error")
				return false
			end

			-- Max attempts reached
			if attempts >= max_retries then
				notify("Max password attempts exceeded", "error")
				return false
			end
		end
	end

	return false
end

-- Toggle encrypted volume (auto-detect current state)
local function toggle(locked_path, open_path, max_retries)
	local expanded_open = expand_path(open_path)

	-- Check if currently mounted
	local mounted = is_mounted(expanded_open)

	if mounted then
		-- Currently unlocked, so lock it
		return lock(open_path)
	else
		-- Currently locked, so unlock it
		return unlock(locked_path, open_path, max_retries)
	end
end

-- Setup plugin configuration
---@param opts? {locked_path?: string, open_path?: string, max_retries?: number}
function M:setup(opts)
	if opts and type(opts) ~= "table" then
		return
	end
	set_state(STATE.LOCKED_PATH, (opts and opts.locked_path) or os.getenv("HOME") .. "/.local/share/crypter/locked")
	set_state(STATE.OPEN_PATH, (opts and opts.open_path) or os.getenv("HOME") .. "/.local/share/crypter/open")
	set_state(STATE.MAX_RETRIES, (opts and opts.max_retries) or 3)
	set_state(STATE.INITIALIZED, true)
end

-- Entry point
function M:entry(job)
	-- Initialize with defaults if not configured
	if not get_state(STATE.INITIALIZED) then
		M:setup()
	end

	local locked_path = get_state(STATE.LOCKED_PATH)
	local open_path = get_state(STATE.OPEN_PATH)
	local max_retries = get_state(STATE.MAX_RETRIES)

	-- Always toggle - check current state and switch
	toggle(locked_path, open_path, max_retries)
end

return M
