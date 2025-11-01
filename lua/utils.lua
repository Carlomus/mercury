local U = {}

function U.new_ID()
	local id = tostring(1e12 * math.random())
	return id:sub(1, 12)
end

function U.getline(buf, row)
	return vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
end

function U.is_py_cell_start(line)
	line = line or ""
	if line:match("^%s*#%s*%%%%%s*$") then
		return true
	end
	if line:match("^%s*#%s*%%%%%s*%b[]%s*$") then
		return true
	end
	return false
end

function U.py_cell_type(line)
	local tag = line:match("%[([^%]]+)%]")
	if tag and tag:lower():find("markdown") then
		return "markdown"
	end
	return "python"
end

function U.parse_header(line)
	if not U.is_py_cell_start(line) then
		return nil
	end
	return U.py_cell_type(line)
end

function U.clean_line(s)
	s = U.strip_ansi(s or "")
	s = s:gsub("\r", "")
	return s
end

function U.split_lines(s)
	s = s or ""
	if s == "" then
		return {}
	end
	local t = {}
	for line in (s .. "\n"):gmatch("([^\n]*)\n") do
		if line ~= "" then
			t[#t + 1] = line
		end
	end
	return t
end

-- Basic HTML → text for terminals
function U.html_to_text(html)
	html = html or ""
	html = html:gsub("<[bB][rR]%s*/?>", "\n")
	html = html:gsub("</p>", "\n")
	html = html:gsub("<[^>]+>", "")
	html = html:gsub("&nbsp;", " ")
	html = html:gsub("&lt;", "<")
	html = html:gsub("&gt;", ">")
	html = html:gsub("&amp;", "&")
	return html
end

return U
