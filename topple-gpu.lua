#!/usr/bin/env luajit
local ffi = require 'ffi'
local vec3ub = require 'vec-ffi.vec3ub'
local template = require 'template'

local toppleType = 'int'

local modulo = 4
local initValue = arg[1] or '1<<10'
local gridsize = assert(tonumber(arg[2] or 1001))

local CLEnv = require 'cl.obj.env'
local env = CLEnv{
	verbose = true,
	useGLSharing = false,
	getPlatform = CLEnv.getPlatformFromCmdLine(table.unpack(arg)),
	getDevices = CLEnv.getDevicesFromCmdLine(table.unpack(arg)),
	deviceType = CLEnv.getDeviceTypeFromCmdLine(table.unpack(arg)),
	size = {gridsize, gridsize},
}
local buffer = env:buffer{name='buffer', type=toppleType}
local nextBuffer = env:buffer{name='nextBuffer', type=toppleType}
local overflow = env:buffer{count=1, name='overflow', type='char'}
local overflowCPU = ffi.new'char[1]'

env:kernel{
	argsOut = {buffer},
	body = template([[
	if (i.x == size.x / 2 && i.y == size.y / 2) {
		buffer[index] = <?=initValue?>;
	} else {
		buffer[index] = 0;
	}
]],	{
		initValue = initValue,
	}),
}()

local iterate = env:kernel{
	argsOut = {nextBuffer, overflow},
	argsIn = {buffer},
	body = require 'template'([[
	<?=toppleType?> lastb = buffer[index];
	global <?=toppleType?>* nextb = nextBuffer + index;
	*nextb = lastb;
	if (lastb >= <?=modulo?>) *overflow = 1;
	*nextb %= <?=modulo?>;
	<? for side=0,1 do ?>{
		if (i.s<?=side?> > 0) {
			*nextb += buffer[index - stepsize.s<?=side?>] / <?=modulo?>;
		}
		if (i.s<?=side?> < size.s<?=side?>-1) {
			*nextb += buffer[index + stepsize.s<?=side?>] / <?=modulo?>;
		}
	}<? end ?>
]], {
	toppleType = toppleType,
	modulo = modulo,
}),
}
iterate:compile()

local startTime = os.clock()
local iter = 1
while true do
	overflow:fill(0)
	-- read from 'buffer', write to 'nextBuffer'
	iterate.obj:setArg(0, nextBuffer.obj)
	iterate.obj:setArg(2, buffer.obj)
	iterate()
	buffer, nextBuffer = nextBuffer, buffer
	-- swap so now 'buffer' has the right data
	overflow:toCPU(overflowCPU)
	if overflowCPU[0] == 0 then break end
	iter = iter + 1
end
local time = os.clock() - startTime
print(time..' seconds')
print(iter..' iterations')

local colors = {
	vec3ub(0,0,0),
	vec3ub(0,255,255),
	vec3ub(255,255,0),
	vec3ub(255,0,0),
}

local bufferCPU = buffer:toCPU()
require 'image'(
	tonumber(env.base.size.x),
	tonumber(env.base.size.y),
	3,
	'unsigned char',
	function(x,y)
		local value = bufferCPU[x + env.base.size.x * y]
		value = value % modulo
		return colors[value+1]:unpack()
	end):save'output.gpu.png'
