--[[
LuCI - Lua Configuration Interface
Copyright 2019 lisaac <https://github.com/lisaac/luci-app-dockerman>
]]--

require "luci.util"
local uci = luci.model.uci.cursor()
local docker = require "luci.model.docker"
local dk = docker.new()
local cmd_line = table.concat(arg, '/')
local create_body = {}

local images = dk.images:list().body
local networks = dk.networks:list().body
local containers = dk.containers:list({query = {all=true}}).body

local is_quot_complete = function(str)
  require "math"
  if not str then return true end
  local num = 0, w
  for w in str:gmatch("\"") do
    num = num + 1
  end
  if math.fmod(num, 2) ~= 0 then return false end
  num = 0
  for w in str:gmatch("\'") do
    num = num + 1
  end
  if math.fmod(num, 2) ~= 0 then return false end
  return true
end

local resolve_cli = function(cmd_line)
  local config = {advance = 1}
  local key_no_val = '|t|d|i|tty|rm|read_only|interactive|init|help|detach|privileged|P|publish_all|'
  local key_with_val = '|sysctl|add_host|a|attach|blkio_weight_device|cap_add|cap_drop|device|device_cgroup_rule|device_read_bps|device_read_iops|device_write_bps|device_write_iops|dns|dns_option|dns_search|e|env|env_file|expose|group_add|l|label|label_file|link|link_local_ip|log_driver|log_opt|network_alias|p|publish|security_opt|storage_opt|tmpfs|v|volume|volumes_from|blkio_weight|cgroup_parent|cidfile|cpu_period|cpu_quota|cpu_rt_period|cpu_rt_runtime|c|cpu_shares|cpus|cpuset_cpus|cpuset_mems|detach_keys|disable_content_trust|domainname|entrypoint|gpus|health_cmd|health_interval|health_retries|health_start_period|health_timeout|h|hostname|ip|ip6|ipc|isolation|kernel_memory|log_driver|mac_address|m|memory|memory_reservation|memory_swap|memory_swappiness|mount|name|network|no_healthcheck|oom_kill_disable|oom_score_adj|pid|pids_limit|restart|runtime|shm_size|sig_proxy|stop_signal|stop_timeout|ulimit|u|user|userns|uts|volume_driver|w|workdir|'
  local key_abb = {net='network',a='attach',c='cpu-shares',d='detach',e='env',h='hostname',i='interactive',l='label',m='memory',p='publish',P='publish_all',t='tty',u='user',v='volume',w='workdir'}
  local key_with_list = '|sysctl|add_host|a|attach|blkio_weight_device|cap_add|cap_drop|device|device_cgroup_rule|device_read_bps|device_read_iops|device_write_bps|device_write_iops|dns|dns_option|dns_search|e|env|env_file|expose|group_add|l|label|label_file|link|link_local_ip|log_driver|log_opt|network_alias|p|publish|security_opt|storage_opt|tmpfs|v|volume|volumes_from|'
  local key = nil
  local _key = nil
  local val = nil
  local is_cmd = false

  cmd_line = cmd_line:match("^DOCKERCLI%s+(.+)")
  for w in cmd_line:gmatch("[^%s]+") do
    if w =='\\' then
    elseif not key and not _key and not is_cmd then
      --key=val
      key, val = w:match("^%-%-([%lP%-]-)=(.+)")
      if not key then
        --key val
        key = w:match("^%-%-([%lP%-]+)")
        if not key then
          -- -v val
          key = w:match("^%-([%lP%-]+)")
          if key then
            -- for -dit
            if key:match("i") or key:match("t") or key:match("d") then
              if key:match("i") then
                config[key_abb["i"]] = true
                key:gsub("i", "")
              end
              if key:match("t") then
                config[key_abb["t"]] = true
                key:gsub("t", "")
              end
              if key:match("d") then
                config[key_abb["d"]] = true
                key:gsub("d", "")
              end
              if key:match("P") then
                config[key_abb["P"]] = true
                key:gsub("P", "")
              end
              if key == "" then key = nil end
            end
          end
        end
      end
      if key then
        key = key:gsub("-","_")
        key = key_abb[key] or key
        if key_no_val:match("|"..key.."|") then
          config[key] = true
          val = nil
          key = nil
        elseif key_with_val:match("|"..key.."|") then
          -- if key == "cap_add" then config.privileged = true end
        else
          key = nil
          val = nil
        end
      else
        config.image = w
        key = nil
        val = nil
        is_cmd = true
      end
    elseif (key or _key) and not is_cmd then
      if key == "mount" then
        -- we need resolve mount options here
        -- type=bind,source=/source,target=/app
        local _type = w:match("^type=([^,]+),") or "bind"
        local source =  (_type ~= "tmpfs") and (w:match("source=([^,]+),") or  w:match("src=([^,]+),")) or ""
        local target =  w:match(",target=([^,]+)") or  w:match(",dst=([^,]+)") or w:match(",destination=([^,]+)") or ""
        local ro = w:match(",readonly") and "ro" or nil
        if source and target then
          if _type ~= "tmpfs" then
            -- bind or volume
            local bind_propagation = (_type == "bind") and w:match(",bind%-propagation=([^,]+)") or nil
            val = source..":"..target .. ((ro or bind_propagation) and (":" .. (ro and ro or "") .. (((ro and bind_propagation) and "," or "") .. (bind_propagation and bind_propagation or ""))or ""))
          else
            -- tmpfs
            local tmpfs_mode = w:match(",tmpfs%-mode=([^,]+)") or nil
            local tmpfs_size = w:match(",tmpfs%-size=([^,]+)") or nil
            key = "tmpfs"
            val = target .. ((tmpfs_mode or tmpfs_size) and (":" .. (tmpfs_mode and ("mode=" .. tmpfs_mode) or "") .. ((tmpfs_mode and tmpfs_size) and "," or "") .. (tmpfs_size and ("size=".. tmpfs_size) or "")) or "")
            if not config[key] then config[key] = {} end
            table.insert( config[key], val )
            key = nil
            val = nil
          end
        end
      else
        val = w
      end
    elseif is_cmd then
      config["command"] = (config["command"] and (config["command"] .. " " )or "")  .. w
    end
    if (key or _key) and val then
      key = _key or key
      if key_with_list:match("|"..key.."|") then
        if not config[key] then config[key] = {} end
        if _key then
          config[key][#config[key]] = config[key][#config[key]] .. " " .. w
        else
          table.insert( config[key], val )
        end
        if is_quot_complete(config[key][#config[key]]) then
          -- clear quotation marks
          config[key][#config[key]] = config[key][#config[key]]:gsub("[\"\']", "")
          _key = nil
        else
          _key = key
        end
      else
        config[key] = (config[key] and (config[key] .. " ") or "") .. val
        if is_quot_complete(config[key]) then
          -- clear quotation marks
          config[key] = config[key]:gsub("[\"\']", "")
          _key = nil
        else
          _key = key
        end
      end
      key = nil
      val = nil
    end
  end
  return config
end
-- reslvo default config
local default_config = {}
if cmd_line and cmd_line:match("^DOCKERCLI.+") then
  default_config = resolve_cli(cmd_line)
elseif cmd_line and cmd_line:match("^duplicate/[^/]+$") then
  local container_id = cmd_line:match("^duplicate/(.+)")
  create_body = dk:containers_duplicate_config({id = container_id}) or {}
  luci.util.perror(luci.jsonc.stringify(create_body))
  if not create_body.HostConfig then create_body.HostConfig = {} end
  if next(create_body) ~= nil then
    default_config.name = nil
    default_config.image = create_body.Image
    default_config.hostname = create_body.Hostname
    default_config.tty = create_body.Tty and true or false
    default_config.interactive = create_body.OpenStdin and true or false
    default_config.privileged = create_body.HostConfig.Privileged and true or false
    default_config.restart =  create_body.HostConfig.RestartPolicy and create_body.HostConfig.RestartPolicy.name or nil
    -- default_config.network = create_body.HostConfig.NetworkMode == "default" and "bridge" or create_body.HostConfig.NetworkMode
    -- if container has leave original network, and add new network, .HostConfig.NetworkMode is INcorrect, so using first child of .NetworkingConfig.EndpointsConfig
    default_config.network = create_body.NetworkingConfig and create_body.NetworkingConfig.EndpointsConfig and next(create_body.NetworkingConfig.EndpointsConfig) or nil
    default_config.ip = default_config.network and default_config.network ~= "bridge" and default_config.network ~= "host" and default_config.network ~= "null" and create_body.NetworkingConfig.EndpointsConfig[default_config.network].IPAMConfig and create_body.NetworkingConfig.EndpointsConfig[default_config.network].IPAMConfig.IPv4Address or nil
    default_config.link = create_body.HostConfig.Links
    default_config.env = create_body.Env
    default_config.dns = create_body.HostConfig.Dns
    default_config.volume = create_body.HostConfig.Binds
    default_config.cap_add = create_body.HostConfig.CapAdd
    default_config.publish_all = create_body.HostConfig.PublishAllPorts

    if create_body.HostConfig.Sysctls and type(create_body.HostConfig.Sysctls) == "table" then
      default_config.sysctl = {}
      for k, v in pairs(create_body.HostConfig.Sysctls) do
        table.insert( default_config.sysctl, k.."="..v )
      end
    end

    if create_body.HostConfig.LogConfig and create_body.HostConfig.LogConfig.Config and type(create_body.HostConfig.LogConfig.Config) == "table" then
      default_config.log_opt = {}
      for k, v in pairs(create_body.HostConfig.LogConfig.Config) do
        table.insert( default_config.log_opt, k.."="..v )
      end
    end

    if create_body.HostConfig.PortBindings and type(create_body.HostConfig.PortBindings) == "table" then
      default_config.publish = {}
      for k, v in pairs(create_body.HostConfig.PortBindings) do
        for x, y in ipairs(v) do
          table.insert( default_config.publish, y.HostPort..":"..k:match("^(%d+)/.+").."/"..k:match("^%d+/(.+)") )
        end
      end
    end

    default_config.user = create_body.User or nil
    default_config.command = create_body.Cmd and type(create_body.Cmd) == "table" and table.concat(create_body.Cmd, " ") or nil
    default_config.advance = 1
    default_config.cpus = create_body.HostConfig.NanoCPUs
    default_config.cpu_shares =  create_body.HostConfig.CpuShares
    default_config.memory = create_body.HostConfig.Memory
    default_config.blkio_weight = create_body.HostConfig.BlkioWeight

    if create_body.HostConfig.Devices and type(create_body.HostConfig.Devices) == "table" then
      default_config.device = {}
      for _, v in ipairs(create_body.HostConfig.Devices) do
        table.insert( default_config.device, v.PathOnHost..":"..v.PathInContainer..(v.CgroupPermissions ~= "" and (":" .. v.CgroupPermissions) or "") )
      end
    end
    if create_body.HostConfig.Tmpfs and type(create_body.HostConfig.Tmpfs) == "table" then
      default_config.tmpfs = {}
      for k, v in pairs(create_body.HostConfig.Tmpfs) do
        table.insert( default_config.tmpfs, k .. (v~="" and ":" or "")..v )
      end
    end
  end
end

local m = SimpleForm("docker", translate("Docker"))
m.redirect = luci.dispatcher.build_url("admin", "services","docker", "containers")
-- m.reset = false
-- m.submit = false
-- new Container

docker_status = m:section(SimpleSection)
docker_status.template = "dockerman/apply_widget"
docker_status.err=docker:read_status()
docker_status.err=docker_status.err and docker_status.err:gsub("\n","<br>"):gsub(" ","&nbsp;")
if docker_status.err then docker:clear_status() end

local s = m:section(SimpleSection, translate("New Container"))
s.addremove = true
s.anonymous = true

local d = s:option(DummyValue,"cmd_line", translate("Resolve CLI"))
d.rawhtml  = true
d.template = "dockerman/newcontainer_resolve"

d = s:option(Value, "name", translate("Container Name"))
d.rmempty = true
d.default = default_config.name or nil

d = s:option(Flag, "interactive", translate("Interactive (-i)"))
d.rmempty = true
d.disabled = 0
d.enabled = 1
d.default = default_config.interactive and 1 or 0

d = s:option(Flag, "tty", translate("TTY (-t)"))
d.rmempty = true
d.disabled = 0
d.enabled = 1
d.default = default_config.tty and 1 or 0

d = s:option(Value, "image", translate("Docker Image"))
d.rmempty = true
d.default = default_config.image or nil
for _, v in ipairs (images) do
  if v.RepoTags then
    d:value(v.RepoTags[1], v.RepoTags[1])
  end
end

d = s:option(Flag, "_force_pull", translate("Always pull image first"))
d.rmempty = true
d.disabled = 0
d.enabled = 1
d.default = 0

d = s:option(Flag, "privileged", translate("Privileged"))
d.rmempty = true
d.disabled = 0
d.enabled = 1
d.default = default_config.privileged and 1 or 0

d = s:option(ListValue, "restart", translate("Restart Policy"))
d.rmempty = true

d:value("no", "No")
d:value("unless-stopped", "Unless stopped")
d:value("always", "Always")
d:value("on-failure", "On failure")
d.default = default_config.restart or "unless-stopped"

local d_network = s:option(ListValue, "network", translate("Networks"))
d_network.rmempty = true
d_network.default = default_config.network or "bridge"

local d_ip = s:option(Value, "ip", translate("IPv4 Address"))
d_ip.datatype="ip4addr"
d_ip:depends("network", "nil")
d_ip.default = default_config.ip or nil

d = s:option(DynamicList, "link", translate("Links with other containers"))
d.placeholder = "container_name:alias"
d.rmempty = true
d:depends("network", "bridge")
d.default = default_config.link or nil

d = s:option(DynamicList, "dns", translate("Set custom DNS servers"))
d.placeholder = "8.8.8.8"
d.rmempty = true
d.default = default_config.dns or nil

d = s:option(Value, "user", translate("User(-u)"), translate("The user that commands are run as inside the container.(format: name|uid[:group|gid])"))
d.placeholder = "1000:1000"
d.rmempty = true
d.default = default_config.user or nil

d = s:option(DynamicList, "env", translate("Environmental Variable(-e)"), translate("Set environment variables to inside the container"))
d.placeholder = "TZ=Asia/Shanghai"
d.rmempty = true
d.default = default_config.env or nil

d = s:option(DynamicList, "volume", translate("Bind Mount(-v)"), translate("Bind mount a volume"))
d.placeholder = "/media:/media:slave"
d.rmempty = true
d.default = default_config.volume or nil

local d_publish = s:option(DynamicList, "publish", translate("Exposed Ports(-p)"), translate("Publish container's port(s) to the host"))
d_publish.placeholder = "2200:22/tcp"
d_publish.rmempty = true
d_publish.default = default_config.publish or nil

d = s:option(Value, "command", translate("Run command"))
d.placeholder = "/bin/sh init.sh"
d.rmempty = true
d.default = default_config.command or nil

d = s:option(Flag, "advance", translate("Advance"))
d.rmempty = true
d.disabled = 0
d.enabled = 1
d.default = default_config.advance or 0

d = s:option(Value, "hostname", translate("Host Name"), translate("The hostname to use for the container"))
d.rmempty = true
d.default = default_config.hostname or nil
d:depends("advance", 1)

d = s:option(Flag, "publish_all", translate("Exposed All Ports(-P)"), translate("Allocates an ephemeral host port for all of a container's exposed ports"))
d.rmempty = true
d.disabled = 0
d.enabled = 1
d.default = default_config.publish_all and 1 or 0
d:depends("advance", 1)

d = s:option(DynamicList, "device", translate("Device(--device)"), translate("Add host device to the container"))
d.placeholder = "/dev/sda:/dev/xvdc:rwm"
d.rmempty = true
d:depends("advance", 1)
d.default = default_config.device or nil

d = s:option(DynamicList, "tmpfs", translate("Tmpfs(--tmpfs)"), translate("Mount tmpfs directory"))
d.placeholder = "/run:rw,noexec,nosuid,size=65536k"
d.rmempty = true
d:depends("advance", 1)
d.default = default_config.tmpfs or nil

d = s:option(DynamicList, "sysctl", translate("Sysctl(--sysctl)"), translate("Sysctls (kernel parameters) options"))
d.placeholder = "net.ipv4.ip_forward=1"
d.rmempty = true
d:depends("advance", 1)
d.default = default_config.sysctl or nil

d = s:option(DynamicList, "cap_add", translate("CAP-ADD(--cap-add)"), translate("A list of kernel capabilities to add to the container"))
d.placeholder = "NET_ADMIN"
d.rmempty = true
d:depends("advance", 1)
d.default = default_config.cap_add or nil

d = s:option(Value, "cpus", translate("CPUs"), translate("Number of CPUs. Number is a fractional number. 0.000 means no limit"))
d.placeholder = "1.5"
d.rmempty = true
d:depends("advance", 1)
d.datatype="ufloat"
d.default = default_config.cpus or nil

d = s:option(Value, "cpu_shares", translate("CPU Shares Weight"), translate("CPU shares relative weight, if 0 is set, the system will ignore the value and use the default of 1024"))
d.placeholder = "1024"
d.rmempty = true
d:depends("advance", 1)
d.datatype="uinteger"
d.default = default_config.cpu_shares or nil

d = s:option(Value, "memory", translate("Memory"), translate("Memory limit (format: <number>[<unit>]). Number is a positive integer. Unit can be one of b, k, m, or g. Minimum is 4M"))
d.placeholder = "128m"
d.rmempty = true
d:depends("advance", 1)
d.default = default_config.memory or nil

d = s:option(Value, "blkio_weight", translate("Block IO Weight"), translate("Block IO weight (relative weight) accepts a weight value between 10 and 1000"))
d.placeholder = "500"
d.rmempty = true
d:depends("advance", 1)
d.datatype="uinteger"
d.default = default_config.blkio_weight or nil

d = s:option(DynamicList, "log_opt", translate("Log driver options"), translate("The logging configuration for this container"))
d.placeholder = "max-size=1m"
d.rmempty = true
d:depends("advance", 1)
d.default = default_config.log_opt or nil

for _, v in ipairs (networks) do
  if v.Name then
    local parent = v.Options and v.Options.parent or nil
    local ip = v.IPAM and v.IPAM.Config and v.IPAM.Config[1] and v.IPAM.Config[1].Subnet or nil
    ipv6 =  v.IPAM and v.IPAM.Config and v.IPAM.Config[2] and v.IPAM.Config[2].Subnet or nil
    local network_name = v.Name .. " | " .. v.Driver  .. (parent and (" | " .. parent) or "") .. (ip and (" | " .. ip) or "").. (ipv6 and (" | " .. ipv6) or "")
    d_network:value(v.Name, network_name)

    if v.Name ~= "none" and v.Name ~= "bridge" and v.Name ~= "host" then
      d_ip:depends("network", v.Name)
    end

    if v.Driver == "bridge" then
      d_publish:depends("network", v.Name)
    end
  end
end

m.handle = function(self, state, data)
  if state ~= FORM_VALID then return end
  local tmp
  local name = data.name or ("luci_" .. os.date("%Y%m%d%H%M%S"))
  local hostname = data.hostname
  local tty = type(data.tty) == "number" and (data.tty == 1 and true or false) or default_config.tty or false
  local publish_all = type(data.publish_all) == "number" and (data.publish_all == 1 and true or false) or default_config.publish_all or false
  local interactive = type(data.interactive) == "number" and (data.interactive == 1 and true or false) or default_config.interactive or false
  local image = data.image
  local user = data.user
  if image and not image:match(".-:.+") then
    image = image .. ":latest"
  end
  local privileged = type(data.privileged) == "number" and (data.privileged == 1 and true or false) or default_config.privileged or false
  local restart = data.restart
  local env = data.env
  local dns = data.dns
  local cap_add = data.cap_add
  local sysctl = {}
  tmp = data.sysctl
  if type(tmp) == "table" then
    for i, v in ipairs(tmp) do
      local k,v1 = v:match("(.-)=(.+)")
      if k and v1 then
        sysctl[k]=v1
      end
    end
  end
  local log_opt = {}
  tmp = data.log_opt
  if type(tmp) == "table" then
    for i, v in ipairs(tmp) do
      local k,v1 = v:match("(.-)=(.+)")
      if k and v1 then
        log_opt[k]=v1
      end
    end
  end
  local network = data.network
  local ip = (network ~= "bridge" and network ~= "host" and network ~= "none") and data.ip or nil
  local volume = data.volume
  local memory = data.memory or 0
  local cpu_shares = data.cpu_shares or 0
  local cpus = data.cpus or 0
  local blkio_weight = data.blkio_weight or 500

  local portbindings = {}
  local exposedports = {}
  local tmpfs = {}
  tmp = data.tmpfs
  if type(tmp) == "table" then
    for i, v in ipairs(tmp)do
      local k= v:match("([^:]+)")
      local v1 = v:match(".-:([^:]+)") or ""
      if k then
        tmpfs[k]=v1
      end
    end
  end

  local device = {}
  tmp = data.device
  if type(tmp) == "table" then
    for i, v in ipairs(tmp) do
      local t = {}
      local _,_, h, c, p = v:find("(.-):(.-):(.+)")
      if h and c then
        t['PathOnHost'] = h
        t['PathInContainer'] = c
        t['CgroupPermissions'] = p or "rwm"
      else
        local _,_, h, c = v:find("(.-):(.+)")
        if h and c then
          t['PathOnHost'] = h
          t['PathInContainer'] = c
          t['CgroupPermissions'] = "rwm"
        else
          t['PathOnHost'] = v
          t['PathInContainer'] = v
          t['CgroupPermissions'] = "rwm"
        end
      end
      if next(t) ~= nil then
        table.insert( device, t )
      end
    end
  end

  tmp = data.publish or {}
  for i, v in ipairs(tmp) do
    for v1 ,v2 in string.gmatch(v, "(%d+):([^%s]+)") do
      local _,_,p= v2:find("^%d+/(%w+)")
      if p == nil then
        v2=v2..'/tcp'
      end
      portbindings[v2] = {{HostPort=v1}}
      exposedports[v2] = {HostPort=v1}
    end
  end

  local link = data.link
  tmp = data.command
  local command = {}
  if tmp ~= nil then
    for v in string.gmatch(tmp, "[^%s]+") do
      command[#command+1] = v
    end 
  end
  if memory ~= 0 then
    _,_,n,unit = memory:find("([%d%.]+)([%l%u]+)")
    if n then
      unit = unit and unit:sub(1,1):upper() or "B"
      if  unit == "M" then
        memory = tonumber(n) * 1024 * 1024
      elseif unit == "G" then
        memory = tonumber(n) * 1024 * 1024 * 1024
      elseif unit == "K" then
        memory = tonumber(n) * 1024
      else
        memory = tonumber(n)
      end
    end
  end

  create_body.Hostname = network ~= "host" and (hostname or name) or nil
  create_body.Tty = tty and true or false
  create_body.OpenStdin = interactive and true or false
  create_body.User = user
  create_body.Cmd = command
  create_body.Env = env
  create_body.Image = image
  create_body.ExposedPorts = exposedports
  create_body.HostConfig = create_body.HostConfig or {}
  create_body.HostConfig.Dns = dns
  create_body.HostConfig.Binds = volume
  create_body.HostConfig.RestartPolicy = { Name = restart, MaximumRetryCount = 0 }
  create_body.HostConfig.Privileged = privileged and true or false
  create_body.HostConfig.PortBindings = portbindings
  create_body.HostConfig.Memory = tonumber(memory)
  create_body.HostConfig.CpuShares = tonumber(cpu_shares)
  create_body.HostConfig.NanoCPUs = tonumber(cpus) * 10 ^ 9
  create_body.HostConfig.BlkioWeight = tonumber(blkio_weight)
  create_body.HostConfig.PublishAllPorts = publish_all
  if create_body.HostConfig.NetworkMode ~= network then
    -- network mode changed, need to clear duplicate config
    create_body.NetworkingConfig = nil
  end
  create_body.HostConfig.NetworkMode = network
  if ip then
    if create_body.NetworkingConfig and create_body.NetworkingConfig.EndpointsConfig and type(create_body.NetworkingConfig.EndpointsConfig) == "table" then
      -- ip + duplicate config
      for k, v in pairs (create_body.NetworkingConfig.EndpointsConfig) do
        if k == network and v.IPAMConfig and v.IPAMConfig.IPv4Address then
          v.IPAMConfig.IPv4Address = ip
        else
          create_body.NetworkingConfig.EndpointsConfig = { [network] = { IPAMConfig = { IPv4Address = ip } } }
        end
        break
      end
    else
      -- ip + no duplicate config
      create_body.NetworkingConfig = { EndpointsConfig = { [network] = { IPAMConfig = { IPv4Address = ip } } } }
    end
  elseif not create_body.NetworkingConfig then
    -- no ip + no duplicate config
    create_body.NetworkingConfig = nil
  end
  create_body["HostConfig"]["Tmpfs"] = tmpfs
  create_body["HostConfig"]["Devices"] = device
  create_body["HostConfig"]["Sysctls"] = sysctl
  create_body["HostConfig"]["CapAdd"] = cap_add
  create_body["HostConfig"]["LogConfig"] = next(log_opt) ~= nil and { Config = log_opt } or nil

  if network == "bridge" then
    create_body["HostConfig"]["Links"] = link
  end
  local pull_image = function(image)
    local json_stringify = luci.jsonc and luci.jsonc.stringify
    docker:append_status("Images: " .. "pulling" .. " " .. image .. "...\n")
    local res = dk.images:create({query = {fromImage=image}}, docker.pull_image_show_status_cb)
    if res and res.code == 200 and (res.body[#res.body] and not res.body[#res.body].error and res.body[#res.body].status and (res.body[#res.body].status == "Status: Downloaded newer image for ".. image or res.body[#res.body].status == "Status: Image is up to date for ".. image)) then
      docker:append_status("done\n")
    else
      res.code = (res.code == 200) and 500 or res.code
      docker:append_status("code:" .. res.code.." ".. (res.body[#res.body] and res.body[#res.body].error or (res.body.message or res.message)).. "\n")
      luci.http.redirect(luci.dispatcher.build_url("admin/services/docker/newcontainer"))
    end
  end
  docker:clear_status()
  local exist_image = false
  if image then
    for _, v in ipairs (images) do
      if v.RepoTags and v.RepoTags[1] == image then
        exist_image = true
        break
      end
    end
    if not exist_image then
      pull_image(image)
    elseif data._force_pull == 1 then
      pull_image(image)
    end
  end

  create_body = docker.clear_empty_tables(create_body)
  docker:append_status("Container: " .. "create" .. " " .. name .. "...")
  local res = dk.containers:create({name = name, body = create_body})
  if res and res.code == 201 then
    docker:clear_status()
    luci.http.redirect(luci.dispatcher.build_url("admin/services/docker/containers"))
  else
    docker:append_status("code:" .. res.code.." ".. (res.body.message and res.body.message or res.message))
    luci.http.redirect(luci.dispatcher.build_url("admin/services/docker/newcontainer"))
  end
end

return m
