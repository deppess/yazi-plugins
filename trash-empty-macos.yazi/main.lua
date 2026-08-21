--- @since 25.5.31
-- Clear the macOS trash system-wide for the current user -- no prompts,
-- instant action.
--
-- Covers ~/.Trash, /System/Volumes/Data/.Trashes/<uid>, and every mounted
-- volume's .Trashes/<uid>. Discovery is based on `mount`, not just /Volumes,
-- so APFS Data and other non-/Volumes mount points are covered too.
--
-- macOS counterpart to trash-empty.yazi (which targets XDG trash + .Trash-*
-- dirs via trash-cli on Linux). See README for details.

local M = {}

local EMPTY_SCRIPT = [[
uid=$(id -u 2>/dev/null) || exit 2

items=0
bytes=0
locations=0
failed=0
seen=

process_dir() {
	dir=$1
	[ -d "$dir" ] || return

	case "
$seen
" in
	*"
$dir
"*) return ;;
	esac
	seen="${seen}
$dir"

	count=$(find "$dir" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')
	case "$count" in ''|*[!0-9]*) count=0 ;; esac
	[ "$count" -gt 0 ] || return

	kb=$(du -sk "$dir" 2>/dev/null | awk '{print $1}')
	case "$kb" in ''|*[!0-9]*) kb=0 ;; esac

	items=$((items + count))
	bytes=$((bytes + kb * 1024))

	if find "$dir" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null; then
		locations=$((locations + 1))
	else
		failed=$((failed + 1))
	fi
}

process_trash_root() {
	root=$1
	process_dir "$root/$uid"
}

[ -n "$HOME" ] && process_dir "$HOME/.Trash"
process_dir "/System/Volumes/Data/.Trashes/$uid"

while IFS= read -r line; do
	case "$line" in
	*" on "*" ("*)
		mountpoint=${line#* on }
		mountpoint=${mountpoint% (*}
		process_trash_root "$mountpoint/.Trashes"
		;;
	esac
done <<__TRASH_EMPTY_MOUNT_OUTPUT__
$(mount 2>/dev/null)
__TRASH_EMPTY_MOUNT_OUTPUT__

printf 'ITEMS=%s\nBYTES=%s\nLOCATIONS=%s\nFAILED=%s\n' "$items" "$bytes" "$locations" "$failed"
]]

local function notify(message, level)
	ya.notify({
		title = "Trash Clear",
		content = message,
		level = level or "info",
		timeout = 3.0,
	})
end

local function format_size(bytes)
	if bytes == 0 then
		return "0 B"
	end

	local units = { "B", "KB", "MB", "GB", "TB" }
	local unit_index = 1
	local size = bytes

	while size >= 1024 and unit_index < #units do
		size = size / 1024
		unit_index = unit_index + 1
	end

	return string.format("%.1f %s", size, units[unit_index])
end

local function clear_trash()
	if ya.target_os() ~= "macos" then
		notify("This plugin only supports macOS", "error")
		return false
	end

	local output, _ = Command("sh")
		:arg({ "-c", EMPTY_SCRIPT })
		:stdout(Command.PIPED)
		:stderr(Command.PIPED)
		:output()
	if not output or not output.status or not output.status.success then
		notify("Failed to clear trash", "error")
		return false
	end

	local item_count = tonumber(output.stdout:match("ITEMS=(%d+)")) or 0
	local size_before = tonumber(output.stdout:match("BYTES=(%d+)")) or 0
	local locations = tonumber(output.stdout:match("LOCATIONS=(%d+)")) or 0
	local failed = tonumber(output.stdout:match("FAILED=(%d+)")) or 0

	if item_count == 0 and failed == 0 then
		notify("Trash is already empty", "info")
		return true
	end

	local message = string.format("Emptied %d items | %s freed | %d locations cleared", item_count, format_size(size_before), locations)
	local level = "info"

	if failed > 0 then
		message = message .. string.format(" | %d failed", failed)
		level = "warn"
	end

	notify(message, level)
	return failed == 0
end

-- Entry point
function M:entry()
	clear_trash()
end

return M
