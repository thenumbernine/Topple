#!/usr/bin/env luajit
local ffi = require 'ffi'
local gl = require 'gl'
local ig = require 'imgui'
local sdl = require 'ffi.req' 'sdl'
local vec3ub = require 'vec-ffi.vec3ub'
local ImGuiApp = require 'imguiapp'
local class = require 'ext.class'
local table = require 'ext.table'
local vec2 = require 'vec.vec2'
local Mouse = require 'glapp.mouse'
local CLEnv = require 'cl.obj.env'
local clnumber = require 'cl.obj.number'
local GLTex2D = require 'gl.tex2d'
local GLProgram = require 'gl.program'
local glreport = require 'gl.report'
local template = require 'template'
local Image = require 'image'

local toppleType = 'int'

local modulo = 4
initValue = 1
drawValue = 25
local gridsize = assert(tonumber(arg[2] or 1024))

local env, buffer, nextBuffer
local iterKernel, doubleKernel, convertToTex

-- if GL sharing is enabled then this isn't needed ... 
-- except for drawing ... which could be done in GL as well ...
local bufferCPU	

local totalSand = 0

local function reset()
	ffi.fill(bufferCPU, ffi.sizeof(toppleType) * gridsize * gridsize)
	bufferCPU[bit.rshift(gridsize,1) + gridsize * bit.rshift(gridsize,1)] = initValue
	buffer:fromCPU(bufferCPU)
	totalSand = initValue
end

local function double()
	doubleKernel(buffer)
	totalSand = totalSand * 2
end

local function iterate()
	-- read from 'buffer', write to 'nextBuffer'
	iterKernel.obj:setArg(0, nextBuffer.obj)
	iterKernel.obj:setArg(1, buffer.obj)
	iterKernel()
	-- swap so now 'buffer' has the right data
	buffer, nextBuffer = nextBuffer, buffer
end

local mouse = Mouse()

local App = class(ImGuiApp)

local colors = {
	vec3ub(0,0,0),
	vec3ub(0,255,255),
	vec3ub(255,255,0),
	vec3ub(255,0,0),
}
assert(#colors == modulo)

local tex, grad, shader
local texCLMem

local texsize = 1024
assert(texsize >= gridsize)

function App:initGL()
	App.super.initGL(self)

	-- init env after GL init to get GL sharing access
	env = CLEnv{size = {gridsize, gridsize}}

	buffer = env:buffer{name='buffer', type=toppleType}
	nextBuffer = env:buffer{name='nextBuffer', type=toppleType}
	bufferCPU = ffi.new(toppleType..'[?]', env.base.volume)

	iterKernel  = env:kernel{
		argsOut = {nextBuffer},
		argsIn = {buffer},
		body = template([[
	<?=toppleType?> lastb = buffer[index];
	global <?=toppleType?>* nextb = nextBuffer + index;
	*nextb = lastb;
	*nextb %= <?=modulo?>;
	<? for side=0,1 do ?>{
		if (i.s<?=side?> > 0) {
			*nextb += buffer[index - stepsize.s<?=side?>] / <?=modulo?>;
		}
		if (i.s<?=side?> < size.s<?=side?>-1) {
			*nextb += buffer[index + stepsize.s<?=side?>] / <?=modulo?>;
		}
	}<? end ?>
]], 	{
			toppleType = toppleType,
			modulo = modulo,
		}),
	}
	iterKernel:compile()

	doubleKernel = env:kernel{
		argsOut = {buffer},
		body = [[
	buffer[index] <<= 1;
]],
	}

	reset()

	gl.glClearColor(.2, .2, .2, 0)

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

	tex = GLTex2D{
		width = texsize,
		height = texsize,
		-- toppleType is 32 bits of integer
		-- so the texture will hold 8,8,8,8 RGBA
		-- and only the 1st channel will hold anything relevant
		-- This way I don't have to modulo each pixel or strip channels when copying.
		
		internalFormat = gl.GL_RGBA,
		type = gl.GL_UNSIGNED_BYTE,
		
		--internalFormat = gl.GL_RGBA32F,
		--type = gl.GL_FLOAT,
		
		format = gl.GL_RGBA,
		minFilter = gl.GL_NEAREST,
		magFilter = gl.GL_NEAREST,
		wrap = {
			s = gl.GL_REPEAT,
			t = gl.GL_REPEAT,
		},
	}
	tex:unbind()
	
	if env.useGLSharing then 
		local CLImageGL = require 'cl.imagegl'
		texCLMem = CLImageGL{context=env.ctx, tex=tex, write=true}

		convertToTex = env:kernel{
			argsOut = {{name='tex', obj=texCLMem.obj, type='__write_only image2d_t'}},
			argsIn = {{name='buffer', obj=buffer.obj, type='uchar4'}},
			body = [[
	write_imagef(tex, i.xy, (float4)(
		(float)buffer[index].s0 / 255.,
		(float)buffer[index].s1 / 255.,
		(float)buffer[index].s2 / 255.,
		(float)buffer[index].s3 / 255.));
]]
		}	
		convertToTex:compile()
		convertToTex.obj:setArgs(texCLMem, buffer)
	end

	shader = GLProgram{
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
uniform sampler2D grad;
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

local iteration = 1
local leftShiftDown
local rightShiftDown 
local zoomFactor = .9
local zoom = 1
local viewPos = vec2(0,0)
function App:update()
	local ar = self.width / self.height
	
	local canHandleMouse = not ig.igGetIO()[0].WantCaptureMouse
	if canHandleMouse then 
		mouse:update()
		if mouse.leftDown then
			buffer:toCPU(bufferCPU)
			
			local pos = (vec2(mouse.pos:unpack()) - vec2(.5, .5)) * (2 / zoom)
			pos[1] = pos[1] * ar
			pos = ((pos + viewPos) * .5 + vec2(.5, .5)) * gridsize
			local curX = math.floor(pos[1] + .5)
			local curY = math.floor(pos[2] + .5)
			
			local lastPos = (vec2(mouse.lastPos:unpack()) - vec2(.5, .5)) * (2 / zoom)
			lastPos[1] = lastPos[1] * ar
			lastPos = ((lastPos + viewPos) * .5 + vec2(.5, .5)) * gridsize
			local lastX = math.floor(lastPos[1] + .5)
			local lastY = math.floor(lastPos[2] + .5)
		
			local dx = curX - lastX
			local dy = curY - lastY
			local ds = math.ceil(math.max(math.abs(dx), math.abs(dy), 1))
			for s=0,ds do
				local f = s/ds
				local x = math.floor(lastX + dx * f + .5)
				local y = math.floor(lastY + dy * f + .5)
			
				if x >= 0 and x < gridsize and y >= 0 and y < gridsize then
					local ptr = bufferCPU + (x + gridsize * y)
					if leftShiftDown or rightShiftDown then
						local oldValue = ptr[0]
						ptr[0] = math.max(0, ptr[0] - drawValue)
						totalSand = totalSand + (ptr[0] - oldValue)
					else
						ptr[0] = ptr[0] + drawValue
						totalSand = totalSand + drawValue
					end
				end
			end
					
			buffer:fromCPU(bufferCPU)
		end
		if mouse.rightDragging then
			if leftShiftDown or rightShiftDown then
				zoom = zoom * math.exp(10 * mouse.deltaPos.y)
			else
				viewPos = viewPos - vec2(mouse.deltaPos.x * ar, mouse.deltaPos.y) * (2 / zoom)
			end
		end
	end

	gl.glClear(bit.bor(gl.GL_COLOR_BUFFER_BIT, gl.GL_DEPTH_BUFFER_BIT))
	
	gl.glMatrixMode(gl.GL_PROJECTION)
	gl.glLoadIdentity()
	gl.glOrtho(-ar, ar, -1, 1, -1, 1)

	gl.glMatrixMode(gl.GL_MODELVIEW)
	gl.glLoadIdentity()
	gl.glScaled(zoom, zoom, 1)
	gl.glTranslated(-viewPos[1], -viewPos[2], 0)

	iterate()
	
	tex:bind(0)
	if env.useGLSharing then 
		env.cmds:enqueueAcquireGLObjects{objs={texCLMem}}
		convertToTex()
		env.cmds:enqueueReleaseGLObjects{objs={texCLMem}}
	else
		buffer:toCPU(bufferCPU)
		gl.glTexSubImage2D(gl.GL_TEXTURE_2D, 0, 0, 0, gridsize, gridsize, gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, bufferCPU)
	end
	
	shader:use()
	grad:bind(1)

	gl.glBegin(gl.GL_TRIANGLE_STRIP)
	for _,v in ipairs{{0,0},{1,0},{0,1},{1,1}} do
		gl.glTexCoord2d(v[1] * gridsize / texsize, v[2] * gridsize / texsize)
		gl.glVertex2d(v[1]*2-1, v[2]*2-1)
	end
	gl.glEnd()

	grad:unbind(1)
	tex:unbind(0)
	shader:useNone()

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
		buffer:toCPU(bufferCPU)
		Image(gridsize, gridsize, 3, 'unsigned char', function(x,y)
				local value = bufferCPU[x + env.base.size.x * y]
				value = value % modulo
				return colors[value+1]:unpack()
		end):save'output.gpu.png'
	end

	ig.igSameLine()
	
	if ig.igButton'Load' then
		local image = Image'output.gpu.png'
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
		buffer:fromCPU(bufferCPU)
	end

	ig.igSameLine()
	
	if ig.igButton'Reset' then
		reset()
	end

	ig.igSameLine()

	if ig.igButton'Double' then
		double()
	end
end

App():run()
