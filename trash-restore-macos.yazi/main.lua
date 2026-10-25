--- @since 26.8.15
-- Trash and restore files using macOS's native per-volume trash locations
-- (~/.Trash, plus each mounted volume's .Trashes/<uid> -- same discovery
-- logic as trash-empty-macos.yazi). Trashing runs one `sh` subprocess no
-- matter how many files are targeted. A tiny per-trash-dir manifest
-- (.restore-manifest.tsv) records original paths at trash time; it lives
-- and dies with that trash dir's contents, so trash-empty-macos.yazi
-- clearing a dir clears its manifest for free.
--
-- Restore opens an in-Yazi picker (ported from restore.yazi's Modal) over
-- the newest 100 manifest entries across every trash location -- space to
-- multi-select, Enter to restore (falls back to the item under the cursor
-- if nothing's selected), j/k or arrows to move, q/Esc to cancel. Picking
-- just narrows down which trashed paths get handed to the same restore
-- logic used everywhere else in this plugin. Listing those entries is also
-- one subprocess total, regardless of how many volumes are mounted.

local M = {}

local TRASH_SCRIPT = [[
uid=$(id -u)
home="$HOME"
home_dev=$(stat -f %d "$home" 2>/dev/null)
trashed=0
skipped=0
for f in "$@"; do
	if [ ! -e "$f" ]; then skipped=$((skipped+1)); continue; fi
	dev=$(stat -f %d "$f" 2>/dev/null)
	if [ "$dev" = "$home_dev" ] || [ -z "$dev" ]; then
		dir="$home/.Trash"
	else
		mp=$(df -P "$f" 2>/dev/null | awk 'END{print $NF}')
		dir="$mp/.Trashes/$uid"
	fi
	mkdir -p "$dir" 2>/dev/null
	chmod 700 "$dir" 2>/dev/null
	name=$(basename "$f")
	dest="$dir/$name"
	n=2
	while [ -e "$dest" ]; do
		dest="$dir/$name ($n)"
		n=$((n+1))
	done
	if mv "$f" "$dest" 2>/dev/null; then
		printf '%s\t%s\t%s\n' "$(basename "$dest")" "$f" "$(date +%s)" >> "$dir/.restore-manifest.tsv"
		trashed=$((trashed+1))
	else
		skipped=$((skipped+1))
	fi
done
printf 'TRASHED=%s\nSKIPPED=%s\n' "$trashed" "$skipped"
]]

local RESTORE_SCRIPT = [[
restored=0
skipped=0
for f in "$@"; do
	if [ ! -e "$f" ]; then skipped=$((skipped+1)); continue; fi
	dir=$(dirname "$f")
	name=$(basename "$f")
	manifest="$dir/.restore-manifest.tsv"
	orig=""
	if [ -f "$manifest" ]; then
		orig=$(awk -F'\t' -v n="$name" '$1==n{print $2; exit}' "$manifest")
	fi
	if [ -z "$orig" ]; then
		skipped=$((skipped+1))
		continue
	fi
	mkdir -p "$(dirname "$orig")" 2>/dev/null
	dest="$orig"
	if [ -e "$dest" ]; then
		n=1
		dest="$orig ($n)"
		while [ -e "$dest" ] && [ "$n" -lt 100 ]; do
			n=$((n+1))
			dest="$orig ($n)"
		done
		if [ -e "$dest" ]; then
			skipped=$((skipped+1))
			continue
		fi
	fi
	if mv "$f" "$dest" 2>/dev/null; then
		tmp="$manifest.tmp.$$"
		awk -F'\t' -v n="$name" 'BEGIN{OFS="\t"} $1!=n{print}' "$manifest" > "$tmp" && mv "$tmp" "$manifest"
		restored=$((restored+1))
	else
		skipped=$((skipped+1))
	fi
done
printf 'RESTORED=%s\nSKIPPED=%s\n' "$restored" "$skipped"
]]

-- Lists the newest 100 manifest entries across every trash location, as
-- "<epoch>\t<trash_dir>\t<trashed_name>\t<original_path>", newest first.
-- Fully self-contained: uid, mount discovery, manifest reads, sort and cap
-- all happen in this one subprocess. Mount output covers APFS Data plus
-- non-/Volumes mounts such as network, encrypted, and FUSE filesystems.
local LIST_SCRIPT = [[
uid=$(id -u)
home="$HOME"
seen=
emit() {
	dir=$1
	case "
$seen
" in
	*"
$dir
") return ;;
	esac
	seen="${seen}
$dir"
	m="$1/.restore-manifest.tsv"
	[ -f "$m" ] && awk -F'\t' -v d="$1" 'NF>=3{printf "%s\t%s\t%s\t%s\n", $3, d, $1, $2}' "$m"
}
{
	emit "$home/.Trash"
	emit "/System/Volumes/Data/.Trashes/$uid"
	while IFS= read -r line; do
		case "$line" in
		*" on "*" ("*)
			mountpoint=${line#* on }
			mountpoint=${mountpoint% (*}
			emit "$mountpoint/.Trashes/$uid"
			;;
		esac
	done <<__TRASH_RESTORE_MOUNT_OUTPUT__
$(mount 2>/dev/null)
__TRASH_RESTORE_MOUNT_OUTPUT__
} | sort -k1,1nr | head -n 100
]]

local function notify(message, level)
	ya.notify({
		title = "Trash",
		content = message,
		level = level or "info",
		timeout = 3.0,
	})
end

-- `cx` is only readable from inside a ya.sync closure, not from the async
-- `entry` context directly (see sudo.yazi's get_state for the same pattern).
-- Resolve icons here too: `File` values only live in the synchronized context.
local selected_or_hovered = ya.sync(function()
	local targets, items = {}, {}

	local function add(file)
		local path = tostring(file.url)
		local icon = th.icon:match(file, { hovered = false })
		targets[#targets + 1] = path
		items[#items + 1] = {
			path = path,
			icon = icon and icon.text or nil,
		}
	end

	if #cx.active.selected ~= 0 then
		for _, file in pairs(cx.active.selected) do
			add(file)
		end
	else
		local hovered = cx.active.current.hovered
		if hovered then
			add(hovered)
		end
	end

	return targets, items
end)

-- Runs the whole batch in a single `sh` subprocess: script as $0's `-c`
-- body, then targets passed as positional args ("$@") so no path ever
-- gets interpolated into the script string -- no quoting to get wrong.
local function run(script, targets)
	local args = { "-c", script, "sh" }
	for _, t in ipairs(targets) do
		args[#args + 1] = t
	end

	return Command("sh"):arg(args):stdout(Command.PIPED):stderr(Command.PIPED):output()
end

-- Returns nil on a genuine scan failure (spawn/exit-code) vs an empty table
-- for a legitimately empty trash, so the caller can report each accurately.
local function gather_recent_items()
	local output = run(LIST_SCRIPT, {})
	if not output or not output.status or not output.status.success then
		return nil
	end

	local items = {}
	for line in output.stdout:gmatch("[^\r\n]+") do
		local epoch, dir, name, orig = line:match("^(%-?%d+)\t([^\t]*)\t([^\t]*)\t(.*)$")
		if epoch and name and name ~= "" and orig and orig ~= "" then
			items[#items + 1] = {
				epoch = tonumber(epoch),
				trashed_path = dir .. "/" .. name,
				orig = orig,
				exists = fs.cha(Url(orig), true) ~= nil,
			}
		end
	end

	return items
end

-- ── Picker (ported from restore.yazi's Modal, trimmed to what this plugin
--    needs -- no theme/position config, since it isn't exposed here) ──────

local PICKER_KEYS = {
	{ on = "q", run = "quit", desc = "Quit" },
	{ on = "<Esc>", run = "quit", desc = "Quit" },
	{ on = "<Enter>", run = "restore", desc = "Restore" },
	{ on = { "<Space>", " " }, run = "toggle", desc = "Select" },
	{ on = "j", run = "down", desc = "Down" },
	{ on = "k", run = "up", desc = "Up" },
	{ on = "<Down>", run = "down", desc = "Down" },
	{ on = "<Up>", run = "up", desc = "Up" },
}

local picker_open = ya.sync(function(state, items)
	state.picker_items = items
	state.picker_cursor = 1
	state.picker_offset = 0
	state.picker_selected = {}
	if not state.picker_children then
		state.picker_children = Modal:children_add(state, 10)
	end
	ui.render()
end)

local picker_close = ya.sync(function(state)
	if state.picker_children then
		Modal:children_remove(state.picker_children)
		state.picker_children = nil
	end
	state.picker_items = nil
	state.picker_cursor = nil
	state.picker_offset = nil
	state.picker_selected = nil
	state.picker_body_area = nil
	ui.render()
end)

local picker_move = ya.sync(function(state, delta)
	local items = state.picker_items or {}
	if #items == 0 then
		return
	end

	local cursor = math.max(1, math.min((state.picker_cursor or 1) + delta, #items))
	local visible = state.picker_body_area and math.max(1, state.picker_body_area.h) or 1
	local offset = state.picker_offset or 0

	if cursor <= offset then
		offset = cursor - 1
	elseif cursor > offset + visible then
		offset = cursor - visible
	end

	state.picker_cursor = cursor
	state.picker_offset = math.max(0, offset)
	ui.render()
end)

local picker_toggle = ya.sync(function(state)
	local items = state.picker_items or {}
	if #items == 0 then
		return
	end

	local idx = state.picker_cursor or 1
	state.picker_selected[idx] = not state.picker_selected[idx]
	ui.render()
end)

local picker_result = ya.sync(function(state)
	local items = state.picker_items or {}
	local selected = state.picker_selected or {}
	local result = {}

	for i = 1, #items do
		if selected[i] then
			result[#result + 1] = items[i]
		end
	end

	-- Nothing explicitly selected -- restore whatever's under the cursor.
	if #result == 0 and #items > 0 then
		result[1] = items[state.picker_cursor or 1]
	end

	return result
end)

local function pick_items(items)
	picker_open(items)
	while true do
		local idx = ya.which({ cands = PICKER_KEYS, silent = true })
		local run_key = idx and PICKER_KEYS[idx] and PICKER_KEYS[idx].run

		if run_key == "down" then
			picker_move(1)
		elseif run_key == "up" then
			picker_move(-1)
		elseif run_key == "toggle" then
			picker_toggle()
		elseif run_key == "restore" then
			local result = picker_result()
			picker_close()
			return result
		else
			picker_close()
			return nil
		end
	end
end

local function confirm_items(items)
	local lines = {}
	for _, item in ipairs(items) do
		lines[#lines + 1] = ui.Line((item.icon and item.icon .. " " or "") .. item.path)
	end

	return ya.confirm({
		pos = { "center", w = 70, h = 20 },
		title = ui.Line(string.format("Trash %d selected file%s?", #items, #items == 1 and "" or "s")),
		body = ui.Text(lines):wrap(ui.Wrap.YES),
	})
end

function M:new(area)
	self:layout(area)
	return self
end

function M:layout(area)
	local rows = ui.Layout()
		:direction(ui.Layout.VERTICAL)
		:constraints({
			ui.Constraint.Percentage(8),
			ui.Constraint.Percentage(84),
			ui.Constraint.Percentage(8),
		})
		:split(area)

	local cols = ui.Layout()
		:direction(ui.Layout.HORIZONTAL)
		:constraints({
			ui.Constraint.Percentage(5),
			ui.Constraint.Percentage(90),
			ui.Constraint.Percentage(5),
		})
		:split(rows[2])

	self.picker_area = cols[2]
end

function M:reflow()
	return { self }
end

function M:redraw()
	local area = self.picker_area
	local inner = area:pad(ui.Pad(1, 2, 1, 2))
	local chunks = ui.Layout()
		:direction(ui.Layout.VERTICAL)
		:constraints({ ui.Constraint.Length(2), ui.Constraint.Fill(1), ui.Constraint.Length(1) })
		:split(inner)

	self.picker_body_area = chunks[2]

	local items = self.picker_items or {}
	local selected = self.picker_selected or {}
	local cursor = self.picker_cursor or 1
	local offset = self.picker_offset or 0
	local selected_count = 0
	for _, picked in pairs(selected) do
		if picked then
			selected_count = selected_count + 1
		end
	end

	local body = {}
	local visible = math.max(1, chunks[2].h)
	local last = math.min(#items, offset + visible)
	for row = offset + 1, last do
		local item = items[row]
		local mark = selected[row] and "[x]" or "[ ]"
		local cursor_mark = row == cursor and ">" or " "
		local collision = item.exists and "!" or " "
		local line = string.format(
			"%s %s %s  %s  %s",
			cursor_mark,
			mark,
			collision,
			os.date("%Y-%m-%d %H:%M:%S", item.epoch),
			item.orig
		)
		local rendered = ui.Line(ui.truncate(line, { max = chunks[2].w }))
		if row == cursor then
			rendered = rendered:fg("blue"):underline()
		end
		body[#body + 1] = rendered
	end
	if #body == 0 then
		body[1] = ui.Line("Nothing to restore")
	end

	local header = ui.Text({
		ui.Line("Recently trashed, newest first"),
		ui.Line("Space select  Enter restore  q/Esc quit  ! exists at original path"),
	}):area(chunks[1])
	local footer = string.format("%d selected, %d total", selected_count, #items)

	return {
		ui.Clear(area),
		ui.Border(ui.Edge.ALL)
			:area(area)
			:type(ui.Border.ROUNDED)
			:style(ui.Style():fg("blue"))
			:title(ui.Line("Restore"):align(ui.Align.CENTER)),
		header,
		ui.Text(body):area(chunks[2]):wrap(ui.Wrap.NO),
		ui.Line(ui.truncate(footer, { max = chunks[3].w })):area(chunks[3]):dim(),
	}
end

function M:click() end
function M:scroll() end
function M:touch() end

-- ── Actions ─────────────────────────────────────────────────────────────

local function restore_picker()
	local items = gather_recent_items()
	if not items then
		notify("Failed to scan trash", "error")
		return
	end
	if #items == 0 then
		notify("Nothing to restore", "info")
		return
	end

	local chosen = pick_items(items)
	if not chosen or #chosen == 0 then
		return
	end

	local paths = {}
	for _, item in ipairs(chosen) do
		paths[#paths + 1] = item.trashed_path
	end

	local output = run(RESTORE_SCRIPT, paths)
	if not output or not output.status or not output.status.success then
		notify("Failed to restore: " .. tostring(output and output.stderr or "could not start shell"), "error")
		return
	end

	local restored = tonumber(output.stdout:match("RESTORED=(%d+)")) or 0
	local skipped = tonumber(output.stdout:match("SKIPPED=(%d+)")) or 0

	if restored == 0 then
		notify("Nothing restored", "warn")
	elseif skipped > 0 then
		notify(string.format("Restored %d item(s), %d skipped", restored, skipped), "warn")
	else
		notify(string.format("Restored %d item(s)", restored), "info")
	end
end

local function trash_selected()
	local targets, items = selected_or_hovered()
	if #targets == 0 then
		notify("Nothing selected or hovered", "warn")
		return
	end

	-- Match native remove: leave visual mode before opening the confirmation.
	ya.emit("escape", { visual = true })
	local confirmed = confirm_items(items)
	if not confirmed then
		return
	end

	local output = run(TRASH_SCRIPT, targets)
	if not output or not output.status or not output.status.success then
		notify("Failed to trash: " .. tostring(output and output.stderr or "could not start shell"), "error")
		return
	end

	local trashed = tonumber(output.stdout:match("TRASHED=(%d+)")) or 0
	local skipped = tonumber(output.stdout:match("SKIPPED=(%d+)")) or 0

	if trashed == 0 then
		notify("Nothing trashed", "warn")
	elseif skipped > 0 then
		notify(string.format("Trashed %d item(s), %d skipped", trashed, skipped), "warn")
	else
		notify(string.format("Trashed %d item(s)", trashed), "info")
	end
end

function M:entry(job)
	if ya.target_os() ~= "macos" then
		notify("This plugin only supports macOS", "error")
		return
	end

	local ok = xpcall(function()
		if job.args[1] == "restore" then
			restore_picker()
		else
			trash_selected()
		end
	end, function() return "" end)
	if not ok then
		notify("Plugin failed", "error")
	end
end

return M
