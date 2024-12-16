local util = require "compl.util"
local snippet = require "compl.snip"
local CompletionItemKind = vim.lsp.protocol.CompletionItemKind

local M = {}
_G.Compl = {}

M._opts = {
	completion = {
		timeout = 100,
		fuzzy = {
			enable = false,
			max_item_num = 100
		},
	},
	info = {
		enable = true,
		timeout = 100,
	},
	snippet = {
		enable = false,
		paths = {},
	},
}

M._ctx = {
	cursor = nil,
	pending_requests = {},
	cancel_pending = function()
		for _, cancel_fn in ipairs(M._ctx.pending_requests) do
			pcall(cancel_fn)
		end
		M._ctx.pending_requests = {}
	end,
}

M._completion = {
	timer = vim.uv.new_timer(),
	responses = {},
}

M._info = {
	timer = vim.uv.new_timer(),
	bufnr = 0,
	winids = {},
	close_windows = function()
		for idx, winid in ipairs(M._info.winids) do
			if pcall(vim.api.nvim_win_close, winid, false) then
				M._info.winids[idx] = nil
			end
		end
	end,
}

function M.attach_buffer(bufnr)
	vim.bo[bufnr].completefunc = "v:lua.Compl.completefunc"
end

function M.accept()
    local keys = "<C-y>"
	local complete_info = vim.fn.complete_info()
	if complete_info.pum_visible == 1 then
		local idx = complete_info.selected
		if idx == -1 then
			keys = "<C-n>" .. keys
		end
		vim.schedule(function()
			vim.api.nvim_exec_autocmds(
				"User",
				{
					pattern = "ComplAccepted",
					modeline = false,
				}
			)
		end)
	end
    return keys
end

function M.setup(opts)
	if vim.fn.has "nvim-0.11" ~= 1 then
		vim.notify("compl.nvim: Requires nvim-0.11", vim.log.levels.ERROR)
		return
	end

	-- apply and validate settings
	M._opts = vim.tbl_deep_extend("force", M._opts, opts or {})
	vim.validate {
		["completion"] = { M._opts.completion, "table" },
		["completion.timeout"] = { M._opts.completion.timeout, "number" },
		["completion.fuzzy"] = { M._opts.completion.fuzzy, "table" },
		["completion.fuzzy.enable"] = { M._opts.completion.fuzzy.enable, "boolean" },
		["completion.fuzzy.max_item_num"] = { M._opts.completion.fuzzy.max_item_num, "number" },
		["info"] = { M._opts.info, "table" },
		["info.enable"] = { M._opts.info.enable, "boolean" },
		["info.timeout"] = { M._opts.info.timeout, "number" },
		["snippet"] = { M._opts.snippet, "table" },
		["snippet.enable"] = { M._opts.snippet.enable, "boolean" },
		["snippet.paths"] = { M._opts.snippet.paths, "table" },
	}

	local group = vim.api.nvim_create_augroup("Compl", { clear = true })

	vim.api.nvim_create_autocmd({ "BufEnter" }, {
		group = group,
		callback = function(args)
			M.attach_buffer(args.buf)
		end,
	})

	vim.api.nvim_create_autocmd({ "TextChangedI", "TextChangedP" }, {
		group = group,
		callback = util.debounce(
			M._completion.timer,
			M._opts.completion.timeout,
			vim.schedule_wrap(M._start_completion)
		),
	})

	vim.api.nvim_create_autocmd("User", {
		pattern = "ComplAccepted",
		group = group,
		callback = M._on_completedone,
	})

	vim.api.nvim_create_autocmd({ "InsertLeavePre", "InsertLeave" }, {
		group = group,
		callback = function()
			M._ctx.cancel_pending()

			M._completion.timer:stop()
			M._info.timer:stop()

			M._info.close_windows()
		end,
	})

	if M._opts.info.enable then
		M._info.bufnr = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_name(M._info.bufnr, "Compl:InfoWindow")
		vim.fn.setbufvar(M._info.bufnr, "&buftype", "nofile")

		vim.api.nvim_create_autocmd("CompleteChanged", {
			group = group,
			callback = util.debounce(
				M._info.timer,
				M._opts.info.timeout,
				vim.schedule_wrap(M._start_info)
			),
		})
	end
end

function M._start_completion()
	M._ctx.cancel_pending()

	local bufnr = vim.api.nvim_get_current_buf()
	local winnr = vim.api.nvim_get_current_win()
	local row, col = unpack(vim.api.nvim_win_get_cursor(winnr))
	local line = vim.api.nvim_get_current_line()
	local before_char = line:sub(col, col)

	if
		-- No LSP clients
		not next(vim.lsp.get_clients { bufnr = bufnr, method = "textDocument/completion" })
		-- Not a normal buffer
		or vim.api.nvim_get_option_value("buftype", { buf = bufnr }) ~= ""
		-- Item is selected
		or vim.fn.complete_info()["selected"] ~= -1
		-- Cursor is at the beginning
		or col == 0
		-- Char before cursor is a whitespace
		or (before_char == " " or before_char == "\t")
		-- Context didn't change
		or vim.deep_equal(M._ctx.cursor, { row, col })
	then
		M._ctx.cursor = { row, col }
		-- Do not trigger completion
		return
	end
	M._ctx.cursor = { row, col }

	-- Make a request to get completion items
	local cancel_fn = vim.lsp.buf_request_all(bufnr, "textDocument/completion", util.position_params, function(responses)
		-- Apply itemDefaults to completion item as per the LSP specs:
		--
		-- "In many cases the items of an actual completion result share the same
		-- value for properties like `commitCharacters` or the range of a text
		-- edit. A completion list can therefore define item defaults which will
		-- be used if a completion item itself doesn't specify the value.
		--
		-- If a completion list specifies a default value and a completion item
		-- also specifies a corresponding value the one from the item is used."
		vim.iter(pairs(responses))
			:filter(function(_, response)
				return (not response.err) and response.result and response.result.itemDefaults
			end)
			:each(function(_, response)
				local itemDefaults = response.result.itemDefaults
				local items = response.result.items or response.result or {}
				vim.iter(ipairs(items)):each(function(_, item)
					-- https://github.com/neovim/neovim/blob/master/runtime/lua/vim/lsp/completion.lua#L173
					item.insertTextFormat = item.insertTextFormat or itemDefaults.insertTextFormat
					item.insertTextMode = item.insertTextMode or itemDefaults.insertTextMode
					item.data = item.data or itemDefaults.data
					if itemDefaults.editRange then
						local textEdit = item.textEdit or {}
						item.textEdit = textEdit
						textEdit.newText = textEdit.newText or item.textEditText or item.insertText
						if itemDefaults.editRange.start then
							textEdit.range = textEdit.range or itemDefaults.editRange
						elseif itemDefaults.editRange.insert then
							textEdit.insert = itemDefaults.editRange.insert
							textEdit.replace = itemDefaults.editRange.replace
						end
					end
				end)
			end)
		M._completion.responses = responses

		if vim.fn.mode() == "i" then
			vim.api.nvim_feedkeys(vim.keycode "<C-x><C-u>", "m", false)
		end
	end)
	table.insert(M._ctx.pending_requests, cancel_fn)
end

function _G.Compl.completefunc(findstart, base)
	local line = vim.api.nvim_get_current_line()
	local winnr = vim.api.nvim_get_current_win()
	local _, col = unpack(vim.api.nvim_win_get_cursor(winnr))

	-- Find completion start
	if findstart == 1 then
		-- Example from: https://github.com/neovim/neovim/blob/master/runtime/lua/vim/lsp/completion.lua#L331
		-- Completion response items may be relative to a position different than `client_start_boundary`.
		-- Concrete example, with lua-language-server:
		--
		-- require('plenary.asy|
		--         ▲       ▲   ▲
		--         │       │   └── cursor_pos:                     20
		--         │       └────── client_start_boundary:          17
		--         └────────────── textEdit.range.start.character: 9
		--                                 .newText = 'plenary.async'
		--                  ^^^
		--                  prefix (We'd remove everything not starting with `asy`,
		--                  so we'd eliminate the `plenary.async` result
		--
		-- We prefer to use the language server boundary if available.
		for _, response in pairs(M._completion.responses) do
			if not response.err and response.result then
				local items = response.result.items or response.result or {}
				for _, item in pairs(items) do
					-- Get server start (if completion item has text edits)
					-- https://github.com/echasnovski/mini.completion/blob/main/lua/mini/completion.lua#L1306
					if type(item.textEdit) == "table" then
						local range = type(item.textEdit.range) == "table" and item.textEdit.range
							or item.textEdit.insert
						return range.start.character
					end
				end
			end
		end

		-- Fallback to client start (if completion item does not provide text edits)
		return vim.fn.match(line:sub(1, col), "\\k*$")
	end

	-- NOTE: in c/cpp file, `base` may start with "." when access fields of pointer
	-- delete the extra "." so that items could match `base` correctly
	if base:sub(1, 1) == "." then
		base = base:sub(2)
	end

	-- Process and find completion words
	local matches = {}
	local node = vim.treesitter.get_node()
	local is_comment = node and vim.tbl_contains({
		"comment",
		"line_comment",
		"block_comment",
		"comment_content",
	}, node:type())
	local completion_match = function(client_id, items)
		-- if base empty, accept all items, set match_score ot 0
		if base == "" then
			for _, item in pairs(items) do
				item.match_score = 0
				table.insert(matches, { client_id = client_id, item = item })
			end
			return
		end

		if M._opts.completion.fuzzy then
			---@diagnostic disable-next-line: param-type-mismatch
			local matched_items, _, score = unpack(vim.fn.matchfuzzypos(items, base, {
				limit = M._opts.completion.fuzzy.max_item_num,
				text_cb = function(item)
					return item.filterText or item.label
				end
			}))
			for i, item in pairs(matched_items) do
				item.match_score = score[i]
				table.insert(matches, { client_id = client_id, item = item })
			end
		else
			local matched_items = vim.tbl_filter(
				function(item)
					local text = item.filterText or item.label
					if #text < #base then
						return false
					end
					for i=1,#base do
						if base:sub(i, i+1) ~= text:sub(i, i+1) then
							item.match_score = i - 1
							break
						end
					end
					return item.match_score and item.match_score > 0 or false
				end,
				items
			)
			for _, item in pairs(matched_items) do
				table.insert(matches, { client_id = client_id, item = item })
			end
		end
	end
	for client_id, response in pairs(M._completion.responses) do
		if not response.err and response.result then
			local items = response.result.items or response.result or {}
			if not vim.tbl_isempty(items) then
				completion_match(client_id, items)
			end
		end
	end
	-- if snippet enabled, load snippets
	if not is_comment and M._opts.snippet.enable and M._opts.snippet.paths and base ~= "" then
		local items = snippet.load_vscode_snippet(
			M._opts.snippet.paths,
			vim.bo.filetype
		)
		completion_match(nil, items)
	end

	-- Sorting is done with multiple fallbacks.
	-- If it fails to find diff in each stage, it will then fallback to the next stage.
	-- https://github.com/hrsh7th/nvim-cmp/blob/main/lua/cmp/config/compare.lua
	table.sort(matches, function(matcha, matchb)
		local a, b = matcha.item, matchb.item

		if base:sub(1, 1) ~= "_" then
			local _, under_count_a = (a.filterText or a.label):find("^_+")
			local _, under_count_b = (b.filterText or b.label):find("^_+")
			under_count_a = under_count_a or 0
			under_count_b = under_count_b or 0
			if under_count_a ~= under_count_b then
				return under_count_a < under_count_b
			end
		end

		-- Sort by match score
		if a.match_score ~= b.match_score then
			return a.match_score > b.match_score
		end

		-- Sort by ordinal value of 'kind'.
		-- Exceptions: 'Snippet' are ranked highest, and 'Text' are ranked lowest
		if a.kind ~= b.kind then
			if not a.kind then
				return false
			end
			if not b.kind then
				return true
			end
			if a.kind == CompletionItemKind.Snippet then
				return true
			end
			if b.kind == CompletionItemKind.Snippet then
				return false
			end
			if a.kind == CompletionItemKind.Text then
				return false
			end
			if b.kind == CompletionItemKind.Text then
				return true
			end
		end
		-- custom snippets have higher rank, nil client_id means custom snippets
		if a.kind and a.kind == CompletionItemKind.Snippet then
			if not matcha.client_id then
				if matchb.client_id then
					return true
				end
			elseif not matchb.client_id then
				return false
			end
		end

		-- Sort by lexicographical order of 'sortText'.
		if a.sortText ~= b.sortText then
			if not a.sortText then
				return false
			end
			if not b.sortText then
				return true
			end
			local diff = vim.stricmp(a.sortText, b.sortText)
			if diff < 0 then
				return true
			elseif diff > 0 then
				return false
			end
		end

		-- Sort by length
		return #(a.insertText or a.label) < #(b.insertText or b.label)
	end)

	return vim.iter(ipairs(matches))
		:map(function(_, match)
			local item = match.item
			local client_id = match.client_id
			-- not use cached kind_map
			local kind = CompletionItemKind[item.kind] or "Unknown"
			local kind_hlgroup = util.get_hl(item.kind)
			local word
			local overlap_word = ""
			local snip_body = snippet.parse_body(item)
			if snip_body then
				local word_width = math.floor((vim.api.nvim_win_get_width(0) - col) / 2)
				if snip_body:find("%$") then
					word = #item.label > word_width and item.filterText or item.label
				else
					word = snip_body
				end
			else
				word = item.insertText or item.label
				local str_after_cursor = line:sub(col + 1, col + vim.fn.strwidth(word))
				for i=1,#str_after_cursor do
					if word:sub(-i) == str_after_cursor:sub(1, i) then
						word = word:sub(1, #word-i)
						overlap_word = word:sub(-i)
						break
					end
				end
			end
			local abbr_width = math.floor((vim.o.columns - col) / 3)
			local abbr = #item.label > abbr_width and item.label:sub(0, abbr_width).."..." or item.label
			return {
				word = word,
				equal = 1, -- we will do the filtering ourselves
				abbr = abbr,
				menu = item.menu,
				kind = kind,
				kind_hlgroup = kind_hlgroup,
				icase = 1,
				dup = 1,
				empty = 1,
				user_data = {
					nvim = {
						lsp = {
							completion_item = item,
							client_id = client_id,
							overlap_word = overlap_word,
						},
					},
				},
			}
		end)
		:totable()
end

function M._start_info()
	M._info.close_windows()
	M._ctx.cancel_pending()

	local lsp_data = vim.tbl_get(vim.v.completed_item, "user_data", "nvim", "lsp") or {}
	local completion_item = lsp_data.completion_item or {}
	if not next(completion_item) then
		return
	end

	-- get resolved item only if item does not already contain documentation
	if completion_item.documentation then
		M._open_info_window(completion_item)
	else
		local client = vim.lsp.get_client_by_id(lsp_data.client_id)
		if not client then
			return
		end

		local ok, request_id = client:request("completionItem/resolve", completion_item, function(err, result)
			if not err and result and result.documentation then
				M._open_info_window(result)
			end
		end)
		if ok then
			assert(request_id)
			local cancel_fn = function()
				if client then
					client:cancel_request(request_id)
				end
			end
			table.insert(M._ctx.pending_requests, cancel_fn)
		end
	end
end

function M._open_info_window(item)
	local detail = item.detail or ""

	local documentation
	if type(item.documentation) == "string" then
		documentation = item.documentation or ""
	else
		documentation = vim.tbl_get(item.documentation or {}, "value") or ""
	end

	if documentation == "" and detail == "" then
		return
	end

	local input
	if detail == "" then
		input = documentation
	elseif documentation == "" then
		input = detail
	else
		input = detail .. "\n" .. documentation
	end

	local lines = vim.lsp.util.convert_input_to_markdown_lines(input) or {}
	local pumpos = vim.fn.pum_getpos() or {}

	if next(lines) and next(pumpos) then
		-- Convert lines into syntax highlighted regions and set it in the buffer
		vim.lsp.util.stylize_markdown(M._info.bufnr, lines)

		local pum_left = pumpos.col - 1
		local pum_right = pumpos.col + pumpos.width + (pumpos.scrollbar and 1 or 0)
		local space_left = pum_left
		local space_right = vim.o.columns - pum_right

		-- Choose the side to open win
		local anchor, col, space = "NW", pum_right, space_right
		if space_right < space_left then
			anchor, col, space = "NE", pum_left, space_left
		end

		-- Calculate width (can grow to full space) and height
		local line_range = vim.api.nvim_buf_get_lines(M._info.bufnr, 0, -1, false)
		local width, height = vim.lsp.util._make_floating_popup_size(line_range, { max_width = space })

		local win_opts = {
			relative = "editor",
			anchor = anchor,
			row = pumpos.row,
			col = col,
			width = width,
			height = height,
			focusable = false,
			style = "minimal",
			border = "none",
		}

		table.insert(M._info.winids, vim.api.nvim_open_win(M._info.bufnr, false, win_opts))
	end
end

function M._on_completedone()
	M._info.close_windows()

	local lsp_data = vim.tbl_get(vim.v.completed_item, "user_data", "nvim", "lsp") or {}
	local completion_item = lsp_data.completion_item or {}
	if not next(completion_item) then
		return
	end

	local bufnr = vim.api.nvim_get_current_buf()
	local winnr = vim.api.nvim_get_current_win()
	local row, col = unpack(vim.api.nvim_win_get_cursor(winnr))

	-- Update context cursor so completion is not triggered right after complete done.
	M._ctx.cursor = { row, col }

	local completed_word = vim.v.completed_item.word or ""

	-- has overlap word, so set cursor to end of duplicate word
	local overlap_word = vim.tbl_get(lsp_data, "overlap_word")
	if overlap_word then
		pcall(vim.api.nvim_win_set_cursor, winnr, { row, col + vim.fn.strwidth(overlap_word) })
	end

	-- Expand snippets
	local expanded = false
	local snip_body = snippet.parse_body(completion_item)
	if snip_body and snip_body:find("%$") then
		pcall(vim.api.nvim_buf_set_text, bufnr, row - 1, col - vim.fn.strwidth(completed_word), row - 1, col, { "" })
		pcall(vim.api.nvim_win_set_cursor, winnr, { row, col - vim.fn.strwidth(completed_word) })
		vim.snippet.expand(snip_body)
		expanded = true
	end

	local client = lsp_data.client_id and vim.lsp.get_client_by_id(lsp_data.client_id)
	if not client then
		return
	end

	-- Apply additionalTextEdits
	local edits = completion_item.additionalTextEdits or {}
	if next(edits) then
		vim.lsp.util.apply_text_edits(edits, bufnr, client.offset_encoding)
	else
		-- TODO fix bug
		-- Reproduce:
		-- 1. Insert newline(s) right after completing an item without exiting insert mode.
		-- 2. Undo changes.
		-- Result: Completed item is not removed without the undo changes.
		local ok, request_id = client:request("completionItem/resolve", completion_item, function(err, result)
			edits = (not err) and (result and result.additionalTextEdits or {}) or {}
			if next(edits) then
				vim.lsp.util.apply_text_edits(edits, bufnr, client.offset_encoding)
			end
		end)
		if ok then
			assert(request_id)
			local cancel_fn = function()
				if client then
					client:cancel_request(request_id)
				end
			end
			table.insert(M._ctx.pending_requests, cancel_fn)
		end
	end

	-- Automatically add brackets
	if
		completion_item.kind == CompletionItemKind.Function
		or completion_item.kind == CompletionItemKind.Method
	then
		local prev_char = vim.api.nvim_buf_get_text(0, row - 1, col - 1, row - 1, col, {})[1]
		if not expanded and prev_char ~= "(" and prev_char ~= ")" then
			vim.api.nvim_feedkeys(
				vim.api.nvim_replace_termcodes(
					"()<left>",
					true,
					false,
					true
				), "i", false
			)
		end
	end
end

return M
