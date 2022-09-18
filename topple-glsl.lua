#!/usr/bin/env luajit
local ffi = require 'ffi'
local sdl = require 'ffi.sdl'
local ig = require 'imgui'
local gl = require 'gl'
local ImGuiApp = require 'imguiapp'	-- on windows, imguiapp needs to be before ig...
local vec3ub = require 'vec-ffi.vec3ub'
local class = require 'ext.class'
local table = require 'ext.table'
local vec2 = require 'vec.vec2'
local GLProgram = require 'gl.program'
local HSVTex = require 'gl.hsvtex'
local PingPong = require 'gl.pingpong'
local glreport = require 'gl.report'
local GLTex2D = require 'gl.tex2d'
local template = require 'template'
local Image = require 'image'
-- isle of misfits:
local clnumber = require 'cl.obj.number'
local Mouse = require 'glapp.mouse'

local modulo = 4
-- there's a bug with using more than 1<<16, so the 'b' and 'a' channels have something wrong in their math
initValue = bit.lshift(1,tonumber(arg[1]) or 17)
drawValue = 25
local gridsize = assert(tonumber(arg[2] or 1024))

local App = class(ImGuiApp)
local grad
local pingpong
local updateShader
local displayShader
local mouse = Mouse()
	
local bufferCPU = ffi.new('int[?]', gridsize * gridsize)

local colors = {
	vec3ub(0,0,0),
	vec3ub(0,255,255),
	vec3ub(255,255,0),
	vec3ub(255,0,0),
}

local totalSand = 0

local function reset()
	ffi.fill(bufferCPU, ffi.sizeof'int' * gridsize * gridsize)
	bufferCPU[bit.rshift(gridsize,1) + gridsize * bit.rshift(gridsize,1)] = initValue
	pingpong:prev():bind(0)
	gl.glTexSubImage2D(gl.GL_TEXTURE_2D, 0, 0, 0, gridsize, gridsize, gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, bufferCPU)
	pingpong:prev():unbind(0)
	totalSand = initValue
end

function App:initGL()
	App.super.initGL(self)

	gl.glClearColor(.2, .2, .2, 0)

	pingpong = PingPong{
		width = gridsize,
		height = gridsize,
		internalFormat = gl.GL_RGBA8,
		format = gl.GL_RGBA,
		type = gl.GL_UNSIGNED_BYTE,
		minFilter = gl.GL_NEAREST,
		magFilter = gl.GL_NEAREST,
		wrap = {
			s = gl.GL_REPEAT,
			t = gl.GL_REPEAT,
		}
	}
	reset()

	grad = GLTex2D{
		width = modulo,
		height = 1,
		internalFormat = gl.GL_RGB,
		format = gl.GL_RGB,
		type = gl.GL_UNSIGNED_BYTE,
		minFilter = gl.GL_NEAREST,
		magFilter = gl.GL_NEAREST,
		wrap = {
			s = gl.GL_REPEAT,
			t = gl.GL_REPEAT,
		},
		data = ffi.new('unsigned char[12]', {
			colors[1].x, colors[1].y, colors[1].z,
			colors[2].x, colors[2].y, colors[2].z,
			colors[3].x, colors[3].y, colors[3].z,
			colors[4].x, colors[4].y, colors[4].z,
		}),
	}
	grad:bind(1)

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
	v /= modulo;	//perform fixed division
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
	next.g += floor(next.r) / 256.;
	next.b += floor(next.g) / 256.;
	next.a += floor(next.b) / 256.;
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
			tex = 0,
		},
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
uniform sampler2D tex, grad;
void main() {
	vec3 toppleColor = texture2D(tex, tc).rgb;
	float value = toppleColor.r * <?=clnumber(256 / modulo)?>;
	gl_FragColor = texture2D(grad, vec2(value + <?=clnumber(.5 / modulo)?>, .5));
}
]],			{
				clnumber = clnumber,
				modulo = modulo,
			}
		),
		uniforms = {
			tex = 0,
			grad = 1,
		},
	}

	glreport 'here'
end

local leftShiftDown
local rightShiftDown 
local zoomFactor = .9
local zoom = 1
local viewPos = vec2(0,0)

local value = ffi.new('int[1]', 0)
function App:update()
	local ar = self.width / self.height
	
	local canHandleMouse = not ig.igGetIO()[0].WantCaptureMouse
	if canHandleMouse then 
		mouse:update()
		if mouse.leftDown then
			local pos = (vec2(mouse.pos:unpack()) - vec2(.5, .5)) * (2 / zoom)
			pos[1] = pos[1] * ar
			pos = ((pos + viewPos) * .5 + vec2(.5, .5)) * gridsize
			local x = math.floor(pos[1] + .5)
			local y = math.floor(pos[2] + .5)
			if x >= 0 and x < gridsize and y >= 0 and y < gridsize then
				pingpong:draw{
					callback = function()
						gl.glReadPixels(x, y, 1, 1, gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, value)
						value[0] = value[0] + drawValue
					end,
				}
				pingpong:prev():bind(0)
				gl.glTexSubImage2D(gl.GL_TEXTURE_2D, 0, x, y, 1, 1, gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, value)
				pingpong:prev():unbind(0)
				totalSand = totalSand + drawValue
			end
		end
		if mouse.rightDragging then
			if leftShiftDown or rightShiftDown then
				zoom = zoom * math.exp(10 * mouse.deltaPos.y)
			else
				viewPos = viewPos - vec2(mouse.deltaPos.x * ar, mouse.deltaPos.y) * (2 / zoom)
			end
		end
	end

	-- update
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

	gl.glMatrixMode(gl.GL_PROJECTION)
	gl.glLoadIdentity()
	gl.glOrtho(-ar, ar, -1, 1, -1, 1)

	gl.glMatrixMode(gl.GL_MODELVIEW)
	gl.glLoadIdentity()
	gl.glScaled(zoom, zoom, 1)
	gl.glTranslated(-viewPos[1], -viewPos[2], 0)

	gl.glClear(bit.bor(gl.GL_COLOR_BUFFER_BIT, gl.GL_DEPTH_BUFFER_BIT))
	displayShader:use()
	pingpong:cur():bind(0)
	gl.glBegin(gl.GL_TRIANGLE_STRIP)
	for _,v in ipairs{{0,0},{1,0},{0,1},{1,1}} do
		gl.glTexCoord2d(v[1], v[2])
		gl.glVertex2d(v[1]*2-1, v[2]*2-1)
	end
	gl.glEnd()
	pingpong:cur():unbind(0)
	
	GLProgram:useNone()
	App.super.update(self)
end

function App:event(event, eventPtr)
	App.super.event(self, event, eventPtr)
	local canHandleMouse = not ig.igGetIO()[0].WantCaptureMouse
	local canHandleKeyboard = not ig.igGetIO()[0].WantCaptureKeyboard

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

function App:updateGUI()
	ig.igText('total sand: '..totalSand)
	
	ig.luatableInputInt('initial value', _G, 'initValue')
	ig.luatableInputInt('draw value', _G, 'drawValue')
	
	if ig.igButton'Save' then
		pingpong:prev():bind(0)	-- prev? shouldn't this be cur?
		gl.glGetTexImage(gl.GL_TEXTURE_2D, 0, gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, bufferCPU)
		pingpong:prev():unbind(0)
		Image(gridsize, gridsize, 3, 'unsigned char', function(x,y)
			local value = bufferCPU[x + gridsize * y]
			value = value % modulo
			return colors[value+1]:unpack()
		end):save'output.glsl.png'
	end

	ig.igSameLine()

	if ig.igButton'Load' then
		local image = Image'output.glsl.png'
		assert(image.width == gridsize)
		assert(image.height == gridsize)
		assert(image.channels == 3)
		for y=0,image.height-1 do
			for x=0,image.width-1 do
				local rgb = image.buffer + 4 * (x + image.width * y)
				for i,color in ipairs(colors) do
					if rgb[0] == color.x
					and rgb[1] == color.y
					and rgb[2] == color.z
					then
						bufferCPU[x + gridsize * y] = i-1
						break
					end
					if i == #colors then
						error("unknown color")
					end
				end
			end
		end
		pingpong:prev():bind(0)
		gl.glTexSubImage2D(gl.GL_TEXTURE_2D, 0, 0, 0, gridsize, gridsize, gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, bufferCPU)
		pingpong:prev():unbind(0)
	end

	ig.igSameLine()
	
	if ig.igButton'Reset' then
		reset()
	end
end

App():run()
