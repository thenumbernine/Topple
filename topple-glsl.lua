#!/usr/bin/env luajit
local ffi = require 'ffi'
local cmdline = require 'ext.cmdline'(...)
local template = require 'template'
local vec3ub = require 'vec-ffi.vec3ub'
local vec2d = require 'vec-ffi.vec2d'
local matrix_ffi = require 'matrix.ffi'
local Image = require 'image'
local gl = require 'gl.setup'(cmdline.gl)
local glnumber = require 'gl.number'
local glreport = require 'gl.report'
local GLPingPong = require 'gl.pingpong'
local GLGeometry = require 'gl.geometry'
local GLSceneObject = require 'gl.sceneobject'
local GLTex2D = require 'gl.tex2d'
local ig = require 'imgui'

local modulo = 4
initValue = bit.lshift(1,tonumber(arg[1]) or 17)
drawValue = 25
local gridsize = assert(tonumber(arg[2] or 1024))

local App = require 'imgui.appwithorbit'()

local grad
local pingpong

local bufferCPU = ffi.new('int32_t[?]', gridsize * gridsize)

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
	local tex = pingpong:prev()
	tex:bind(0)
	gl.glTexSubImage2D(gl.GL_TEXTURE_2D, 0, 0, 0, gridsize, gridsize, tex.format, tex.type, bufferCPU)
	tex:unbind(0)
	totalSand = initValue
end

function App:initGL()
	App.super.initGL(self)

	self.view.ortho = true
	self.view.orthoSize = 1
	self.view.pos:set(0, 0, 1)

	gl.glClearColor(.2, .2, .2, 0)

	pingpong = GLPingPong{
		width = gridsize,
		height = gridsize,
		internalFormat = gl.GL_R32UI,
		minFilter = gl.GL_NEAREST,
		magFilter = gl.GL_NEAREST,
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
		data = ffi.new('unsigned char[12]', {
			colors[1].x, colors[1].y, colors[1].z,
			colors[2].x, colors[2].y, colors[2].z,
			colors[3].x, colors[3].y, colors[3].z,
			colors[4].x, colors[4].y, colors[4].z,
		}),
	}:unbind()
	grad:bind(1)

	self.quadGeom = GLGeometry{
		mode = gl.GL_TRIANGLE_STRIP,
		vertexes = {
			data = 	{
				0, 0,
				1, 0,
				0, 1,
				1, 1,
			},
			dim = 2,
		},
	}

	self.updateSceneObj = GLSceneObject{
		program = {
			version = 'latest',
			header = 'precision highp float;',
			vertexCode = [[
in vec2 vertex;
void main() {
	gl_Position = vec4(vertex * 2. - 1., 0., 1.);
}
]],
			fragmentCode = template([[
precision highp usampler2D;
out uint fragColor;
uniform usampler2D tex;
void main() {
	ivec2 itc = ivec2(gl_FragCoord);
	fragColor = (texelFetch(tex, itc, 0).r % <?=modulo?>u)
		+ (texelFetch(tex, ivec2((itc.x + 1) % <?=gridsize?>, itc.y), 0).r / <?=modulo?>u)
		+ (texelFetch(tex, ivec2((itc.x + <?=gridsize?> - 1) % <?=gridsize?>, itc.y), 0).r / <?=modulo?>u)
		+ (texelFetch(tex, ivec2(itc.x, (itc.y + 1) % <?=gridsize?>), 0).r / <?=modulo?>u)
		+ (texelFetch(tex, ivec2(itc.x, (itc.y + <?=gridsize?> - 1) % <?=gridsize?>), 0).r / <?=modulo?>u)
	;
}
]],				{
					gridsize = gridsize,
					modulo = modulo,
				}
			),
			uniforms = {
				tex = 0,
			},
		},
		geometry = self.quadGeom,
	}

	self.drawSceneObj = GLSceneObject{
		program = {
			version = 'latest',
			header = 'precision highp float;',
			vertexCode = [[
in vec2 vertex;
out vec2 tc;
uniform mat4 mvProjMat;
void main() {
	tc = vertex;
	gl_Position = mvProjMat * vec4(vertex * 2. - 1., 0., 1.);
}
]],
			fragmentCode = template([[
precision highp usampler2D;
in vec2 tc;
out vec4 fragColor;
uniform usampler2D tex;
uniform sampler2D grad;
void main() {
	uint value = texelFetch(tex, ivec2(tc * <?=glnumber(gridsize)?>), 0).r % <?=modulo?>u;
	fragColor = texelFetch(grad, ivec2(int(value), 0), 0);
}
]],				{
					glnumber = glnumber,
					modulo = modulo,
					gridsize = gridsize,
				}
			),
			uniforms = {
				tex = 0,
				grad = 1,
			},
		},
		geometry = self.quadGeom,
	}

	glreport 'here'
end

-- hmm wish there was an easier way to do this
local function vec3d_to_vec2d(v)
	return vec2d(v.x, v.y)
end


local value = ffi.new('uint32_t[1]', 0)
function App:update()
	local ar = self.width / self.height

--[[
do
	local tex = pingpong:prev()
	tex:bind()
	tex:toCPU(bufferCPU)
	tex:unbind()
counter = (counter or 0) + 1
print('counter', counter)
	for i=0,gridsize*gridsize-1 do
		print(i, bufferCPU[i])
	end
if counter == 2 then  os.exit() end
end
--]]

	local canHandleMouse = not ig.igGetIO()[0].WantCaptureMouse
	if canHandleMouse then
		self.mouse:update()
		if self.mouse.rightDown then
			local pos = (vec3d_to_vec2d(self.mouse.pos) - vec2d(.5, .5)) * (2 * self.view.orthoSize)
			pos.x = pos.x * ar
			pos = ((pos + vec3d_to_vec2d(self.view.pos)) * .5 + vec2d(.5, .5)) * gridsize
			local x = math.floor(pos.x + .5)
			local y = math.floor(pos.y + .5)
			if x >= 0 and x < gridsize and y >= 0 and y < gridsize then
				local tex = pingpong:cur()
				pingpong:draw{
					callback = function()
						gl.glReadPixels(x, y, 1, 1, tex.format, tex.type, value)
						value[0] = value[0] + drawValue
					end,
				}
				pingpong:prev()
					:bind(0)
					:subimage{xoffset=x, yoffset=y, width=1, height=1, data=value}
					:unbind(0)
				totalSand = totalSand + drawValue
			end
		end
	end

	-- update
	gl.glViewport(0, 0, gridsize, gridsize)
	pingpong:draw{
		--viewport = {0, 0, gridsize, gridsize},
		callback = function()
			gl.glClear(gl.GL_COLOR_BUFFER_BIT)
			self.updateSceneObj.texs[1] = pingpong:prev()
			self.updateSceneObj:draw()
		end,
	}
	gl.glViewport(0, 0, self.width, self.height)
	pingpong:swap()

	gl.glClear(gl.GL_COLOR_BUFFER_BIT)

	self.drawSceneObj.texs[1] = pingpong:cur()
	self.drawSceneObj.uniforms.mvProjMat = self.view.mvProjMat.ptr
	self.drawSceneObj:draw()

	App.super.update(self)
end

function App:updateGUI()
	ig.igText('total sand: '..totalSand)

	ig.luatableInputInt('initial value', _G, 'initValue')
	ig.luatableInputInt('draw value', _G, 'drawValue')

	if ig.igButton'Save' then
		pingpong:prev()
			:bind()	-- prev? shouldn't this be cur?
			:subimage{data=bufferCPU}
			:unbind()
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
		local tex = pingpong:prev()
		tex:bind(0)
		gl.glTexSubImage2D(gl.GL_TEXTURE_2D, 0, 0, 0, gridsize, gridsize, tex.format, tex.type, bufferCPU)
		tex:unbind(0)
	end

	ig.igSameLine()

	if ig.igButton'Reset' then
		reset()
	end
end

return App():run()
