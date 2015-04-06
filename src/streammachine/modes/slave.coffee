_       = require "underscore"
nconf   = require "nconf"
cluster = require "cluster"
path    = require "path"
RPC     = require "ipc-rpc"
net     = require "net"

Logger  = require "../logger"
Slave   = require "../slave"

#----------

# basically just an event-emitting struct with our worker attributes
class Worker extends require("events").EventEmitter
    constructor: (attributes) ->
        @[k] = v for k,v of attributes

    destroy: ->
        @removeAllListeners()

#----------

module.exports = class SlaveMode extends require("./base")

    MODE: "Slave"
    constructor: (@opts,cb) ->
        @log = (new Logger @opts.log).child({component:'slave',pid:process.pid})
        @log.debug "Slave Instance initialized"

        process.title = "StreamM:slave"

        super

        @workers        = {}
        @lWorkers       = {}
        @_handle        = null
        @_haveHandle    = false
        @_shuttingDown  = false
        @_inHandoff     = false

        @_lastAddress   = null
        @_initFull      = false

        # -- Set up Internal RPC -- #

        if process.send?
            @_rpc = new RPC process, timeout:5000, functions:
                slave_port: (msg,handle,cb) =>
                    if @_lastAddress
                        cb null, @_lastAddress.port
                    else
                        cb new Error "No address returned yet."

                #---

                workers: (msg,handle,cb) =>

                #---

                stream_listener: (msg,handle,cb) =>
                    @_landListener null, msg, handle, cb

        # -- Set up Clustered Workers -- #

        cluster.setupMaster
            exec: path.resolve(__dirname,"./slave_worker.js")

        cluster.on "online", (worker) =>
            @log.info "SlaveWorker online: #{worker.id}"

            w = new Worker
                id:         worker.id
                w:          worker
                rpc:        null
                pid:        worker.process.pid
                _loaded:    false

            w.rpc = new RPC worker, functions:

                # triggered by the worker once it has its streams configured
                # (though they may not yet have data to give out)
                worker_configured: (msg,handle,cb) =>
                    #if @_haveHandle && !w._listening
                    #    w.rpc.request "listen", {fd:@_handle?.fd}, (err,address) =>
                    #        if err
                    #            @log.error "Worker listen error: #{err}" if err
                    #            return false

                    #        w._listening = true
                    #        @lWorkers[ w.id ] = w
                    #        @_lastAddress = address

                    #        @emit "worker_listening"

                    cb null

                #---

                # sent by the worker once its stream rewinds are loaded.
                # tells us that it's safe to trigger a new worker launch
                rewinds_loaded: (msg,handle,cb) =>
                    w._loaded = true
                    @lWorkers[ w.id ] = w
                    @emit "worker_loaded"

                    # ACK
                    cb null

                    # now that we're done, see if any more workers need to start
                    @_respawnWorkers()

                #---

                # a worker is allowed to shed listeners at any point by
                # sending them here. This could be part of a handoff (where
                # we've asked for the listeners), or part of the worker
                # crashing / shutting down
                send_listener: (msg,handle,cb) =>
                    if @_inHandoff
                        # we're in a handoff. ship the listener out there
                        @_rpc.request "stream_listener", msg, handle, (err) =>
                            cb err
                    else
                        # we can hand the listener to any slave except the one
                        # it came from
                        @_landListener w.id, msg, handle, cb

                #---

                # triggered by the worker to request configuration
                config: (msg,handle,cb) =>
                    cb null, @opts

            , (err) =>
                if err
                    @log.error "Error setting up RPC for new worker: #{err}"
                    worker.kill()
                    return false

                @log.debug "Worker #{w.id} is set up.", id:w.id, pid:w.pid

                @workers[ worker.id ] = w

        cluster.on "disconnect", (worker) =>
            @log.info "SlaveWorker disconnect: #{worker.id}"
            @workers[ worker.id ]?.emit "disconnect"
            delete @lWorkers[worker.id]

        cluster.on "exit", (worker) =>
            @log.info "SlaveWorker exit: #{worker.id}"
            w = @workers[ worker.id ]
            delete @workers[ worker.id ]

            w.emit "exit"
            w.destroy()

            @_respawnWorkers() if !@_shuttingDown

        @_respawnWorkers()

        # -- set up server -- #

        # We handle incoming connections here in the slave process, and then
        # distribute them to our ready workers.

        # If we're doing a handoff, we wait to receive a server handle from
        # the sending process. If not, we should go ahead and start a server
        # ourself.

        if nconf.get("handoff")
            @_acceptHandoff()
        else
            # we'll listen via our configured port
            @_openServer null, cb

    #----------

    slavePort: ->
        @_server?.address().port

    #----------

    _openServer: (handle,cb) ->
        @_server = net.createServer pauseOnConnect:true, allowHalfOpen:true
        @_server.listen handle || @opts.port, (err) =>
            if err
                @log.error "Failed to start slave server: #{err}"
                throw err

            @_server.on "connection", (conn) =>
                @_distributeConnection conn

            @log.info "Slave server is up and listening."

            cb? null, @

    #----------

    _distributeConnection: (conn) ->
        worker_ids = Object.keys(@lWorkers)

        if worker_ids.length == 0
            @once "worker_loaded", =>
                @_distributeConnection conn

        else
            id = _.sample worker_ids
            @workers[id].rpc.request "connection", null, conn, (err) =>
                if err
                    @log.error "Failed to land incoming connection: #{err}"
                    conn.destroy()

    #----------

    # Launch more workers one-at-a-time until we're back to full strength
    _respawnWorkers: ->
        if Object.keys(@workers).length < @opts.cluster
            @log.debug "Asking cluster to spawn a new worker."
            cluster.fork()

            # once the worker has forked and loaded its rewind, we'll get
            # called again and can load another worker then

        else
            @log.debug "Slave is at full strength."
            @_initFull = true
            @emit "full_strength"

    #----------

    shutdownWorker: (id,cb) ->
        if !@workers[id]
            cb? "Cannot call shutdown: Worker id unknown"
            return false

        @log.info "Sending shutdown to worker #{id}"
        @workers[id].rpc.request "shutdown", {}, (err) =>
            if err
                @log.error "Shutdown errored: #{err}"
                return false

            cb = _.once cb

            # set a shutdown timer
            timer = setTimeout =>
                cb "Failed to get worker exit before timeout."
            , 1000

            # now watch for the worker's exit event
            @workers[id].once "exit", =>
                @log.info "Shutdown succeeded for worker #{id}."
                clearTimeout timer if timer
                cb null

    #----------

    status: (cb) ->
        # send back a status for each of our workers
        status = {}
        af = _.after Object.keys(@workers).length, =>
            cb null, status

        for id,w of @workers
            do (id,w) =>
                w.rpc.request "status", (err,s) =>
                    status[ id ] = id:id, listening:w._listening, loaded:w._loaded, streams:s, pid:w.pid
                    af()

    #----------

    # Distribute a listener to one of our ready slave workers. This could be
    # an external request via handoff, or it could be an internal request from
    # a worker instance that is shutting down.

    _landListener: (sender,obj,handle,cb) ->
        # what are our potential workers?
        worker_ids = Object.keys(@lWorkers)

        # do we have a sender? if so, subtract it from our pool of candidates
        if sender
            worker_ids = _.without worker_ids, sender

        if worker_ids.length == 0
            cb "No workers ready to receive listeners."
        else
            id = _.sample(worker_ids)
            @workers[id].rpc.request "land_listener", obj, handle, (err) =>
                cb err

    #----------

    _sendHandoff: () ->
        @log.info "Starting slave handoff."

        # don't try to spawn new workers
        @_shuttingDown  = true
        @_inHandoff     = true

        # Coordinate handing off our server handle

        @_rpc.request "server_socket", {}, @_server?._handle, (err) =>
            if err
                @log.error "Error sending socket across handoff: #{err}"
                # FIXME: Proceed? Cancel?

            @log.info "Server socket transferred. Sending listener connections."

            # now we ask each worker to send its listeners. We proxy them through
            # to the new process, which in turn hands them off to its workers

            _proxyWorker = (cb) =>
                # are we done yet?
                if Object.keys(cluster.workers).length == 0
                    cb?()
                    return false

                # grab a worker id off the stack
                id = Object.keys(cluster.workers)[0]

                console.log "#{process.pid} STARTING #{id}"

                @workers[id].rpc.request "send_listeners", (err,msg) =>
                    if err
                        @log.error "Worker hit error sending listeners during handoff: #{err}", error:err, worker:id

                    # tell the worker we're done with its services
                    @workers[id].w.kill()

                    # do it again...
                    _proxyWorker cb

            _proxyWorker =>
                @log.event "Sent slave data to new process. Exiting."

                # Exit
                process.exit()

    #----------

    _acceptHandoff: ->
        @log.info "Initializing handoff receptor."

        if !@_rpc
            @log.error "Handoff called, but no RPC interface set up. Aborting."
            return false

        @_rpc.once "HANDOFF_GO", (msg,handle,cb) =>
            @_rpc.once "server_socket", (msg,handle,cb) =>
                @_handle        = handle
                @_haveHandle    = true
                @emit "server_socket"

                _go = =>
                    # let our sender know we're ready... we're already listening for
                    # the stream_listener requests on our rpc, so our job in here is
                    # done. The rest is on the sender.
                    cb null

                # wait until we're at full strength to start transferring listeners
                if @_initFull
                    _go()
                else
                    @once "full_strength", => _go()


            cb null, "GO"

        if !process.send?
            @log.error "Handoff called, but process has no send function. Aborting."
            return false

        console.log "Sending GO"
        process.send "HANDOFF_GO"

    #----------
