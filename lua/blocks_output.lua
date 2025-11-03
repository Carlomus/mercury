local Names = require("mercury.lua.names")
local U = require("mercury.lua.utils")

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

local function output_config(virt_txt)
	return {
		virt_lines = virt_txt,
		virt_lines_above = false,
		hl_mode = "combine",
		right_gravity = false,
	}
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
	Block.new = function(buf, start_row, end_row, id, type_, output_, header_text)
		local self = old_new(buf, start_row, end_row, id, type_, output_, header_text)

		-- output state
		self.output = nil
		self.is_collapsed = false
		self.showing_full_output = true
		self._last_preview_virt = nil
		self._images = {}
		self._image_paths = {}

		if output_ then
			self:insert_output(output_)
		end
		return self
	end

	-- helpers
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

	function Block:_render_images_from_output()
		local ok, api = pcall(require, "image")
		if not ok or not api or (api.is_enabled and not api.is_enabled()) then
			return
		end
		if not self.output or not self.output.items then
			return
		end

		self:_clear_images()
		Image = Image or api

		local win = vim.api.nvim_get_current_win()
		local win_w = vim.api.nvim_win_get_width(win)
		local y = self:_tail_row() + 1

		for _, it in ipairs(self.output.items) do
			if (it.type == "display_data" or it.type == "execute_result") and it.data then
				local has_img = it.data["image/png"] or it.data["image/svg+xml"]
				if has_img then
					local path = write_image_tmp_from_data(it.data)
					if path then
						local img = Image.from_file(path, {
							window = win,
							buffer = self.buf,
							inline = true,
							with_virtual_padding = true,
							x = 0,
							y = y,
							width = math.floor(0.9 * win_w),
						})
						if img and img.render then
							img:render()
							table.insert(self._images, img)
							table.insert(self._image_paths, path)
							y = y + 1
						else
							_unlink_tmp(path)
						end
					end
				end
			end
		end
	end

	function Block:generate_output(output)
		local items = output.items or {}
		local body = {}

		for _, it in ipairs(items) do
			local t = it.type
			if t == "clear_output" then
				body = {}
			elseif t == "stream" then
				for _, ln in ipairs(stream_lines(it)) do
					body[#body + 1] = ln
				end
			elseif t == "error" then
				body[#body + 1] = ("Error: %s: %s"):format(it.ename or "", it.evalue or "")
				for _, ln in ipairs(it.traceback or {}) do
					body[#body + 1] = U.clean_line(ln)
				end
			elseif t == "display_data" or t == "execute_result" then
				for _, ln in ipairs(mime_text_lines(it.data)) do
					body[#body + 1] = ln
				end
			else
				body[#body + 1] = ("[%s output unsupported]"):format(t or "unknown")
			end
		end

		local virt = {}
		virt[#virt + 1] =
			{ { ("Out[%d] (%d ms):"):format(output.exec_count or 0, output.ms or 0), "Comment" } }
		for i = 1, #body do
			virt[#virt + 1] = { { body[i], "Comment" } }
		end

		self.output = output
		self.output.virt_lines = virt
	end

	function Block:attach_output()
		if not self.output then
			return
		end
		if self.is_collapsed then
			self.is_collapsed = false
		end

		local lines_shown = (self.output.max_preview_lines or 9999) + 1 -- header
		local lines = self.output.virt_lines or {}
		self._last_preview_virt = nil

		local n = self.showing_full_output and #lines or math.min(lines_shown, #lines)

		local virt = {}
		for i = 1, n do
			virt[#virt + 1] = lines[i]
		end
		if #lines > n then
			virt[#virt + 1] = { { ("... (cont) %d lines hidden"):format(#lines - n), "Comment" } }
		end
		self._last_preview_virt = virt

		self:_ensure_tail_anchor()
		local cfg = output_config(self._last_preview_virt)
		cfg.id = self.tail_mark
		pcall(vim.api.nvim_buf_set_extmark, self.buf, Names.preview, self:_tail_row(), 0, cfg)

		self:_render_images_from_output()
	end

	function Block:insert_output(output)
		if output.max_preview_lines then
			self.showing_full_output = false
		else
			self.showing_full_output = true
			output.virtual_preview_lines = 9999
		end
		self:generate_output(output)
		self:attach_output()
	end

	function Block:truncate_output()
		self.showing_full_output = false
		self:attach_output()
	end
	function Block:show_full_output()
		self.showing_full_output = true
		self:attach_output()
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
		self:_clear_images()
		self._last_preview_virt = { { { "Output collapsed...", "Comment" } } }
		self:_ensure_tail_anchor()
		local cfg = output_config(self._last_preview_virt)
		cfg.id = self.tail_mark
		pcall(vim.api.nvim_buf_set_extmark, self.buf, Names.preview, self:_tail_row(), 0, cfg)
		self.is_collapsed = true
	end

	function Block:expand_output()
		if not self.output then
			return
		end
		self:attach_output()
		self.is_collapsed = false
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
		self:_clear_images()
		self._last_preview_virt = { { { "Running…", "Comment" } } }
		self:_ensure_tail_anchor()
		local cfg = output_config(self._last_preview_virt)
		cfg.id = self.tail_mark
		pcall(vim.api.nvim_buf_set_extmark, self.buf, Names.preview, self:_tail_row(), 0, cfg)
	end

	function Block:set_killed()
		self.output = nil
		self:_clear_images()
		self._last_preview_virt = { { { "󱚢 Killed cell", "Comment" } } }
		self:_ensure_tail_anchor()
		local cfg = output_config(self._last_preview_virt)
		cfg.id = self.tail_mark
		pcall(vim.api.nvim_buf_set_extmark, self.buf, Names.preview, self:_tail_row(), 0, cfg)
	end

	function Block:clear_output()
		self:_clear_images()
		self._last_preview_virt = nil
		self.output = nil
		if self.tail_mark then
			pcall(vim.api.nvim_buf_set_extmark, self.buf, Names.preview, self:_tail_row(), 0, {
				id = self.tail_mark,
				virt_lines = {},
				virt_lines_above = false,
				hl_mode = "combine",
				right_gravity = false,
			})
		end
	end

	-- augment sync_decorations to also re-apply preview virt lines
	local old_sync = Block.sync_decorations
	Block.sync_decorations = function(self)
		old_sync(self)
		if self._last_preview_virt then
			local cfg = output_config(self._last_preview_virt)
			cfg.id = self.tail_mark
			pcall(vim.api.nvim_buf_set_extmark, self.buf, Names.preview, self:_tail_row(), 0, cfg)
		end
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
