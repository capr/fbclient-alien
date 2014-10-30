--brute-force testing which keywords are reserved keywords for each firebird version
--the output is a csv of all reserved keywords x fb server version

local config = require 'test_config'
local keywords = require 'sql_keywords_lists'

local function pad(s,k)
	return s..string.rep(' ',math.max(0, k-#s))
end

local function sortedkeys(t)
	local keys = {}
	for k in pairs(t) do
		keys[#keys+1] = k
	end
	table.sort(keys)
	return keys
end

local envs = {}

local function test_everything(env)

	local at = env:create_test_db()

	local t = {}
	envs[env.server_ver] = t

	local funcs = {
		T = function(k) at:exec_immediate('create table '..k..' (c integer)') end,
		C = function(k,i) at:exec_immediate('create table T'..i..' ('..k..' integer)') end,
		E = function(k) at:exec_immediate('create exception '..k.." ''") end,
		G = function(k) at:exec_immediate('create generator '..k) end,
	}
	local fnames = sortedkeys(funcs)

	local i=0
	for k in pairs(keywords['All']) do
		local ks = {}
		for j,fn in ipairs(fnames) do
			i=i+1
			local ok,err = pcall(funcs[fn],k,i)
			if ok then ks[#ks+1] = fn end
		end
		t[k] = (#ks == #fnames and ' ') or (#ks == 0 and '*') or table.concat(ks)
		assert(t[k] == ' ' or t[k] == '*')
	end

	at:close()
end


local comb = {{lib='fbclient',ver='2.5.0'}}
local excomb = {{lib='fbembed'}}
config.run(test_everything,comb,excomb,...)

local function print_csv()
	local envnames = sortedkeys(envs)
	print(pad('',32)..','..table.concat(envnames,','))

	for i,k in ipairs(sortedkeys(keywords['All'])) do
		local t = {}
		for i,name in ipairs(envnames) do
			t[i] = envs[name][k]
		end
		print(pad(k,32)..','..table.concat(t,','))
	end
end

local function print_lua()
	local envnames = sortedkeys(envs)
	print("local keywords = {")
	for _,name in ipairs(envnames) do
		local keys = envs[name]
		print('',"['Firebird "..name.."'] = {")
		local t = {}
		for k,v in pairs(keys) do
			if v == '*' then
				t[#t+1] = k
			end
		end
		table.sort(t)
		for i,k in ipairs(t) do
			t[i] = (k:find'%$' and "['"..k.."']" or k)..' = true'
		end
		print('','',table.concat(t,', ')..',')
		--print('',"'"..table.concat(t,"', '").."',")
		print('',"},")
	end
	print("}")
end

local function print_csv_all()
	local all = keywords['All']
	local modes,counts = {},{}
	for name in pairs(keywords) do
		modes[#modes+1] = name
		counts[#modes] = 0
	end
	table.sort(modes)
	print('Keyword,'..table.concat(modes,','))

	for k in pairs(all) do
		local t = {k}
		for i,mode in ipairs(modes) do
			t[#t+1] = keywords[mode][k] and '*' or ''
			counts[i] = counts[i] + (keywords[mode][k] and 1 or 0)
		end
		print(table.concat(t,','))
	end
	print('[COUNTS],'..table.concat(counts,','))
end

print_csv()
print_lua()
--print_csv_all()

