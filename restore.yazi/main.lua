--- @since 25.5.31

local M = {}
local shell = os.getenv("SHELL") or ""
local PackageName = "Restore"

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

---@class TrashItem
---@field trash_index number
---@field trashed_date_time string
---@field trashed_path string
---@field type File_Type

---@class Theme
---@field title? any
---@field header? any
---@field header_warning? any
---@field list_item? {odd?: any, even?: any}

---@class SetupOptions
---@field position? AsPos
---@field show_confirm? boolean
---@field theme? Theme
---@field suppress_success_notification? boolean

local function success(s, ...)
	ya.notify({ title = PackageName, content = string.format(s, ...), timeout = 5, level = "info" })
end

local function error(s, ...)
	ya.notify({ title = PackageName, content = string.format(s, ...), timeout = 5, level = "error" })
end

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
	POSITION = "position",
	SHOW_CONFIRM = "show_confirm",
	SUPPRESS_SUCCESS_NOTIFICATION = "suppress_success_notification",
	THEME = "theme",
	INITIALIZED = "initialized",
}

---@enum File_Type
local File_Type = {
	File = "file",
	Dir = "dir_all",
	None_Exist = "unknown",
}

--- Get current working directory
---@return string
local get_cwd_raw = ya.sync(function()
	return tostring(cx.active.current.cwd.path or cx.active.current.cwd)
end)

--- Quote path for shell command
---@param path string Absolute path
---@return string
local function path_quote(path)
	local result = "'" .. string.gsub(path, "'", "'\\''") .. "'"
	return result
end

--- Check path is file or directory or none exist.
---@param path string Absolute path
---@return File_Type
local function get_file_type(path)
	local cha, _ = fs.cha(Url(path), true)
	if cha then
		return cha.is_dir and File_Type.Dir or File_Type.File
	end
	return File_Type.None_Exist
end

--- Get trash volume of current working directory.
---@return string|nil
local function get_trash_volume()
	local cwd_raw = get_cwd_raw()
	local trash_volumes_stream, cmr_err =
		Command("trash-list"):arg({ "--volumes" }):stdout(Command.PIPED):stderr(Command.PIPED):output()

	---@type string|nil
	local best_matched_vol_path
	if trash_volumes_stream then
		local previous_matched_vol_length = 0
		for vol in trash_volumes_stream.stdout:gmatch("[^\r\n]+") do
			local vol_length = utf8.len(vol) or 1
			if cwd_raw:sub(1, vol_length) == vol and vol_length > previous_matched_vol_length then
				-- NOTE: Don't break here, because we need to get the best match volume
				best_matched_vol_path = vol
				previous_matched_vol_length = vol_length
			end
		end
		if not best_matched_vol_path then
			error("Can't get trash directory")
		end
	else
		error("Failed to start `trash-list` with error: `%s`. Do you have `trash-cli` installed?", cmr_err)
	end
	return best_matched_vol_path
end

--- Get list of files/folders trashed in reversed order
---@param curr_working_volume string current working volume
local function get_latest_trashed_items(curr_working_volume)
	---@type TrashItem[], TrashItem[]
	local reversed_restorable_items, reversed_existed_items = {}, {}

	-- NOTE: use `tac` to reverse the list. So that we can pop items from the end faster
	local reversed_trashed_list_stream, err_cmd = Command(shell)
		:arg({ "-c", "printf '\n' | trash-restore " .. path_quote(curr_working_volume) .. " | tac" })
		:stdout(Command.PIPED)
		:stderr(Command.PIPED)
		:spawn()

	if reversed_trashed_list_stream then
		local last_item_datetime = nil

		while true do
			local line, event = reversed_trashed_list_stream:read_line()
			if event ~= 0 then
				break
			end
			-- remove leading spaces
			local trash_index, item_date, item_path = line:match("^%s*(%d+) (%S+ %S+) ([^\n]+)")
			if item_date and item_path and trash_index ~= nil then
				if last_item_datetime and last_item_datetime ~= item_date then
					break
				end
				local trash_item_type = get_file_type(item_path)
				local trash_item = {
					trash_index = tonumber(trash_index),
					trashed_date_time = item_date,
					trashed_path = item_path,
					type = trash_item_type,
				}
				table.insert(reversed_restorable_items, trash_item)
				if trash_item_type ~= File_Type.None_Exist then
					table.insert(reversed_existed_items, trash_item)
				end
				last_item_datetime = item_date
			end
		end
		reversed_trashed_list_stream:start_kill()

		if #reversed_restorable_items == 0 then
			success("Nothing left to restore")
			return
		end
	else
		error("Failed to start `trash-restore` with error: `%s`. Do you have `trash-cli` installed?", err_cmd)
		return
	end
	return reversed_restorable_items, reversed_existed_items
end

---@param curr_working_volume string current working volume
---@param limit integer max items to collect
local function get_recent_trashed_items(curr_working_volume, limit)
	local items = {}
	local stream, err_cmd = Command(shell)
		:arg({ "-c", "printf '\n' | trash-restore " .. path_quote(curr_working_volume) .. " | tac" })
		:stdout(Command.PIPED)
		:stderr(Command.PIPED)
		:spawn()

	if not stream then
		error("Failed to start `trash-restore` with error: `%s`. Do you have `trash-cli` installed?", err_cmd)
		return
	end

	while #items < limit do
		local line, event = stream:read_line()
		if event ~= 0 then
			break
		end

		local trash_index, item_date, item_path = line:match("^%s*(%d+) (%S+ %S+) ([^\n]+)")
		if item_date and item_path and trash_index ~= nil then
			items[#items + 1] = {
				trash_index = tonumber(trash_index),
				trashed_date_time = item_date,
				trashed_path = item_path,
				type = get_file_type(item_path),
			}
		end
	end
	stream:start_kill()

	if #items == 0 then
		success("Nothing left to restore")
		return
	end
	return items
end

--- Restore files/folders from trash list based on trash item start and end index
---@param curr_working_volume string current working volume
---@param start_index integer trash item start index
---@param end_index integer trash item end index
local function restore_files(curr_working_volume, start_index, end_index)
	if type(start_index) ~= "number" or type(end_index) ~= "number" or start_index < 0 or end_index < 0 then
		error("Failed to restore file(s): out of range")
		return
	end

	local restored_status, _ = Command(shell)
		:arg({
			"-c",
			"echo " .. ya.quote(start_index .. "-" .. end_index) .. " | trash-restore --overwrite " .. path_quote(
				curr_working_volume
			),
		})
		:stdout(Command.PIPED)
		:stderr(Command.PIPED)
		:output()

	local file_to_restore_count = end_index - start_index + 1
	if restored_status then
		if not get_state(STATE.SUPPRESS_SUCCESS_NOTIFICATION) then
			success(
				"Restored " .. tostring(file_to_restore_count) .. " file" .. (file_to_restore_count > 1 and "s" or "")
			)
		end
	else
		error(
			"Failed to restore "
				.. tostring(file_to_restore_count)
				.. " file"
				.. (file_to_restore_count > 1 and "s" or "")
		)
	end
end

---@param curr_working_volume string current working volume
---@param items TrashItem[] selected trash items
local function restore_selected_files(curr_working_volume, items)
	if not items or #items == 0 then
		return
	end

	table.sort(items, function(a, b)
		return a.trash_index > b.trash_index
	end)

	local failed = {}
	for _, item in ipairs(items) do
		local restored_status, err = Command(shell)
			:arg({
				"-c",
				"echo "
					.. ya.quote(tostring(item.trash_index))
					.. " | trash-restore --overwrite "
					.. path_quote(curr_working_volume),
			})
			:stdout(Command.PIPED)
			:stderr(Command.PIPED)
			:output()

		if not (restored_status and restored_status.status.success) then
			failed[#failed + 1] = restored_status and restored_status.stderr or tostring(err)
		end
	end

	if #failed == 0 then
		if not get_state(STATE.SUPPRESS_SUCCESS_NOTIFICATION) then
			success("Restored " .. tostring(#items) .. " file" .. (#items > 1 and "s" or ""))
		end
		return
	end

	error("Failed to restore %d of %d file(s): %s", #failed, #items, failed[1])
end

--- Convert trash list to UI component list
---@param reversed_trash_list TrashItem[]
---@return ui.List[]
local function get_components(reversed_trash_list)
	---@type Theme
	local theme = get_state(STATE.THEME)
	local item_odd_style = theme.list_item and theme.list_item.odd and ui.Style():fg(theme.list_item.odd)
		or th.confirm.list
	local item_even_style = theme.list_item and theme.list_item.even and ui.Style():fg(theme.list_item.even)
		or th.confirm.list

	local trashed_items_components = {}
	local display_index = 1

	for idx = #reversed_trash_list, 1, -1 do
		local item = reversed_trash_list[idx]
		table.insert(
			trashed_items_components,
			ui.Line({
				ui.Span(" "),
				ui.Span(item.trashed_path):style((display_index % 2 == 1) and item_odd_style or item_even_style),
			}):align(ui.Align.LEFT)
		)
		display_index = display_index + 1
	end
	return trashed_items_components
end

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

	local item_idx = state.picker_cursor or 1
	state.picker_selected[item_idx] = not state.picker_selected[item_idx]
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

	if #result == 0 and #items > 0 then
		result[1] = items[state.picker_cursor or 1]
	end

	return result
end)

local function pick_recent_items(items)
	picker_open(items)
	while true do
		local idx = ya.which({ cands = PICKER_KEYS, silent = true })
		local run = idx and PICKER_KEYS[idx] and PICKER_KEYS[idx].run
		if run == "down" then
			picker_move(1)
		elseif run == "up" then
			picker_move(-1)
		elseif run == "toggle" then
			picker_toggle()
		elseif run == "restore" then
			local result = picker_result()
			picker_close()
			return result
		else
			picker_close()
			return nil
		end
	end
end

local function collided_items(items)
	local collided = {}
	for _, item in ipairs(items or {}) do
		if item.type ~= File_Type.None_Exist then
			collided[#collided + 1] = item
		end
	end
	return collided
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
		local item_idx = row
		local item = items[item_idx]
		local mark = selected[item_idx] and "[x]" or "[ ]"
		local cursor_mark = row == cursor and ">" or " "
		local collision = item.type ~= File_Type.None_Exist and "!" or " "
		local line = string.format(
			"%s %s %s %4d  %s  %s",
			cursor_mark,
			mark,
			collision,
			item.trash_index,
			item.trashed_date_time,
			item.trashed_path
		)
		local rendered = ui.Line(ui.truncate(line, { max = chunks[2].w }))
		if row == cursor then
			rendered:fg("blue"):underline()
		end
		body[#body + 1] = rendered
	end
	if #body == 0 then
		body[1] = ui.Line("No items")
	end

	local header = ui.Text({
		ui.Line("Newest 100 deleted items"),
		ui.Line("Space select  Enter restore  q/Esc quit  ! path exists"),
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

--- Setup plugin, add it to yazi/init.lua file
---@param opts? SetupOptions
function M:setup(opts)
	if opts and type(opts) ~= "table" then
		return
	end
	set_state(
		STATE.POSITION,
		(opts and type(opts.position) == "table") and opts.position or { "center", w = 70, h = 40 }
	)
	set_state(STATE.SHOW_CONFIRM, opts == nil or opts.show_confirm ~= false)
	set_state(STATE.THEME, (opts and type(opts.theme) == "table") and opts.theme or {})
	set_state(STATE.SUPPRESS_SUCCESS_NOTIFICATION, opts and opts.suppress_success_notification)
	set_state(STATE.INITIALIZED, true)
end

function M:entry(job)
	if not get_state(STATE.INITIALIZED) then
		M:setup()
	end
	local curr_working_volume = get_trash_volume()
	if not curr_working_volume then
		return
	end
	local interactive_mode = job.args.interactive
	local interactive_overwrite = job.args.interactive_overwrite

	if interactive_mode == true then
		local recent_trashed_items = get_recent_trashed_items(curr_working_volume, 100)
		if recent_trashed_items == nil then
			return
		end

		local selected_items = pick_recent_items(recent_trashed_items)
		if not selected_items or #selected_items == 0 then
			return
		end

		local selected_collisions = collided_items(selected_items)
		if not interactive_overwrite and #selected_collisions > 0 then
			local theme = get_state(STATE.THEME)
			theme.title = theme.title and ui.Style():fg(theme.title):bold() or th.confirm.title
			theme.header_warning = ui.Style():fg(theme.header_warning or "yellow")
			local confirm_body = ui.Text({
				ui.Line(""),
				ui.Line("Selected path" .. (#selected_collisions > 1 and "s already exist, overwrite?" or " already exists, overwrite?"))
					:style(theme.header_warning),
				ui.Line(""),
				table.unpack(get_components(selected_collisions)),
			})
				:align(ui.Align.LEFT)
				:wrap(ui.Wrap.YES)
			local overwrite_confirmed = ya.confirm({
				title = ui.Line("Restore files/folders"):style(theme.title),
				body = confirm_body,
				content = confirm_body,
				pos = get_state(STATE.POSITION),
			})
			if not overwrite_confirmed then
				return
			end
		end

		restore_selected_files(curr_working_volume, selected_items)
		return
	end

	--NOTE: No need to reverse the list here, waste of time and memory
	local reversed_trashed_items, reversed_collided_items = get_latest_trashed_items(curr_working_volume)
	if reversed_trashed_items == nil then
		return
	end

	local overwrite_confirmed = true
	local show_confirm = get_state(STATE.SHOW_CONFIRM)
	local pos = get_state(STATE.POSITION)

	---@type Theme
	local theme = get_state(STATE.THEME)
	theme.title = theme.title and ui.Style():fg(theme.title):bold() or th.confirm.title
	theme.header = theme.header and ui.Style():fg(theme.header) or th.confirm.content
	theme.header_warning = ui.Style():fg(theme.header_warning or "yellow")
	if show_confirm then
		local continue_restore = ya.confirm({
			title = ui.Line("Restore files/folders"):style(theme.title),
			body = ui.Text({
				ui.Line(""),
				ui.Line(
					#reversed_trashed_items
						.. " file"
						.. (#reversed_trashed_items <= 1 and " " or "s ")
						.. "and folder"
						.. (#reversed_trashed_items <= 1 and " " or "s ")
						.. (#reversed_trashed_items <= 1 and "is " or "are ")
						.. "going to be restored:"
				):style(theme.header),
				ui.Line(""),
				table.unpack(get_components(reversed_trashed_items)),
			})
				:align(ui.Align.LEFT)
				:wrap(ui.Wrap.YES),
			-- TODO: remove this after next yazi released
			content = ui.Text({
				ui.Line(""),
				ui.Line(
					#reversed_trashed_items
						.. " file"
						.. (#reversed_trashed_items <= 1 and " " or "s ")
						.. "and folder"
						.. (#reversed_trashed_items <= 1 and " " or "s ")
						.. (#reversed_trashed_items <= 1 and "is " or "are ")
						.. "going to be restored:"
				):style(theme.header),
				ui.Line(""),
				table.unpack(get_components(reversed_trashed_items)),
			})
				:align(ui.Align.LEFT)
				:wrap(ui.Wrap.YES),
			pos = pos,
		})
		-- stopping
		if not continue_restore then
			return
		end
	end

	-- show Confirm dialog with list of collided items
	if reversed_collided_items and #reversed_collided_items > 0 then
		overwrite_confirmed = ya.confirm({
			title = ui.Line("Restore files/folders"):style(theme.title),
			body = ui.Text({
				ui.Line(""),
				ui.Line(
					#reversed_collided_items
						.. " file"
						.. (#reversed_collided_items <= 1 and " " or "s ")
						.. "and folder"
						.. (#reversed_collided_items <= 1 and " " or "s ")
						.. (#reversed_collided_items <= 1 and "is " or "are ")
						.. "existed, overwrite?"
				):style(theme.header_warning),
				ui.Line(""),
				table.unpack(get_components(reversed_collided_items)),
			})
				:align(ui.Align.LEFT)
				:wrap(ui.Wrap.YES),
			-- TODO: remove this after next yazi released
			content = ui.Text({
				ui.Line(""),
				ui.Line(
					#reversed_collided_items
						.. " file"
						.. (#reversed_collided_items <= 1 and " " or "s ")
						.. "and folder"
						.. (#reversed_collided_items <= 1 and " " or "s ")
						.. (#reversed_collided_items <= 1 and "is " or "are ")
						.. "existed, overwrite?"
				):style(theme.header_warning),
				ui.Line(""),
				table.unpack(get_components(reversed_collided_items)),
			})
				:align(ui.Align.LEFT)
				:wrap(ui.Wrap.YES),
			pos = pos,
		})
	end
	if overwrite_confirmed then
		restore_files(
			curr_working_volume,
			reversed_trashed_items[#reversed_trashed_items].trash_index,
			reversed_trashed_items[1].trash_index
		)
	end
end

return M
