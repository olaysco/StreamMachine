_u = require 'underscore'

Concentrate = require "concentrate"
Dissolve    = require "dissolve"

# RewindBuffer supports play from an arbitrary position in the last X hours 
# of our stream. 

# Buffer is an array of objects. Each object should have:
# * ts:         Timestamp for when chunk was emitted from master stream
# * data:       Chunk of audio data (in either MP3 or AAC)
# * meta:       Metadata that should be running as of this chunk
# * duration:   Duration of the audio chunk

# When the buffer is dumped, it will be in the form of a loop of binary 
# packets.  Each will contain:
# * uint8: metadata length
# * Buffer: metadata, stringified into JSON and stuck in a buffer (obj is ts, 
#   duration and meta)
# * uint16: data length
# * Buffer: data chunk 

module.exports = class RewindBuffer extends require("events").EventEmitter
    constructor: ->
        @_rsecsPerChunk = Infinity
        @_rmax = null
        @_rburst = null
                        
        # each listener should be an object that defines obj._offset and 
        # obj.writeFrame. We implement RewindBuffer.Listener, but other 
        # classes can work with those pieces
        @_rlisteners = []
        
        # create buffer as an array
        @_rbuffer = []
                
        # -- set up header and frame functions -- #
        
        @_rdataFunc = (chunk) =>
            #@log.debug "Rewind data func", length:@_rbuffer.length
            # if we're at max length, shift off a chunk (or more, if needed)
            while @_rbuffer.length > @_rmax
                @_rbuffer.shift()

            # push the chunk on the buffer
            @_rbuffer.push chunk

            # loop through all connected listeners and pass the frame buffer at 
            # their offset.
            bl = @_rbuffer.length
            for l in @_rlisteners
                # we'll give them whatever is at length - offset
                l._insert @_rbuffer[ bl - 1 - l._offset ]
        
        # -- look for stream connections -- #
                
        @on "source", (newsource) =>
            @log.debug "RewindBuffer got source event"
            # -- disconnect from old source -- #
            
            if @_rsource
                @_rsource.removeListener "data", @_rdataFunc 
                @log.debug "removed old rewind data listener"
            
            # -- compute initial stats -- #
                        
            newsource.once "vitals", (vitals) =>
                if @_rstreamKey && @_rstreamKey == vitals.streamKey
                    # reconnecting, but rate matches so we can keep using 
                    # our existing buffer.
                    @log.debug "Rewind buffer validated new source.  Reusing buffer."
                
                else
                    @_rChunkLength vitals
                
                # connect our data listener
                newsource.on "data", @_rdataFunc
                    
                # keep track of our source
                @_rsource = newsource

    #----------
    
    _rChunkLength: (vitals) ->
        console.log "_rChunkLength with ", vitals
        if @_rstreamKey != vitals.streamKey
            if @_rstreamKey
                # we're reconnecting, but didn't match rate...  we 
                # should wipe out the old buffer
                @log.debug "Invalid existing rewind buffer. Reset."
                @_rbuffer = []
                
            # compute new frame numbers
            @_rsecsPerChunk   = vitals.emitDuration
            @_rmax            = Math.round @opts.seconds / @_rsecsPerChunk
            @_rburst          = Math.round @opts.burst / @_rsecsPerChunk
            
            @log.debug "Rewind's max buffer length is ", max:@_rmax, secsPerChunk:@_rsecsPerChunk, secs:vitals.emitDuration

    #----------
    
    getRewinder: (id,opts,cb) ->
        # get a rewinder object (opts.offset will tell it where to connect)
        rewind = new RewindBuffer.Rewinder @, id, opts
        
        # add it to our list of listeners
        @_raddListener rewind unless opts.pumpOnly
        
        # and return it
        cb? null, rewind
    
    #----------
    
    bufferedSecs: ->
        # convert buffer length to seconds
        Math.round @_rbuffer.length * @_rsecsPerChunk 
    
    #----------
    
    # Insert a chunk into the RewindBuffer. Inserts can only go backward, so 
    # the timestamp must be less than @_rbuffer[0].ts for a valid chunk
    _insertBuffer: (chunk) ->
        #console.log "Checking _insertBuffer: #{chunk.ts} vs #{ @_rbuffer[0]?.ts||Infinity }"
        if chunk?.ts < @_rbuffer[0]?.ts||Infinity
            @_rbuffer.unshift chunk
    
    #----------
    
    # Load a RewindBuffer.  Buffer should arrive newest first, which means 
    # that we can simply shift() it into place and don't have to lock out 
    # any incoming data.
    
    loadBuffer: (stream,cb) ->
        parser = Dissolve().loop (end) ->
            @uint8("meta_length")
                .tap ->
                    @buffer("meta",@vars.meta_length)
                        .uint16le("data_length")
                        .tap ->
                            @buffer("data",@vars.data_length)
                                .tap ->
                                    meta = JSON.parse @vars.meta.toString()
                                    @push ts:meta.ts, meta:meta.meta, data:@vars.data
                                    @vars = {}

        stream.pipe(parser)
                
        parser.on "readable", =>
            while c = parser.read()
                @_insertBuffer(c)
                @emit "buffer", c
        
        parser.on "end", => 
            @log.info "RewindBuffer is now at ", seconds:@bufferedSecs(), length:@_rbuffer.length
            cb? null
    
    #----------
    
    # Dump the rewindbuffer. We want to dump the newest data first, so that 
    # means running back from the end of the array to the front.  
    
    dumpBuffer: (stream,cb) ->
        # taking a copy of the array should effectively freeze us in place
        rbuf_copy = @_rbuffer.slice(0)
        
        # make sure there's something to send
        if rbuf_copy.length == 0
            stream.end()
            @log.debug "No rewind buffer to dump."
            cb? null
            return false
        
        c = Concentrate()
        
        # Pipe concentrated buffer to the stream object
        c.pipe stream
        
        slices = 0
        
        for i in [(rbuf_copy.length-1)..0]
            chunk = rbuf_copy[ i ]
                        
            meta_buf = new Buffer JSON.stringify ts:chunk.ts, meta:chunk.meta, duration:chunk.duration
            
            # 1) metadata length
            c.uint8 meta_buf.length
            
            # 2) metadata json
            c.buffer meta_buf
            
            # 3) data chunk length
            c.uint16le chunk.data.length
            
            # 4) data chunk
            c.buffer chunk.data
            
            c.flush()
            
            slices += 1
            
            if i == 0
                c.end()        
                @log.info "Dumped rewind buffer. Sent #{slices} slices."
                cb? null
                
            
        #console.log "Dump socket is ", stream
        
    #----------
    
    checkOffsetSecs: (secs) ->
        @checkOffset @secsToOffset(secs)
        
    #----------
    
    checkOffset: (offset) ->        
        if offset < 0
            @log.debug "offset is invalid! 0 for live."
            return 0
                    
        if @_rbuffer.length >= offset
            @log.debug "Granted. current buffer length is ", length:@_rbuffer.length
            return offset
        else
            @log.debug "Not available. Instead giving max buffer of ", length:@_rbuffer.length - 1
            return @_rbuffer.length - 1
    
    #----------
    
    secsToOffset: (secs) ->
        Math.round Number(secs) / @_rsecsPerChunk
    
    #----------
            
    offsetToSecs: (offset) ->
        Math.round Number(offset) * @_rsecsPerChunk
            
    #----------
    
    pumpSeconds: (seconds) ->
        # pump the most recent X seconds
        
        frames = @checkOffsetSecs seconds
            
        @pumpFrom(frames,frames)
        
    #----------
    
    pumpFrom: (offset,length) ->
        # we want to send _length_ frames, starting at _offset_
        
        return null if offset == 0
        
        # sanity checks...
        if offset > @_rbuffer.length
            offset = @_rbuffer.length
            
        # can't pump into the future, obviously
        length = offset if length > offset
        
        bl = @_rbuffer.length
        
        bufs        = []
        pumpLen     = 0
        duration    = 0
        
        meta = null
        
        for i in [1..length]
            b = @_rbuffer[ bl - 1 - (offset - i) ]
            pumpLen     += b.data.length
            bufs.push   b.data
            duration    += b.duration
            
            meta = b.meta if !meta
            
        @log.debug "creating buffer of ", pumpLen:pumpLen, offset:offset, length:length, bl:bl
        
        pumpBuf = Buffer.concat bufs, pumpLen
            
        return data:pumpBuf, meta:meta, duration:duration
        
    #----------
    
    burstFrom: (offset,burstSecs) ->
        # we want to send them @burst frames (if available), starting at offset.
        # return them the new offset position and the burst data
        
        # convert burstSecs to frames
        burst = @checkOffsetSecs burstSecs

        if offset > burst
            return [ offset-burst, @pumpFrom(offset,burst) ]
        else
            return [ 0, @pumpFrom(offset,offset) ]
    
    #----------
            
    _raddListener: (obj) ->
        console.log "addListener request"
        if obj._offset? && obj._offset >= 0
            console.log "Pushing to _rlisteners"
            @_rlisteners.push obj
            return true
        else
            console.log "REJECTING OBJ: ", obj._offset, obj.data
            return false
    
    #----------
    
    _rremoveListener: (obj) ->
        @_rlisteners = _u(@_rlisteners).without obj
        @disconnectListener? obj.conn_id
        return true
        
    #----------
    
    # Rewinder is the general-purpose listener stream.
    # Arguments:
    # * offset: Number
    #   - Where to position the playHead relative to now.  Should be a positive 
    #     number representing the number of seconds behind live
    # * pump: Boolean||Number
    #   - If true, burst 30 seconds or so of data as a buffer. If offset is 0, 
    #     that 30 seconds will effectively put the offset at 30. If offset is 
    #     greater than 0, burst will go forward from that point.
    #   - If a number, specifies the number of seconds of data to pump 
    #     immediately.  
    # * pumpOnly: Boolean, default false
    #   - Don't hook the Rewinder up to incoming data. Pump whatever data is 
    #     requested and then send EOF
    
    class @Rewinder extends require("stream").Readable
        constructor: (@rewind,@conn_id,opts={}) ->
            super highWaterMark:512*1024
            
            @_offset = -1
            
            @_offset = 
                if opts.offsetSecs
                    @rewind.checkOffsetSecs opts.offsetSecs
                else if opts.offset
                    @rewind.checkOffset opts.offset
                else
                    0
                        
            @rewind.log.debug "Rewinder: creation with ", opts:opts, offset:@_offset
            
            @_queue = []
            @_reading = false
            
            @_length = 0
            
            @pumpSecs = if opts.pump == true then @rewind.opts.burst else opts.pump
            
            # -- What are we sending? -- #
            
            if opts?.pumpOnly
                # we're just giving one pump of data, then EOF
                pumpFrames = @rewind.checkOffsetSecs opts.pump || 0
                @_queue.push @rewind.pumpFrom( pumpFrames, @_offset )
                            
            else if opts?.pump                
                if @_offset == 0
                    # pump some data before we start regular listening
                    @rewind.log.debug "Rewinder: Pumping #{@rewind.opts.burst} seconds."
                    @_queue.push @rewind.pumpSeconds( @pumpSecs )
                else
                    # we're offset, so we'll pump from the offset point forward instead of 
                    # back from live
                    [@_offset,data] = @rewind.burstFrom @_offset, @pumpSecs
                    @_queue.push data
                    
            @_length += @_queue[0]?.data.length
            console.log "Initial pump length is ", @_length
            
            # that's it... now RewindBuffer will call our @data directly
            @emit "readable"
            
        onFirstMeta: (cb) ->
            if @_queue.length > 0
                cb? null, @_queue[0].meta
            else
                @once "readable", =>
                    cb? null, @_queue[0].meta
            
        _read: (size) =>
            if @_reading
                return false
                
            if @_queue.length == 0
                @push ''
                return false
                
            # -- push anything queued up to size -- #
            
            @_reading = true

            sent = 0
            
            _pushQueue = =>
                next_buf = @_queue.shift()
                
                if !next_buf
                    @rewind.log.error "Shifted queue but got null", length:@_queue.length
                
                if next_buf.meta
                    @emit "meta", next_buf.meta 
                
                if @push next_buf.data
                    sent += next_buf.data.length
                    
                    if sent < size && @_queue.length > 0
                        _pushQueue()
                    else
                        if opts?.pumpOnly && @_queue.length == 0
                            # this is a listener that is only getting pump data.  Now 
                            # that we're done pumping we can go ahead and trigger EOF
                            @push null
                            @_reading = false
                            
                        else                        
                            @push ''
                            @_reading = false

            _pushQueue()
            
        _insert: (b) =>
            @_queue.push b
            @emit "readable" if !@_reading
        
        #----------
        
        # Set a new offset (in seconds)                
        setOffset: (offset) ->
            # -- make sure our offset is good -- #
            
            @_offset = @rewind.checkOffsetSecs offset

            # clear out the data we had buffered
            @_queue.slice(0)

            if @_offset == 0
                # pump some data before we start regular listening
                @rewind.log.debug "Rewinder: Pumping #{@rewind.opts.burst} seconds."
                @_queue.push @rewind.pumpSeconds( @pumpSecs )
            else
                # we're offset, so we'll pump from the offset point forward instead of 
                # back from live
                [@_offset,data] = @rewind.burstFrom @_offset, @pumpSecs
                @_queue.push data
                
            @_offset
        
        #----------
        
        # Return the current offset in chunks
        offset: ->
            @_offset
            
        #----------
        
        # Return the current offset in seconds
        offsetSecs: ->
            @rewind.offsetToSecs @_offset
            
        #----------
            
        disconnect: ->
            @rewind._rremoveListener @
            
    #----------
    