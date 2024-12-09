local M = {}


function M.parse_body(kind, completion_item)
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


return M
