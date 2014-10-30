#!/usr/bin/lua

local config = require 'test_config'

local libs = setmetatable({}, {__mode='k'})

function test_everything(env)

	local binding = require 'fbclient.binding'
	local util = require 'fbclient.util'
	local dump = require('fbclient.util').dump
	local alien = require 'alien'

	local fbapi = binding.new(env.libname)
	libs[fbapi] = true
	print(fbapi)

	local buf = alien.buffer()
	fbapi.isc_get_client_version(buf)
	print(buf, fbapi.isc_get_client_major_version()..'.'..fbapi.isc_get_client_minor_version())

	return 1,0
end


--local comb = {{lib='fbembed',ver='2.1.3'}}
config.run(test_everything,comb,nil,...)


for lib in pairs(alien.loaded) do
	alien.loaded[lib] = nil
end
collectgarbage('collect')
collectgarbage('collect')

if next(libs) then
	print('not all bindings were garbage-collected!')
	for lib in pairs(libs) do
		print('',lib)
	end
end

