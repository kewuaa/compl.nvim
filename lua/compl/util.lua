local M = {}
-- cache kind_map because vim.lsp.CompletionItemKind may be changed(such as MiniIcons.tweak_lsp_kind)
local kind_map = {}
for k, v in pairs(vim.lsp.protocol.CompletionItemKind) do
    if type(k) == 'string' and type(v) == 'number' then kind_map[v] = k end
end

function M.get_kind(kind)
	return kind_map[kind] or "Unknown"
end

function M.get_hl(kind)
	---@diagnostic disable-next-line: undefined-field
	if not _G.MiniIcons then
		return
	end
	local _, hl, is_default = _G.MiniIcons.get('lsp', M.get_kind(kind))
	return not is_default and hl or nil
end

-- https://github.com/nvim-lua/plenary.nvim/blob/master/lua/plenary/path.lua#L21
M.sep = (function()
	if jit then
		local os = string.lower(jit.os)
		if os ~= "windows" then
			return "/"
		else
			return "\\"
		end
	else
		return package.config:sub(1, 1)
	end
end)()

function M.debounce(timer, timeout, callback)
	return function(...)
		local argv = { ... }
		timer:start(timeout, 0, function()
			timer:stop()
            callback(unpack(argv))
		end)
	end
end

-- https://github.com/nvim-lua/plenary.nvim/blob/master/lua/plenary/path.lua#L755
function M.async_read(file, callback)
	vim.uv.fs_open(file, "r", 438, function(err_open, fd)
		assert(not err_open, err_open)
		vim.uv.fs_fstat(fd, function(err_fstat, stat)
			assert(not err_fstat, err_fstat)
			if stat.type ~= "file" then
				return callback ""
			end
			vim.uv.fs_read(fd, stat.size, 0, function(err_read, data)
				assert(not err_read, err_read)
				vim.uv.fs_close(fd, function(err_close)
					assert(not err_close, err_close)
					return callback(data)
				end)
			end)
		end)
	end)
end

function M.async_read_json(file, callback)
	M.async_read(file, function(buffer)
		local success, data = pcall(vim.json.decode, buffer)
		if not success or not data then
			vim.schedule(function()
				vim.notify(string.format("compl.nvim: Could not decode json file %s", file), vim.log.levels.ERROR)
			end)
			return
		end
		callback(data)
	end)
end

M.make_position_params =
	vim.fn.has("nvim-0.11") == 1
	and function()
		return function(client, _)
			return vim.lsp.util.make_position_params(0, client.offset_encoding)
		end
	end
	or vim.lsp.util.make_position_params

return M
