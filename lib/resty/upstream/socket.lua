local ngx_socket_tcp = ngx.socket.tcp
local ngx_timer_at = ngx.timer.at
local ngx_worker_pid = ngx.worker.pid
local ngx_log = ngx.log
local ngx_DEBUG = ngx.DEBUG
local ngx_ERR = ngx.ERR
local ngx_INFO = ngx.INFO
local str_format = string.format
local tbl_insert = table.insert
local tbl_sort = table.sort
local randomseed = math.randomseed
local random = math.random
local now = ngx.now
local pairs = pairs
local ipairs = ipairs
local getfenv = getfenv
local shared = ngx.shared
local phase = ngx.get_phase
local cjson = require('cjson')
local json_encode = cjson.encode
local json_decode = cjson.decode
local resty_lock = require('resty.lock')

local _M = {
    _VERSION = '0.01',
    available_methods = {},
    background_period = 60
}

local mt = { __index = _M }


local background_thread
background_thread = function(premature, self)
    if premature then
        ngx.log(ngx.DEBUG, ngx_worker_pid(), " background thread prematurely exiting")
        return
    end

    if not self:there_can_be_only_one() then
        return
    end

    self:_background_func()

    -- Call ourselves on a timer again
    local ok, err = ngx_timer_at(self.background_period, background_thread, self)
end


function _M.there_can_be_only_one(self)
    -- Ensure there is only 1 background thread running,
    -- by checking the current thread's PID against the shared dict PID
    local flagged_pid = self.dict:get(self.background_flag)
    local pid = ngx_worker_pid()
    if flagged_pid ~= pid then
        return false
    else
        ngx_log(ngx_DEBUG, "background thread running in ", pid)
        return true
    end
end


function _M.new(_, dict_name, id)
    local dict = shared[dict_name]
    if not dict then
        ngx_log(ngx_ERR, "Shared dictionary not found" )
        return nil
    end

    if not id then id = 'default_upstream' end
    if type(id) ~= 'string' then
        return nil, 'Upstream ID must be a string'
    end

    local self = {
        id = id,
        dict = dict,
        dict_name = dict_name
    }
    -- Create unique dictionary keys for this instance of upstream
    self.pools_key = self.id..'_pools'
    self.priority_key = self.id..'_priority_index'
    self.background_flag = self.id..'_background_running'
    self.lock_key = self.id..'_lock'

    local configured = true
    if dict:get(self.pools_key) == nil then
        dict:set(self.pools_key, json_encode({}))
        configured = false
    end

    randomseed(now())
    return setmetatable(self, mt), configured
end


-- A safe place in ngx.ctx for the current module instance (self).
function _M.ctx(self)
    -- Straight up stolen from lua-resty-core
    -- No request available so must be the init phase, return an empty table
    if not getfenv(0).__ngx_req then
        return {}
    end
    local ngx_ctx = ngx.ctx
    local id = self.id
    local ctx = ngx_ctx[id]
    if ctx == nil then
        ctx = {
            failed = {}
        }
        ngx_ctx[id] = ctx
    end
    return ctx
end


function _M.get_pools(self)
    local ctx = self:ctx()
    if ctx.pools == nil then
        local pool_str = self.dict:get(self.pools_key)
        ctx.pools = json_decode(pool_str)
    end
    return ctx.pools
end


local function get_lock_obj(self)
    local ctx = self:ctx()
    if not ctx.lock then
        ctx.lock = resty_lock:new(self.dict_name)
    end
    return ctx.lock
end


function _M.get_locked_pools(self)
    if phase() == 'init' then
        return self:get_pools()
    end
    local lock = get_lock_obj(self)
    local ok, err = lock:lock(self.lock_key)

    if ok then
        local pool_str = self.dict:get(self.pools_key)
        local pools = json_decode(pool_str)
        return pools
    else
        ngx_log(ngx_ERR, str_format("Failed to lock pools for '%s': %s", self.id, err))
    end

    return ok, err
end


function _M.unlock_pools(self)
    if phase() == 'init' then
        return true
    end
    local lock = get_lock_obj(self)
    local ok, err = lock:unlock(self.lock_key)
    if not ok then
        ngx_log(ngx_ERR, str_format("Failed to release pools lock for '%s': %s", self.id, err))
    end
    return ok, err
end


function _M.get_priority_index(self)
    local ctx = self:ctx()
    if ctx.priority_index == nil then
        local priority_str = self.dict:get(self.priority_key)
        ctx.priority_index = json_decode(priority_str)
    end
    return ctx.priority_index
end


function _M.save_pools(self, pools)
    self:ctx().pools = pools

    local serialised = json_encode(pools)
    return self.dict:set(self.pools_key, serialised)
end


function _M.sort_pools(self, pools)
    -- Create a table of priorities and a map back to the pool
    local priorities = {}
    local map = {}
    for id,p in pairs(pools) do
        map[p.priority] = id
        tbl_insert(priorities, p.priority)
    end
    tbl_sort(priorities)

    local sorted_pools = {}
    for k,pri in ipairs(priorities) do
        tbl_insert(sorted_pools, map[pri])
    end

    local serialised = json_encode(sorted_pools)
    return self.dict:set(self.priority_key, serialised)
end


function _M.init_background_thread(self)
    self._init_background_thread(self.dict, self.background_flag, background_thread, self)
end


function _M._init_background_thread(dict, flag, thread, ...)
    -- Start the thread a short time after worker is initialised
    -- Allows the pid to be correctly saved in the dict
    local ok, err = ngx_timer_at(1, thread, ...)
    if ok then
        dict:set(flag, ngx.worker.pid())
    else
        ngx_log(ngx_ERR, "Failed to start background thread: "..err)
    end
end


function _M._background_func(self)
    local now = now()

    -- Reset state for any failed hosts
    local pools = self:get_locked_pools()

    for poolid,pool in pairs(pools) do
        local failed_timeout = pool.failed_timeout
        local max_fails = pool.max_fails
        for k, host in ipairs(pool.hosts) do
            -- Reset any hosts past their timeout
             if host.lastfail ~= 0 and (host.lastfail + failed_timeout) < now then
                ngx_log(ngx_INFO,
                    str_format('Host "%s" in Pool "%s" is up', host.id, poolid)
                )
                host.up = true
                host.failcount = 0
                host.lastfail = 0
            end
        end
    end

    local ok, err = self:save_pools(pools)
    if not ok then
        ngx_log(ngx_ERR, "Error saving pools for upstream ", self.id, ": ", err)
    end
    self:unlock_pools()
    return ok, err
end


function _M.get_host_idx(id, hosts)
    for i, host in ipairs(hosts) do
        if host.id == id then
            return i
        end
    end
    return nil
end


function _M._post_process(premature, self, ctx)
    --local ctx = self:ctx()
    local failed = ctx.failed
    local now = now()
    local get_host_idx = self.get_host_idx

    local pools, err = self:get_locked_pools()
    if not pools then
        return
    end

    for poolid,hosts in pairs(failed) do
        local pool = pools[poolid]
        local failed_timeout = pool.failed_timeout
        local max_fails = pool.max_fails
        local pool_hosts = pool.hosts

        for id,_ in pairs(hosts) do
            local host_idx = get_host_idx(id, pool_hosts)
            local host = pool_hosts[host_idx]

            host.lastfail = now
            host.failcount = host.failcount + 1
            if host.failcount >= max_fails and host.up == true then
                host.up = false
                ngx_log(ngx_ERR,
                    str_format('Host "%s" in Pool "%s" is down', host.id, poolid)
                )
            end
        end
    end

    local ok, err = self:save_pools(pools)
    if not ok then
        ngx_log(ngx_ERR, "Error saving pools for upstream ", self.id, " ", err)
    end

    self:unlock_pools()
    return ok, err
end


function _M.post_process(self)
    -- Run in a background thread immediately after the request is done
    ngx_timer_at(0, self._post_process, self, self:ctx())
end


local function get_live_hosts(all_hosts, failed_hosts)
    if all_hosts == nil then
        return {}, 0, 0
    end

    local live_hosts = {}
    local total_weight = 0

    -- Get live hosts in the pool
    local num_hosts = 0
    for _, host in ipairs(all_hosts) do
        -- Disregard dead hosts
        if host.up and not failed_hosts[host.id] then
            num_hosts = num_hosts+1
            live_hosts[num_hosts] = host
            total_weight = total_weight + host.weight
        end
    end

    return live_hosts, num_hosts, total_weight
end


local function connect_failed(failed_hosts, host, poolid)
    -- Flag host as failed
    local hostid = host.id
    failed_hosts[hostid] = true
    ngx_log(ngx_ERR,
        str_format('Failed connecting to Host "%s" (%s:%d) from pool "%s"',
            hostid,
            host.host,
            host.port,
            poolid
        )
    )
end


_M.available_methods.round_robin = function(self, live_hosts, failed_hosts, total_weight, sock, poolid)
    local connected, err

    local num_hosts = #live_hosts
    -- Loop until we run out of hosts or have connected
    repeat
        local rand = random(0,total_weight)
        local host = nil
        local running = 0

        -- Might need the index afterwards
        local idx = 0
        while idx < num_hosts do
            idx = idx + 1
            local cur_host = live_hosts[idx]
            if cur_host ~= false then
                -- Keep a running total of the weights so far
                running = running + cur_host.weight
                if rand <= running then
                    host = cur_host
                    break
                end
            end
        end
        if not host then
            -- Run out of hosts, break out of the loop (go to next pool)
            break
        end

        -- Try connecting to the winner
        connected, err = sock:connect(host.host, host.port)

        if connected then
            return connected, sock, host, err
        else
            -- Set the bad host to false and reduce total_weight
            live_hosts[idx] = false
            total_weight = total_weight - host.weight

            connect_failed(failed_hosts, host, poolid)
        end
    until connected
    return nil, sock, {}, err
end


function _M.connect(self, sock)
    local ctx = self:ctx()

    -- Get pool data
    local priority_index = self:get_priority_index()
    local pools = self:get_pools()
    if not pools or not priority_index then
        return nil, 'Pools broken'
    end

    -- A socket (or resty client module) can be passed in, otherwise create a socket
    if not sock then
        sock = ngx_socket_tcp()
    end

    local available_methods = self.available_methods
    local failed = ctx.failed

    -- upvalue these to return errors later
    local connected, err = nil, nil

    -- resty modules use set_timeout instead
    local set_timeout = sock.settimeout or sock.set_timeout

    -- Loop over pools in priority order
    for _, poolid in ipairs(priority_index) do
        local pool = pools[poolid]

        if pool.up then
            local failed_hosts = failed[poolid]
            if not failed_hosts then
                failed[poolid] = {}
                failed_hosts = failed[poolid]
            end

            local live_hosts, num_hosts, total_weight = get_live_hosts(pool.hosts, failed_hosts)

            set_timeout(sock, pool.timeout)

            -- Attempt a connection
            local host
            if num_hosts == 1 then
                -- Don't bother trying to balance between 1 host
                host = live_hosts[1]
                connected, err = sock:connect(host.host, host.port)
                if not connected then
                    connect_failed(failed_hosts, host, poolid)
                end
            elseif num_hosts > 0 then
                -- Load balance between available hosts using specified method
                local method_func = available_methods[pool.method]
                connected, sock, host, err = method_func(self, live_hosts, failed_hosts, total_weight, sock, poolid)
            end

            if connected then
                pool.id = poolid
                return sock, {host = host, pool = pool}
            end
            -- Failed to connect, try next pool
        end -- Pool was dead, next
    end
    -- Didnt find any pools with working hosts, return the last error message
    return nil, err
end

return _M
