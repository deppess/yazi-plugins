--- @since 26.5.6
-- Recursive folder search scoped to a media library root. Searches a manual,
-- disk-persisted index (see `b i`) or -- before the first-ever index build --
-- a single fd walk taken when the search opens (folders only), and shows the
-- ranked candidates in a panel joined to the native ya.input(realtime=true)
-- box, refreshed on every settled (debounced) keystroke. Enter, a
-- double-click, or Tab then j/k picks a result: native cd, no custom picker.

local M = {}

local STATE = {
	ROOT = "root",
	ERROR = "error",
	INITIALIZED = "initialized",
	INDEX = "index",
}

-- Keep the index with the library so it follows the library when moved.
local INDEX_FILENAME = ".media-search-index"
-- Tens of thousands of folders are a few hundred KB; anything near this
-- is not an index this plugin wrote.
local INDEX_MAX_BYTES = 64 * 1024 * 1024

local byte, find, sub = string.byte, string.find, string.sub

local set_state = ya.sync(function(state, key, val)
	state[key] = val
end)
local get_state = ya.sync(function(state, key)
	return state and state[key]
end)

local function notify(content, level)
	ya.notify({ title = "Media Search", content = content, level = level or "info", timeout = 4 })
end

local function normalize_root(path)
	if type(path) ~= "string" or path == "" then
		return nil, "root must be a path string"
	end
	if path == "~" or path:sub(1, 2) == "~/" then
		local home = os.getenv("HOME")
		if not home or home == "" then
			return nil, "HOME is not set, cannot expand " .. path
		end
		path = home .. path:sub(2)
	end
	if path:sub(1, 1) ~= "/" then
		return nil, "root must be absolute or start with ~/: " .. path
	end
	path = path:gsub("/+$", "")
	return path ~= "" and path or "/"
end

local function join(root, rel)
	return root == "/" and "/" .. rel or root .. "/" .. rel
end

---@param opts? {root?: string}
function M:setup(opts)
	local root, err = "~/Media", nil
	if opts ~= nil and type(opts) ~= "table" then
		err = "setup() expects a table"
	elseif opts and opts.root ~= nil then
		root = opts.root
	end
	if not err then
		root, err = normalize_root(root)
	end
	set_state(STATE.ROOT, root)
	set_state(STATE.ERROR, err and ("Invalid config: " .. err))
	set_state(STATE.INITIALIZED, true)
end

-- ── Paths ─────────────────────────────────────────────────────────────────

local function split(s, sep, out)
	local pos, len = 1, #s
	while pos <= len do
		local stop = find(s, sep, pos, true) or len + 1
		if stop > pos then
			out[#out + 1] = sub(s, pos, stop - 1)
		end
		pos = stop + 1
	end
	return out
end

-- Relative, with no empty, "." or ".." segments: anything else would let a
-- tampered index steer cd outside the root.
local function valid_rel(rel)
	return rel ~= "" and byte(rel, 1) ~= 47 and not find("/" .. rel .. "/", "/%.?%.?/")
end

-- ── fd ────────────────────────────────────────────────────────────────────
-- Every folder under root, hidden ones included (search filters them per
-- show_hidden, so index and live results agree), NUL-separated so any legal
-- name survives. -t d does not match symlinks, so symlinked directories are
-- intentionally excluded. Sorted, so rebuilds of an unchanged library write
-- an identical index.

local function fd_walk(root)
	local out, err = Command("fd")
		:arg({ "--base-directory", root, "--type", "d", "--hidden", "--print0", "--strip-cwd-prefix" })
		:stdout(Command.PIPED)
		:stderr(Command.PIPED)
		:output()

	if not out then
		return nil, "Failed to start fd: " .. tostring(err)
	end
	if not out.status.success then
		local msg = out.stderr:gsub("%s+$", "")
		return nil, msg ~= "" and msg or "fd exited with an error"
	end

	local list = {}
	for _, rel in ipairs(split(out.stdout, "\0", {})) do
		rel = rel:gsub("/+$", "")
		if valid_rel(rel) then
			list[#list + 1] = rel
		end
	end
	table.sort(list)
	return list
end

-- ── Index (manual, -- see `b i`) ─────────────────────────────────────────
-- NUL-terminated relative paths, the same list fd_walk returns. Indexes
-- from older versions were newline-separated and still load.

local function index_path(root)
	return join(root, INDEX_FILENAME)
end

local function load_index_from_disk(root)
	local path = index_path(root)
	local cha = fs.cha(Url(path), false)
	if not cha then
		return nil
	end
	if cha.is_link or cha.is_dir or cha.is_block or cha.is_char or cha.is_fifo or cha.is_sock then
		return nil, "Index is not a regular file, ignoring it"
	end
	if (cha.len or 0) > INDEX_MAX_BYTES then
		return nil, "Index is too large, ignoring it"
	end

	local f = io.open(path, "rb")
	if not f then
		return nil, "Cannot read index"
	end
	local data = f:read("a") or ""
	f:close()

	local sep = find(data, "\0", 1, true) and "\0" or "\n"
	local list = {}
	for _, rel in ipairs(split(data, sep, {})) do
		if valid_rel(rel) then
			list[#list + 1] = rel
		end
	end
	return #list > 0 and list or nil
end

-- Written to a fresh temp file and renamed over the index, so a crash can't
-- leave it half-written and a symlink planted at the index path gets
-- replaced instead of written through.
local function save_index_to_disk(root, list)
	local path = index_path(root)
	local tmp, err = fs.unique("file", Url(path .. ".tmp"))
	if not tmp then
		return false, tostring(err)
	end

	local ok
	ok, err = fs.write(tmp, #list > 0 and table.concat(list, "\0") .. "\0" or "")
	if ok then
		ok, err = fs.rename(tmp, Url(path))
	end
	if not ok then
		fs.remove("file", tmp)
		return false, tostring(err)
	end
	return true
end

-- Load once per session so the input loop does not repeatedly read disk.
local function load_index(root)
	local index = get_state(STATE.INDEX)
	if index then
		return index
	end
	local err
	index, err = load_index_from_disk(root)
	if index then
		set_state(STATE.INDEX, index)
	end
	return index, err
end

-- Counts added/removed paths between two index snapshots via two hash
-- sets (O(old+new)). Only ever called once per manual `b i` press.
local function diff_counts(old, new)
	local old_set, new_set = {}, {}
	for i = 1, #old do
		old_set[old[i]] = true
	end
	for i = 1, #new do
		new_set[new[i]] = true
	end

	local added, removed = 0, 0
	for i = 1, #new do
		if not old_set[new[i]] then
			added = added + 1
		end
	end
	for i = 1, #old do
		if not new_set[old[i]] then
			removed = removed + 1
		end
	end
	return added, removed
end

-- Rebuilds the index from a live fd walk, updates the in-memory copy
-- unconditionally, and persists it to disk best-effort: if the write fails
-- (read-only mount, permissions), the session still gets the speed
-- benefit, it just won't survive a restart. added/removed are nil on the
-- first-ever build (nothing to diff against yet).
local function reindex(root)
	local previous = load_index(root)

	local list, err = fd_walk(root)
	if not list then
		return nil, err
	end
	set_state(STATE.INDEX, list)
	local ok, werr = save_index_to_disk(root, list)

	local added, removed
	if previous then
		added, removed = diff_counts(previous, list)
	end
	return list, (not ok) and werr or nil, added, removed
end

-- ── Search session ────────────────────────────────────────────────────────
-- Basenames, their lowercase form, depth and hidden-ness are derived once
-- when the search opens, so each keystroke is one pass of plain finds.

local function build_session(list)
	local base, lower, depth, hidden = {}, {}, {}, {}
	for i = 1, #list do
		local rel = list[i]
		local d, last, pos = 1, 0, 1
		while true do
			local s = find(rel, "/", pos, true)
			if not s then
				break
			end
			d, last, pos = d + 1, s, s + 1
		end
		local name = last > 0 and sub(rel, last + 1) or rel
		base[i], lower[i], depth[i] = name, name:lower(), d
		hidden[i] = byte(rel, 1) == 46 or find(rel, "/.", 1, true) ~= nil
	end
	return { rel = list, base = base, lower = lower, depth = depth, hidden = hidden }
end

-- Matches the folder name only, smart-case, like fd's own default. Exact
-- name matches are kept apart so they rank ahead of substring matches.
local function filter(session, query, show_hidden)
	local sensitive = query:find("%u") ~= nil
	local names = sensitive and session.base or session.lower
	local needle = sensitive and query or query:lower()
	local hidden = session.hidden

	local exact, partial = {}, {}
	for i = 1, #names do
		if show_hidden or not hidden[i] then
			local name = names[i]
			if name == needle then
				exact[#exact + 1] = i
			elseif find(name, needle, 1, true) then
				partial[#partial + 1] = i
			end
		end
	end
	return exact, partial
end

-- ── Native-order tiebreak (mirrors yazi's own natural sort) ─────────────

local function is_digit(s, i)
	local c = s:byte(i)
	return c ~= nil and c >= 48 and c <= 57
end

local function is_ascii_space(s, i)
	local c = s:byte(i)
	return c == 32 or c == 9 or c == 10 or c == 12 or c == 13
end

local function natsort_compare_left(a, b, li, ri)
	while true do
		local da, db = is_digit(a, li), is_digit(b, ri)
		if da and db then
			local ca, cb = a:byte(li), b:byte(ri)
			if ca ~= cb then
				return ca < cb and -1 or 1
			end
		elseif da then
			return 1
		elseif db then
			return -1
		else
			return 0
		end
		li, ri = li + 1, ri + 1
	end
end

local function natsort_compare_right(a, b, li, ri)
	local bias = 0
	while true do
		local da, db = is_digit(a, li), is_digit(b, ri)
		if da and db then
			if bias == 0 then
				local ca, cb = a:byte(li), b:byte(ri)
				if ca ~= cb then
					bias = ca < cb and -1 or 1
				end
			end
		elseif da then
			return 1
		elseif db then
			return -1
		else
			return bias
		end
		li, ri = li + 1, ri + 1
	end
end

local function natsort(a, b, insensitive)
	local li, ri = 1, 1
	while true do
		while is_ascii_space(a, li) do
			li = li + 1
		end
		while is_ascii_space(b, ri) do
			ri = ri + 1
		end

		local ca, cb = a:byte(li), b:byte(ri)
		if ca and cb then
			local da, db = is_digit(a, li), is_digit(b, ri)
			if da and db then
				local ord = (ca == 48 or cb == 48) and natsort_compare_left(a, b, li, ri)
					or natsort_compare_right(a, b, li, ri)
				if ord ~= 0 then
					return ord
				end
				while a:byte(li) and is_digit(a, li) do
					li = li + 1
				end
				while b:byte(ri) and is_digit(b, ri) do
					ri = ri + 1
				end
			else
				local xa, xb = ca, cb
				if insensitive then
					if xa >= 65 and xa <= 90 then
						xa = xa + 32
					end
					if xb >= 65 and xb <= 90 then
						xb = xb + 32
					end
				end
				if xa ~= xb then
					return xa < xb and -1 or 1
				end
				li, ri = li + 1, ri + 1
			end
		elseif ca then
			return 1
		elseif cb then
			return -1
		else
			return 0
		end
	end
end

local function alpha_cmp(cfg, a, b)
	if not cfg.sensitive then
		a, b = a:lower(), b:lower()
	end
	if a == b then
		return 0
	end
	return a < b and -1 or 1
end

local function natural_cmp(cfg, a, b)
	return natsort(a, b, not cfg.sensitive)
end

-- Byte range of the first segment where two same-depth paths differ, found
-- in place so ranking never splits paths into tables.
local function diverge(a, b)
	local n = #a < #b and #a or #b
	local i, start = 1, 1
	while i <= n do
		local c = byte(a, i)
		if c ~= byte(b, i) then
			break
		end
		if c == 47 then
			start = i + 1
		end
		i = i + 1
	end
	local stop_a = (find(a, "/", start, true) or #a + 1) - 1
	local stop_b = (find(b, "/", start, true) or #b + 1) - 1
	return start, stop_a, stop_b
end

-- Compares at the first diverging segment, the way the two folders would
-- sort side by side in yazi. Extension and size do not provide meaningful
-- ordering for directories; "none" and "random" use the fallback so the
-- winner is the same on every run.
local function compare_rel(ctx, a, b)
	local cfg = ctx.cfg
	local start, stop_a, stop_b = diverge(a, b)
	local name_a, name_b = sub(a, start, stop_a), sub(b, start, stop_b)

	local ord = 0
	if cfg.by == "mtime" or cfg.by == "btime" then
		local ca, cb = ctx.stat(join(ctx.root, sub(a, 1, stop_a))), ctx.stat(join(ctx.root, sub(b, 1, stop_b)))
		local va, vb = (ca and ca[cfg.by]) or 0, (cb and cb[cfg.by]) or 0
		ord = (va == vb) and 0 or (va < vb and -1 or 1)
	elseif cfg.by == "alphabetical" then
		ord = alpha_cmp(cfg, name_a, name_b)
	elseif cfg.by == "natural" then
		ord = natural_cmp(cfg, name_a, name_b)
	end

	if ord == 0 then
		ord = (cfg.fallback == "natural") and natural_cmp(cfg, name_a, name_b) or alpha_cmp(cfg, name_a, name_b)
	end
	if ord == 0 and name_a ~= name_b then
		ord = name_a < name_b and -1 or 1
	end

	return cfg.reverse and -ord or ord
end

-- Cached for the whole search: mtimes don't move while you type.
local function make_stat_cache()
	local cache = {}
	return function(path)
		local v = cache[path]
		if v == nil then
			v = fs.cha(Url(path), false) or false
			cache[path] = v
		end
		return v or nil
	end
end

local function new_rank_ctx(root)
	return {
		root = root,
		stat = make_stat_cache(),
		cfg = {
			by = rt.mgr.sort_by,
			sensitive = rt.mgr.sort_sensitive,
			reverse = rt.mgr.sort_reverse,
			fallback = rt.mgr.sort_fallback,
		},
	}
end

-- Keeps the k smallest ids by insertion; one comparison rejects anything
-- that can't make the cut. Avoids table.sort because the filesystem
-- metadata lookup may yield.
local function top_k(ids, k, less)
	local top = {}
	for n = 1, #ids do
		local id = ids[n]
		local pos = #top + 1
		while pos > 1 and less(id, top[pos - 1]) do
			pos = pos - 1
		end
		if pos <= k then
			table.insert(top, pos, id)
			if #top > k then
				top[#top] = nil
			end
		end
	end
	return top
end

-- Exact name matches first, then shallowest first, then yazi's sort order.
-- Groups are bucketed by depth so only the buckets that can still fill the
-- limit are ever compared (or stat'ed).
local function rank(session, ctx, groups, limit)
	local rel, depth = session.rel, session.depth
	local function less(i, j)
		return compare_rel(ctx, rel[i], rel[j]) < 0
	end

	local out = {}
	for g = 1, #groups do
		if #out >= limit then
			break
		end
		local ids, buckets, depths = groups[g], {}, {}
		for n = 1, #ids do
			local d = depth[ids[n]]
			local bucket = buckets[d]
			if not bucket then
				bucket = {}
				buckets[d] = bucket
				depths[#depths + 1] = d
			end
			bucket[#bucket + 1] = ids[n]
		end
		table.sort(depths)
		for n = 1, #depths do
			local need = limit - #out
			if need <= 0 then
				break
			end
			local top = top_k(buckets[depths[n]], need, less)
			for k = 1, #top do
				out[#out + 1] = top[k]
			end
		end
	end

	local result = {}
	for i = 1, #out do
		result[i] = rel[out[i]]
	end
	return result
end

-- ── Live panel (Modal child) ─────────────────────────────────────────────
-- M also acts as the Modal component for the live result panel. It holds
-- up to RESULT_LIMIT ranked results behind a PANEL_ROWS-tall viewport with
-- one selected row, driven by the mouse (scroll, click, double-click) and,
-- once Tab hands it focus, by the keyboard.

local INPUT_Y, INPUT_H = 2, 3 -- ya.input is always 3 rows tall
local PANEL_W = 60
local PANEL_ROWS = 8
local RESULT_LIMIT = 50
local DOUBLE_CLICK = 0.4 -- max seconds between the clicks of a double-click

-- Keeps the selection in range and the viewport scrolled to it.
local function clamp_view(state)
	local n = #(state.panel_lines or {})
	local sel = math.max(1, math.min(state.panel_sel or 1, n))
	local top = math.max(1, math.min(state.panel_top or 1, sel))
	if sel >= top + PANEL_ROWS then
		top = sel - PANEL_ROWS + 1
	end
	state.panel_sel, state.panel_top = sel, top
end

-- Root forwards clicks and scrolls only while the mgr layer is active, so
-- they never reach the panel while the input or the results key loop has
-- focus. Claim just the events that land inside the open panel; everything
-- else goes to the original handlers untouched.
local function hook_mouse(state)
	if state.mouse_hooked then
		return
	end
	state.mouse_hooked = true

	local click, scroll = Root.click, Root.scroll
	local function hit(event)
		local area = state.panel_children and state.panel_area
		return area and area:contains(ui.Rect({ x = event.x, y = event.y }))
	end
	function Root:click(event, up)
		if hit(event) then
			Root._dragging = nil
			return M.click(state, event, up)
		end
		return click(self, event, up)
	end
	function Root:scroll(event, step)
		if hit(event) then
			return M.scroll(state, event, step)
		end
		return scroll(self, event, step)
	end
end

local panel_open = ya.sync(function(state, hint)
	hook_mouse(state)
	state.panel_lines, state.panel_hint = {}, hint
	state.panel_sel, state.panel_top, state.panel_focus = 1, 1, false
	state.panel_picked, state.panel_click, state.focus_wanted = nil, nil, nil
	if not state.panel_children then
		state.panel_children = Modal:children_add(state, 10)
	end
	ui.render()
end)

local panel_set = ya.sync(function(state, lines, hint)
	state.panel_lines, state.panel_hint = lines, hint
	state.panel_sel, state.panel_top = 1, 1
	ui.render()
end)

local panel_move = ya.sync(function(state, step)
	state.panel_sel = (state.panel_sel or 1) + step
	clamp_view(state)
	ui.render()
end)

local panel_focus = ya.sync(function(state, focused)
	state.panel_focus = focused
	ui.render()
end)

-- The double-clicked row (consumed) and the selected row, if any.
local panel_take = ya.sync(function(state)
	local picked = state.panel_picked
	state.panel_picked = nil
	return picked, state.panel_lines and state.panel_lines[state.panel_sel or 1]
end)

-- Tab in the input runs `-- focus`; honored only while this plugin's own
-- search input is open, so Tab in any other input stays a no-op.
local request_focus = ya.sync(function(state)
	if state.panel_children and not state.panel_focus and not state.focus_wanted then
		state.focus_wanted = true
		return true
	end
	return false
end)

local take_focus = ya.sync(function(state)
	local wanted = state.focus_wanted
	state.focus_wanted = nil
	return wanted
end)

local panel_close = ya.sync(function(state)
	if state.panel_children then
		Modal:children_remove(state.panel_children)
		state.panel_children = nil
	end
	state.panel_lines, state.panel_hint, state.panel_focus = nil, nil, nil
	state.panel_picked, state.panel_click, state.focus_wanted = nil, nil, nil
	ui.render()
end)

function M:new(area)
	self:layout(area)
	return self
end

-- Directly under the input, column for column: this mirrors the top-center
-- math yazi uses to place the input itself, which ratatui's Fill split can
-- miss by one on odd widths.
function M:layout(area)
	local max_x = math.max(0, area.w - PANEL_W)
	local x = math.min(math.max(0, area.w // 2 - PANEL_W // 2), max_x)
	local y = INPUT_Y + INPUT_H
	local rect = ui.Rect({
		x = area.x + x,
		y = area.y + y,
		w = math.min(PANEL_W, area.w - x),
		h = math.max(0, math.min(PANEL_ROWS + 1, area.h - y)),
	})
	-- _area is what Root's hit-testing (ya.child_at) reads on every click.
	self.panel_area, self._area = rect, rect
end

function M:reflow()
	return { self }
end

function M:scroll(_, step)
	self.panel_sel = (self.panel_sel or 1) + step
	clamp_view(self)
	ui.render()
end

-- One click selects a row; a second on the same row within DOUBLE_CLICK
-- opens it, ending whichever loop has focus the way Enter would.
function M:click(event, up)
	if up or not event.is_left then
		return
	end
	local offset = event.y - self.panel_area.y
	local i = (self.panel_top or 1) + offset
	local lines = self.panel_lines or {}
	if offset < 0 or offset >= PANEL_ROWS or not lines[i] then
		return
	end

	local now, last = ya.time() or 0, self.panel_click
	self.panel_sel = i
	clamp_view(self)
	if last and last.i == i and now - last.t <= DOUBLE_CLICK then
		self.panel_click, self.panel_picked = nil, lines[i]
		if tostring(cx.layer) == "which" then
			ya.emit("which:dismiss", {})
		else
			ya.emit("input:close", { submit = true })
		end
	else
		self.panel_click = { i = i, t = now }
	end
	ui.render()
end

local function split_segments(rel)
	local segs = {}
	for seg in rel:gmatch("[^/]+") do
		segs[#segs + 1] = seg
	end
	return segs
end

-- First Unicode codepoint of s, as a string -- not just the first byte,
-- which would corrupt multi-byte UTF-8 sequences for non-ASCII names.
local function first_char(s)
	local b1 = s:byte(1)
	if not b1 then
		return ""
	end
	local len = 1
	if b1 >= 240 then
		len = 4
	elseif b1 >= 224 then
		len = 3
	elseif b1 >= 192 then
		len = 2
	end
	return s:sub(1, len)
end

-- Shell-prompt-style path abbreviation (starship/fish-like): every
-- ancestor segment collapses to its first character, the deepest folder
-- (basename) always stays spelled out in full -- e.g.
-- "Projects/-Dots/config/fish/themes" -> "P/-/c/f/themes". Applied
-- unconditionally, same as a shell prompt does, not just when the full
-- path wouldn't otherwise fit. If the abbreviated form still doesn't fit
-- max_w (many ancestor levels, or a very long basename), the already-tiny
-- ancestor prefix shrinks further (rtl, so its tail survives) before the
-- basename is ever touched, and the basename itself is the last resort.
local function truncate_path(rel, max_w)
	local segs = split_segments(rel)
	local basename = segs[#segs] or rel

	local abbrev = basename
	if #segs > 1 then
		local parts = {}
		for i = 1, #segs - 1 do
			parts[i] = first_char(segs[i])
		end
		abbrev = table.concat(parts, "/") .. "/" .. basename
	end

	if ui.width(abbrev) <= max_w then
		return abbrev
	end

	local basename_w = ui.width(basename)
	if basename_w >= max_w then
		-- Basename alone doesn't fit -- the one unavoidable edge case.
		return ui.truncate(basename, { max = max_w, rtl = true })
	end

	local dir_budget = max_w - basename_w - 1 -- -1 for the "/" separator
	if dir_budget <= 0 then
		return basename
	end
	local prefix = abbrev:sub(1, #abbrev - #basename - 1)
	return ui.truncate(prefix, { max = dir_budget, rtl = true }) .. "/" .. basename
end

function M:redraw()
	local area = self.panel_area
	local lines = self.panel_lines or {}
	local sel, top = self.panel_sel or 1, self.panel_top or 1

	-- The selected row is what Enter opens: bold while typing, reversed
	-- once the results have focus.
	local inner_w = math.max(1, area.w - 2)
	local body = {}
	for i = top, math.min(#lines, top + PANEL_ROWS - 1) do
		local line = ui.Line(truncate_path(lines[i], inner_w))
		if i == sel then
			line = self.panel_focus and line:reverse() or line:bold()
		end
		body[#body + 1] = line
	end
	if #body == 0 then
		body[1] = ui.Line(self.panel_hint or "(no matches)"):dim()
	end

	-- No top edge: the input's bottom border closes the box from above, and
	-- the rows line up with the input's own text column.
	local border = ui.Border(ui.Edge.LEFT | ui.Edge.RIGHT | ui.Edge.BOTTOM)
		:area(area)
		:type(ui.Border.ROUNDED)
		:style(th.input.border)
	if #lines > 0 then
		border = border:title(ui.Line(string.format(" %d/%d ", sel, #lines)):align(ui.Align.RIGHT), ui.Edge.BOTTOM)
	end

	return {
		ui.Clear(area),
		border,
		ui.Text(body):area(area:pad(ui.Pad(0, 1, 1, 1))):wrap(ui.Wrap.NO),
	}
end

-- ── Entry ─────────────────────────────────────────────────────────────────

local MIN_QUERY_LEN = 2
local DEBOUNCE = 0.1 -- every keystroke is an in-memory filter, never a walk
local HINT_TYPE = "Type at least " .. MIN_QUERY_LEN .. " characters"

local function is_blank(value)
	return not value or value:match("^%s*$") ~= nil
end

-- Keys while the results have focus; ya.which returns nil for any other
-- key, which is simply ignored.
local RESULT_KEYS = {
	{ on = "j", act = "down" },
	{ on = "<Down>", act = "down" },
	{ on = "k", act = "up" },
	{ on = "<Up>", act = "up" },
	{ on = "g", act = "first" },
	{ on = "G", act = "last" },
	{ on = "<Enter>", act = "open" },
	{ on = "<Tab>", act = "edit" },
	{ on = "<Esc>", act = "cancel" },
	{ on = "q", act = "cancel" },
	{ on = "<C-c>", act = "cancel" },
}

local function open_input(value)
	return ya.input({
		title = "Search Media",
		value = value,
		pos = { "top-center", y = INPUT_Y, w = PANEL_W },
		realtime = true,
		debounce = DEBOUNCE,
	})
end

-- Returns the folder to cd into, or nil plus an optional message and level.
-- Alternates between two focus modes: the native input (typing; Tab ends
-- it through the `focus` entry) and a silent ya.which loop over the
-- results (j/k; Tab reopens the input with the same query).
local function run_search(root)
	local list, load_err = load_index(root)
	if load_err then
		notify(load_err .. " -- scanning live instead", "warn")
	end

	panel_open(list and HINT_TYPE or "Scanning library…")

	local rx = open_input("")

	-- Without an index, walk once while the user starts typing; keystrokes
	-- queue up meanwhile and are then served from memory like the index.
	local walk_err
	if not list then
		list, walk_err = fd_walk(root)
		if walk_err then
			notify("Scan failed: " .. walk_err, "error")
		end
		panel_set({}, walk_err and "Scan failed" or HINT_TYPE)
	end

	local session = list and build_session(list)
	local ctx = new_rank_ctx(root)
	local show_hidden = rt.mgr.show_hidden

	-- The submitted query is almost always the last previewed one, so
	-- Enter reuses that ranking instead of filtering again.
	local last_query, last_top
	local function ranked(query)
		if query ~= last_query then
			local exact, partial = filter(session, query, show_hidden)
			last_query, last_top = query, rank(session, ctx, { exact, partial }, RESULT_LIMIT)
		end
		return last_top
	end

	-- The query the panel currently shows results for.
	local query = ""
	local function show(value)
		query = value or ""
		if not session then
			panel_set({}, "Scan failed")
		elseif is_blank(query) or #query < MIN_QUERY_LEN then
			panel_set({}, HINT_TYPE)
		else
			panel_set(ranked(query))
		end
	end

	-- A row the user picked must exist; the implicit top pick instead falls
	-- through stale index entries rather than reveal a ghost.
	local function open(rel, fallbacks)
		local candidates = fallbacks or { rel }
		for i = 1, #candidates do
			local target = join(root, candidates[i])
			local cha = fs.cha(Url(target), false)
			if cha and cha.is_dir then
				return target
			end
		end
		return nil, "That folder no longer exists -- rebuild the index", "warn"
	end

	while true do
		if rx then
			local value, event = rx:recv()

			if event == 3 then
				-- Changed values are already debounced by the native input stream.
				show(value)
			elseif event == 1 then
				local picked, selected = panel_take()
				if picked then
					return open(picked)
				end
				if is_blank(value) or not session then
					return nil
				end
				-- Enter can beat the debounce, so rank what was submitted.
				local top = ranked(value)
				if #top == 0 then
					return nil, 'No matches for "' .. value .. '"', "warn"
				end
				if value ~= query or not selected then
					selected = top[1]
				end
				return open(selected, selected == top[1] and top or nil)
			elseif event == 2 and take_focus() then
				rx = nil
				if value ~= query then
					show(value)
				end
				panel_focus(true)
			else
				-- Cancel / escape / unknown error.
				return nil
			end
		else
			local idx = ya.which({ cands = RESULT_KEYS, silent = true })
			local act = idx and RESULT_KEYS[idx].act
			local picked, selected = panel_take()

			if picked then
				return open(picked)
			elseif act == "down" then
				panel_move(1)
			elseif act == "up" then
				panel_move(-1)
			elseif act == "first" then
				panel_move(-RESULT_LIMIT)
			elseif act == "last" then
				panel_move(RESULT_LIMIT)
			elseif act == "open" and selected then
				return open(selected)
			elseif act == "edit" then
				take_focus()
				panel_focus(false)
				rx = open_input(query)
			elseif act == "cancel" then
				return nil
			end
		end
	end
end

function M:entry(job)
	-- Tab inside the search input (see README): hand focus to the results.
	if job and job.args and job.args[1] == "focus" then
		if request_focus() then
			ya.emit("input:close", {})
		end
		return
	end

	if not get_state(STATE.INITIALIZED) then
		M:setup()
	end
	local config_err = get_state(STATE.ERROR)
	if config_err then
		notify(config_err, "error")
		return
	end
	local root = get_state(STATE.ROOT)

	-- Follow links here: a root that is itself a symlink to the library is fine.
	local cha = fs.cha(Url(root), true)
	if not cha or not cha.is_dir then
		notify("Media root not found: " .. root, "error")
		return
	end

	if job and job.args and job.args[1] == "reindex" then
		local list, err, added, removed = reindex(root)
		if not list then
			notify("Reindex failed: " .. tostring(err), "error")
			return
		end

		local summary = string.format("Indexed %d folders", #list)
		if added or removed then
			summary = summary .. string.format(" (+%d, -%d)", added or 0, removed or 0)
		end
		if err then
			notify(summary .. " -- session only, failed to persist: " .. err, "warn")
		else
			notify(summary, "info")
		end
		return
	end

	-- Always tear the panel down, even if the search loop throws.
	local ok, target, msg, level = pcall(run_search, root)
	panel_close()
	if not ok then
		notify("Search failed: " .. tostring(target), "error")
	elseif target then
		ya.emit("cd", { target })
	elseif msg then
		notify(msg, level)
	end
end

return M
