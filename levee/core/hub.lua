local ffi = require('ffi')
local C = ffi.C


local errors = require("levee.errors")
local _ = require("levee._")
local d = require("levee.d")


local message = require("levee.core.message")


local log = _.log.Log("levee.core.hub")


local State_mt = {}
State_mt.__index = State_mt


function State_mt:recv(timeout)
	if self.value then
		local value = self.value
		self.value = nil
		return nil, nil, value
	end

	self.co = coroutine.running()
	local err, sender, value = self.hub:pause(timeout)
	self.co = nil
	return err, sender, value
end


function State_mt:set(value)
	if not self.co then
		self.value = value
		return
	end

	local co = self.co
	self.co = nil
	self.hub:_coresume(co, nil, nil, value)
end


local function State(hub)
	local self = setmetatable({hub=hub}, State_mt)
	return self
end


local Hub_mt = {}
Hub_mt.__index = Hub_mt


function Hub_mt:pipe()
	local sender = message.Sender(self)
	local recver = message.Recver(self)
	sender.recver = recver
	recver.sender = sender
	return sender, recver
end


function Hub_mt:value(value)
	local sender = message.Value(self, value)
	local recver = message.Recver(self)
	sender.recver = recver
	recver.sender = sender
	return sender, recver
end


function Hub_mt:flag(value)
	local sender = message.Flag(self, value)
	local recver = message.Recver(self)
	sender.recver = recver
	recver.sender = sender
	return sender, recver
end


function Hub_mt:gate()
	local sender = message.Gate(self)
	local recver = message.Recver(self)
	sender.recver = recver
	recver.sender = sender
	return sender, recver
end


function Hub_mt:queue(size)
	local sender = message.Sender(self)
	local recver = message.Queue(self, size)
	sender.recver = recver
	recver.sender = sender
	return sender, recver
end


function Hub_mt:stalk(size)
	local sender = message.Sender(self)
	local recver = message.Stalk(self, size)
	sender.recver = recver
	recver.sender = sender
	return sender, recver
end


function Hub_mt:selector()
	return message.Selector(self)
end


function Hub_mt:dealer()
	local sender = message.Sender(self)
	local recver = message.Dealer(self)
	sender.recver = recver
	recver.sender = sender
	return sender, recver
end


function Hub_mt:broadcast()
	return message.Broadcast(self)
end


function Hub_mt:pool(factory, size)
	return message.Pool(self, factory, size)
end


function Hub_mt:_coresume(co, err, sender, value)
	if co ~= self._pcoro then
		local status, target = coroutine.resume(co, err, sender, value)
		if not status then
			log:fatal(debug.traceback(co) .. "\n\n" .. target)
		end
	else
		coroutine.yield(err, sender, value)
	end
end


function Hub_mt:_coyield(co, err, sender, value)
	if coroutine.running() ~= self._pcoro then
		return coroutine.yield(co, err, sender, value)
	end
	local status, err, sender, value = coroutine.resume(
		self.loop, co, err, sender, value)
	if not status then
		log:fatal(("%s\n\n%s"):format(debug.traceback(self.loop), err))
	end
	return err, sender, value
end


function Hub_mt:spawn(f, a)
	local co = coroutine.create(f)
	self.ready:push({co, a})
	self:continue()
end


function Hub_mt:spawn_later(ms, f)
	ms = self.poller:abstime(ms)
	local co = coroutine.create(f)
	self.scheduled:push(ms, co)
end


function Hub_mt:sleep(ms)
	ms = self.poller:abstime(ms)
	self.scheduled:push(ms, coroutine.running())
	self:_coyield()
end


function Hub_mt:pause(ms)
	if not ms then return self:_coyield() end

	ms = self.poller:abstime(ms)
	local timeout = self.scheduled:push(ms, coroutine.running())
	local err, sender, value = self:_coyield()
	if err ~= errors.TIMEOUT then
		timeout:remove()
	end
	return err, sender, value
end


function Hub_mt:resume(co, err, sender, value)
	self.ready:push({co, err, sender, value})
end


function Hub_mt:continue()
	self.ready:push({coroutine.running()})
	self:_coyield()
end


function Hub_mt:register(no, r, w)
	local r_ev = r and State(self)
	local w_ev = w and State(self)
	self.registered[no] = {r_ev, w_ev}
	self.poller:register(no, r, w)
	return r_ev, w_ev
end


local function EVStub()
	return {
		recv = function() return 1 end,
		set = function() end,
	}
end


function Hub_mt:register_nopoll(no, r, w)
	local r_ev = r and EVStub()
	local w_ev = w and EVStub()
	self.registered[no] = {r_ev, w_ev}
	return r_ev, w_ev
end


function Hub_mt:unregister(no)
	local r = self.registered[no]
	if r then
		table.insert(self.closing, no)

		-- this is only needed if a platform doesn't remove an fd from a poller on
		-- fd close
		-- TODO: detect r, w
		-- self.poller:unregister(no, r, w)

		if r[1] then r[1]:set(-1) end
		if r[2] then r[2]:set(-1) end
		self.registered[no] = nil
	end
end


function Hub_mt:in_use()
	for no in pairs(self.registered) do
		if not self.dialer.state or
				(no ~= self.dialer.r and no ~= self.dialer.state.io[1]) then
			return true
		end
	end
	return false
end


function Hub_mt:pump()
	local num = #self.ready
	for _ = 1, num do
		local co, err, sender, value = unpack(self.ready:pop())
		self:_coresume(co, err, sender, value)
	end

	local timeout
	if #self.ready > 0 then
		timeout = 0
	else
		timeout = self.scheduled:peek()
	end

	if #self.closing > 0 then
		for i = 1, #self.closing do
			C.close(self.closing[i])
		end
		self.closing = {}
	end

	local err, events, n = self.poller:poll(timeout)
	assert(not err)

	while true do
		local timeout = self.scheduled:peek()
		if not timeout or self.poller:reltime(timeout) > 0 then
			break
		end
		local ms, co = self.scheduled:pop()
		self:_coresume(co, errors.TIMEOUT)
	end

	for i = 0, n - 1 do
		local no, c_ev, s_ev, r_ev, w_ev, e_ev = events[i]:value()

		if c_ev then
			self.thread.chan:pump()

		elseif s_ev then
			self.signal:trigger(no)

		else
			local r = self.registered[no]
			if r then
				if not e_ev then
					if r_ev then r[1]:set(1) end
					if w_ev then r[2]:set(1) end
				else
					if r[1] then r[1]:set(-1) end
					if r[2] then r[2]:set(-1) end
				end
			end
		end
	end
end


function Hub_mt:main()
	while true do
		self:pump()
	end
end


local function Hub()
	local self = setmetatable({}, Hub_mt)

	self.ready = d.Fifo()
	self.scheduled = d.Heap()

	self.registered = {}
	self.poller = _.poller()
	self.closing = {}

	self._pcoro = coroutine.running()
	self.loop = coroutine.create(function()
		local status, err = xpcall(
			function() return self:main() end,
			function(err) return debug.traceback() .. "\n\n" .. err end)
		if not status then
			log:fatal(err .. "\n\nmain loop crashed")
		end
	end)

	self.io = require("levee.core.io")(self)
	self.signal = require("levee.core.signal")(self)
	self.process = require("levee.core.process")(self)
	self.thread = require("levee.core.thread")(self)

	self.stream = require("levee.net.stream")(self)
	self.dgram = require("levee.net.dgram")(self)
	self.dialer = require("levee.net.dialer")(self)
	self.tcp = self.stream

	self.http = require("levee.p.http")(self)
	self.consul = require("levee.app.consul")(self)

	return self
end


return Hub
