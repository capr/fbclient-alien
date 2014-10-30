--[=[
	Events API

	**** THIS FILE IS WORK-IN-PROGRESS - DO NOT USE IT ****

	new(name1,name2,...) -> event_state
	wait(status_vector, dbh, event_state) -> event1_count,event2_count,...
	listen(status_vector, dbh, event_state, callbackf) -> event_id
	cancel(status_vector, dbh, event_id)

]=]

module(...,require 'fbclient.module')

local fbapi		= require 'fbclient.binding'
local fbtry		= require('fbclient.status_vector').try

local buffer = alien.buffer
local sizeof = alien.sizeof

local MAX_NAME_LEN = 31

local function trim(s)
	return (string.gsub(s, "^%s*(.-)%s*$", "%1"))
end

-- an EPB has the form: 1:byte .. #event_name:byte .. event_name:string .. event_count:int
function new(...) -- hack: implement isc_event_block() ourselves with gds__alloc()
	local s = '\1' -- EPB_version1
	local names_t = {}
	for i=1,select('#',...) do
		local name = trim(select(i,...))
		assert(#name <= MAX_NAME_LEN, 'event_block(): event name larger than '..MAX_NAME_LEN..' bytes')
		s = s..string.char(#name)..name..'\0\0\0\0' --the event count stays in this integer
		names_t[i] = name
	end
	local event_buf_ptr = fbapi.gds__alloc(#s)
	local result_buf_ptr = fbapi.gds__alloc(#s)
	alien.memcpy(event_buf_ptr, s)

	return {
		names = names_t,
		event_buf = event_buf_ptr,
		result_buf = result_buf_ptr,
		bufsize = #s
	}
end

--[[
/* calculate length of event parameter block,
   setting initial length to include version
   and counts for each argument */

	SLONG length = 1;
	USHORT i = count;
	while (i--) {
		const char* q = va_arg(ptr, SCHAR *);
		length += strlen(q) + 5;
	}
	va_end(ptr);

	UCHAR* p = *event_buffer = (UCHAR *) gds__alloc((SLONG) length);
/* FREE: apparently never freed */
	if (!*event_buffer)			/* NOMEM: */
		return 0;
	if ((*result_buffer = (UCHAR *) gds__alloc((SLONG) length)) == NULL) {	/* NOMEM: */
		/* FREE: apparently never freed */
		gds__free(*event_buffer);
		*event_buffer = NULL;
		return 0;
	}

#ifdef DEBUG_GDS_ALLOC
/* I can find no place where these are freed */
/* 1994-October-25 David Schnepper  */
	gds_alloc_flag_unfreed((void *) *event_buffer);
	gds_alloc_flag_unfreed((void *) *result_buffer);
#endif /* DEBUG_GDS_ALLOC */

/* initialize the block with event names and counts */

	*p++ = EPB_version1;

	va_start(ptr, count);

	i = count;
	while (i--) {
		const char* q = va_arg(ptr, SCHAR *);

		/* Strip the blanks from the ends */
		const char* end = q + strlen(q);
		while (--end >= q && *end == ' ')
			;
		*p++ = end - q + 1;
		while (q <= end)
			*p++ = *q++;
		*p++ = 0;
		*p++ = 0;
		*p++ = 0;
		*p++ = 0;
	}
	va_end(ptr);

	return static_cast<SLONG>(p - *event_buffer);
]]

function new_vararg(...) -- the official vararg version: segfaoults
	local maxn = 15
	local n = select('#',...)
	assert(n <= maxn, 'too many events, max. limit is '..maxn)
	local names_t = {}
	for i=1,n do
		local name = trim(select(i,...))
		assert(#name <= MAX_NAME_LEN, 'event_block(): event name larger than '..MAX_NAME_LEN..' bytes')
		names_t[i] = name
	end

	local event_buf = buffer(sizeof('pointer'))
	local result_buf = buffer(sizeof('pointer'))

	local bufsize = fbapi.isc_event_block(event_buffer, result_buffer, n, unpack(names_t,1,maxn))
	return {
		names = names_t,
		event_buf = event_buf,
		result_buf = result_buf,
		bufsize = bufsize
	}
end

--isc_event_block_a takes an array of pointers to a space-padded char[MAX_NAME_LEN] of event names. got tubes?
function new_a(...) -- the non-verarg version: not exported on linux
	local n = select('#',...)
	assert(n <= 15, 'too many events, max. limit is 15')
	local name_ptrs_buf = buffer(sizeof('pointer')*n)
	local names_s = ''
	local names_t = {}
	for i=1,n do
		local name = trim(select(i,...))
		assert(#name <= MAX_NAME_LEN, 'event_block(): event name larger than '..MAX_NAME_LEN..' bytes')
		names_s = names_s + name + (' '):rep(MAX_NAME_LEN-#name)
		names_t[i] = name
	end
	local names_buf = buffer(names_s)
	for i=0,n-1 do
		name_ptrs_buf:set(i*sizeof('pointer'), names_buf:topointer(i*MAX_NAME_LEN), 'pointer')
	end

	local event_buf = buffer(sizeof('pointer'))
	local result_buf = buffer(sizeof('pointer'))

	local bufsize = fbapi.isc_event_block_a(event_buffer, result_buffer, n, name_ptrs_buf)
	return {
		names = names_t,
		event_buf = event_buf,
		result_buf = result_buf,
		bufsize = bufsize
	}
end

local function event_counts(status_vector, t)
	fbapi.isc_event_counts(status_vector, t.bufsize, t.event_buf, t.result_buf)
	tt={}
	for i=0,#t.names-1 do
		tt[#tt+1] = status_vector:get(i*sizeof('int'), 'int')
	end
	return unpack(tt)
end

function wait(status_vector, dbh, t)
	fbtry(status_vector, 'isc_wait_for_event', dbh, t.bufsize, t.event_buf, t.result_buf)
	return event_counts(status_vector, t)
end

function listen(status_vector, dbh, t, f)
	local event_id_buf = buffer(sizeof('long'))
	local function helper(result_buf, bufsize, updated_buf)
		if bufsize > 0 then
			alien.memcpy(result_buf, updated_buf, bufsize)
		end
		f(event_counts(status_vector, t))
	end
	local callback = fbapi.isc_que_events_callback(helper)
	fbtry(status_vector, 'isc_que_events', dbh, event_id_buf, t.bufsize, t.event_buf, callback, t.result_buf)
	return event_id_buf
end

function cancel(status_vector, dbh, event_id_buf)
	fbtry(status_vector, 'isc_cancel_events', dbh, event_id_buf)
end

