--[=[
	Blob API to complement xsqlvar.lua
	Supports both segmented blobs and stream blobs (stream blobs are blobs that support random-access reading).

	*** PROCEDURAL API ***
	open(fbapi, sv, dbh, trh, blob_id_buf, bpb_options_t) -> bh (see bpb.lua for options)
	create(fbapi, sv, dbh, trh, bpb_options_t, [blob_id_buf]) -> bh, blob_id_buf
	read_segment(fbapi, sv, bh, [data_buf_size], [data_buf], [len_buf]) -> s, data_buf, len_buf, data_buf_size
	write_segment(fbapi, sv, bh, s)
	seek(fbapi, sv, bh, offset, [mode], [offset_buf]) -> offset, offset_buf; for mode see seek_modes below;
	cancel(fbapi, sv, bh)
	close(fbapi, sv, bh)
	info(fbapi, sv, bh, options_t, [info_buf_len]) -> blob_info_t

	segments(fbapi, sv, bh, [data_buf_size], [data_buf], [len_buf]) -> iterator() -> s
	write(fbapi, sv, bh, s, [max_segment_size])

	THINGS THAT MAY SURPRISE YOU:
	- both segmented and stream blobs are write-once-read-many-times data chunks. this means that
	blobs opened with create() can only be written to, and blobs opened with open() can only be
	read from and, in the case of stream blobs, seek()'ed into. you can't seek inside a blob opened
	for writing, and you can't ever change a blob's contents after the first writing session (you must make
	another blob and replace the blob id in your table). All this I believe differs from file semantics
	because of transaction semantics.
	- stream blobs differ from segmented blobs in two ways:
		1) seek() doesn't work for segmented blobs.
		2) stream blobs are not read in segments: the read buffer gets filled with as much data as available.
	- blob_info.lua is only loaded on demand (on the first call to info()).
	- you can't change the blob type of an existing blob.
	- you can't get info on a blob opened for writing.

	*** XSQLVAR API ***
	xsqlvar:open([bpb_opts_t])
	xsqlvar:create('segmented'|'stream', [storage = 'main'|'temp'], [bpb_opts_t])
	xsqlvar:create_ex(bpb_options_t)
	xsqlvar:close()
	xsqlvar:closed() -> true|false
	xsqlvar:read([buf_size]) -> s; calls open() if blob not opened.
	xsqlvar:seek(offset,['absolute'|'relative'|'from_tail']) -> offset; calls open() if blob not opened.
	xsqlvar:segments([buf_size]) -> segment_iterator() -> s; buf_size: nil == 64K-1
	xsqlvar:write(s,[max_segment_size]); calls create('stream') if blob not already open.

	xsqlvar:set(s); extended to create a stream-type blob, write a string of arbitrary length to it and close it.
	xsqlvar:set(t); extended to create a segmented-type blob, write an array of string segments to it and close it.
	xsqlvar:get() -> extended to return the whole blob as a string.

	*** XSQLVAR INFO API ***
	xsqlvar:blobinfo(options_t,[info_buf_len]) -> blob_info_t
	xsqlvar:segmentlength() -> n
	xsqlvar:maxsegmentlength() -> n
	xsqlvar:maxsegmentcount() -> n
	xsqlvar:blobtype() -> 'stream'|'segmented'

	MAX_SEGMENT_SIZE = util.MAX_USHORT

	TODO:
	- blob filters. ask me to implement them.

	LIMITATIONS:
	- seek() doesn't seem to work in Firebird (screws up read_segment() afterwards).

]=]

module(...,require 'fbclient.module')

local svapi   = require 'fbclient.status_vector'
local bpb     = require 'fbclient.bpb'
local xsqlda  = require 'fbclient.xsqlda'
local xsqlvar_class = require('fbclient.xsqlvar').xsqlvar_class
local fbtry = svapi.try
local blobapi = _M

local ISC_QUAD = 'c8'
local ISC_QUAD_SIZE = struct.size(ISC_QUAD)
local isc_segment = 335544366 --isc_get_segment error code: more
local isc_segstr_eof = 335544367 --isc_get_segment error code: eof

MIN_SEGMENT_SIZE = 1 --writing a 0-byte segment is supported but reading it back is not!
MAX_SEGMENT_SIZE = MAX_USHORT

function open(fbapi, sv, dbh, trh, blob_id_buf, opts)
	local bpb_str = bpb.encode(opts)
	local bh = alien.buffer(POINTER_SIZE)
	bh:set(1,nil,'pointer') --important!

	fbtry(fbapi, sv, 'isc_open_blob2', dbh, trh, bh, blob_id_buf, bpb_str and #bpb_str or 0, bpb_str)
	return bh
end

function create(fbapi, sv, dbh, trh, opts, blob_id_buf)
	local bpb_str = bpb.encode(opts)

	local bh = alien.buffer(POINTER_SIZE)
	bh:set(1,nil,'pointer') --important!

	blob_id_buf = blob_id_buf or alien.buffer(ISC_QUAD_SIZE)
	alien.memset(blob_id_buf,0,ISC_QUAD_SIZE) --important!

	fbtry(fbapi, sv, 'isc_create_blob2', dbh, trh, bh, blob_id_buf, bpb_str and #bpb_str or 0, bpb_str)
	return bh, blob_id_buf
end

function cancel(fbapi, sv, bh)
	fbtry(fbapi, sv, 'isc_cancel_blob', bh)
end

function close(fbapi, sv, bh)
	fbtry(fbapi, sv, 'isc_close_blob', bh)
end

--you can pass info().isc_info_blob_max_segment to data_buf_size if you're short on memory, otherwise
--let it default to MAX_SEGMENT_SIZE (64K-1); in case you also pass a data_buf, then data_buf_size is
--required, and must not be larger than the length of the buffer.
--returns s, data_buf, len_buf, data_buf_size; s is nil on EOF.
function read_segment(fbapi, sv, bh, data_buf_size, data_buf, len_buf)
	if data_buf then
		assert(data_buf_size, 'missing data_buf_size for data_buf')
	end
	data_buf_size = data_buf_size or MAX_SEGMENT_SIZE
	asserts(data_buf_size >= MIN_SEGMENT_SIZE, 'buffer too small. min. allowed is %d bytes', MIN_SEGMENT_SIZE)
	asserts(data_buf_size <= MAX_SEGMENT_SIZE, 'buffer too large. max. allowed is %d bytes', MAX_SEGMENT_SIZE)
	data_buf = data_buf or alien.buffer(data_buf_size)
	len_buf = len_buf or alien.buffer(SHORT_SIZE)

	fbapi.isc_get_segment(sv, bh, len_buf, data_buf_size, data_buf)
	local ok, errcode = svapi.status(sv)
	if ok or errcode == isc_segment or errcode == isc_segstr_eof then
		local len = len_buf:get(1,'ushort')
		return len >= MIN_SEGMENT_SIZE and data_buf:tostring(len) or nil, data_buf, len_buf, data_buf_size
	end
	assert(svapi.full_status(sv))
	assert(false)
end

function write_segment(fbapi, sv, bh, s)
	asserts(#s >= MIN_SEGMENT_SIZE, 'segment too small. min. allowed is %d bytes', MIN_SEGMENT_SIZE)
	asserts(#s <= MAX_SEGMENT_SIZE, 'segment too large. max. allowed is %d bytes', MAX_SEGMENT_SIZE)
	fbtry(fbapi, sv, 'isc_put_segment', bh, #s, s)
end

local seek_modes = {
	blb_seek_absolute  = 0,
	blb_seek_relative  = 1,
	blb_seek_from_tail = 2,
}

function seek(fbapi, sv, bh, offset, mode, offset_buf)
	mode = seek_modes[mode or 'blb_seek_absolute']
	assert(mode,'invalid seek mode')
	offset_buf = offset_buf or alien.buffer(LONG_SIZE)
	fbtry(fbapi, sv, 'isc_seek_blob', bh, mode, offset-1, offset_buf)
	return offset_buf:get(1,'int')+1, offset_buf
end

function info(fbapi, sv, bh, opts, info_buf_len)
	local inf = require 'fbclient.blob_info' -- blob_info is not bloated by any means, but we value consistency :)
	local opts, max_len = inf.encode(opts)
	info_buf_len = math.min(MAX_SHORT, info_buf_len or max_len)
	local info_buf = alien.buffer(info_buf_len)
	fbtry(fbapi, sv, 'isc_blob_info', bh, #opts, opts, info_buf_len, info_buf)
	return inf.decode(info_buf, info_buf_len)
end

--segments() returns a self-contained iterator that reads all segments from the
--current seek position. it has the advantage of reusing data_buf and len_buf
--in exchange of creating one closure for the whole iteration.
function segments(fbapi, sv, bh, data_buf_size, data_buf, len_buf)
	return function()
		local s
		s, data_buf, len_buf, data_buf_size =
			read_segment(fbapi, sv, bh, data_buf_size, data_buf, len_buf)
		return s
	end
end

--unlike write_segment(), write() writes any string, automatically segmenting it into segment_size-long segments.
function write(fbapi, sv, bh, s, segment_size)
	segment_size = segment_size or math.min(MAX_SEGMENT_SIZE, #s)
	if segment_size > 0 then
		local full_seg_num = math.floor(#s / segment_size)
		local last_seg_size = #s % segment_size
		for i=1,full_seg_num do
			write_segment(fbapi, sv, bh, s:sub(1 + (i-1) * segment_size, i * segment_size))
		end
		if last_seg_size > 0 then
			write_segment(fbapi, sv, bh, s:sub(1 + full_seg_num * segment_size))
		end
	else
		assert(#s == 0, 'attempt to write a non-empty string with a segment_size of 0')
		write_segment(fbapi, sv, bh, '')
	end
end

function xsqlvar_class:open(opts)
	assert(not self:isnull(), 'NULL value')
	asserts(self:type() == 'blob', 'incompatible data type %s', self:type())
	assert(not self.blob_handle, 'blob already open')
	self.blob_handle = blobapi.open(self.fbapi,self.sv,self.dbh,self.trh,self:getblobid(),opts)
	self.blob_mode = 'r'
end

function xsqlvar_class:create(kind,storage,opts)
	storage = storage or 'main'
	assert(kind == 'stream' or kind == 'segmented', 'arg#1 must be either "stream" or "segmented"')
	assert(storage == 'main' or storage == 'temp', 'arg#2 must be either "main" or "temp"')
	opts = opts or {}
	opts.isc_bpb_type = 'isc_bpb_type_'..kind
	opts.isc_bpb_storage = 'isc_bpb_storage_'..storage
	self:create_ex(opts)
end

function xsqlvar_class:create_ex(opts)
	asserts(self:type() == 'blob', 'incompatible data type %s', self:type())
	assert(not self.blob_handle, 'blob already open')
	self.blob_handle = blobapi.create(self.fbapi,self.sv,self.dbh,self.trh,opts,self:getblobid())
	self.blob_mode = 'w'
	self.sqlind_buf:set(1,0,'int') --reset the NULL flag
end

--note: since create_ex() uses self:getblobid() for its blob id buffer thus replacing the blob id,
--so there's no need to call self:setblobid() after closing the blob.
function xsqlvar_class:close()
	assert(self.blob_handle, 'blob already closed')
	blobapi.close(self.fbapi,self.sv,self.blob_handle)
	self.blob_handle = nil
	self.blob_mode = nil
end

function xsqlvar_class:closed()
	return self.blob_handle == nil
end

function xsqlvar_class:read(buf_size)
	if not self.blob_handle then
		self:open()
	else
		assert(self.blob_mode == 'r', 'blob opened in write mode')
	end
	buf_size = buf_size == 0 and self:maxsegmentlength() or buf_size
	return blobapi.read_segment(self.fbapi,self.sv,self.blob_handle,buf_size)
end

function xsqlvar_class:seek(offset,mode)
	if not self.blob_handle then
		self:open()
	else
		assert(self.blob_mode == 'r', 'blob opened in write mode')
	end
	local ofs
	ofs, self.seek_ofs_buffer =
		blobapi.seek(self.fbapi,self.sv,self.blob_handle,offset,'blb_seek_'..mode,self.seek_ofs_buffer)
	return ofs
end

function xsqlvar_class:segments(buf_size)
	if not self.blob_handle then
		self:open()
	else
		assert(self.blob_mode == 'r', 'blob opened in write mode')
	end
	local segments_iter = blobapi.segments(self.fbapi,self.sv,self.blob_handle,buf_size)
	return function()
		local s = segments_iter()
		if not s then
			self:close()
		end
		return s
	end
end

function xsqlvar_class:write(s,max_segment_size)
	if not self.blob_handle then
		self:create('stream')
	else
		assert(self.blob_mode == 'w', 'blob opened in read mode')
	end
	blobapi.write(self.fbapi,self.sv,self.blob_handle,s,max_segment_size)
end

function xsqlvar_class:blobinfo(opts,info_buf_len)
	if not self.blob_handle then
		self:open()
	else
		assert(self.blob_mode == 'r', 'blob opened in write mode')
	end
	return blobapi.info(self.fbapi,self.sv,self.blob_handle,opts,info_buf_len)
end

function xsqlvar_class:segmentlength()
	return self:blobinfo().isc_info_blob_total_length
end

function xsqlvar_class:maxsegmentlength()
	return self:blobinfo().isc_info_blob_max_segment
end

function xsqlvar_class:segmentcount()
	return self:blobinfo().isc_info_blob_num_segments
end

function xsqlvar_class:blobtype()
	return self:blobinfo().isc_info_blob_type:sub(#'isc_bpb_type_'+1)
end

--the setters and getter must be module-bound so they won't get garbage-collected
xsqlvar_class:add_set_handler(
	function(self,s,typ,opt)
		if typ == 'blob' and type(s) == 'string' then --string for blob -> write a stream blob
			self:create('stream')
			self:write(s)
			self:close()
			return true
		end
	end
)

xsqlvar_class:add_set_handler(
	function(self,t,typ,opt)
		if typ == 'blob' and applicable(t,'__ipairs') then --iterable for blob -> write a segmented blob
			self:create('segmented')
			for i,s in ipairs(t) do
				self:write(s)
			end
			self:close()
			return true
		end
	end
)

xsqlvar_class:add_get_handler(
	function(self,typ,opt)
		if typ == 'blob' then
			local t = {}
			for s in self:segments() do
				t[#t+1] = s
			end
			return true,table.concat(t)
		end
	end
)

