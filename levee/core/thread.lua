local ffi = require("ffi")
local C = ffi.C


local errors = require("levee.errors")
local message = require("levee.core.message")
local msgpack = require("levee.p").msgpack
local d = require("levee.d")


local ctype_ptr = ffi.typeof("struct LeveeData")
local ctype_buf = ffi.typeof("LeveeBuffer")
local ctype_dbl = ffi.typeof("double")
local ctype_u64 = ffi.typeof("uint64_t")
local ctype_i64 = ffi.typeof("int64_t")
local ctype_error = ffi.typeof("SpError")


--
-- Channel

local Recver_mt = {}
Recver_mt.__index = Recver_mt


function Recver_mt:__tostring()
	local chan_id = C.levee_chan_event_id(self.chan.chan)
	return string.format(
		"levee.ChannelRecver: chan=%d id=%d",
		tonumber(chan_id),
		tonumber(self.id))
end


function Recver_mt:pump(node)
	local err
	if node.error ~= 0 then
		err = errors.get(node.error)
	end

	if node.type == C.LEVEE_CHAN_NIL then
		self.queue:pass(err, nil)
	elseif node.type == C.LEVEE_CHAN_PTR then
		local err, data
		if node.as.ptr.fmt == C.LEVEE_CHAN_MSGPACK then
			err, data = msgpack.decode(node.as.ptr.val, node.as.ptr.len)
		else
			data = d.Data(node.as.ptr.val, node.as.ptr.len)
			node.as.ptr.val = nil
		end
		self.queue:pass(err, data)
	elseif node.type == C.LEVEE_CHAN_BUF then
		local buf = d.Buffer:from_ptr(node.as.ptr.val)
		self.queue:pass(nil, buf)
	elseif node.type == C.LEVEE_CHAN_OBJ then
		self.queue:pass(err, ffi.gc(node.as.obj.obj, node.as.obj.free))
	elseif node.type == C.LEVEE_CHAN_DBL then
		self.queue:pass(err, tonumber(node.as.dbl))
	elseif node.type == C.LEVEE_CHAN_I64 then
		self.queue:pass(err, node.as.i64)
	elseif node.type == C.LEVEE_CHAN_U64 then
		self.queue:pass(err, node.as.u64)
	elseif node.type == C.LEVEE_CHAN_BOOL then
		self.queue:pass(err, node.as.b)
	elseif node.type == C.LEVEE_CHAN_SND then
		self.queue:pass(err, C.levee_chan_sender_ref(node.as.sender))
	end
end


function Recver_mt:recv(ms)
	return self.queue:recv(ms)
end


function Recver_mt:__call()
	return self.queue()
end


function Recver_mt:create_sender()
	-- TODO: do we need to track senders
	local sender = C.levee_chan_sender_create(self.chan.chan, self.id)
	if sender == nil then
		-- TODO: some errors should not halt (e.g closed channel)
		error("levee_chan_sender_create")
	end
	return ffi.gc(sender, C.levee_chan_sender_unref)
end


local function Recver(chan, id)
	return setmetatable({
		chan = chan,
		id = id,
		-- TODO:
		queue = message.Pair(chan.hub:queue()), }, Recver_mt)
end


local Sender_mt = {}
Sender_mt.__index = Sender_mt


function Sender_mt:__tostring()
	local chan_id = C.levee_chan_event_id(self.chan)
	return string.format(
		"levee.ChannelSender: chan=%d id=%d",
		tonumber(chan_id),
		tonumber(self.recv_id))
end


function Sender_mt:pass(err, val)
	if ffi.istype(ctype_error, err) then
		err = tonumber(err.code)
	elseif type(err) ~= "number" then
		err = 0
	end
	if val == nil then
		return C.levee_chan_send_nil(self, err)
	elseif type(val) == "number" or ffi.istype(ctype_dbl, val) then
		return C.levee_chan_send_dbl(self, err, val)
	elseif type(val) == "boolean" then
		return C.levee_chan_send_bool(self, err, val)
	elseif ffi.istype(ctype_buf, val) then
		ffi.gc(val, nil)  -- cancel the buffer's local gc
		return C.levee_chan_send_buf(self, err, val)
	elseif ffi.istype(ctype_ptr, val) then
		local rc = C.levee_chan_send_ptr(self, err,
			val.val, val.len, C.LEVEE_CHAN_RAW)
		if rc >= 0 then
			val.val = nil
			val.len = 0
		end
		return rc
	elseif ffi.istype(ctype_i64, val) then
		return C.levee_chan_send_i64(self, err, val)
	elseif ffi.istype(ctype_u64, val) then
		return C.levee_chan_send_u64(self, err, val)
	elseif ffi.istype(ctype_error, val) then
		return C.levee_chan_send_error(self, err, val.code)
	else
		local encerr, m = msgpack.encode(val)
		if encerr then return encerr end
		local buf, len = m:value()
		local rc = C.levee_chan_send_ptr(self, err,
			buf, len, C.LEVEE_CHAN_MSGPACK)
		if rc >= 0 then
			m.buf = nil
		end
		return rc
	end
end


function Sender_mt:send(val)
	return self:pass(nil, val)
end


function Sender_mt:connect(chan)
	local recv_id = C.levee_chan_connect(self, chan.chan)
	if recv_id < 0 then
		-- TODO: expose connection error
		return nil
	end
	recv_id = tonumber(recv_id)
	local recver = Recver(chan, recv_id)
	chan.listeners[recv_id] = recver
	return recver
end


function Sender_mt:close()
	C.levee_chan_sender_close()
end


ffi.metatype("LeveeChanSender", Sender_mt)


local Channel_mt = {}
Channel_mt.__index = Channel_mt


function Channel_mt:__tostring()
	return string.format("levee.Channel: %d", self:event_id())
end


function Channel_mt:event_id()
	return C.levee_chan_event_id(self.chan)
end


function Channel_mt:close()
	C.levee_chan_close(self.chan)
end


function Channel_mt:bind()
	local id = tonumber(C.levee_chan_next_recv_id(self.chan))
	if id < 0 then
		-- channel is closed
		return nil
	end

	local recv = Recver(self, id)
	self.listeners[id] = recv
	return recv
end


function Channel_mt:pump()
	local head = C.levee_chan_recv(self.chan)
	while head ~= nil do
		local recv_id = tonumber(head.recv_id)
		local recv = self.listeners[recv_id]
		if recv then
			recv:pump(head)
		else
			print("no recver", recv_id)
		end
		head = C.levee_chan_recv_next(head)
	end
end


local function Channel(hub)
	local chan = C.levee_chan_create(hub.poller.fd)
	if chan == nil then
		error("levee_chan_create")
	end
	ffi.gc(chan, C.levee_chan_unref)
	return setmetatable({hub=hub, chan=chan, listeners={}}, Channel_mt)
end


--
-- State
-- a lua state

ffi.cdef[[
struct LeveeState {
	Levee *child;
};
]]

local State_mt = {}
State_mt.__index = State_mt


local access_error = "invalid access of background state"
local sender_type = ffi.typeof("LeveeChanSender *")


local function check(child, ok)
	if ok then
		return true
	end
	return false, ffi.string(C.levee_get_error(child))
end


function State_mt:__new()
	local state = ffi.new(self)
	state.child = C.levee_create()
	return state
end


function State_mt:__gc()
	if self.child then
		C.levee_destroy(self.child)
		self.child = nil
	end
end


function State_mt:__tostring()
	return string.format("levee.State: %p", self)
end


function State_mt:load_file(path)
	if self.child == nil then
		return false, access_error
	end
	return check(self.child, C.levee_load_file(self.child, path))
end


function State_mt:load_string(str, name)
	if self.child == nil then
		return false, access_error
	end
	return check(self.child, C.levee_load_string(self.child, str, #str, name))
end


function State_mt:load_function(fn)
	-- TODO: what should the name be?
	return self:load_string(string.dump(fn), "main")
end


function State_mt:push(val)
	if self.child == nil then
		return
	end
	if type(val) == "number" then
		C.levee_push_number(self.child, val)
	elseif type(val) == "string" then
		C.levee_push_string(self.child, val, #val)
	elseif type(val) == "boolean" then
		C.levee_push_bool(self.child, val)
	elseif type(val) == "cdata" and ffi.typeof(val) == sender_type then
		C.levee_push_sender(self.child, val)
	else
		C.levee_push_nil(self.child)
	end
end


function State_mt:pop(n)
	if self.child == nil then
		return
	end
	C.levee_pop(self.child, n or 1)
end


function State_mt:run(narg, bg)
	if self.child == nil then
		return false, access_error
	end
	local child = self.child
	if bg then
		self.child = nil
	end
	return check(child, C.levee_run(child, narg, not not bg))
end


local State = ffi.metatype("struct LeveeState", State_mt)


--
-- Thread

local Thread_mt = {}
Thread_mt.__index = Thread_mt


function Thread_mt:channel()
	if self.chan == nil then
		self.chan = Channel(self.hub)
	end
	return self.chan
end


function Thread_mt:call(f, ...)
	local state = State()

	-- bootstrap
	assert(state:load_function(
		function(sender, f, ...)
			local ok, err, value = pcall(loadstring(f), ...)

			if not ok then
				-- TODO: we should work an optional error message into Pipe close
				error("ERROR:", err)
			else
				-- TODO: close
				sender:pass(err, value)
			end
		end))

	local recver = self:channel():bind()
	state:push(recver:create_sender())

	state:push(string.dump(f))

	local args = {...}
	for i = 1, #args do
		state:push(args[i])
	end
	state:run(2 + #args, true)

	return recver
end


function Thread_mt:spawn(f)
	local state = State()

	-- bootstrap
	assert(state:load_function(
		function(sender, f)
			local levee = require("levee")
			local message = require("levee.core.message")

			local h = levee.Hub()
			h.parent = message.Pair(sender, sender:connect(h.thread:channel()))

			local ok, got = pcall(loadstring(f), h)

			if not ok then
				-- TODO: we should work an optional error message into Pipe close
				print("ERROR:", got)
			else
				-- TODO: close
			end
		end))

		local recver = self:channel():bind()
		state:push(recver:create_sender())

		state:push(string.dump(f))
		state:run(2, true)

		local err, sender = recver:recv()
		assert(not err)
		return message.Pair(sender, recver)
end


return function(hub)
	return setmetatable({hub = hub}, Thread_mt)
end
