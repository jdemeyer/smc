###
(c) William Stein, 2014

Synchronized document-oriented database, based on differential synchronization.


NOTE: The API is sort of like <http://hood.ie/#docs>, though I found that *after* I wrote this.
The main difference is my syncdb doesn't use a database, instead using a file, and also it
doesn't use localStorage.  HN discussion: <https://news.ycombinator.com/item?id=7767765>

###


{EventEmitter} = require('events')


{defaults, required, from_json, hash_string, len} = require('misc')
syncdoc = require('syncdoc')

misc = require('misc')

to_json = (s) ->
    try
        return misc.to_json(s)
    catch e
        console.log("UNABLE to convert this object to json", s)
        throw e

class SynchronizedDB extends EventEmitter
    constructor: (@project_id, @filename, cb) ->
        syncdoc.synchronized_string
            project_id : @project_id
            filename   : @filename    # should end with .smcdb
            cb         : (err, doc) =>
                if err
                    cb(err)
                else
                    @_doc = doc
                    @readonly = doc.readonly
                    @_data = {}
                    @_set_data_from_doc()
                    @_doc._presync = () =>
                        @_live_before_sync = @_doc.live()
                    @_doc.on 'sync', (err) =>
                        @emit('sync')
                        #console.log("syncdb -- syncing")
                        if not @_set_data_from_doc() and @_live_before_sync?
                            #console.log("DEBUG: invalid/corrupt sync request; revert it")
                            @_doc.live(@_live_before_sync)
                            @_set_data_from_doc()
                            @emit('presync')
                            @_doc.sync()
                    cb(undefined, @)

    destroy: () =>
        @_doc?.disconnect_from_session()
        delete @_doc
        delete @_data

    # set the data object to equal what is defined in the syncdoc
    #
    _set_data_from_doc: () =>
        # change/add anything that has changed or been added
        i = 0
        hashes = {}
        changes = []
        is_valid = true
        for x in @_doc.live().split('\n')
            if x.length > 0
                h = hash_string(x)
                hashes[h] = true
                if not @_data[h]?
                    try
                        data = from_json(x)
                    catch
                        # invalid/corrupted json -- still, we try out best
                        # WE will revert this, unless it is on the initial load.
                        data = {'corrupt':x}
                        is_valid = false
                    @_data[h] = {data:data, line:i}
                    changes.push({insert:misc.deep_copy(data)})
            i += 1
        # delete anything that was deleted
        for h,v of @_data
            if not hashes[h]?
                changes.push({remove:v.data})
                delete @_data[h]
        if changes.length > 0
            @emit("change", changes)
        return is_valid

    _set_doc_from_data: (hash) =>
        if hash?
            # only one line changed
            d = @_data[hash]
            v = @_doc.live().split('\n')
            v[d.line] = to_json(d.data)
        else
            # major change to doc (e.g., deleting records)
            m = []
            for hash, x of @_data
                m[x.line] = {hash:hash, x:x}
            m = (x for x in m when x?)
            line = 0
            v = []
            for z in m
                if not z?
                    continue
                z.x.line = line
                v.push(to_json(z.x.data))
                line += 1
        @_doc.live(v.join('\n'))
        @emit('presync')
        @_doc.sync()

    save: (cb) =>
        @sync (err) =>
            if err
                setTimeout((()=>@save(cb)), 3000)
            else
                @_doc.save(cb)

    sync: (cb) =>
        @_doc.sync(cb)

    # change (or create) exactly *one* database entry that matches the given where criterion.
    update: (opts) =>
        opts = defaults opts,
            set   : required
            where : required
        set = opts.set
        where = opts.where
        i = 0
        for hash, val of @_data
            match = true
            x = val.data
            for k, v of where
                if x[k] != v
                    match = false
                    break
            if match
                for k, v of set
                    x[k] = v
                @_set_doc_from_data(hash)
                return
            i += 1
        new_obj = {}
        for k, v of set
            new_obj[k] = v
        for k, v of where
            new_obj[k] = v
        hash = hash_string(to_json(new_obj))
        @_data[hash] = {data:new_obj, line:len(@_data)}
        @_set_doc_from_data(hash)

    # return list of all database objects that match given condition.
    select: (where={}) =>
        result = []
        for hash, val of @_data
            x = val.data
            match = true
            for k, v of where
                if x[k] != v
                    match = false
                    break
            if match
                result.push(x)
        return misc.deep_copy(result)

    # return first database objects that match given condition or undefined if there are no matches
    select_one: (where={}) =>
        result = []
        for hash, val of @_data
            x = val.data
            match = true
            for k, v of where
                if x[k] != v
                    match = false
                    break
            if match
                return misc.deep_copy(x)

    # delete everything that matches the given criterion; returns number of deleted items
    delete: (where, one=false) =>
        result = []
        i = 0
        for hash, val of @_data
            x = val.data
            match = true
            for k, v of where
                if x[k] != v
                    match = false
                    break
            if match
                i += 1
                delete @_data[hash]
                if one
                    break
        @_set_doc_from_data()
        return i

    # delete first thing in db that matches the given criterion
    delete_one: (where) =>
        @delete(where, true)

    # anything that couldn't be parsed from JSON as a map gets converted to {key:thing}.
    ensure_objects: (key) =>
        changes = {}
        for h,v of @_data
            if typeof(v.data) != 'object'
                x = v.data
                v.data = {}
                v.data[key] = x
                h2 = hash_string(to_json(v.data))
                delete @_data[h]
                changes[h2] = v
        if misc.len(changes) > 0
            for h, v of changes
                @_data[h] = v
            @_set_doc_from_data()

    # ensure that every db entry has a distinct uuid value for the given key
    ensure_uuid_primary_key: (key) =>
        uuids   = {}
        changes = {}
        for h,v of @_data
            if not v.data[key]? or uuids[v.data[key]]  # not defined or seen before
                v.data[key] = misc.uuid()
                h2 = hash_string(to_json(v.data))
                delete @_data[h]
                changes[h2] = v
            uuids[v.data[key]] = true
        if misc.len(changes) > 0
            for h, v of changes
                @_data[h] = v
            @_set_doc_from_data()


exports.synchronized_db = (opts) ->
    opts = defaults opts,
        project_id : required
        filename   : required
        cb         : required
    new SynchronizedDB(opts.project_id, opts.filename, opts.cb)

