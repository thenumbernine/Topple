#!/usr/bin/env luajit
local ffi = require 'ffi'
local gl = require 'gl'
local ig = require 'imgui'
local sdl = require 'sdl'
local vec3ub = require 'vec-ffi.vec3ub'
local table = require 'ext.table'
local vec2d = require 'vec-ffi.vec2d'
local CLEnv = require 'cl.obj.env'
local clnumber = require 'cl.obj.number'
local GLTex2D = require 'gl.tex2d'
local GLTex3D = require 'gl.tex3d'
local GLProgram = require 'gl.program'
local GLSceneObject = require 'gl.sceneobject'
local template = require 'template'
local Image = require 'image'

local toppleType = 'int'

local modulo = 6
initValue = 1
drawValue = 25
local gridsize = assert(tonumber(arg[2] or 256))

local env, buffer, nextBuffer
local iterKernel, doubleKernel, convertToTex

-- if GL sharing is enabled then this isn't needed ...
-- except for drawing ... which could be done in GL as well ...
local bufferCPU

local totalSand = 0

local function reset()
	ffi.fill(bufferCPU, ffi.sizeof(toppleType) * gridsize * gridsize * gridsize)
	bufferCPU[bit.rshift(gridsize,1) + gridsize * (bit.rshift(gridsize,1) + gridsize * bit.rshift(gridsize,1))] = initValue
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

local App = require 'imgui.appwithorbit'()

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
	env = CLEnv{
		verbose = true,
		useGLSharing = false,
		getPlatform = CLEnv.getPlatformFromCmdLine(table.unpack(arg)),
		getDevices = CLEnv.getDevicesFromCmdLine(table.unpack(arg)),
		deviceType = CLEnv.getDeviceTypeFromCmdLine(table.unpack(arg)),
		size = {gridsize, gridsize, gridsize},
	}

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
	}:unbind()

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
	}:unbind()

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
		version = 'latest',
		header = 'precision highp float;',
		vertexCode = [[
in vec3 vertex;
out vec3 tcv;
uniform mat4 mvProjMat;
void main() {
	gl_Position = mvProjMat * vec4(vertex * 2. - 1., 1.);
	tcv = vertex;
}
]],
		fragmentCode = template([[
in vec3 tcv;
out vec4 fragColor;
uniform sampler3D tex;
uniform sampler2D grad;
uniform float alpha;
void main() {
	vec3 toppleColor = texture(tex, tcv).rgb;
	float value = toppleColor.r * <?=clnumber(256 / modulo)?>;
	fragColor = texture(grad, vec2(value + <?=clnumber(.5 / modulo)?>, .5));
	fragColor.a *= alpha;
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
	}:useNone()

	local vertexesInQuad = {
		{0,0},{1,0},{0,1},
		{1,1},{0,1},{1,0},
	}
	self.drawSceneObjs = {}
	for fwddir=1,3 do
		self.drawSceneObjs[fwddir] = {}
		for sign=-1,1,2 do
			local numslices = gridsize
			local n = numslices
			local jmin, jmax, jdir
			if sign < 0 then
				jmin, jmax, jdir = 0, n, 1
			else
				jmin, jmax, jdir = n, 0, -1
			end

			local vertexes = table()
			for j=jmin,jmax,jdir do
				local f = (j+.5)/n
				for _,vtx in ipairs(vertexesInQuad) do
					if fwddir == 1 then
						vertexes:append{f, vtx[1], vtx[2]}
					elseif fwddir == 2 then
						vertexes:append{vtx[1], f, vtx[2]}
					elseif fwddir == 3 then
						vertexes:append{vtx[1], vtx[2], f}
					end
				end
			end
			self.drawSceneObjs[fwddir][sign] = GLSceneObject{
				program = shader,
				vertexes = {
					data = vertexes,
					count = #vertexes / 3,
					dim = 3,
				},
				geometry = {
					mode = gl.GL_TRIANGLES,
				},
			}
		end
	end
end

alpha = .1
function App:update()
	local ar = self.width / self.height

	--[[
	local canHandleMouse = not ig.igGetIO()[0].WantCaptureMouse
	if canHandleMouse then
		local zoom = (self.view.pos - self.view.orbit):length()
		if self.mouse.rightDown then
			buffer:toCPU(bufferCPU)

			local pos = (self.mouse.pos - vec2d(.5, .5)) * (2 / zoom)
			pos.x = pos.x * ar
			pos = ((pos + self.view.pos) * .5 + vec2d(.5, .5)) * gridsize
			local curX = math.floor(pos.x + .5)
			local curY = math.floor(pos.y + .5)

			local lastPos = (self.mouse.lastPos - vec2d(.5, .5)) * (2 / zoom)
			lastPos.x = lastPos.x * ar
			lastPos = ((lastPos + self.view.pos) * .5 + vec2d(.5, .5)) * gridsize
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
					if self.leftShiftDown or self.rightShiftDown then
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
	tex:unbind()

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

	local sceneobj = self.drawSceneObjs[fwddir][fwd.s[fwddir-1] < 0 and -1 or 1]
	sceneobj.texs[1] = tex
	sceneobj.texs[2] = grad
	sceneobj.uniforms.alpha = alpha
	sceneobj.uniforms.mvProjMat = self.view.mvProjMat.ptr
	sceneobj:draw()
	--]]
	gl.glDisable(gl.GL_DEPTH_TEST)

	App.super.update(self)
end

function App:updateGUI()
	ig.igText('total sand: '..totalSand)

	ig.luatableInputInt('initial value', _G, 'initValue')
	ig.luatableInputInt('draw value', _G, 'drawValue')
	ig.luatableInputFloat('alpha', _G, 'alpha')

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

return App():run()
