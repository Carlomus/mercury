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

function U.strip_ansi(s)
	s = s or ""

	s = s:gsub("\27%[[0-9;?]*[ -/]*[@-~]", "")
	s = s:gsub("\27%].-\7", "")
	s = s:gsub("\27.", "")

	return s
end

function U.clean_line(s)
	s = U.strip_ansi(s or "")
	s = s:gsub("\r", "")
	return s
end

function U.b64decode(data)
	data = data or ""
	if data == "" then
		return ""
	end

	data = data:gsub("[^A-Za-z0-9%+/%=]", "")

	local b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	local decode_map = {}
	for i = 1, #b64chars do
		decode_map[b64chars:sub(i, i)] = i - 1
	end

	local bytes = {}
	local bitbuf = 0
	local bitlen = 0

	for i = 1, #data do
		local c = data:sub(i, i)
		if c == "=" then
			-- Padding; stop processing
			break
		end
		local val = decode_map[c]
		if val ~= nil then
			bitbuf = bitbuf * 64 + val
			bitlen = bitlen + 6

			while bitlen >= 8 do
				bitlen = bitlen - 8
				local byte = math.floor(bitbuf / (2 ^ bitlen))
				bitbuf = bitbuf % (2 ^ bitlen)
				bytes[#bytes + 1] = string.char(byte)
			end
		end
	end

	return table.concat(bytes)
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
