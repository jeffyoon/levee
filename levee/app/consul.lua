local errors = require("levee.errors")
local json = require("levee.p.json")
local _ = require("levee._")


--
-- utilities

local function b64dec(data)
	local b='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
	local data = string.gsub(data, '[^'..b..'=]', '')
	return (
		data:gsub('.', function(x)
			if (x == '=') then return '' end
			local r,f='',(b:find(x)-1)
			for i=6,1,-1 do r=r..(f%2^i-f%2^(i-1)>0 and '1' or '0') end
			return r;
		end):gsub('%d%d%d?%d?%d?%d?%d?%d?', function(x)
			if (#x ~= 8) then return '' end
			local c=0
			for i=1,8 do c=c+(x:sub(i,i)=='1' and 2^(8-i) or 0) end
			return string.char(c)
		end))
end


--
-- Consul API

local Consul_mt = {}
Consul_mt.__index = Consul_mt


function Consul_mt:election(prefix, session_id, n)
	n = n or 1
	local err, ok = self.kv:put(
		prefix..session_id, session_id, {acquire=session_id})
	if err then return err end
	assert(ok)

	local is_elected = false

	local sender, recver = self.hub:pipe()
	self.hub:spawn(function()
		local err, index, data
		while true do
			err, index, data = self.kv:get(prefix, {index=index, recurse=true})

			local order = {}
			local map = {}

			local seen = false

			for _, v in ipairs(data) do
				if v.Value == session_id then
					seen = true
				end
				table.insert(order, v.CreateIndex)
				map[v.CreateIndex] = v.Value
			end

			if not seen then
				-- our entry has dropped out of consul
				sender:close()
				return
			end

			table.sort(order)
			local elected = false
			for i = 1, n do
				if map[order[i]] == session_id then
					elected = true
					break
				end
			end

			-- it shouldn't be possible to drop from election, once elected
			assert(not (is_elected and not elected))

			if elected and not is_elected then
				is_elected = true
				sender:send(true)
			end
		end
	end)
	return nil, recver
end


function Consul_mt:request(method, path, options, callback)
	local err, conn = self.hub.http:connect(self.port)
	if err then return err end
	if type(options.data) == "table" then
		err, options.data = json.encode(options.data)
		if err then return err end
	end
	local err, req = conn:request(
		method, "/v1/"..path, options.params, options.headers, options.data)
	if err then return err end
	local err, res = req:recv()
	if err then return err end
	res = {callback(res)}
	conn:close()
	return unpack(res)
end


--
-- KV namespace

local KV_mt = {}
KV_mt.__index = KV_mt


function KV_mt:get(key, options)
	-- options:
	-- 	index
	-- 	wait
	-- 	recurse
	-- 	keys
	-- 	separator
	-- 	TODO:
	-- 	token
	-- 	consistency

	options = options or {}
	local params = {}

	params.index = options.index
	params.wait = options.wait
	params.recurse = options.recurse and "1"
	params.keys = options.keys and "1"
	params.separator = options.separator

	return self.agent:request("GET", "kv/"..key, {params=params},
		function(res)
			if res.code ~= 200 then
				res:discard()
				return nil, res.headers["X-Consul-Index"], options.recurse and {} or nil
			end

			local err, data = res:json()
			if err then return err end

			if not options.keys then
				for _, item in ipairs(data) do
					if item.Value then item.Value = b64dec(item.Value) end
				end
				if not options.recurse then
					data = data[1]
				end
			end
			return nil, res.headers["X-Consul-Index"], data
	end)
end


function KV_mt:put(key, value, options)
	-- options:
	-- 	acquire
	-- 	release
	-- 	cas
	-- 	TODO:
	-- 	flags
	-- 	token

	options = options or {}
	local params = {}

	params.acquire = options.acquire
	params.release = options.release
	params.cas = options.cas

	return self.agent:request("PUT", "kv/"..key, {params=params, data=value},
		function(res)
			return nil, res:tostring() == "true"
		end)
end


function KV_mt:delete(key, options)
	-- options:
	-- 	recurse
	-- 	TODO:
	-- 	cas
	-- 	token

	options = options or {}
	local params = {}
	params.recurse = options.recurse and "1"

	return self.agent:request("DELETE", "kv/"..key, {params=params},
		function(res)
			res:discard()
			return nil, res.code == 200
		end)
end


local Session_mt = {}
Session_mt.__index = Session_mt


-- convenience to establish an ephemeral session and keep alive
function Session_mt:init()
	local err, session_id = self:create({behavior="delete", ttl=10})
	if err then return err end

	-- keep session alive
	self.agent.hub:spawn(function()
		while true do
			-- TODO: if renew fails should break
			self.agent.hub:sleep(5000)
			self:renew(session_id)
		end
	end)

	return err, session_id
end


function Session_mt:create(options)
	-- options:
	-- 	name
	-- 	node
	-- 	lock_delay
	-- 	behavior
	-- 	ttl

	options = options or {}
	local data = {}

	data.name = options.name
	data.node = options.node

	-- TODO: checks

	if options.lock_delay then
		data.lockdelay = tostring(options.lock_delay).."s"
	end

	data.behavior = options.behavior

	if options.ttl then
		assert(options.ttl >= 10 and options.ttl <= 3600)
		data.ttl = tostring(options.ttl).."s"
	end

	return self.agent:request("PUT", "session/create", {data=data},
		function(res)
			if res.code ~= 200 then
				assert(res.code == 200, ("%s: %s"):format(res.code, res:tostring()))
			end
			local err, data = res:json()
			if err then return err end
			return nil, data["ID"]
		end)
end


function Session_mt:list()
	return self.agent:request("GET", "session/list", {},
		function(res)
			if res.code ~= 200 then
				assert(res.code == 200, ("%s: %s"):format(res.code, res:tostring()))
			end
			local err, data = res:json()
			if err then return err end
			return nil, res.headers["X-Consul-Index"], data
		end)
end


function Session_mt:destroy(session_id)
	return self.agent:request("PUT", "session/destroy/"..session_id, {},
		function(res)
			res:discard()
			return nil, res.code == 200
		end)
end


function Session_mt:info(session_id)
	return self.agent:request("GET", "session/info/"..session_id, {},
		function(res)
			if res.code ~= 200 then
				return res:tostring()
			end
			local err, session = res:json()
			if err then return err end
			if session then session = session[1] end
			return nil, res.headers["X-Consul-Index"], session
		end)
end


function Session_mt:renew(session_id)
	return self.agent:request("PUT", "session/renew/"..session_id, {},
		function(res)
			if res.code == 404 then
				res:discard()
				return nil, false
			end
			if res.code ~= 200 then
				return res:tostring()
			end
			local err, data = res:json()
			if err then return err end
			return nil, data[1]
		end)
end


local Agent_mt = {}
Agent_mt.__index = Agent_mt


function Agent_mt:self()
	return self.agent:request("GET", "agent/self", {},
		function(res)
			if res.code ~= 200 then
				assert(res.code == 200, ("%s: %s"):format(res.code, res:tostring()))
			end
			return res:json()
		end)
end


function Agent_mt:services()
	return self.agent:request("GET", "agent/services", {},
		function(res)
			if res.code ~= 200 then
				assert(res.code == 200, ("%s: %s"):format(res.code, res:tostring()))
			end
			return res:json()
		end)
end


local AgentCheck_mt = {}
AgentCheck_mt.__index = AgentCheck_mt


function AgentCheck_mt:pass(check_id, options)
	-- options:
	--   note
	options = options or {}

	local params = {}
	params.note = options.note

	return self.agent:request(
		"GET", "agent/check/pass/"..check_id, {params=params},
		function(res)
			return nil, res.code == 200
		end)
end


local AgentService_mt = {}
AgentService_mt.__index = AgentService_mt


function AgentService_mt:register(name, options)
	-- options:
	-- 	service_id
	-- 	address
	-- 	port
	-- 	tags
	-- 	check
	-- 		ttl or
	-- 		script, interval or
	-- 		http, interval, timeout

	options = options or {}
	local data = {name = name}

	data.id = options.service_id
	data.address = options.address
	data.port = options.port
	data.tags = options.tags
	data.check = options.check

	return self.agent:request(
		"PUT", "agent/service/register", {data=data},
		function(res)
			return nil, res.code == 200, res:tostring()
		end)
end


function AgentService_mt:deregister(service_id)
	return self.agent:request("GET", "agent/service/deregister/"..service_id, {},
		function(res)
			res:discard()
			return nil, res.code == 200
		end)
end


local Health_mt = {}
Health_mt.__index = Health_mt


function Health_mt:service(name, options)
	-- options
	-- 	index
	-- 	passing
	-- 	tags

	options = options or {}
	local params = {}

	params.index = options.index
	params.passing = options.passing and "1"
	params.tag = options.tag

	params.consistent = params.consistent and "1"
	params.stale = params.stale and "1"

	return self.agent:request("GET", "health/service/"..name, {params=params},
		function(res)
			local err, data
			if res.code ~= 200 then
				data = {}
			else
				err, data = res:json()
				if err then return err end
			end
			return nil, res.headers["X-Consul-Index"], data
		end)
end


--
-- A spawned Consul instance, usually for testing

local Instance_mt = {}
Instance_mt.__index = Instance_mt


function Instance_mt:connect()
	return self.hub:consul(self.port)
end


function Instance_mt:stop()
	self.child:kill()
	self.child.done:recv()
	self.path:remove(true)
end


local function Instance(hub, bin, http_port, join)

	local function freeport()
		local err, no = _.listen(C.AF_INET, C.SOCK_STREAM, host, port)
		local err, addr = _.getsockname(no)
		C.close(no)
		return addr:port()
	end

	local self = setmetatable({}, Instance_mt)

	self.hub = hub
	self.path = _.path.Path:tmpdir()

	self.config = {
		ports = {
			http = http_port or freeport(),
			rpc = freeport(),
			serf_lan = freeport(),
			serf_wan = freeport(),
			server = freeport(),
			dns = freeport(), } }

	self.port = self.config.ports.http

	local err, buf = json.encode(self.config)
	local data = buf:take()
	self.path("config.json"):write(data)

	local argv
	if not join then
		argv = {
			"agent",
			"-server",
			"-dev",
			"-bind=127.0.0.1",
			"-bootstrap",
			"-config-dir="..self.path, }
	else
		argv = {
			"agent",
			"-dev",
			"-bind=127.0.0.1",
			"-join=localhost:"..tostring(join.config.ports.serf_lan),
			"-node=node2",
			"-config-dir="..self.path, }
	end

	self.child = self.hub.process:spawn(bin, {
		argv=argv,
		io={
			STDIN=0,
			}, })

	self.hub:spawn(function()
		local stream = self.child.stdout:stream()
		local log = _.log.Log("levee.app.consul")
		while true do
			local err, line = stream:line()
			if err then break end
			log:info(line)
		end
	end)


	local err, done = self.child.done:recv(100)
	if done then
		self.path:remove(true)
		return errors.CLOSED
	end

	while true do
		local err, conn = self.hub.tcp:connect(self.port)
		if conn then conn:close(); break; end
		self.hub:sleep(100)
	end

	local c = self:connect()

	c.agent.service:register("foo")
	while true do
		local err, index, services = c.health:service("foo")
		if #services > 0 then break end
		self.hub:sleep(300)
	end
	c.agent.service:deregister("foo")

	return nil, self
end


--
-- Module interface

local M_mt = {}
M_mt.__index = M_mt


function M_mt:__call(hub, port)
	local M = setmetatable({hub = self.hub, port = port or 8500}, Consul_mt)
	M.kv = setmetatable({agent = M}, KV_mt)
	M.session = setmetatable({agent = M}, Session_mt)
	M.agent = setmetatable({agent = M}, Agent_mt)
	M.agent.check = setmetatable({agent = M}, AgentCheck_mt)
	M.agent.service = setmetatable({agent = M}, AgentService_mt)
	M.health = setmetatable({agent = M}, Health_mt)
	return M
end


function M_mt:spawn(options)
	options = options or {}
	options.bin = options.bin or "consul"
	return Instance(self.hub, options.bin, options.http_port, options.join)
end


return function(hub)
	return setmetatable({hub=hub}, M_mt)
end
