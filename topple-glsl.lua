#!/usr/bin/env luajit
local ffi = require 'ffi'
local gl = require 'ffi.OpenGL'
local sdl = require 'ffi.sdl'
local GLApp = require 'glapp'
local class = require 'ext.class'
local table = require 'ext.table'
local vec2 = require 'vec.vec2'
local GLProgram = require 'gl.program'
local HSVTex = require 'gl.hsvtex'
local PingPong = require 'gl.pingpong'
local glreport = require 'gl.report'
local clnumber = require 'cl.obj.number'
local Mouse = require 'gui.mouse'
local template = require 'template'

local modulo = 4
local initValue = tonumber(arg[1] or bit.lshift(1,30))
local gridsize = assert(tonumber(arg[2] or 1024))

local App = class(GLApp)
local grad
local pingpong
local updateShader
local displayShader
local mouse = Mouse()
function App:initGL()
	local bufferCPU = ffi.new('int[?]', gridsize * gridsize)
	ffi.fill(bufferCPU, ffi.sizeof'int' * gridsize * gridsize)
	bufferCPU[bit.rshift(gridsize,1) + gridsize * bit.rshift(gridsize,1)] = initValue

	pingpong = PingPong{
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

	grad = HSVTex(256)

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

const float du = <?=clnumber(du)?>;
const float modulo = <?=clnumber(modulo)?>;

//divide by modulo
vec4 fixedShift(vec4 v) {
	vec4 r = mod(v, modulo / 256.);
	v -= r;	//remove lower bits
	v *= 1. / modulo;	//perform fixed division
	v.rgb += r.gba * (256. / modulo);	//add the remainder lower bits
	return v;
}

void main() {
	vec4 last = texture2D(tex, tc);
	
	//sum neighbors
	vec4 next = fixedShift(texture2D(tex, tc + vec2(du, 0)))
		+ fixedShift(texture2D(tex, tc + vec2(-du, 0)))
		+ fixedShift(texture2D(tex, tc + vec2(0, du)))
		+ fixedShift(texture2D(tex, tc + vec2(0, -du)));

	//add last cell modulo
	next.r += mod(last.r, modulo / 256.);
	
	//addition with overflow
	next.gba += floor(next.rgb) * (1. / 256.);
	next = mod(next, 1.);
	
	gl_FragColor = next;
}
]],			{
				clnumber = clnumber,
				du = 1 / gridsize,
				modulo = modulo,
			}
		),
		uniforms = {
			'tex',
		},
	}
	updateShader:use()
	gl.glUniform1i(updateShader.uniforms.tex, 0)
	updateShader:useNone()

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
				clnumber = clnumber,
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

	glreport 'here'
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

	-- [[
	pingpong:draw{
		viewport = {0, 0, gridsize, gridsize},
		resetProjection = true,
		shader = updateShader,
		texs = {pingpong:prev()},
		callback = function()
			gl.glBegin(gl.GL_TRIANGLE_STRIP)
			for _,v in ipairs{{0,0},{1,0},{0,1},{1,1}} do
				gl.glTexCoord2d(v[1], v[2])
				gl.glVertex2d(v[1], v[2])
			end
			gl.glEnd()
		end,
	}
	pingpong:swap()
	iteration = iteration + 1
	--]]

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
