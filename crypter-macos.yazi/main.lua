--- @since 25.5.31
-- Encrypted volume manager for macOS APFS volumes.
-- Toggles lock state via `diskutil apfs lockVolume`/`unlockVolume`, mirroring
-- the `lock`/`unlock` fish functions (~/.config/fish/functions/{lock,unlock}.fish).
-- macOS counterpart to crypter.yazi (which targets gocryptfs on Linux).

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
	VOLUME_NAME = "volume_name",
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

-- Find the disk identifier for a named APFS volume. Same two-pass matching
-- as the fish functions' awk script: track the most recent "APFS Volume Disk
-- (Role):" device as we scan, and return it once its paired "Name:" line
-- matches (the volume's display name may contain a trailing "(Case-...)"
-- qualifier, which is stripped before comparing).
local function find_volume_disk(name)
	local output, err = Command("diskutil"):arg({ "apfs", "list" }):stdout(Command.PIPED):stderr(Command.PIPED):output()
	if not output then
		return nil, string.format("Failed to run `diskutil apfs list`: %s", tostring(err))
	elseif not output.status.success then
		return nil, string.format("`diskutil apfs list` failed: %s", output.stderr)
	end

	local dev = nil
	for line in output.stdout:gmatch("[^\r\n]+") do
		local role_dev = line:match("APFS Volume Disk %(Role%):%s+(%S+)")
		if role_dev then
			dev = role_dev
		end

		local vol_name = line:match("Name:%s+(.-)%s+%(")
		if vol_name and vol_name == name and dev then
			return dev
		end
	end

	return nil, string.format("APFS volume '%s' not found", name)
end

-- Query whether a given APFS volume disk is currently locked.
---@return boolean? locked
---@return string? err
local function is_locked(dev)
	local output, err = Command("diskutil"):arg({ "info", dev }):stdout(Command.PIPED):stderr(Command.PIPED):output()
	if not output then
		return nil, string.format("Failed to query volume status: %s", tostring(err))
	elseif not output.status.success then
		return nil, string.format("`diskutil info` failed: %s", output.stderr)
	end

	local locked = output.stdout:match("\n%s*Locked:%s+(%S+)")
	if locked == nil then
		return nil, "Could not determine lock state (no `Locked:` field — is this an encrypted volume?)"
	end
	return locked == "Yes"
end

-- Lock the volume.
local function lock(dev)
	local output, err = Command("diskutil"):arg({ "apfs", "lockVolume", dev }):stdout(Command.PIPED):stderr(Command.PIPED):output()

	if output and output.status.success then
		notify("Locked successfully", "info")
		return true
	end

	notify(string.format("Failed to lock: %s", output and output.stderr or tostring(err)), "error")
	return false
end

-- Unlock the volume, prompting for the passphrase up to `max_retries` times.
-- The passphrase is piped directly to `diskutil`'s stdin via
-- `-stdinpassphrase` — never written to disk, never passed as a CLI arg.
local function unlock(dev, max_retries)
	local attempts = 0

	while attempts < max_retries do
		local title = attempts == 0 and "Unlock Encrypted Volume"
			or string.format("Invalid Password (%d/%d)", attempts, max_retries)

		local password, event = ya.input({
			title = title,
			value = "",
			placeholder = "Enter password",
			obscure = true,
			pos = { "center", w = 60 },
		})

		if event ~= 1 then
			notify("Unlock cancelled", "warn")
			return false
		end

		attempts = attempts + 1

		local child, spawn_err = Command("diskutil")
			:arg({ "apfs", "unlockVolume", dev, "-stdinpassphrase" })
			:stdin(Command.PIPED)
			:stdout(Command.PIPED)
			:stderr(Command.PIPED)
			:spawn()

		if not child then
			notify(string.format("Failed to start diskutil: %s", tostring(spawn_err)), "error")
			return false
		end

		child:write_all(password .. "\n")
		child:flush()
		local output, wait_err = child:wait_with_output()

		if output and output.status.success then
			notify("Unlocked successfully", "info")
			return true
		end

		local err_msg = output and output.stderr or tostring(wait_err)
		if attempts >= max_retries then
			notify(string.format("Max password attempts exceeded: %s", err_msg), "error")
			return false
		end
		-- Otherwise loop and re-prompt; diskutil's own stderr (shown above on
		-- the final attempt) already conveys wrong-password vs other errors.
	end

	return false
end

-- Toggle encrypted volume (auto-detect current state)
local function toggle(volume_name, max_retries)
	local dev, find_err = find_volume_disk(volume_name)
	if not dev then
		notify(find_err, "error")
		return false
	end

	local locked, status_err = is_locked(dev)
	if locked == nil then
		notify(status_err, "error")
		return false
	end

	if locked then
		return unlock(dev, max_retries)
	else
		return lock(dev)
	end
end

-- Setup plugin configuration
---@param opts? {volume_name?: string, max_retries?: number}
function M:setup(opts)
	if opts and type(opts) ~= "table" then
		return
	end
	set_state(STATE.VOLUME_NAME, (opts and opts.volume_name) or "Media")
	set_state(STATE.MAX_RETRIES, (opts and opts.max_retries) or 3)
	set_state(STATE.INITIALIZED, true)
end

-- Entry point
function M:entry(job)
	if not get_state(STATE.INITIALIZED) then
		M:setup()
	end

	local volume_name = get_state(STATE.VOLUME_NAME)
	local max_retries = get_state(STATE.MAX_RETRIES)

	toggle(volume_name, max_retries)
end

return M
