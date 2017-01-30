#!/usr/bin/env lua
require 'ext'
local gridsize = 1001

local sizes = table()
local cputimes = table()
local gputimes = table()

for i=10,15,.5 do
	local stacksize = math.floor(2^i)
	print('stacksize', stacksize)
	sizes:insert(stacksize)

	local results = io.readproc('dist/linux/release/Topple '..stacksize..' '..gridsize)
	local seconds, iterations = results:trim():match'([%d%.]+) seconds%s+(%d+) iterations'
	cputimes:insert(seconds)
	print('cpu seconds:', seconds)
	print('cpu iterations:', iterations)
	
	local results = io.readproc('./topple-gpu.lua '..stacksize..' '..gridsize)
	local seconds, iterations = results:trim():match'([%d%.]+) seconds%s+(%d+) iterations'
	gputimes:insert(seconds)
	print('gpu seconds:', seconds)
	print('gpu iterations:', iterations)
end

file['results.txt'] = range(#sizes):map(function(i)
	return table{sizes[i], cputimes[i], gputimes[i]}:concat'\t'
end):concat'\n'
