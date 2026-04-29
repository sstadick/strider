local M = {}

local labels = {
	flow = "StriderFlow",
	patch = "StriderPatch",
	q = "StriderQ",
}

function M.preview(text, max_chars)
	local preview = vim.trim((text or ""):gsub("%s+", " "))
	if preview == "" then
		preview = "untitled"
	end
	max_chars = max_chars or 48
	if vim.fn.strchars(preview) > max_chars then
		preview = vim.fn.strcharpart(preview, 0, max_chars - 1) .. "…"
	end
	return preview
end

function M.default(kind, seq, prompt)
	local label = labels[kind] or "StriderCard"
	return string.format("%s #%s: %s", label, tostring(seq or "?"), M.preview(prompt))
end

function M.for_card(card)
	if card and card.name and card.name ~= "" then
		return card.name
	end
	return M.default(card and card.kind, card and card.seq, card and card.prompt)
end

return M
