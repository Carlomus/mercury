local U = require("mercury.utils")

local M = {}

-- one-time temp-file tracker and exit cleanup
local TMP_TRACKER = TMP_TRACKER or {}

local function _track_tmp(path)
	if path then
		TMP_TRACKER[path] = true
	end
end

local function _unlink_tmp(path)
	if path then
		pcall(os.remove, path)
		TMP_TRACKER[path] = nil
	end
end

if not _G.__MERCURY_IMG_TMP_CLEANUP__ then
	_G.__MERCURY_IMG_TMP_CLEANUP__ = true
	local aug = vim.api.nvim_create_augroup("MercuryImageTmpCleanup", { clear = true })
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = aug,
		callback = function()
			for path, _ in pairs(TMP_TRACKER) do
				pcall(os.remove, path)
			end
		end,
	})
end

local function mime_text_lines(data)
	if not data then
		return {}
	end
	if data["text/html"] then
		local html = data["text/html"]
		if type(html) == "table" then
			html = table.concat(html, "")
		end
		local txt = U.html_to_text(html or "")
		return U.split_lines(txt)
	elseif data["text/markdown"] then
		local md = data["text/markdown"]
		if type(md) == "table" then
			md = table.concat(md, "")
		end
		return U.split_lines(md or "")
	elseif data["text/plain"] then
		local txt = data["text/plain"]
		if type(txt) == "table" then
			txt = table.concat(txt, "")
		end
		return U.split_lines(tostring(txt or ""))
	end
	return {}
end

local function stream_lines(item)
	local name = item.name or "stdout"
	local prefix = (name == "stderr") and "[stderr] " or ""
	local text = item.text or ""
	if type(text) == "table" then
		text = table.concat(text, "")
	end
	return U.split_lines(prefix .. text)
end

local function save_bytes(path, bytes)
	local f = io.open(path, "wb")
	if not f then
		return false
	end
	f:write(bytes)
	f:close()
	return true
end

local function write_image_tmp_from_data(data)
	if not data then
		return nil
	end
	if data["image/png"] then
		local b64 = data["image/png"]
		local ok, bin = pcall(U.b64decode, b64 or "")
		if ok and bin and #bin > 0 then
			local tmp = vim.fn.tempname() .. ".png"
			if save_bytes(tmp, bin) then
				_track_tmp(tmp)
				return tmp
			end
		end
	elseif data["image/svg+xml"] then
		local svg = data["image/svg+xml"]
		if type(svg) == "table" then
			svg = table.concat(svg, "")
		end
		local tmp = vim.fn.tempname() .. ".svg"
		if save_bytes(tmp, svg or "") then
			_track_tmp(tmp)
			return tmp
		end
	end
	return nil
end

function M.extend(Block)
	if Block.__output_extended then
		return Block
	end
	Block.__output_extended = true

	-- lazy image.nvim
	local Image = nil

	-- wrap constructor to initialize output fields
	local old_new = Block.new
	Block.new = function(buf, start_row, end_row, id, type_, header_text, output_)
		local self = old_new(buf, start_row, end_row, id, type_, header_text)

		-- output state
		self.output = nil
		self.is_collapsed = false
		self.showing_full_output = true
		self._images = {}
		self._image_paths = {}

		if output_ then
			self:insert_output(output_)
		end
		return self
	end

	function Block:_clear_images()
		if self._images then
			for _, img in ipairs(self._images) do
				pcall(function()
					if img and img.clear then
						img:clear()
					end
				end)
			end
		end
		self._images = {}

		if self._image_paths then
			for _, path in ipairs(self._image_paths) do
				_unlink_tmp(path)
			end
		end
		self._image_paths = {}
	end

	-- Turn current self.output.items into flat text lines + image anchors
	function Block:_materialize_output_lines()
		local out = self.output or {}
		local items = out.items or {}
		local lines = {}
		local anchors = {}

		local header = ("Out[%d] (%d ms):"):format(out.exec_count or 0, out.ms or 0)
		lines[#lines + 1] = header

		-- Clear any stale paths
		self._image_paths = {}

		for _, it in ipairs(items) do
			local t = it.type
			if t == "clear_output" then
				lines = { header }
				anchors = {}
			elseif t == "stream" then
				for _, ln in ipairs(stream_lines(it)) do
					lines[#lines + 1] = ln
				end
			elseif t == "error" then
				lines[#lines + 1] = ("Error: %s: %s"):format(it.ename or "", it.evalue or "")
				for _, ln in ipairs(it.traceback or {}) do
					local cleaned = U.clean_line(ln)
					for _, part in ipairs(U.split_lines(cleaned)) do
						lines[#lines + 1] = part
					end
				end
			elseif t == "display_data" or t == "execute_result" then
				for _, ln in ipairs(mime_text_lines(it.data)) do
					lines[#lines + 1] = ln
				end

				local path = write_image_tmp_from_data(it.data)
				if path then
					lines[#lines + 1] = ""
					anchors[#anchors + 1] = {
						line_index = #lines,
						path = path,
					}
					self._image_paths[#self._image_paths + 1] = path
				end
			else
				lines[#lines + 1] = ("[%s output unsupported]"):format(t or "unknown")
			end
		end

		return lines, anchors
	end

	function Block:_render_images_at(out_start, anchors)
		local ok, api = pcall(require, "image")
		if not ok or not api or (api.is_enabled and not api.is_enabled()) then
			return
		end
		Image = Image or api

		local wins = vim.fn.win_findbuf(self.buf)
		local win = wins[1]
		if not win or not vim.api.nvim_win_is_valid(win) then
			return
		end

		local win_w = vim.api.nvim_win_get_width(win)
		self._images = {}

		for _, a in ipairs(anchors or {}) do
			if a.path then
				local row = out_start + (a.line_index - 1)
				local img = Image.from_file(a.path, {
					window = win,
					buffer = self.buf,
					inline = true,
					with_virtual_padding = false,
					x = 0,
					y = row,
					width = math.floor(0.9 * win_w),
				})
				if img and img.render then
					img:render()
					table.insert(self._images, img)
				end
			end
		end
	end

	function Block:_render_output_lines()
		self:_clear_images()

		if not self.output or not self.output.items then
			self:replace_output_lines({})
			if self.sync_decorations then
				self:sync_decorations()
			end
			return
		end

		local all_lines, anchors = self:_materialize_output_lines()
		local lines = all_lines
		local used_anchors = anchors
		local hidden = 0

		local max_preview = self.output.max_preview_lines
		if max_preview and not self.showing_full_output then
			local limit = max_preview + 1
			if #lines > limit then
				hidden = #lines - limit
				lines = {}
				for i = 1, limit do
					lines[i] = all_lines[i]
				end
				used_anchors = {}
				for _, a in ipairs(anchors) do
					if a.line_index <= limit then
						used_anchors[#used_anchors + 1] = a
					end
				end
			end
		end

		if hidden > 0 then
			lines[#lines + 1] = ("... (cont) %d lines hidden"):format(hidden)
		end

		self:replace_output_lines(lines)

		if self.sync_decorations then
			self:sync_decorations()
		end

		if #used_anchors > 0 then
			local out_s, _ = self:output_range()
			self:_render_images_at(out_s, used_anchors)
		end
	end

	function Block:insert_output(output)
		self.output = output
		if output and output.max_preview_lines then
			self.showing_full_output = false
		else
			self.showing_full_output = true
		end
		self.is_collapsed = false
		self:_render_output_lines()
	end

	function Block:truncate_output()
		self.showing_full_output = false
		self.is_collapsed = false
		self:_render_output_lines()
	end

	function Block:show_full_output()
		self.showing_full_output = true
		self.is_collapsed = false
		self:_render_output_lines()
	end

	function Block:toggle_full_output()
		if self.showing_full_output then
			self:truncate_output()
		else
			self:show_full_output()
		end
	end

	function Block:collapse_output()
		if not self.output then
			return
		end
		self.is_collapsed = true
		self:_clear_images()
		self:replace_output_lines({ "Output collapsed..." })
	end

	function Block:expand_output()
		if not self.output then
			return
		end
		self.is_collapsed = false
		self:_render_output_lines()
	end

	function Block:toggle_collapse_output()
		if self.is_collapsed then
			self:expand_output()
		else
			self:collapse_output()
		end
	end

	function Block:set_running()
		self.output = nil
		self.is_collapsed = false
		self.showing_full_output = true
		self:_clear_images()
		self:replace_output_lines({ "Running…" })
	end

	function Block:set_killed()
		self.output = nil
		self.is_collapsed = false
		self.showing_full_output = true
		self:_clear_images()
		self:replace_output_lines({ "󱚢 Killed cell" })
	end

	function Block:clear_output()
		self.output = nil
		self.is_collapsed = false
		self.showing_full_output = true
		self:_clear_images()
		self:replace_output_lines({})
	end

	local old_sync = Block.sync_decorations
	Block.sync_decorations = function(self)
		old_sync(self)
	end

	-- ensure images/temp files are removed on destroy
	local old_destroy = Block.destroy
	Block.destroy = function(self)
		self:_clear_images()
		old_destroy(self)
	end

	return Block
end

return M.extend
