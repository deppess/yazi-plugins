--- @since 26.5.6
-- Recursive folder search scoped to a media library root. Runs fd itself
-- (-t d, folders only) either against a manual, disk-persisted index
-- (see `b i`) or -- before the first-ever index build -- a live walk, and
-- shows a read-only panel of the top-N ranked candidates as you type,
-- refreshed on every settled (debounced) keystroke via native
-- ya.input(realtime=true). Enter jumps straight to the top-ranked match:
-- native cd for a folder, no custom picker.

local M = {}

local STATE = {
	ROOT = "root",
	INITIALIZED = "initialized",
	INDEX = "index",
}

-- Keep the index with the library so it follows the library when moved.
local INDEX_FILENAME = ".media-search-index"

local set_state = ya.sync(function(state, key, val) state[key] = val end)
local get_state = ya.sync(function(state, key) return state and state[key] end)

local function notify(content, level)
	ya.notify({ title = "Media Search", content = content, level = level or "info", timeout = 4 })
end

local function expand_path(path)
	if path:sub(1, 1) == "~" then
		return os.getenv("HOME") .. path:sub(2)
	end
	return path
end

---@param opts? {root?: string}
function M:setup(opts)
	if opts and type(opts) ~= "table" then
		return
	end
	local root = (opts and opts.root) or "~/Media"
	set_state(STATE.ROOT, expand_path(root))
	set_state(STATE.INITIALIZED, true)
end

-- ── fd ────────────────────────────────────────────────────────────────────
-- Folders only (-t d). Symlinked directories are intentionally excluded.

local function fd_matches(root, query)
	local out, err = Command("fd")
		:arg({
			"--base-directory",
			root,
			"--fixed-strings",
			"-t",
			"d",
			rt.mgr.show_hidden and "--hidden" or "--no-hidden",
			"--",
			query,
		})
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

	local matches = {}
	for line in out.stdout:gmatch("[^\r\n]+") do
		matches[#matches + 1] = line:gsub("/+$", "")
	end
	return matches
end

-- ── Index (manual, -- see `b i`) ─────────────────────────────────────────
-- Flat, newline-delimited relative paths -- the same shape fd_matches
-- already returns -- so a cached list plugs straight into rank_matches
-- with no format translation. No JSON/serialization: this is just a plain
-- list of short strings, even tens of thousands of them cost a few hundred
-- KB uncompressed, not worth the code to compress.

local function index_url(root)
	return root .. "/" .. INDEX_FILENAME
end

local function load_index_from_disk(root)
	local f = io.open(index_url(root), "r")
	if not f then
		return nil
	end
	local list = {}
	for line in f:lines() do
		if line ~= "" then
			list[#list + 1] = line
		end
	end
	f:close()
	return #list > 0 and list or nil
end

local function save_index_to_disk(root, list)
	local ok, err = fs.write(Url(index_url(root)), table.concat(list, "\n"))
	return ok, err and tostring(err)
end

-- Load once per session so the input loop does not repeatedly read disk.
local function load_index(root)
	local index = get_state(STATE.INDEX)
	if index then
		return index
	end
	index = load_index_from_disk(root)
	if index then
		set_state(STATE.INDEX, index)
	end
	return index
end

-- Counts added/removed paths between two index snapshots via two hash
-- sets (O(old+new), same cost class as the filter itself -- negligible
-- even at tens of thousands of entries). Only ever called once per manual
-- `b i` press, never on the per-keystroke hot path.
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

-- Rebuilds the index from a live fd walk (fd_matches with an empty
-- pattern lists everything -- verified against the real binary), updates
-- the in-memory copy unconditionally, and persists it to disk best-effort:
-- if the write fails (read-only mount, permissions), the session still
-- gets the speed benefit, it just won't survive a restart. added/removed
-- are nil on the first-ever build (nothing to diff against yet).
local function reindex(root)
	local previous = load_index(root)

	local matches, err = fd_matches(root, "")
	if not matches then
		return nil, err
	end
	set_state(STATE.INDEX, matches)
	local ok, werr = save_index_to_disk(root, matches)

	local added, removed
	if previous then
		added, removed = diff_counts(previous, matches)
	end
	return matches, (not ok) and werr or nil, added, removed
end

-- Lowercased once per session alongside the index, not once per keystroke.
-- Case-insensitive filtering (the common case -- no uppercase in query) is
-- by far the more frequent path across a session's worth of keystrokes as
-- a query gets refined, so re-lowering all N entries on every single
-- filter call would repeat identical work many times over.
local function lower_index(index)
	local lower = {}
	for i = 1, #index do
		lower[i] = index[i]:lower()
	end
	return lower
end

local function filter_index(index, index_lower, query)
	local matches = {}
	if query:find("%u") then
		for i = 1, #index do
			if index[i]:find(query, 1, true) then
				matches[#matches + 1] = index[i]
			end
		end
	else
		local needle = query:lower()
		for i = 1, #index do
			if index_lower[i]:find(needle, 1, true) then
				matches[#matches + 1] = index[i]
			end
		end
	end
	return matches
end

-- Matches from the (already-loaded-this-session) index when one exists,
-- falling back to a live fd_matches call otherwise -- so search always
-- works even before the first-ever `b i`, just slower until then.
local function get_matches(root, query, index, index_lower)
	if index then
		return filter_index(index, index_lower, query)
	end
	return fd_matches(root, query)
end

local function split_segments(rel)
	local segs = {}
	for seg in rel:gmatch("[^/]+") do
		segs[#segs + 1] = seg
	end
	return segs
end

-- ── Native-order tiebreak (identical to media-search.yazi) ──────────────

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

-- Extension and size do not provide meaningful ordering for directories.
local function compare_names(cfg, name_a, name_b, path_a, path_b, stat)
	if cfg.by == "none" or cfg.by == "random" then
		return 0
	end

	local ord = 0
	if cfg.by == "mtime" or cfg.by == "btime" then
		local ca, cb = stat(path_a), stat(path_b)
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

	return cfg.reverse and -ord or ord
end

local function compare_paths(cfg, root, entry_a, entry_b, stat)
	local segs_a, segs_b = entry_a.segs, entry_b.segs
	for i = 1, #segs_a do
		if segs_a[i] ~= segs_b[i] then
			local path_a = root .. "/" .. table.concat(segs_a, "/", 1, i)
			local path_b = root .. "/" .. table.concat(segs_b, "/", 1, i)
			return compare_names(cfg, segs_a[i], segs_b[i], path_a, path_b, stat)
		end
	end
	return 0
end

local function make_stat_cache()
	local cache = {}
	return function(path)
		local v = cache[path]
		if v == nil then
			v = fs.cha(Url(path), false) or false
			cache[path] = v
		end
		if v == false then
			return nil
		end
		return v
	end
end

local function smart_case_eq(name, query, query_lower, query_has_upper)
	if query_has_upper then
		return name == query
	end
	return name:lower() == query_lower
end

-- The preview and Enter use the same ranking, keeping the first result stable.

local function entry_less(cfg, root, stat, a, b)
	local da, db = #a.segs, #b.segs
	if da ~= db then
		return da < db
	end
	return compare_paths(cfg, root, a, b, stat) < 0
end

local function rank_matches(root, matches, query, limit)
	local query_has_upper = query:find("%u") ~= nil
	local query_lower = not query_has_upper and query:lower() or nil

	local n = #matches
	local entries = {}
	local has_exact = false
	for i = 1, n do
		local rel = matches[i]
		local segs = split_segments(rel)
		local exact = smart_case_eq(segs[#segs], query, query_lower, query_has_upper)
		entries[i] = { rel = rel, segs = segs, exact = exact }
		has_exact = has_exact or exact
	end

	local cfg = {
		by = rt.mgr.sort_by,
		sensitive = rt.mgr.sort_sensitive,
		reverse = rt.mgr.sort_reverse,
		fallback = rt.mgr.sort_fallback,
	}
	local stat = make_stat_cache()

	-- Avoid table.sort because filesystem metadata lookup may yield.
	local top = {}
	for i = 1, n do
		local e = entries[i]
		if not has_exact or e.exact then
			local pos = #top + 1
			for j = #top, 1, -1 do
				if entry_less(cfg, root, stat, e, top[j]) then
					pos = j
				else
					break
				end
			end
			if pos <= limit then
				table.insert(top, pos, e)
				if #top > limit then
					table.remove(top)
				end
			end
		end
	end

	local result = {}
	for i = 1, #top do
		result[i] = top[i].rel
	end
	return result
end

-- ── Live panel (Modal child) ─────────────────────────────────────────────
-- M also acts as the Modal component for the live result panel.

local PANEL_LIMIT = 5
local PANEL_W = 60
local PANEL_TOP = 6 -- fixed row offset below the input's own pos (y=2)

local panel_open = ya.sync(function(state)
	state.panel_lines = {}
	if not state.panel_children then
		state.panel_children = Modal:children_add(state, 10)
	end
	ui.render()
end)

local panel_set = ya.sync(function(state, lines)
	state.panel_lines = lines
	ui.render()
end)

local panel_close = ya.sync(function(state)
	if state.panel_children then
		Modal:children_remove(state.panel_children)
		state.panel_children = nil
	end
	state.panel_lines = nil
	ui.render()
end)

function M:new(area)
	self:layout(area)
	return self
end

function M:layout(area)
	local rows = ui.Layout()
		:direction(ui.Layout.VERTICAL)
		:constraints({
			ui.Constraint.Length(PANEL_TOP),
			ui.Constraint.Length(PANEL_LIMIT + 2),
			ui.Constraint.Fill(1),
		})
		:split(area)

	local cols = ui.Layout()
		:direction(ui.Layout.HORIZONTAL)
		:constraints({
			ui.Constraint.Fill(1),
			ui.Constraint.Length(PANEL_W),
			ui.Constraint.Fill(1),
		})
		:split(rows[2])

	self.panel_area = cols[2]
end

function M:reflow()
	return { self }
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
	local basename = segs[#segs]

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

	local inner_w = math.max(1, area.w - 4)
	local body = {}
	for i = 1, #lines do
		body[#body + 1] = ui.Line(truncate_path(lines[i], inner_w))
	end
	if #body == 0 then
		body[1] = ui.Line("(no matches)"):dim()
	end

	return {
		ui.Clear(area),
		ui.Border(ui.Edge.ALL)
			:area(area)
			:type(ui.Border.ROUNDED)
			:style(ui.Style():fg("blue")),
		ui.Text(body):area(area:pad(ui.Pad(1, 2, 1, 2))):wrap(ui.Wrap.NO),
	}
end

-- ── Entry ─────────────────────────────────────────────────────────────────

local MIN_QUERY_LEN = 2
local DEBOUNCE_INDEXED = 0.1 -- real work is ~ms with an index, can be snappy
local DEBOUNCE_LIVE = 0.25 -- conservative: each trigger may spawn fd (~100s of ms)

local function is_blank(value)
	return not value or value:match("^%s*$") ~= nil
end

function M:entry(job)
	if not get_state(STATE.INITIALIZED) then
		M:setup()
	end
	local root = get_state(STATE.ROOT)

	local cha = fs.cha(Url(root), false)
	if not cha or not cha.is_dir then
		notify("Media root not found: " .. root, "error")
		return
	end

	if job and job.args and job.args[1] == "reindex" then
		local matches, err, added, removed = reindex(root)
		if not matches then
			notify("Reindex failed: " .. tostring(err), "error")
			return
		end

		-- One notification either way -- added/removed are nil on the very
		-- first build (nothing to diff against), so that case just shows
		-- the total, exactly as before.
		local summary = string.format("Indexed %d folders", #matches)
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

	-- The index and its lowercase form remain stable for one input session.
	local index = load_index(root)
	local index_lower = index and lower_index(index)

	panel_open()

	local rx = ya.input({
		title = "Search Media",
		value = "",
		pos = { "top-center", y = 2, w = PANEL_W },
		realtime = true,
		debounce = index and DEBOUNCE_INDEXED or DEBOUNCE_LIVE,
	})

	-- Debounce settles well before a human can react and hit Enter, so the
	-- submitted query is almost always identical to the last live-previewed
	-- one -- caching that last successful (query, matches) pair here skips
	-- a redundant fd spawn (or, now, a redundant index filter pass) on
	-- submit in the common case. Only ever reused on an exact query match;
	-- any mismatch or prior failure falls back to a fresh call, so this
	-- can't serve stale data.
	local last_query, last_matches

	while true do
		local value, event = rx:recv()

		if event == 3 then
			-- Changed values are already debounced by the native input stream.
			if is_blank(value) or #value < MIN_QUERY_LEN then
				panel_set({})
			else
				local matches = get_matches(root, value, index, index_lower)
				last_query, last_matches = matches and value or nil, matches
				if not matches or #matches == 0 then
					panel_set({})
				else
					panel_set(rank_matches(root, matches, value, PANEL_LIMIT))
				end
			end
		elseif event == 1 then
			-- Submit the highest-ranked match.
			panel_close()
			if not is_blank(value) then
				local matches, err
				if value == last_query then
					matches = last_matches
				else
					matches, err = get_matches(root, value, index, index_lower)
				end
				if not matches then
					notify(err or "Failed to start fd", "error")
				elseif #matches == 0 then
					notify('No matches for "' .. value .. '"', "warn")
				else
					local winner = rank_matches(root, matches, value, 1)[1]
					local target = root .. "/" .. winner
					local target_cha = fs.cha(Url(target), false)
					if target_cha and target_cha.is_dir then
						ya.emit("cd", { target })
					else
						ya.emit("reveal", { target })
					end
				end
			end
			break
		else
			-- Cancel / escape / unknown error.
			panel_close()
			break
		end
	end
end

return M
