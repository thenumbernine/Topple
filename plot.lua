#!/usr/bin/env lua
require 'ext'

if not io.fileexists'results.txt' then
	print('no results found -- performing performance test')
	os.execute('./test.lua')
end

require 'gnuplot'{
	output = 'results.png',
	style = 'data linespoints',
	log = 'xy',
	title = 'cpu vs gpu on a '..gridsize..' grid',
	{datafile='results.txt', using='1:2', title='CPU'},
	{datafile='results.txt', using='1:3', title='GPU'},
}
