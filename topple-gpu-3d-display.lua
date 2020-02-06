#!/usr/bin/env luajit
local ffi = require 'ffi'
local gl = require 'gl'
local ig = require 'ffi.imgui'
local sdl = require 'ffi.sdl'
local vec3ub = require 'vec-ffi.vec3ub'
local class = require 'ext.class'
local table = require 'ext.table'
local vec2d = require 'vec-ffi.vec2d'
local CLEnv = require 'cl.obj.env'
local clnumber = require 'cl.obj.number'
local GLTex2D = require 'gl.tex2d'
local GLTex3D = require 'gl.tex3d'
local GLProgram = require 'gl.program'
local glreport = require 'gl.report'
local template = require 'template'
local Image = require 'image'

local toppleType = 'int'

local modulo = 6
local initValue, drawValue
local gridsize = assert(tonumber(arg[2] or 256))

local env, buffer, nextBuffer
local iterKernel, doubleKernel, convertToTex

-- if GL sharing is enabled then this isn't needed ... 
-- except for drawing ... which could be done in GL as well ...
local bufferCPU	

local totalSand = 0

local function reset()
	ffi.fill(bufferCPU, ffi.sizeof(toppleType) * gridsize * gridsize * gridsize)
	bufferCPU[bit.rshift(gridsize,1) + gridsize * (bit.rshift(gridsize,1) + gridsize * bit.rshift(gridsize,1))] = initValue[0]
	buffer:fromCPU(bufferCPU)
	totalSand = initValue[0]
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

local App = class(require 'glapp.orbit'(require 'imguiapp'))

local colors = {
	vec3ub(0,0,0),
	vec3ub(0,255,255),
	vec3ub(255,255,0),
	vec3ub(255,0,255),
	vec3ub(255,0,0),
	vec3ub(0,255,0),
--	vec3ub(0,0,255),
}
assert(#colors == modulo)

local tex, grad, shader
local texCLMem

local texsize = gridsize
assert(texsize >= gridsize)

function App:initGL()
	App.super.initGL(self)

	-- init env after GL init to get GL sharing access
	env = CLEnv{size = {gridsize, gridsize, gridsize}}

	-- wait til after real is defined
	initValue = ffi.new(toppleType..'[1]', 1)
	drawValue = ffi.new(toppleType..'[1]', 25)
	
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
	<? for side=0,2 do ?>{
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

	gl.glClearColor(0,0,0,0)

	local graddata = ffi.new('unsigned char[?]', modulo * 4)
	for i=0,modulo-1 do
		graddata[0+4*i] = colors[i+1].x
		graddata[1+4*i] = colors[i+1].y
		graddata[2+4*i] = colors[i+1].z
		graddata[3+4*i] = i == 0 and 0 or 255
	end
	grad = GLTex2D{
		width = modulo,
		height = 1,
		internalFormat = gl.GL_RGBA,
		format = gl.GL_RGBA,
		type = gl.GL_UNSIGNED_BYTE,
		minFilter = gl.GL_NEAREST,
		magFilter = gl.GL_NEAREST,
		wrap = {
			s = gl.GL_REPEAT,
			t = gl.GL_REPEAT,
		},
		data = graddata,
	}

	tex = GLTex3D{
		width = texsize,
		height = texsize,
		depth = texsize,
		-- toppleType is 32 bits of integer
		-- so the texture will hold 8,8,8,8 RGBA
		-- and only the 1st channel will hold anything relevant
		-- This way I don't have to modulo each pixel or strip channels when copying.
		-- but there is a danger that the internal format doesn't store all bits accurately ...

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
			r = gl.GL_REPEAT,
		},
	}
	tex:unbind()

--[=[
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
--]=]

	shader = GLProgram{
		vertexCode = [[
varying vec3 tc;
void main() {
	gl_Position = ftransform();
	tc = gl_MultiTexCoord0.xyz;
}
]],
		fragmentCode = template([[
varying vec3 tc;
uniform sampler3D tex;
uniform sampler2D grad;
uniform float alpha;
void main() {
	vec3 toppleColor = texture3D(tex, tc).rgb;
	float value = toppleColor.r * <?=clnumber(256 / modulo)?>;
	gl_FragColor = texture2D(grad, vec2(value + <?=clnumber(.5 / modulo)?>, .5));
	gl_FragColor.a *= alpha;
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

local alpha = ffi.new('float[1]', .1)
local iteration = 1
local leftShiftDown
local rightShiftDown 
local zoomFactor = .9
local zoom = 1
local viewPos = vec2d(0,0)
function App:update()
	local ar = self.width / self.height

	--[[
	local canHandleMouse = not ig.igGetIO()[0].WantCaptureMouse
	if canHandleMouse then 
		self.mouse:update()
		if self.mouse.leftDown then
			buffer:toCPU(bufferCPU)
			
			local pos = (self.mouse.pos - vec2d(.5, .5)) * (2 / zoom)
			pos.x = pos.x * ar
			pos = ((pos + viewPos) * .5 + vec2d(.5, .5)) * gridsize
			local curX = math.floor(pos.x + .5)
			local curY = math.floor(pos.y + .5)
			
			local lastPos = (self.mouse.lastPos - vec2d(.5, .5)) * (2 / zoom)
			lastPos.x = lastPos.x * ar
			lastPos = ((lastPos + viewPos) * .5 + vec2d(.5, .5)) * gridsize
			local lastX = math.floor(lastPos.x + .5)
			local lastY = math.floor(lastPos.y + .5)
		
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
						ptr[0] = math.max(0, ptr[0] - drawValue[0])
						totalSand = totalSand + (ptr[0] - oldValue)
					else
						ptr[0] = ptr[0] + drawValue[0]
						totalSand = totalSand + drawValue[0]
					end
				end
			end
					
			buffer:fromCPU(bufferCPU)
		end
		if self.mouse.rightDragging then
			if leftShiftDown or rightShiftDown then
				zoom = zoom * math.exp(10 * self.mouse.deltaPos.y)
			else
				viewPos = viewPos - vec2d(self.mouse.deltaPos.x * ar, self.mouse.deltaPos.y) * (2 / zoom)
			end
		end
	end
	--]]

	gl.glClear(bit.bor(gl.GL_COLOR_BUFFER_BIT, gl.GL_DEPTH_BUFFER_BIT))

	self.view:setup(self.width/self.height)
	
	iterate()
	
	tex:bind(0)
	--[[
	if env.useGLSharing then 
		env.cmds:enqueueAcquireGLObjects{objs={texCLMem}}
		convertToTex()
		env.cmds:enqueueReleaseGLObjects{objs={texCLMem}}
	else --]] do
		buffer:toCPU(bufferCPU)
		
		for z=0,gridsize-1 do
			gl.glTexSubImage3D(gl.GL_TEXTURE_3D, 0, 0, 0, z, gridsize, gridsize, 1, gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, bufferCPU + gridsize * gridsize * z)
		end
	end
	
	shader:use()
	gl.glUniform1f(shader.uniforms.alpha.loc, alpha[0])
	grad:bind(1)

	--gl.glEnable(gl.GL_DEPTH_TEST)
	-- [[
	gl.glDisable(gl.GL_DEPTH_TEST)
	gl.glEnable(gl.GL_BLEND)
	gl.glBlendFunc(gl.GL_SRC_ALPHA, gl.GL_ONE_MINUS_SRC_ALPHA)
	--]]
	
	--[[ draw points
	gl.glPointSize(3)
	gl.glBegin(gl.GL_POINTS)
	for i=1,gridsize do
		for j=1,gridsize do
			for k=1,gridsize do
				gl.glTexCoord3d(
					(i-.5)/gridsize,
					(j-.5)/gridsize,
					(k-.5)/gridsize)
				gl.glVertex3d(
					2*(i-.5)/gridsize - 1,
					2*(j-.5)/gridsize - 1,
					2*(k-.5)/gridsize - 1)
			end
		end
	end
	gl.glEnd()
	--]]
	-- [[
	local numslices = gridsize
	local n = numslices
	local fwd = -self.view.angle:zAxis()
	local fwddir = select(2, table{fwd:unpack()}:map(math.abs):sup())
	local jmin, jmax, jdir
	if fwd.s[fwddir-1] < 0 then
		jmin, jmax, jdir = 0, n, 1
	else
		jmin, jmax, jdir = n, 0, -1
	end

	local vertexesInQuad = {{0,0},{1,0},{1,1},{0,1}}

	gl.glBegin(gl.GL_QUADS)
	for j=jmin,jmax,jdir do
		local f = (j+.5)/n
		for _,vtx in ipairs(vertexesInQuad) do
			if fwddir == 1 then
				gl.glTexCoord3f(f, vtx[1], vtx[2])
				gl.glVertex3f(2*f-1, 2*vtx[1]-1, 2*vtx[2]-1)
			elseif fwddir == 2 then
				gl.glTexCoord3f(vtx[1], f, vtx[2])
				gl.glVertex3f(2*vtx[1]-1, 2*f-1, 2*vtx[2]-1)
			elseif fwddir == 3 then
				gl.glTexCoord3f(vtx[1], vtx[2], f)
				gl.glVertex3f(2*vtx[1]-1, 2*vtx[2]-1, 2*f-1)
			end
		end
	end
	gl.glEnd()
	--]]
	gl.glDisable(gl.GL_DEPTH_TEST)

	grad:unbind(1)
	tex:unbind(0)
	shader:useNone()

	App.super.update(self)
end

--[[
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
--]]

function App:updateGUI()
	ig.igText('total sand: '..totalSand)
	
	ig.igInputInt('initial value', initValue)	
	ig.igInputInt('draw value', drawValue)
	ig.igInputFloat('alpha', alpha)

	if ig.igButton'Save' then
		buffer:toCPU(bufferCPU)
		Image(gridsize*gridsize, gridsize, 3, 'unsigned char', function(xz,y)
				local x = xz % gridsize
				local y = math.floor(xz / gridsize)
				local value = bufferCPU[x + gridsize * (y + gridsize * z)]
				value = value % modulo
				return colors[value+1]:unpack()
		end):save'output.gpu.png'
	end

	--[[
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
	--]]

	if ig.igButton'Reset' then
		reset()
	end

	ig.igSameLine()

	if ig.igButton'Double' then
		double()
	end
end

App():run()
