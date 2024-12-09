local M = {}

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


function M.parse_snippet_body(kind, completion_item)
	local snip_body
	if
		kind:match("Snippet")
		or completion_item.insertTextFormat == vim.lsp.protocol.InsertTextFormat.Snippet
	then
		local new_text = vim.tbl_get(completion_item, "textEdit", "newText")
		local insert_text = completion_item.insertText
		snip_body = (new_text and new_text:find("%$") and new_text)
		or (insert_text and insert_text:find("%$") and insert_text)
	end
	return snip_body
end

function M.debounce(timer, timeout, callback)
	return function(...)
		local argv = { ... }
		timer:start(timeout, 0, function()
			timer:stop()
			vim.schedule_wrap(callback)(unpack(argv))
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

function M.make_position_params()
	if vim.fn.has "nvim-0.11" == 1 then
		return function(client, _)
			return vim.lsp.util.make_position_params(0, client.offset_encoding)
		end
	end
	return vim.lsp.util.make_position_params()
end

return M
