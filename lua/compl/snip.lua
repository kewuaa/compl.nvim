local M = {}
local util = require("compl.util")
---@type table<string, table[]>
local cache = {}


---@param completion_item table
function M.parse_body(completion_item)
	local snip_body
	if
		completion_item.kind == vim.lsp.protocol.CompletionItemKind.Snippet
		or completion_item.insertTextFormat == vim.lsp.protocol.InsertTextFormat.Snippet
	then
		local new_text = vim.tbl_get(completion_item, "textEdit", "newText")
		local insert_text = completion_item.insertText
		snip_body = (new_text and new_text)
			or (insert_text and insert_text)
	end
	return snip_body
end


---@param paths string[]
---@param filetype string
local function load(paths, filetype)
	local parse_snippet_data = function(snippet_data)
		vim.iter(pairs(snippet_data or {})):each(function(_, snippet)
			local prefixes = type(snippet.prefix) == "table" and snippet.prefix or { snippet.prefix }
			vim.iter(ipairs(prefixes)):each(function(_, prefix)
				table.insert(cache[filetype], {
					detail = "snippet",
					label = prefix,
					kind = vim.lsp.protocol.CompletionItemKind["Snippet"],
					documentation = {
						value = snippet.description,
						kind = vim.lsp.protocol.MarkupKind.Markdown,
					},
					insertTextFormat = vim.lsp.protocol.InsertTextFormat.Snippet,
					insertText = type(snippet.body) == "table" and table.concat(snippet.body, "\n") or snippet.body,
				})
			end)
		end)
	end

	cache[filetype] = {}
	vim.iter(ipairs(paths)):each(function(_, root)
		local manifest_path = table.concat({ root, "package.json" }, util.sep)
		util.async_read_json(manifest_path, function(manifest_data)
			vim.iter(ipairs((manifest_data.contributes and manifest_data.contributes.snippets) or {}))
				:filter(function(_, s)
					if type(s.language) == "table" then
						return vim.iter(ipairs(s.language)):any(function(_, l)
							return l == filetype
						end)
					else
						return s.language == filetype
					end
				end)
				:map(function(_, snippet_contribute)
					return vim.fn.resolve(table.concat({ root, snippet_contribute.path }, util.sep))
				end)
				:each(function(snippet_path)
					util.async_read_json(snippet_path, parse_snippet_data)
				end)
		end)
	end)
end


---@param paths string[] vscode snippet paths
---@param filetype string filetype
---@return table[] items snippet items
function M.load_vscode_snippet(paths, filetype)
    if not cache[filetype] then
        load(paths, filetype)
    end
    return cache[filetype]
end


return M
