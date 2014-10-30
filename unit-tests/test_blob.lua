#!/usr/bin/lua

--[[
	Test unit for blob.lua

	TODO:
	- test seek() if it will ever be fixed in Firebird

]]

local config = require 'test_config'

local function asserteq(a,b,s)
	assert(a==b,s or string.format('%s ~= %s', tostring(a), tostring(b)))
end

function test_everything(env)

	local asserts = (require 'fbclient.util').asserts
	local dump = (require 'fbclient.util').dump
	local blobapi = require 'fbclient.blob' --not loaded automatically

	local at

	local function gen_s(len)
		local t = {}
		for i=1,len do
			t[#t+1] = string.char(math.random(('a'):byte(), ('z'):byte()))
		end
		return table.concat(t)
	end

	local min = assert(blobapi.MIN_SEGMENT_SIZE)
	local max = assert(blobapi.MAX_SEGMENT_SIZE)
	local function test_segmented_blobs()
		local segments = {
			gen_s(max),
			gen_s(min),
			gen_s(min+1),
			gen_s(255),
			gen_s(3*max+1), --this should occupy 3 more segments
		}

		at:exec_immediate('create table test(c blob sub_type binary)')
		local st = at:start_transaction():prepare('insert into test(c) values (?)')
		st:setparams(segments):run()
		assert(st.params[1]:closed())
		at:commit_all()

		local st = at:start_transaction():prepare('select c from test')
		assert(st:run():fetch())
		local xs = st.columns[1]

		xs:open()
		local binfo = xs:blobinfo{
			isc_info_blob_total_length=true,
			isc_info_blob_max_segment=true,
			isc_info_blob_num_segments=true,
			isc_info_blob_type=true,
		}
		print'BLOB info:'; dump(binfo)
		asserteq(binfo['isc_info_blob_total_length'],#table.concat(segments))
		asserteq(binfo['isc_info_blob_max_segment'],max)
		asserteq(binfo['isc_info_blob_num_segments'],#segments+3)
		asserteq(binfo['isc_info_blob_type'],'isc_bpb_type_segmented')

		local segs = {}
		for seg in xs:segments() do
			segs[#segs+1]=seg
		end
		assert(xs:closed())
		asserteq(#segs, #segments+3)
		for i=1,#segments-1 do
			asserteq(segs[i], segments[i])
		end
		for i=0,3 do
			asserteq(segs[#segments+i], segments[#segments]:sub(i*max+1,(i+1)*max))
		end
		asserteq(table.concat(segs), table.concat(segments))
		asserteq(st.values[1], table.concat(segments))

		at:commit_all()
	end

	local function test_stream_blobs()
		local s = '1234567890abcdefghijklmnopqrstuvwxyz'
		local max_seg = 13

		at:exec_immediate('create table test_sb(c blob sub_type binary)')
		local st = at:start_transaction():prepare('insert into test_sb(c) values (?)')
		local xs = st.params[1]
		xs:create('stream')
		xs:write(s,max_seg)
		st:run()
		assert(xs:closed())
		at:commit_all()

		local st = at:start_transaction():prepare('select c from test_sb')
		assert(st:run():fetch())
		local xs = st.columns[1]
		xs:open()
		local binfo = xs:blobinfo{
			isc_info_blob_total_length=true,
			isc_info_blob_max_segment=true,
			isc_info_blob_num_segments=true,
			isc_info_blob_type=true,
		}
		print'BLOB info:'; dump(binfo)
		local num_segs = math.floor(#s / max_seg) + (#s % max_seg > 0 and 1 or 0)
		asserteq(binfo['isc_info_blob_total_length'], #s)
		asserteq(binfo['isc_info_blob_max_segment'], max_seg)
		asserteq(binfo['isc_info_blob_num_segments'], num_segs)
		asserteq(binfo['isc_info_blob_type'], 'isc_bpb_type_stream')

		local segs = {}
		for seg in xs:segments(max_seg*2) do
			segs[#segs+1]=seg
		end
		assert(xs:closed())
		asserteq(#segs, math.floor(#s / (max_seg*2)) + (#s % (max_seg*2) > 0 and 1 or 0))
		asserteq(table.concat(segs), s)
		asserteq(st.values[1], s)

		--TODO: test seek() if it will ever work
	end

	at = env:create_test_db()

	test_segmented_blobs()
	test_stream_blobs()

	at:close()

	return 1,0
end

--local comb = {{lib='fbembed',ver='2.1.3'}}
config.run(test_everything,comb,nil,...)

