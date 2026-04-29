local M = {}

local function encode(payload)
	local ok, json = pcall(vim.json.encode, payload)
	if ok then
		return json
	end

	local fallback = {
		ok = payload.ok == true,
		inspected = true,
		value = vim.inspect(payload.value or payload),
	}
	if payload.phase then
		fallback.phase = payload.phase
	end
	if payload.error then
		fallback.error = tostring(payload.error)
	end

	local fallback_ok, fallback_json = pcall(vim.json.encode, fallback)
	if fallback_ok then
		return fallback_json
	end

	return '{"ok":false,"phase":"encode","error":"strider_vim result could not be encoded"}'
end

local function load_chunk(code)
	if type(code) ~= "string" then
		return nil, "strider_vim expected Lua code as a string"
	end

	if loadstring then
		return loadstring(code, "strider_vim")
	end
	return load(code, "strider_vim", "t", _G)
end

function M.exec(code)
	local chunk, load_err = load_chunk(code)
	if not chunk then
		return encode({
			ok = false,
			phase = "load",
			error = load_err,
		})
	end

	local ok, value = xpcall(chunk, debug.traceback)
	if not ok then
		return encode({
			ok = false,
			phase = "execute",
			error = value,
		})
	end

	return encode({
		ok = true,
		value = value,
	})
end

return M
