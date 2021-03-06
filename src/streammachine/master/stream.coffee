_u      = require "underscore"
uuid    = require "node-uuid"
URL     = require "url"

Rewind              = require '../rewind_buffer'
FileSource          = require "../sources/file"
ProxySource         = require '../sources/proxy_room'
TranscodingSource   = require "../sources/transcoding"
HLSSegmenter        = require "../rewind/hls_segmenter"

# Master streams are about source management.

# Events:
# * source: emits when a source is promoted to active
# * add_source: emits when a source is added to the source list, but not made active
# * disconnect: emits when a source disconnects. `active` boolean indicates whether
#   this was the live source. `count` integer indicates remaining sources

module.exports = class Stream extends require('events').EventEmitter
    DefaultOptions:
        meta_interval:      32768
        max_buffer:         4194304 # 4 megabits (64 seconds of 64k audio)
        key:                null
        seconds:            (60*60*4) # 4 hours
        burst:              30
        source_password:    null
        host:               null
        fallback:           null
        acceptSourceMeta:   false
        log_minutes:        true
        monitored:          false
        metaTitle:          ""
        metaUrl:            ""
        format:             "mp3"
        preroll:            ""
        preroll_key:        ""
        root_route:         false
        group:              null
        bandwidth:          0
        codec:              null
        ffmpeg_args:        null

    constructor: (@core,@key,@log,opts)->
        @opts = _u.defaults opts||{}, @DefaultOptions

        @sources = []
        @source = null

        # Cache the last stream vitals we've seen
        @_vitals = null

        @emitDuration = 0

        @STATUS = "Initializing"

        @log.event "Stream is initializing."

        # -- Initialize Master Rewinder -- #

        # set up a rewind buffer, for use in bringing new slaves up to speed
        # or to transfer to a new master when restarting
        @log.info "Initializing RewindBuffer for master stream."
        @rewind = new Rewind
            seconds:    @opts.seconds
            burst:      @opts.burst
            key:        "master__#{@key}"
            log:        @log.child(module:"rewind")
            hls:        @opts.hls?.segment_duration

        # Rewind listens to us, not to our source
        @rewind.emit "source", @

        # Pass along buffer loads
        @rewind.on "buffer", (c) => @emit "buffer", c

        # if we're doing HLS, pass along new segments
        if @opts.hls?
            @rewind.hls_segmenter.on "snapshot", (snap) =>
                @emit "hls_snapshot", snap

        # -- Set up data functions -- #

        @_meta =
            StreamTitle:    @opts.metaTitle
            StreamUrl:      ""

        @sourceMetaFunc = (meta) =>
            if @opts.acceptSourceMeta
                @setMetadata meta

        @dataFunc = (data) =>
            # inject our metadata into the data object
            @emit "data", _u.extend {}, data, meta:@_meta

        @vitalsFunc = (vitals) =>
            @_vitals = vitals
            @emit "vitals", vitals

        # -- Stream Variants -- #



        # -- Hardcoded Source -- #

        # This is an initial source like a proxy that should be connected from
        # our end, rather than waiting for an incoming connection

        if @opts.fallback?
            # what type of a fallback is this?
            uri = URL.parse @opts.fallback

            newsource = switch uri.protocol
                when "file:"
                    new FileSource
                        format:     @opts.format
                        filePath:   uri.path
                        logger:     @log

                when "http:"
                    new ProxySource
                        format:     @opts.format
                        url:        @opts.fallback
                        fallback:   true
                        logger:     @log

                else
                    null

            if newsource
                newsource.on "connect", =>
                    @addSource newsource, (err) =>
                        if err
                            @log.error "Connection to fallback source failed."
                        else
                            @log.event "Fallback source connected."

                newsource.on "error", (err) =>
                    @log.error "Fallback source error: #{err}", error:err

            else
                @log.error "Unable to determine fallback source type for #{@opts.fallback}"

    #----------

    # Return our configuration

    config: ->
        @opts

    #----------

    vitals: (cb) ->
        _vFunc = (v) =>
            cb? null, v

        if @_vitals
            _vFunc @_vitals
        else
            @once "vitals", _vFunc

    #----------

    getHLSSnapshot: (cb) ->
        if @rewind.hls_segmenter
            @rewind.hls_segmenter.snapshot cb
        else
            cb "Stream does not support HLS"

    #----------

    getStreamKey: (cb) ->
        if @_vitals
            cb? @_vitals.streamKey
        else
            @once "vitals", => cb? @_vitals.streamKey

    #----------

    status: ->
        # id is DEPRECATED in favor of key
        key:        @key
        id:         @key
        vitals:     @_vitals
        sources:    ( s.info() for s in @sources )
        rewind:     @rewind._rStatus()

    #----------

    setMetadata: (opts,cb) ->
        if opts.StreamTitle? || opts.title?
            @_meta.StreamTitle = opts.StreamTitle||opts.title

        if opts.StreamUrl? || opts.url?
            @_meta.StreamUrl = opts.StreamUrl||opts.url

        @emit "meta", @_meta

        cb? null, @_meta

    #----------

    addSource: (source,cb) ->
        # add a disconnect monitor
        source.once "disconnect", =>
            # remove it from the list
            @sources = _u(@sources).without source

            # was this our current source?
            if @source == source
                # yes...  need to promote the next one (if there is one)
                if @sources.length > 0
                    @useSource @sources[0]
                    @emit "disconnect", active:true, count:@sources.length, source:@source
                else
                    @log.alert "Source disconnected. No sources remaining."
                    @_disconnectSource @source
                    @source = null
                    @emit "disconnect", active:true, count:0, source:null
            else
                # no... just remove it from the list
                @log.event "Inactive source disconnected."
                @emit "disconnect", active:false, count:@sources.length, source:@source

        # -- Add the source to our list -- #

        @sources.push source

        # -- Should this source be made active? -- #

        # check whether this source should be made active. It should be if
        # the active source is defined as a fallback

        if @sources[0] == source || @sources[0]?.isFallback
            # our new source should be promoted
            @log.event "Promoting new source to active.", source:(source.TYPE?() ? source.TYPE)
            @useSource source, cb

        else
            # add the source to the end of our list
            @log.event "Source connected.", source:(source.TYPE?() ? source.TYPE)

            # and emit our source event
            @emit "add_source", source

            cb? null

    #----------

    _disconnectSource: (s) ->
        s.removeListener "metadata",   @sourceMetaFunc
        s.removeListener "data",       @dataFunc
        s.removeListener "vitals",     @vitalsFunc

    #----------

    useSource: (newsource,cb=null) ->
        # stash our existing source if we have one
        old_source = @source || null

        # set a five second timeout for the switchover
        alarm = setTimeout =>
            @log.error "useSource failed to get switchover within five seconds.",
                new_source: (newsource.TYPE?() ? newsource.TYPE)
                old_source: (old_source?.TYPE?() ? old_source?.TYPE)

            cb? new Error "Failed to switch."
        , 5000

        # Look for a header before switching
        newsource.vitals (err,vitals) =>
            if @source && old_source != @source
                # source changed while we were waiting for vitals. we'll
                # abort our change attempt
                @log.event "Source changed while waiting for vitals.",
                    new_source:     (newsource.TYPE?() ? newsource.TYPE)
                    old_source:     (old_source?.TYPE?() ? old_source?.TYPE)
                    current_source: (@source.TYPE?() ? @source.TYPE)

                return cb? new Error "Source changed while waiting for vitals."

            if old_source
                # unhook from the old source's events
                @_disconnectSource(old_source)

            @source = newsource

            # connect to the new source's events
            newsource.on "metadata",   @sourceMetaFunc
            newsource.on "data",       @dataFunc
            newsource.on "vitals",     @vitalsFunc

            # how often will we be emitting?
            @emitDuration = vitals.emitDuration

            # note that we've got a new source
            process.nextTick =>
                @log.event "New source is active.",
                    new_source: (newsource.TYPE?() ? newsource.TYPE)
                    old_source: (old_source?.TYPE?() ? old_source?.TYPE)

                @emit "source", newsource
                @vitalsFunc vitals

            # jump our new source to the front of the list (and remove it from
            # anywhere else in the list)
            @sources = _u.flatten [newsource,_u(@sources).without newsource]

            # cancel our timeout
            clearTimeout alarm

            # give the a-ok to the callback
            cb? null

    #----------

    promoteSource: (uuid,cb) ->
        # do we have a source with this UUID?
        if ns = _u(@sources).find( (s) => s.uuid == uuid )
            # we do...
            # make sure it isn't already the active source, though
            if ns == @sources[0]
                # it is.  nothing to be done.
                cb? null, msg:"Source is already active", uuid:uuid
            else
                # it isn't. we can try to promote it
                @useSource ns, (err) =>
                    if err
                        cb? err
                    else
                        cb? null, msg:"Promoted source to active.", uuid:uuid

        else
            cb? "Unable to find a source with that UUID on #{@key}"

    #----------

    configure: (new_opts,cb) ->
        # allow updates, but only to keys that are present in @DefaultOptions.
        for k,v of @DefaultOptions
            @opts[k] = new_opts[k] if new_opts[k]?

            # convert to a number if necessary
            @opts[k] = Number(@opts[k]) if _u.isNumber(@DefaultOptions[k])

        if @key != @opts.key
            @key = @opts.key

        # did they update the metaTitle?
        if new_opts.metaTitle
            @setMetadata title:new_opts.metaTitle

        # Update our rewind settings
        @rewind.setRewind @opts.seconds, @opts.burst

        @emit "config"

        cb? null, @config()

    #----------

    getRewind: (cb) ->
        @rewind.dumpBuffer (err,writer) =>
            cb? null, writer

    #----------

    destroy: ->
        # shut down our sources and go away
        s.disconnect() for s in @sources
        @emit "destroy"
        true

    #----------

    class @StreamGroup extends require("events").EventEmitter
        constructor: (@key,@log) ->
            @streams        = {}
            @transcoders    = {}
            @hls_min_id     = null

            @_stream = null

        #----------

        addStream: (stream) ->
            if !@streams[ stream.key ]
                @log.debug "SG #{@key}: Adding stream #{stream.key}"

                @streams[ stream.key ] = stream

                @_cloneStream(stream) if !@_stream

                # listen in case it goes away
                delFunc = =>
                    @log.debug "SG #{@key}: Stream disconnected: #{ stream.key }"
                    delete @streams[ stream.key ]

                stream.on "disconnect", delFunc

                stream.on "config", =>
                    delFunc() if stream.opts.group != @key

                    if stream.opts.ffmpeg_args && !@transcoders[ stream.key ]
                        tsource = @_startTranscoder stream
                        @transcoders[ stream.key ] = tsource

                if stream.opts.ffmpeg_args
                    tsource = @_startTranscoder stream
                    @transcoders[ stream.key ] = tsource

                # if HLS is enabled, sync the stream to the rest of the group
                stream.rewind.hls_segmenter?.syncToGroup @

        #----------

        status: ->
            id:         @key
            sources:    ( s.info() for s in @_stream.sources )

        #----------

        _startTranscoder: (stream) ->
            @log.debug "SG #{@key}: Setting up transcoding source for #{ stream.key }"

            # -- create a transcoding source -- #

            tsource = new TranscodingSource
                stream:         @_stream
                ffmpeg_args:    stream.opts.ffmpeg_args
                format:         stream.opts.format
                logger:         stream.log

            stream.addSource tsource

            # if our transcoder goes down, restart it
            tsource.once "disconnect", =>
                @log.info "SG #{@key}: Transcoder disconnected for #{ stream.key}. Restarting."
                @_startTranscoder(stream)

            tsource

        #----------

        hlsUpdateMinSegment: (id) ->
            if !@hls_min_id || id > @hls_min_id
                prev = @hls_min_id
                @hls_min_id = id
                @emit "hls_update_min_segment", id
                @log.debug "New HLS min segment id: #{id} (Previously: #{prev})"

        #----------

        _cloneStream: (stream) ->
            @_stream = new Stream null, @key, @log.child(stream:"_#{@key}"), _u.extend {}, stream.opts, seconds:30

        #----------
