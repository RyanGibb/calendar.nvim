local api = vim.api
local os = require("os")

local function read_file(file_path)
	local content = vim.fn.readfile(file_path)
	if not content then
		print("Could not read file: " .. file_path)
		return nil
	end
	return table.concat(content, "\n")
end

local function all_trim(s)
	return s:match("^%s*(.-)%s*$")
end

local function parse_ical(content, file_path)
	local events = {}
	local event = nil
	for line in content:gmatch("[^\r\n]+") do
		if line:match("^BEGIN:VEVENT") then
			event = { file_path = file_path }
		elseif line:match("^END:VEVENT") then
			if event then
				table.insert(events, event)
			end
			event = nil
		elseif event then
			local key, value = line:match("^([^;:]+).-:(.*)$")
			if key and value then
				event[key] = value
			end
		end
	end
	return events
end

local function parse_datetime(date)
	if not date then
		return nil
	end
	-- TODO timezones
	local t = {}
	t.year, t.month, t.day = date:match("^(%d%d%d%d)(%d%d)(%d%d)")
	t.hour, t.min, t.sec = date:match("T(%d%d)(%d%d)(%d%d)")
	if t.year and t.month and t.day and t.hour and t.min and t.sec then
		return { type = "time", value = os.time(t) }
	end
	if t.year and t.month and t.day then
		t.hour, t.min, t.sec = 0, 0, 0
		return { type = "date", value = os.time(t) }
	end
	return nil, "Invalid date format"
end

local function get_date(datetime)
	local t = os.date("*t", datetime)
	t.hour, t.min, t.sec = 0, 0, 0
	return os.time(t)
end

local function format_date(date)
	local format = "%a %Y-%m-%d"
	return os.date(format, date)
end

local function format_time(time)
	local format = "%I:%M%p"
	return os.date(format, time)
end

local function load_entry(event)
	local entry = {}
	entry.dtstart = parse_datetime(event.DTSTART)
	entry.dtend = parse_datetime(event.DTEND)
	entry.rrule = event.RRULE
	entry.summary = all_trim(event.SUMMARY)
	-- TODO multiline
	entry.file_path = event.file_path
	entry.recurrence_id = parse_datetime(event["RECURRENCE-ID"])
	if not entry.dtstart then
		print("No start date for: " .. event.file_path)
		return nil
	end
	return entry
end

local function load_cal(dir)
	dir = vim.fs.normalize(dir)
	local cal_name = vim.fs.basename(dir)
	local stat = vim.loop.fs_stat(dir)
	if not stat or stat.type ~= 'directory' then
		print("Directory does not exist: " .. dir)
		return nil, {}
	end

	-- events are ical files
	local events = {}
	for filename, type in vim.fs.dir(dir) do
		if type == "file" then
			local file_path = dir .. "/" .. filename
			local content = read_file(file_path)
			if content then
				local file_events = parse_ical(content, file_path)
				for _, event in ipairs(file_events) do
					table.insert(events, event)
				end
			end
		end
	end

	-- entries are our in-memory representation of ical events
	local entries = {}
	for _, event in ipairs(events) do
		local entry = load_entry(event)
		if entry then
			table.insert(entries, entry)
		end
	end
	return cal_name, entries
end

-- TODO make this timezone insensative
local function increment_date(date, interval, unit)
	local t = os.date("*t", date)
	if unit == "DAILY" then
		t.day = t.day + interval
	elseif unit == "WEEKLY" then
		t.day = t.day + interval * 7
	elseif unit == "MONTHLY" then
		t.month = t.month + interval
	elseif unit == "YEARLY" then
		t.year = t.year + interval
	end
	return os.time(t)
end

local function recurring_entries(entry, exceptions, window_start, window_end)
	local rrule = entry.rrule
	if not rrule then
		return { entry }
	end
	local recurrences = {}
	local interval = tonumber(rrule:match("INTERVAL=(%d+)")) or 1
	local freq = rrule:match("FREQ=(%a+)")
	local until_str = rrule:match("UNTIL=(%d+T?%d*)")
	local count = tonumber(rrule:match("COUNT=(%d+)"))
	local until_time = nil
	if until_str then
		until_time = parse_datetime(until_str).value
	end
	local occurrence_datetime = entry.dtstart.value
	local end_time_offset = entry.dtend and entry.dtend.value - entry.dtstart.value or 0
	local max_recurrences = 1000
	local recurrences_count = 0
	while recurrences_count < max_recurrences do
		if (until_time and occurrence_datetime > until_time) or
			(count and recurrences_count >= count) or
			(occurrence_datetime > window_end) then
			break
		end
		if occurrence_datetime >= window_start or (occurrence_datetime + end_time_offset) <= window_end then
			local occurrence = vim.deepcopy(entry)
			occurrence.dtstart.value = occurrence_datetime
			if occurrence.dtend then
				occurrence.dtend.value = occurrence_datetime + end_time_offset
			end
			local is_exception = false
			for _, ex in ipairs(exceptions) do
				if ex.recurrence_id and ex.recurrence_id.value == occurrence_datetime then
					is_exception = true
					table.insert(recurrences, ex)
					break
				end
			end
			if not is_exception then
				table.insert(recurrences, occurrence)
			end
			recurrences_count = recurrences_count + 1
		end
		occurrence_datetime = increment_date(occurrence_datetime, interval, freq)
	end
	return recurrences
end

function _G.calendar_fold_text()
	local start = vim.v.foldstart
	local finish = vim.v.foldend
	local lines = {}
	for lnum = start, finish do
		table.insert(lines, all_trim(vim.fn.getline(lnum)))
	end
	return table.concat(lines, " ")
end

local function generate_day_map(entries, window_start, window_end)
	local entries_with_recurrences = {}
	local exceptions = {}
	for _, entry in ipairs(entries) do
		if entry.recurrence_id then
			table.insert(exceptions, entry)
		end
	end
	for _, entry in ipairs(entries) do
		if not entry.recurrence_id then
			local recurrences = recurring_entries(entry, exceptions, window_start, window_end)
			for _, recurrence in ipairs(recurrences) do
				table.insert(entries_with_recurrences, recurrence)
			end
		end
	end
	table.sort(entries_with_recurrences, function(a, b)
		return a.dtstart.value < b.dtstart.value
	end)
	local days_map = {}
	for _, entry in ipairs(entries_with_recurrences) do
		if entry.dtstart.value > window_end or (entry.dtstart and entry.dtstart.value < window_start) then
			goto continue
		end
		local current_day = get_date(entry.dtstart.value)
		repeat
			if not days_map[current_day] then
				days_map[current_day] = {}
			end
			if current_day >= window_start and current_day <= window_end then
				table.insert(days_map[current_day], entry)
			end
			-- we call get_date here to zero the hours, mins, and seconds,
			-- (e.g. summer time) which might vary due to timezone changes
			current_day = get_date(increment_date(current_day, 1, "DAILY"))
		until
			-- dtend is exclusive
			not entry.dtend or current_day >= entry.dtend.value
		::continue::
	end

	-- Sort the days
	local sorted_days = {}
	for day in pairs(days_map) do
		table.insert(sorted_days, day)
	end
	table.sort(sorted_days)

	local lines = {}
	local today = get_date(os.time())
	local current_line = 0
	local line_to_entry_map = {}

	for _, day in ipairs(sorted_days) do
		if day == today then
			current_line = #lines + 1
		end
		local day_str = format_date(day)
		local first_event = true
		for _, entry in ipairs(days_map[day]) do
			local summary = entry.summary or ""
			local time = ""
			-- the last day the event occurs on is one day (86400 seconds) before the exclusive dtend
			local last_day = entry.dtend and entry.dtend.value - 86400 or entry.dtstart.value
			if entry.dtstart.type == "date" and entry.dtstart.value ~= last_day then
				if day == entry.dtstart.value then
					summary = "|->" .. entry.summary
				elseif day == last_day then
					summary = "<-|" .. entry.summary
				elseif day > entry.dtstart.value and day < last_day then
					summary = "<->" .. entry.summary
				end
			else
				local start_time = format_time(entry.dtstart.value)
				local end_time = entry.dtend and format_time(entry.dtend.value) or ""
				time = string.format("%7s - %7s", start_time, end_time)
			end
			local line
			if first_event then
				line = string.format("%s %17s %s", day_str, time, summary)
				first_event = false
			else
				line = string.format(" %31s %s", time, summary)
			end
			table.insert(lines, line)
			line_to_entry_map[#lines] = entry
		end
	end
	return lines, line_to_entry_map, current_line
end

local function display_cal(cal_name, lines, line_to_entry_map, current_line)
	local bufnr = api.nvim_create_buf(false, true)
	api.nvim_set_option_value('buftype', 'nofile', { buf = bufnr })
	api.nvim_set_option_value('swapfile', false, { buf = bufnr })
	api.nvim_set_option_value('buflisted', true, { buf = bufnr })
	api.nvim_buf_set_name(bufnr, cal_name .. " Calendar")
	api.nvim_command('enew')
	api.nvim_win_set_buf(0, bufnr)
	api.nvim_set_option_value('cursorline', true, { scope = "local" })

	api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

	api.nvim_set_option_value('modifiable', false, { buf = bufnr })
	api.nvim_set_option_value('readonly', true, { buf = bufnr })

	-- Create a mapping to open the corresponding file
	api.nvim_buf_set_var(bufnr, 'entry_to_line_map', line_to_entry_map)
	api.nvim_buf_set_keymap(bufnr, 'n', '<CR>', '<cmd>lua _G.open_event_file()<CR>', { noremap = true, silent = true })

	-- Move the cursor to the first event on or after current date
	if current_line > 0 then
		api.nvim_win_set_cursor(0, { current_line, 0 })
	end

	-- Set up folding
	vim.api.nvim_set_option_value('foldmethod', 'expr', { scope = "local" })
	vim.api.nvim_set_option_value('foldexpr', "indent(v:lnum)==0?'>1':1", { scope = "local" })
	vim.api.nvim_set_option_value('foldtext', 'v:lua._G.calendar_fold_text()', { scope = "local" })
	vim.api.nvim_set_option_value('foldlevelstart', 1, { scope = "local" })
end

function _G.open_event_file()
	local bufnr = api.nvim_get_current_buf()
	local cursor = api.nvim_win_get_cursor(0)
	local line_nr = cursor[1]
	local entry_to_line_map = api.nvim_buf_get_var(bufnr, 'entry_to_line_map')
	local entry = entry_to_line_map[line_nr]
	if entry and entry.file_path then
		vim.cmd('edit ' .. entry.file_path)
	else
		print("No file found for this line")
	end
end

vim.api.nvim_create_user_command(
	'Calendar',
	function(opts)
		local args = vim.split(opts.args, " ")
		local dir = args[1]
		if not dir or dir == "" then
			print("Usage: Calendar <dir> [<start_date>] [<end_date>]")
			return
		end
		local window_start, window_end = os.time({ year = 0, month = 1, day = 1 }),
			increment_date(os.time(), 100, "YEARLY")
		if args[2] then
			window_start = parse_datetime(args[2]).value
		end
		if args[3] then
			window_end = parse_datetime(args[3]).value
		end
		local cal_name, entries = load_cal(dir)
		if cal_name then
			local lines, line_to_entry_map, current_line = generate_day_map(entries, window_start, window_end)
			display_cal(cal_name, lines, line_to_entry_map, current_line)
		end
	end,
	{ nargs = '*' }
)
