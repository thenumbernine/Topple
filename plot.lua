#!/usr/bin/env lua
require 'ext'

if not io.fileexists'results.txt' then
	print('no results found -- performing performance test')
	os.execute('./test.lua')
end

require 'gnuplot'{
	output = 'results.png',
	style = 'data linespoints',
	title = 'cpu vs gpu on a '..gridsize..' grid',
	data = {sizes, cputimes, gputimes},
	{using='1:2', title='CPU'},
	{using='1:3', title='GPU'},
}
