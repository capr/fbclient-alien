#!/usr/bin/lua
--[[
	Test unit for tracing API

]]

local config = require 'test_config'

local fb = require 'fbclient.class'
local asserts = (require 'fbclient.util').asserts

function test_everything(env)

	local at = env:create_test_db()

	--

	at:close()

	return 1,0
end

--local comb = {{lib='fbembed',ver='2.1.3'}}
config.run(test_everything,comb,nil,...)

