_u      = require "underscore"
net     = require "net"
express = require "express"

IcecastSource = require "../sources/icecast"

module.exports = class SourceIn extends require("events").EventEmitter
    constructor: (opts) ->
        @core = opts.core

        @log = @core.log.child mode:"sourcein"

        # grab our listening port
        @port = opts.port

        @behind_proxy = opts.behind_proxy

        # create our server

        @server = net.createServer (c) => @_connection(c)

    listen: (spec=@port) ->
        #@core.log.debug "SourceIn listening on ", spec:spec
        @server.listen spec

    _connection: (sock) =>
        @log.debug "Incoming source attempt."

        # immediately attach an error listener so that a connection reset
        # doesn't crash the whole system
        sock.on "error", (err) =>
            @log.debug "Source socket errored with #{err}"

        # -- incoming data -- #

        parser = new SourceIn.IcyParser SourceIn.IcyParser.REQUEST

        readerF = =>
            parser.execute d while d = sock.read()
        sock.on "readable", readerF

        parser.on "headersComplete", (headers) =>
            if parser.info.protocol == "ICE" || parser.info.method == "SOURCE"
                @log.debug "ICY SOURCE attempt.", url:parser.info.url
                @_trySource sock, parser.info

                # get out of the way
                sock.removeListener "readable", readerF

            # TODO: Need to add support for the shoutcast metadata admin URL


    _trySource: (sock,info) =>
        _authFunc = (stream) =>
            # first, make sure the authorization header contains the right password
            @log.debug "Trying to authenticate ICY source for #{stream.key}"
            if info.headers.authorization && @_authorize(stream.opts.source_password,info.headers.authorization)
                sock.write "HTTP/1.0 200 OK\n\n"
                @log.debug "ICY source authenticated for #{stream.key}."

                # if we're behind a proxy, look for the true IP address
                source_ip = sock.remoteAddress
                if @behind_proxy && info.headers['x-forwarded-for']
                    source_ip = info.headers['x-forwarded-for']

                # now create a new source
                source = new IcecastSource
                    format:     stream.opts.format
                    sock:       sock
                    headers:    info.headers
                    logger:     stream.log
                    source_ip:  source_ip

                stream.addSource source

            else
                @log.debug "ICY source failed to authenticate for #{stream.key}."
                sock.write "HTTP/1.0 401 Unauthorized\r\n"
                sock.end "Invalid source or password.\r\n"


        # -- source request... is the endpoint one that we recognize? -- #

        # stream groups
        if Object.keys(@core.stream_groups).length > 0 && m = ///^/(#{Object.keys(@core.stream_groups).join("|")})///.exec info.url
            sg = @core.stream_groups[ m[1] ]
            _authFunc sg._stream

        else if m = ///^/(#{Object.keys(@core.streams).join("|")})///.exec info.url
            stream = @core.streams[ m[1] ]
            _authFunc stream

        else
            @log.debug "ICY source attempted to connect to bad URL.", url:info.url

            sock.write "HTTP/1.0 401 Unauthorized\r\n"
            sock.end "Invalid source or password.\r\n"

    _tmp: ->
        if ///^/admin/metadata///.match req.url
            res.writeHead 200, headers
            res.end "OK"

        else
            res.writeHead 400, headers
            res.end "Invalid method #{res.method}."

    #----------

    _authorize: (stream_passwd,header) ->
        # split the auth type from the value
        [type,value] = header.split " "

        if type.toLowerCase() == "basic"
            value = new Buffer(value, 'base64').toString('ascii')
            [user,pass] = value.split ":"

            if pass == stream_passwd
                true
            else
                false
        else
            false

    #----------

    class @IcyParser extends require("events").EventEmitter
        constructor: (type) ->
            @["INIT_"+type]()
            @offset = 0

        @REQUEST:    "REQUEST"
        @RESPONSE:   "RESPONSE"

        reinitialize: @

        execute: (@chunk) ->
            @offset = 0
            @end = @chunk.length

            while @offset < @end
                @[@state]()
                @offset++;

            true

        INIT_REQUEST: ->
            @state = "REQUEST_LINE"
            @lineState = "DATA"
            @info = headers:{}

        consumeLine: ->
            @captureStart = @offset if !@captureStart?

            byte = @chunk[@offset]
            if byte == 0x0d && @lineState == "DATA" # \r
                @captureEnd = @offset
                @lineState = "ENDING"
                return

            if @lineState == "ENDING"
                @lineState = "DATA"
                return if byte != 0x0a

                line = @chunk.toString "ascii", @captureStart, @captureEnd

                @captureStart = undefined
                @captureEnd = undefined

                return line

        requestExp: /^([A-Z]+) (.*) (ICE|HTTP)\/(1).(0|1)$/;

        REQUEST_LINE: ->
            line = @consumeLine()

            return if !line?

            match = @requestExp.exec line

            [@info.method,@info.url,@info.protocol,@info.versionMajor,@info.versionMinor] = match[1..5]

            @info.request_offset = @offset
            @info.request_line = line

            @state = "HEADER"

        headerExp: /^([^:]+): *(.*)$/

        HEADER: ->
            line = @consumeLine()

            return if !line?

            if line
                match = @headerExp.exec line
                @info.headers[match[1].toLowerCase()] = match[2]
            else
                @emit "headersComplete", @info.headers
                #@state = "BODY"