#!/usr/bin/env lua
require 'ext'

if not os.fileexists'results.txt' then
	print('no results found -- performing performance test')
	os.execute('./test.lua')
end

require 'gnuplot'{
	output = 'results.png',
	style = 'data linespoints',
	log = 'xy',
	title = 'Performance',
	xlabel = 'initial stack size',
	ylabel = 'time to compute (seconds)',
	{datafile='results.txt', using='1:2', title='CPU'},
	{datafile='results.txt', using='1:3', title='GPU'},
}
