local M = {}
local CompletionItemKind = vim.lsp.protocol.CompletionItemKind

M.score = function(matcha, matchb)
    local a, b = matcha.item, matchb.item
    if a.match_score ~= b.match_score then
        return a.match_score > b.match_score
    end
    if a.score and b.score then
        local diff = b.score - a.score
        if math.abs(diff) > 1e-6 then
            return diff < 0
        end
    end
    return nil
end

M.kind = function(matcha, matchb)
    local a, b = matcha.item, matchb.item
    -- 'Snippet' are ranked highest, and 'Text' are ranked lowest
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
    return nil
end

M.sort_text = function(matcha, matchb)
    local a, b = matcha.item, matchb.item
    if a.sortText and b.sortText then
        local diff = vim.stricmp(a.sortText, b.sortText)
        if diff < 0 then
            return true
        elseif diff > 0 then
            return false
        end
    end
    return nil
end

M.length = function(matcha, matchb)
    local a, b = matcha.item, matchb.item
    if #a.label ~= #b.label then
        return #a.label < #b.label
    end
    return nil
end

return M
