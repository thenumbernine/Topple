#!/usr/bin/env luajit
local ffi = require 'ffi'
local template = require 'template'

local modulo = 4
local initValue = tonumber(arg[1] or bit.lshift(1,10))
local gridsize = assert(tonumber(arg[2] or 1024))

--[=[
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
	toppleType = 'int',
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
--]=]

-- [[ show progress?
local gl = require 'ffi.OpenGL'
local sdl = require 'ffi.sdl'
local GLApp = require 'glapp'
local class = require 'ext.class'
local table = require 'ext.table'
local vec2 = require 'vec.vec2'
local GLProgram = require 'gl.program'
local App = class(GLApp)
local grad
local pingpong
local updateShader
local displayShader
local mouse = require 'gui.mouse'()
function App:initGL()
	local bufferCPU = ffi.new('int[?]', gridsize * gridsize)
	ffi.fill(bufferCPU, ffi.sizeof'int' * gridsize * gridsize)
	bufferCPU[bit.rshift(gridsize,1) + gridsize * bit.rshift(gridsize,1)] = initValue

	pingpong = require 'gl.pingpong'{
		width = gridsize,
		height = gridsize,
		internalFormat = gl.GL_RGBA,
		format = gl.GL_RGBA,
		type = gl.GL_UNSIGNED_BYTE,
		minFilter = gl.GL_NEAREST,
		magFilter = gl.GL_NEAREST,
		wrap = {
			s = gl.GL_REPEAT,
			t = gl.GL_REPEAT,
		},
		data = bufferCPU,
	}

	grad = require 'gl.hsvtex'(256)

	updateShader = GLProgram{
		vertexCode = [[
varying vec2 tc;
void main() {
	tc = gl_MultiTexCoord0.st;
	gl_Position = ftransform();
}
]],
		fragmentCode = template([[
varying vec2 tc;
uniform sampler2D tex;
void main() {
	const float du = <?=du?>;
	vec4 last = texture2D(tex, tc);
	vec4 next = last;
	next = vec4(mod(next.r, 4./256.), 0., 0., 0.);
	next += texture2D(tex, tc + vec2(du, 0));
	next += texture2D(tex, tc + vec2(-du, 0));
	next += texture2D(tex, tc + vec2(0, du));
	next += texture2D(tex, tc + vec2(0, -du));
	
	next.gba += floor(next.rgb) * (1. / 256.);
	next = mod(next, 1.);
	
	gl_FragColor = next;
}
]],			{
				du = 1 / gridsize,
			}),
	}

	displayShader = GLProgram{
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
	displayShader:use()
	gl.glUniform1i(displayShader.uniforms.tex, 0)
	gl.glUniform1i(displayShader.uniforms.grad, 1)
	displayShader:useNone()

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
	
	pingpong:draw{
		viewport = {0, 0, gridsize, gridsize},
		resetProjection = true,
		shader = updateShader,
		texs = {pingpong:prev()},
		callback = function()
			gl.glBegin(gl.GL_TRIANGLE_STRIP)
			for _,v in ipairs{{0,0},{1,0},{0,1},{1,1}} do
				gl.glTexCoord2d(v[1], v[2])
				gl.glVertex2d(v[1]*2-1, v[2]*2-1)
			end
			gl.glEnd()
		end,
	}
	pingpong:swap()
	iteration = iteration + 1

	local ar = self.width / self.height
	gl.glMatrixMode(gl.GL_PROJECTION)
	gl.glLoadIdentity()
	gl.glOrtho(-ar, ar, -1, 1, -1, 1)

	gl.glMatrixMode(gl.GL_MODELVIEW)
	gl.glLoadIdentity()
	gl.glTranslated(-viewPos[1], -viewPos[2], 0)
	gl.glScaled(zoom, zoom, 1)

	gl.glClear(bit.bor(gl.GL_COLOR_BUFFER_BIT, gl.GL_DEPTH_BUFFER_BIT))
	displayShader:use()
	pingpong:cur():bind(0)
	grad:bind(1)
	gl.glBegin(gl.GL_TRIANGLE_STRIP)
	for _,v in ipairs{{0,0},{1,0},{0,1},{1,1}} do
		gl.glTexCoord2d(v[1], v[2])
		gl.glVertex2d(v[1]*2-1, v[2]*2-1)
	end
	gl.glEnd()
	displayShader:useNone()
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
local vec3ub = require 'ffi.vec.vec3ub'
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
