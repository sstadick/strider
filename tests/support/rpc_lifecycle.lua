-- Exercise the real RPC dispatcher/state; replace only presentation surfaces.
local H = { calls = {}, streams = {}, scheduled = {} }
local state = require("strider.state")
state.setup({ open_log_on_start = false })
H.state = state

local function record(name, ...)
	table.insert(H.calls, { name = name, args = { ... } })
end

package.loaded["strider.ui"] = setmetatable({}, {
	__index = function(_, name)
		return function(...)
			record(name, ...)
		end
	end,
})
package.loaded["strider.review"] = {
	has_active_review = function()
		return true
	end,
	is_planning = function()
		return false
	end,
	is_awaiting_summary = function()
		return H.awaiting_summary
	end,
	capture_plan_message = function(text)
		record("plan_message", text)
	end,
	capture_assistant_text = function(text)
		record("review_message", text)
	end,
}
package.loaded["strider.search"] = {
	handle_response = function(text)
		record("search", text)
		return text
	end,
	summary_text = function(text)
		return "Search: " .. text
	end,
}
package.loaded["strider"] = {
	dispatch_first_review = function()
		record("dispatch_review")
	end,
	complete_review_summary = function(text)
		record("complete_summary", text)
	end,
}
vim.schedule = function(fn)
	table.insert(H.scheduled, fn)
end
vim.fn.jobstart = function(_, opts)
	table.insert(H.streams, opts.on_stdout)
	return #H.streams
end
vim.fn.jobwait = function()
	return { -1 }
end
local rpc = require("strider.rpc")

function H.drain()
	while #H.scheduled > 0 do
		table.remove(H.scheduled, 1)()
	end
end

function H.start(lane, operation)
	assert(rpc.start(lane, vim.fn.getcwd()))
	state.set_pending_request(operation, { card_id = "card", summary_id = "patch" }, lane)
	local stream = H.streams[state.get_session(lane).job_id]
	return function(event)
		stream(0, { vim.json.encode(event), "" })
		H.drain()
	end
end

function H.message(text, stop_reason)
	return {
		type = "message_end",
		message = {
			role = "assistant",
			stopReason = stop_reason or "stop",
			content = text and { { type = "text", text = text } } or {},
		},
	}
end

function H.count(name)
	local n = 0
	for _, call in ipairs(H.calls) do
		if call.name == name then
			n = n + 1
		end
	end
	return n
end

function H.last(name)
	for i = #H.calls, 1, -1 do
		if H.calls[i].name == name then
			return H.calls[i].args
		end
	end
end

return H
