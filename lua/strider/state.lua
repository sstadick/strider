local session_factory = require("strider.state.session")

local M = {}

local lane_order = { "main", "flow", "q", "patch", "review" }
local lane_set = {}
for _, lane in ipairs(lane_order) do
	lane_set[lane] = true
end
local dynamic_lanes = {}

local flow_lanes = { flow = true, q = true, patch = true }
local flow_operations = { q = true, search = true, patch = true }
local model_config_lane_keys = {
	chat = true,
	default = true,
	flow = true,
	main = true,
	patch = true,
	q = true,
	review = true,
	search = true,
}

local function plugin_root()
	local source = debug.getinfo(1, "S").source:sub(2)
	local dir = vim.fs.dirname(source)
	return vim.fs.dirname(vim.fs.dirname(dir))
end

local defaults = {
	auto_jump = true,
	extension_path = nil,
	log_buffer_name = "strider://log",
	log_max_lines = 5000,
	log_pin_max_rows = 5,
	log_pin_user_message = true,
	model_env_var = "PI_MODEL_ENV",
	open_log_on_start = true,
	pi_cmd = { "pi" },
	q_default_model = "fast",
	q_models = {
		fast = { model = "codex-spark" },
		deep = "chat",
	},
}

local function is_dynamic_q_lane(lane)
	return type(lane) == "string" and lane:match("^q%-%d+$") ~= nil
end

local function is_known_lane(lane)
	return lane_set[lane] == true or is_dynamic_q_lane(lane)
end

local function normalize_lane(lane)
	if lane == nil or lane == "" then
		return "main"
	end
	if is_known_lane(lane) then
		return lane
	end
	return "main"
end

local function resolve_lane_and_cwd(arg1, arg2)
	if is_known_lane(arg1) then
		return normalize_lane(arg1), arg2
	end
	if is_known_lane(arg2) then
		return normalize_lane(arg2), arg1
	end
	return "main", arg1 or arg2
end

local function configured_lane_models(config)
	if type(config.lane_models) == "table" and next(config.lane_models) ~= nil then
		return config.lane_models
	end
	if type(config.models) == "table" and next(config.models) ~= nil then
		return config.models
	end

	local profiles = {}
	local found = false
	for key in pairs(model_config_lane_keys) do
		if type(config[key]) == "table" then
			profiles[key] = config[key]
			found = true
		end
	end
	return found and profiles or nil
end

local function env_profile_key(config)
	local name = config.model_profile_env or config.model_env_var or "PI_MODEL_ENV"
	if type(name) ~= "string" or vim.trim(name) == "" then
		name = "PI_MODEL_ENV"
	end
	local key = vim.trim(vim.env[name] or "")
	if key == "" or key:lower() == "default" then
		key = "default"
	end
	return name, key
end

local function has_model_fields(profile)
	return type(profile) == "table"
		and (profile.model ~= nil or profile.provider ~= nil or profile.thinking ~= nil or profile.reasoning ~= nil)
end

local function lane_model_keys(lane)
	lane = normalize_lane(lane)
	if is_dynamic_q_lane(lane) then
		return { lane, "q" }
	end
	if lane == "main" then
		return { "main", "chat" }
	end
	if lane == "flow" then
		return { "flow", "search" }
	end
	return { lane }
end

local function select_model_profile(profiles, requested)
	if type(profiles) ~= "table" then
		return nil, nil
	end
	if has_model_fields(profiles) then
		return profiles, "default"
	end
	if requested ~= "default" and type(profiles[requested]) == "table" then
		return profiles[requested], requested
	end
	if type(profiles.default) == "table" then
		return profiles.default, "default"
	end
	return nil, nil
end

M.config = vim.tbl_deep_extend("force", defaults, {
	plugin_root = plugin_root(),
})

M.sessions = {}

function M.setup(opts)
	local next_config = vim.tbl_deep_extend("force", M.config, opts or {})
	if opts and opts.pi_cmd then
		next_config.pi_cmd = opts.pi_cmd
	end
	if type(next_config.pi_cmd) == "string" then
		next_config.pi_cmd = { next_config.pi_cmd }
	end
	M.config = next_config
end

function M.get_config()
	return M.config
end

function M.resolve_lane_model(lane)
	lane = normalize_lane(lane)
	local env_name, requested = env_profile_key(M.config)
	local meta = { env = env_name, requested = requested }
	local session = M.sessions[lane]
	if session and session.model_profile_override then
		meta.lane = lane
		meta.profile = session.model_label or "override"
		meta.override = true
		return session.model_profile, meta
	end
	local profiles = configured_lane_models(M.config)
	if not profiles then
		return nil, meta
	end

	for _, key in ipairs(lane_model_keys(lane)) do
		local profile, selected = select_model_profile(profiles[key], requested)
		if profile then
			meta.lane = key
			meta.profile = selected
			return profile, meta
		end
	end

	local profile, selected = select_model_profile(profiles.default, requested)
	if profile then
		meta.lane = "default"
		meta.profile = selected
		return profile, meta
	end
	return nil, meta
end

local function q_model_spec(label)
	local config = M.config
	local models = type(config.q_models) == "table" and config.q_models or {}
	label = vim.trim(label or config.q_default_model or "fast")
	if label == "" then
		label = "fast"
	end
	return label, models[label]
end

local function profile_from_q_spec(spec)
	if spec == "chat" or spec == "deep" then
		return M.resolve_lane_model("main")
	end
	if spec == "q" or spec == "fast" then
		return M.resolve_lane_model("q")
	end
	if type(spec) == "string" and vim.trim(spec) ~= "" then
		return { model = spec }, { profile = spec }
	end
	if type(spec) == "table" then
		return vim.deepcopy(spec), { profile = "override" }
	end
	return nil, nil
end

function M.resolve_q_model(label)
	local resolved, spec = q_model_spec(label)
	local profile = profile_from_q_spec(spec)
	return profile, resolved
end

function M.set_model_override(lane, profile, label)
	local session = M.get_session(lane)
	if not session then
		return
	end
	session.model_profile_override = true
	session.model_profile = type(profile) == "table" and vim.deepcopy(profile) or nil
	session.model_label = label
end

function M.lanes()
	local lanes = vim.deepcopy(lane_order)
	local dynamic = {}
	for lane in pairs(dynamic_lanes) do
		table.insert(dynamic, lane)
	end
	table.sort(dynamic, function(a, b)
		return (M.q_lane_index(a) or 0) < (M.q_lane_index(b) or 0)
	end)
	vim.list_extend(lanes, dynamic)
	return lanes
end

function M.is_lane(lane)
	return is_known_lane(lane)
end

function M.normalize_lane(lane)
	return normalize_lane(lane)
end

function M.get_session(lane)
	return M.sessions[normalize_lane(lane)]
end

function M.ensure_session(arg1, arg2)
	local lane, cwd = resolve_lane_and_cwd(arg1, arg2)
	if is_dynamic_q_lane(lane) then
		dynamic_lanes[lane] = true
	end
	if not cwd or cwd == "" then
		local current = M.sessions[lane]
		cwd = current and current.cwd or vim.fn.getcwd()
	end
	if not M.sessions[lane] or M.sessions[lane].cwd ~= cwd then
		M.sessions[lane] = session_factory.new(cwd, lane)
	end
	return M.sessions[lane]
end

function M.clear_session(lane)
	if lane == nil then
		M.sessions = {}
		dynamic_lanes = {}
		return
	end
	lane = normalize_lane(lane)
	M.sessions[lane] = nil
	dynamic_lanes[lane] = nil
end

function M.next_request_id(lane)
	local session = M.get_session(lane)
	if not session then
		return nil
	end
	session.request_seq = session.request_seq + 1
	return string.format("strider-%s-%d", normalize_lane(lane), session.request_seq)
end

function M.record_file(path, lane)
	local session = M.get_session(lane)
	if not session then
		return
	end
	session.last_touched_file = path
	local recent = { path }
	for _, item in ipairs(session.recent_files) do
		if item ~= path and #recent < 5 then
			table.insert(recent, item)
		end
	end
	session.recent_files = recent
end

function M.set_status(key, value, lane)
	local session = M.get_session(lane)
	if not session then
		return
	end
	session.status[key] = value
end

function M.set_widget(lines, lane)
	local session = M.get_session(lane)
	if not session then
		return
	end
	session.widget = lines or {}
end

function M.set_summary(text, lane)
	local session = M.get_session(lane)
	if not session then
		return
	end
	session.last_summary = text
end

function M.set_error(text, lane)
	local session = M.get_session(lane)
	if session then
		session.last_error = text
	end
end

function M.clear_error(lane)
	local session = M.get_session(lane)
	if session then
		session.last_error = nil
	end
end

function M.set_pending_request(operation, metadata, lane)
	local session = M.get_session(lane)
	if not session then
		return
	end
	if not operation then
		session.pending_request = nil
		return
	end
	session.pending_request = {
		operation = operation,
		metadata = metadata or {},
	}
end

function M.peek_pending_request(lane)
	local session = M.get_session(lane)
	return session and session.pending_request
end

function M.consume_pending_request(lane)
	local session = M.get_session(lane)
	if not session then
		return nil
	end
	local pending = session.pending_request
	session.pending_request = nil
	return pending
end

-- Pending clarify: when the model calls strider_clarify, the plugin
-- stashes the extension_ui_request id + title here and routes the next
-- compose send back as the clarify reply. Cleared by dispatch_compose
-- (on answer) or by <Esc><Esc> in compose (on reject).
function M.set_pending_clarify(id, title, lane, opts)
	local session = M.get_session(lane)
	if session then
		opts = opts or {}
		session.pending_clarify = {
			id = id,
			kind = opts.kind or "question",
			prefill = opts.prefill,
			title = title or "",
		}
	end
end

function M.peek_pending_clarify(lane)
	local session = M.get_session(lane)
	return session and session.pending_clarify
end

function M.consume_pending_clarify(lane)
	local session = M.get_session(lane)
	if not session then
		return nil
	end
	local p = session.pending_clarify
	session.pending_clarify = nil
	return p
end

function M.record_review_acceptance(stop, lane)
	local session = M.get_session(lane or "review")
	if not session or not stop then
		return
	end
	local id = stop.id or string.format("%s:%s-%s", stop.path or "", stop.startLine or "", stop.endLine or "")
	for _, item in ipairs(session.review_acceptances) do
		if item.id == id then
			item.accepted_at = os.time()
			return
		end
	end
	table.insert(session.review_acceptances, {
		accepted_at = os.time(),
		endLine = stop.endLine,
		id = id,
		path = stop.path,
		startLine = stop.startLine,
		title = stop.title,
	})
end

function M.review_acceptances(lane)
	local session = M.get_session(lane or "review")
	return session and session.review_acceptances or {}
end

function M.q_lane_index(lane)
	lane = normalize_lane(lane)
	if lane == "q" then
		return 1
	end
	return tonumber(type(lane) == "string" and lane:match("^q%-(%d+)$") or nil)
end

function M.is_q_lane(lane)
	return M.q_lane_index(lane) ~= nil
end

function M.next_q_worker_lane()
	local max_index = 0
	for lane in pairs(M.sessions) do
		if M.is_q_lane(lane) then
			max_index = math.max(max_index, M.q_lane_index(lane) or 0)
		end
	end
	local next_index = max_index + 1
	local lane = next_index == 1 and "q" or ("q-" .. next_index)
	if is_dynamic_q_lane(lane) then
		dynamic_lanes[lane] = true
	end
	return lane, next_index
end

function M.is_flow_lane(lane)
	lane = normalize_lane(lane)
	return flow_lanes[lane] == true or M.is_q_lane(lane)
end

function M.is_flow_operation(op)
	return flow_operations[op] == true
end

return M
