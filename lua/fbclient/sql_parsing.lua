
local lpeg = require 'lpeg'

--splits a string containing multiple sql statements separated by ';'
--implements 'SET TERM'
function parse_statements(s)
	return {s}
end

--replace :NAME and %NAME placeholders from a text with values from a table or the result of a function
--:: and %% are replaced with : and % respectively
function parse_template(s,t)
	local f = t
	if type(t) == 'table' then
		function f(s)
			return t[s]
		end
	end
	s = s:gsub('%::("?[%w_%.]+"?)', function(s) return f(s) end)
	s = s:gsub('%:("?[%w_%.]+"?)', function(s) return format_name(f(s)) end)
	s = s:gsub('%%("?[%w_%.]+"?)', function(s) return format_string(f(s)) end)
	return s
end

if false then
	print(format_name('TABLE','Firebird 2.5.0'))
	print(format_name('"TABLEX"','Firebird 2.5.0'))
	print(format_name('"TABLEX"YY"','Firebird 2.5.0'))
end

