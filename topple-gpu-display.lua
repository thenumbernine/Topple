#!/usr/bin/env luajit
local ffi = require 'ffi'
local vec3ub = require 'ffi.vec.vec3ub'
local template = require 'template'

local toppleType = 'int'

local modulo = 4
local initValue = arg[1] or '1<<10'
local gridsize = assert(tonumber(arg[2] or 1001))

local env = require 'cl.obj.env'{size = {gridsize, gridsize}}
local buffer = env:buffer{name='buffer', type=toppleType}
local nextBuffer = env:buffer{name='nextBuffer', type=toppleType}
local bufferCPU = ffi.new(toppleType..'[?]', env.base.volume)

local overflow = env:buffer{size=1, name='overflow', type='char'}
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

local iterKernel = env:kernel{
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
iterKernel:compile()

local function iterate()
	overflow:fill(0)
	-- read from 'buffer', write to 'nextBuffer'
	iterKernel.obj:setArg(0, nextBuffer.obj)
	iterKernel.obj:setArg(2, buffer.obj)
	iterKernel()
	buffer, nextBuffer = nextBuffer, buffer
	-- swap so now 'buffer' has the right data
	overflow:toCPU(overflowCPU)
	return overflowCPU[0] == 0
end

-- [[ show progress?
local gl = require 'ffi.OpenGL'
local sdl = require 'ffi.sdl'
local GLApp = require 'glapp'
local class = require 'ext.class'
local table = require 'ext.table'
local vec2 = require 'vec.vec2'
local App = class(GLApp)
local tex, grad
local mouse = require 'gui.mouse'()
function App:initGL()
	assert(toppleType == 'int')

	grad = require 'gl.hsvtex'(256)
	
	tex = require 'gl.tex2d'{
		width = 1024,
		height = 1024,
		-- toppleType is 32 bits of integer
		-- so the texture will hold 8,8,8,8 RGBA
		-- and only the 1st channel will hold anything relevant
		-- This way I don't have to modulo each pixel or strip channels when copying.
		internalFormat = gl.GL_RGBA,
		format = gl.GL_RGBA,
		type = gl.GL_UNSIGNED_BYTE,
		minFilter = gl.GL_NEAREST,
		magFilter = gl.GL_NEAREST,
		wrap = {
			s = gl.GL_REPEAT,
			t = gl.GL_REPEAT,
		},
	}
	tex:unbind()

	shader = require 'gl.program'{
		vertexCode = [[
varying vec2 tc;
void main() {
	gl_Position = ftransform();
	tc = gl_MultiTexCoord0.st;
}
]],
		fragmentCode = template([[
varying vec2 tc;
uniform sampler2D tex;
uniform sampler1D grad;
void main() {
	vec3 toppleColor = texture2D(tex, tc).rgb;
	float value = toppleColor.r * <?=clnumber(256 / modulo)?>;
	gl_FragColor = texture1D(grad, value);
}
]],			{
				clnumber = require 'cl.obj.number',
				modulo = modulo,
			}
		),
		uniforms = {
			'tex',
			'grad',
		},
	}
	shader:use()
	gl.glUniform1i(shader.uniforms.tex, 0)
	gl.glUniform1i(shader.uniforms.grad, 1)
	
	tex:bind(0)
	grad:bind(1)

	require 'gl.report' 'here'
end
local iteration = 1
local leftShiftDown
local rightShiftDown 
local zoomFactor = .9
local zoom = 1
local viewPos = vec2(0,0)
function App:update()
	mouse:update()
	if mouse.leftDragging then
		if leftShiftDown or rightShiftDown then
			zoom = zoom * math.exp(10 * mouse.deltaPos[2])
		else
			local ar = self.width / self.height
			viewPos = viewPos - vec2(mouse.deltaPos[1] * ar, mouse.deltaPos[2]) * 2
		end
	end
	
	gl.glClear(bit.bor(gl.GL_COLOR_BUFFER_BIT, gl.GL_DEPTH_BUFFER_BIT))
	
	local ar = self.width / self.height
	gl.glMatrixMode(gl.GL_PROJECTION)
	gl.glLoadIdentity()
	gl.glOrtho(-ar, ar, -1, 1, -1, 1)

	gl.glMatrixMode(gl.GL_MODELVIEW)
	gl.glLoadIdentity()
	gl.glTranslated(-viewPos[1], -viewPos[2], 0)
	gl.glScaled(zoom, zoom, 1)

	iterate()
	buffer:toCPU(bufferCPU)
	gl.glActiveTexture(gl.GL_TEXTURE0)
	gl.glTexSubImage2D(gl.GL_TEXTURE_2D, 0, 0, 0, gridsize, gridsize, gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, bufferCPU)

	gl.glBegin(gl.GL_TRIANGLE_STRIP)
	for _,v in ipairs{{0,0},{1,0},{0,1},{1,1}} do
		gl.glTexCoord2d(v[1] * gridsize / 1024, v[2] * gridsize / 1024)
		gl.glVertex2d(v[1]*2-1, v[2]*2-1)
	end
	gl.glEnd()
end
function App:event(event)
	if event.type == sdl.SDL_MOUSEBUTTONDOWN then
		if event.button.button == sdl.SDL_BUTTON_WHEELUP then
			zoom = zoom * zoomFactor
		elseif event.button.button == sdl.SDL_BUTTON_WHEELDOWN then
			zoom = zoom / zoomFactor
		end
	elseif event.type == sdl.SDL_KEYDOWN or event.type == sdl.SDL_KEYUP then
		if event.key.keysym.sym == sdl.SDLK_LSHIFT then
			leftShiftDown = event.type == sdl.SDL_KEYDOWN
		elseif event.key.keysym.sym == sdl.SDLK_RSHIFT then
			rightShiftDown = event.type == sdl.SDL_KEYDOWN
		end
	end
end
App():run()
--]]

--[[ output results?
local colors = {
	vec3ub(0,0,0),
	vec3ub(0,255,255),
	vec3ub(255,255,0),
	vec3ub(255,0,0),
}

buffer:toCPU(bufferCPU)
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
--]]
