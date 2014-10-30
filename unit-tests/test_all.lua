#!/usr/bin/lua
--[[
	Automated test suite for the fbclient Lua binding.
	Before reporting a bug, make sure this script doesn't break for you.

	Read README.TXT before running this script.

]]


local config = require 'test_config'

total_ok_num = 0
total_fail_num = 0

local function add(ok_num,fail_num)
	total_ok_num = total_ok_num + ok_num
	total_fail_num = total_fail_num + fail_num
end

--local included_comb={{lib='fbclient',ver='2.5.0',server_ver='2.5.0'}}
add(config.run('test_binding.lua',included_comb)) --pass
add(config.run('test_wrapper.lua',included_comb)) --pass
add(config.run('test_class.lua',included_comb)) --pass
add(config.run('test_xsqlvar.lua',included_comb)) --pass
add(config.run('test_blob.lua',included_comb)) --pass
add(config.run('test_service_wrapper.lua',included_comb)) --pass
add(config.run('test_service_class.lua',included_comb)) --pass

print(('Grand total for all tests: %d ok, %d failed'):format(total_ok_num,total_fail_num))

