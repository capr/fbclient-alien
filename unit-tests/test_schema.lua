#!/usr/bin/lua

config = require 'test_config'

function test_everything(env)
	--require 'profiler'
	require 'socket'

	--profiler.start('test_metadata.profile.txt')

	local function newtrace(name)
		local tm
		return function(s,...)
			print(name,s,tm and socket.gettime()-tm or 0,...)
			tm = socket.gettime()
		end
	end

	traceall = newtrace('all')
	trace = newtrace('each')

	traceall('start')
	trace('start')

	local schema = require 'fbclient.schema'
	local dump = require('fbclient.util').dump

	trace('loadlib')

	local tr = env:create_test_db():start_transaction_ex()
	local options = {
		system_flag = true,
		source_code = true,
		table_fields = true,
		security = true,
		collations = true,
		function_args = true,
		procedure_args = true,
	}
	local sc0 = schema{options = options}
	local sc1 = schema{options = options}
	local sc2 = schema{options = options}

	trace('attach')

	sc1.domains:load(tr)
	sc1.tables:load(tr, 'RDB$RELATIONS')
	sc1.tables:load(tr, 'RDB$INDICES')

	sc2.domains:load(tr)
	sc2.tables:load(tr, 'RDB$RELATIONS')
	sc2.tables:load(tr, 'RDB$DATABASE')
	--dump(sc2.tables.elements['RDB$RELATIONS'].fields)
	sc2.tables.elements['RDB$RELATIONS'].fields.elements['RDB$RELATION_TYPE'].domain =
		sc2.domains.elements['RDB$DESCRIPTION']
	--dump(sc1,sc2)
	for sql in sc2:diff(sc1) do
		print(sql)
	end

	trace('load all')

	next(tr.attachments):close()

	traceall('end')

	--profiler.end()
end

local comb = {{lib='fbclient',ver='2.5.0',server_ver='2.5.0'}}
config.run(test_everything,comb,nil,...)

