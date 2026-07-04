local match = string.match; local gmatch = string.gmatch

-- https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/4/html/reference_guide/s1-proc-topfiles
local mod = {}

--: () -> (string | nil, string | nil)
mod.version = function ()
	local f = io.open("/proc/version")
	if not f then return nil, "could not open " .. "/proc/version" end
	local ret = f:read("*line")
	f:close()
	return ret
end

--: () -> ({ uptime: number | nil, idle: number | nil } | nil, string | nil)
mod.uptime = function ()
	local f = io.open("/proc/uptime")
	if not f then return nil, "could not open " .. "/proc/uptime" end
	local line = f:read("*line") or ""
	local uptime, idle = match(line, "(%d+%.%d+) (%d+%.%d+)")
	local ret = { uptime = tonumber(uptime), idle = tonumber(idle) }
	f:close()
	return ret
end

--: () -> ({ [integer]: { nodev: boolean, name: string }, ... } | nil, string | nil)
mod.filesystems = function ()
	local f = io.open("/proc/filesystems")
	if not f then return nil, "could not open " .. "/proc/filesystems" end
	local ret = {}
	while true do
		local line = f:read("*line")
		if not line then break end
		local nodev, name = match(line, "(%S*)\t(%S+)")
		ret[#ret+1] = { nodev = nodev == "nodev", name = name }
	end
	f:close()
	return ret
end

--: () -> ({ [integer]: { minor: number | nil, name: string }, ... } | nil, string | nil)
mod.misc = function ()
	local f = io.open("/proc/misc")
	if not f then return nil, "could not open " .. "/proc/misc" end
	local ret = {}
	while true do
		local line = f:read("*line")
		if not line then break end
		local minor, name = match(line, "%s*(%d+) (%S+)")
		ret[#ret+1] = { minor = tonumber(minor), name = name }
	end
	f:close()
	return ret
end

--: () -> ({ loadavg_1min: number | nil, loadavg_5min: number | nil, loadavg_10min: number | nil, running_procs: number | nil, total_procs: number | nil, last_pid: number | nil } | nil, string | nil)
mod.loadavg = function ()
	local f = io.open("/proc/loadavg")
	if not f then return nil, "could not open " .. "/proc/loadavg" end
	local line = f:read("*line") or ""
	local loadavg_1min, loadavg_5min, loadavg_10min, running_procs, total_procs, last_pid = match(line, "(%d+%.%d+) (%d+%.%d+) (%d+%.%d+) (%d+)/(%d+) (%d+)")
	local ret = {
		loadavg_1min = tonumber(loadavg_1min), loadavg_5min = tonumber(loadavg_5min), loadavg_10min = tonumber(loadavg_10min),
		running_procs = tonumber(running_procs), total_procs = tonumber(total_procs), last_pid = tonumber(last_pid)
	}
	f:close()
	return ret
end

mod.swap_type = {
	partition = "partition",
}

--: () -> ({ [integer]: { filename: string, type: string, size: number | nil, used: number | nil, priority: number | nil }, ... } | nil, string | nil)
mod.swaps = function ()
	local f = io.open("/proc/swaps")
	if not f then return nil, "could not open " .. "/proc/swaps" end
	local ret = {}
	local line = f:read("*line")
	while true do
		line = f:read("*line")
		if not line then break end
		local filename, type, size, used, priority = match(line, "(%S+) +(%S+)\t+(%d+)\t+(%d+)\t+(-?%d+)")
		ret[#ret+1] = { filename = filename, type = type, size = tonumber(size), used = tonumber(used), priority = tonumber(priority) }
	end
	f:close()
	return ret
end

--: () -> ({ [integer]: { major: number | nil, minor: number | nil, blocks: number | nil, name: string }, ... } | nil, string | nil)
mod.partitions = function ()
	local f = io.open("/proc/partitions")
	if not f then return nil, "could not open " .. "/proc/partitions" end
	local ret = {}
	local line = f:read("*line")
	line = f:read("*line")
	while true do
		line = f:read("*line")
		if not line then break end
		local major, minor, blocks, name = match(line, " *(%d+) +(%d+) +(%d+) +(%S+)")
		ret[#ret+1] = { major = tonumber(major), minor = tonumber(minor), blocks = tonumber(blocks), name = name }
	end
	f:close()
	return ret
end

--: () -> ({ [integer]: { device: string, path: string, filesystem: string, options: { [string]: unknown }, should_backup: boolean, fsck_order: number | nil }, ... } | nil, string | nil)
mod.mounts = function ()
	local f = io.open("/proc/mounts")
	if not f then return nil, "could not open " .. "/proc/mounts" end
	local ret = {}
	local line = f:read("*line")
	line = f:read("*line")
	while true do
		line = f:read("*line")
		if not line then break end
		local device, path, filesystem, options_raw, should_backup, fsck_order = match(line, "(.-) (.-) (.-) (.-) (%d+) (%d+)")
		local options = {}
		for option in gmatch(options_raw or "", "[^,]+") do
			local name, value = option:match("(.-)=(.+)")
			if name then options[name] = tonumber(value) or value
			else options[option] = true end
		end
		ret[#ret+1] = { device = device, path = path, filesystem = filesystem, options = options, should_backup = should_backup ~= "0", fsck_order = tonumber(fsck_order) }
	end
	f:close()
	return ret
end

-- user nice system idle iowait irq softirq steal guest guest-nice
--: () -> (unknown, string | nil)
mod.stat = function ()
	local f = io.open("/proc/stat")
	if not f then return nil, "could not open " .. "/proc/stat" end
	local ret = {}
	local line = f:read("*line") or ""
	local user, nice, system, idle, iowait, irq, softirq, steal, guest, guest_nice = match(line, "cpu +(%d+) (%d+) (%d+) (%d+) (%d+) (%d+) (%d+) (%d+) (%d+) (%d+)")
	ret.cpu = {
		user = tonumber(user), nice = tonumber(nice), system = tonumber(system), idle = tonumber(idle), iowait = tonumber(iowait),
		irq = tonumber(irq), softirq = tonumber(softirq), steal = tonumber(steal), guest = tonumber(guest), guest_nice = tonumber(guest_nice)
	}
	ret.cpus = {}
	while true do
		line = f:read("*line") or ""
		user, nice, system, idle, iowait, irq, softirq, steal, guest, guest_nice = match(line, "cpu%d+ (%d+) (%d+) (%d+) (%d+) (%d+) (%d+) (%d+) (%d+) (%d+) (%d+)")
		if not user then break end
		ret.cpus[#ret.cpus+1] = {
			user = tonumber(user), nice = tonumber(nice), system = tonumber(system), idle = tonumber(idle), iowait = tonumber(iowait),
			irq = tonumber(irq), softirq = tonumber(softirq), steal = tonumber(steal), guest = tonumber(guest), guest_nice = tonumber(guest_nice)
		}
	end
	ret.intr = {}
	local intr = ret.intr
	for n in gmatch(line, "%d+") do
		intr[#intr+1] = tonumber(n)
	end
	ret.ctxt = tonumber(match(f:read("*line") or "", "%d+"))
	ret.btime = tonumber(match(f:read("*line") or "", "%d+"))
	ret.processes = tonumber(match(f:read("*line") or "", "%d+"))
	ret.procs_running = tonumber(match(f:read("*line") or "", "%d+"))
	ret.procs_blocked = tonumber(match(f:read("*line") or "", "%d+"))
	line = f:read("*line") or ""
	ret.softirq = {}
	local softirqs = ret.softirq
	for n in gmatch(line, "%d+") do
		softirqs[#softirqs+1] = tonumber(n)
	end
	f:close()
	return ret
end

--[[all numbers are kilobytes, except for huge_pages which are counts]]
local name_to_key = {
	MemTotal = "mem_total",
	MemFree = "mem_free",
	MemAvailable = "mem_available",
	Buffers = "buffers",
	Cached = "cached",
	SwapCached = "swap_cached",
	Active = "active",
	Inactive = "inactive",
	["Active(anon)"] = "active_anon",
	["Inactive(anon)"] = "inactive_anon",
	["Active(file)"] = "active_file",
	["Inactive(file)"] = "inactive_file",
	Unevictable = "unevictable",
	Mlocked = "mlocked",
	HighTotal = "high_total",
	HighFree = "high_free",
	LowTotal = "low_total",
	LowFree = "low_free",
	SwapTotal = "swap_total",
	SwapFree = "swap_free",
	Zswap = "zswap",
	Zswapped = "zswapped",
	Dirty = "dirty",
	Writeback = "writeback",
	AnonPages = "anon_pages",
	Mapped = "mapped",
	Shmem = "shmem",
	KReclaimable = "k_reclaimable",
	Slab = "slab",
	SReclaimable = "s_reclaimable",
	SUnreclaim = "s_unreclaim",
	KernelStack = "kernel_stack",
	PageTables = "page_tables",
	SecPageTables = "sec_page_tables",
	NFS_Unstable = "nfs_unstable",
	Bounce = "bounce",
	WritebackTmp = "writeback_tmp",
	CommitLimit = "commit_limit",
	Committed_AS = "committed_as",
	VmallocTotal = "vmalloc_total",
	VmallocUsed = "vmalloc_used",
	VmallocChunk = "vmalloc_chunk",
	Percpu = "percpu",
	HardwareCorrupted = "hardware_corrupted",
	AnonHugePages = "anon_huge_pages",
	ShmemHugePages = "shmem_huge_pages",
	ShmemPmdMapped = "shmem_pmd_mapped",
	FileHugePages = "file_huge_pages",
	FilePmdMapped = "file_pmd_mapped",
	CmaTotal = "cma_total",
	CmaFree = "cma_free",
	Unaccepted = "unaccepted",
	HugePages_Total = "huge_pages_total",
	HugePages_Free = "huge_pages_free",
	HugePages_Rsvd = "huge_pages_rsvd",
	HugePages_Surp = "huge_pages_surp",
	Hugepagesize = "hugepagesize",
	Hugetlb = "hugetlb",
	DirectMap4k = "direct_map4k",
	DirectMap2M = "direct_map2_m",
	DirectMap1G = "direct_map1_g",
}

mod._get_name_to_key = function ()
	return name_to_key
end

--: () -> ({ [string]: number | nil } | nil, string | nil)
mod.meminfo = function ()
	local f = io.open("/proc/meminfo")
	if not f then return nil, "could not open " .. "/proc/meminfo" end
	local ret = {}
	while true do
		local line = f:read("*line")
		if not line then break end
		local name, n_str = match(line, "(.-): +(%d+)")
		local key = name_to_key[name]
		if key then ret[key] = tonumber(n_str) end
	end
	f:close()
	return ret
end

--: () -> ({ [string]: number | nil } | nil, string | nil)
mod.vmstat = function ()
	local f = io.open("/proc/vmstat")
	if not f then return nil, "could not open " .. "/proc/vmstat" end
	local ret = {}
	while true do
		local line = f:read("*line")
		if not line then break end
		local name, n_str = match(line, "(%S+) (%d+)")
		if name then ret[name] = tonumber(n_str) end
	end
	f:close()
	return ret
end

mod.net = {}

--: () -> ({ [string]: { receive: { bytes: number | nil, packets: number | nil, errs: number | nil, drop: number | nil, fifo: number | nil, frame: number | nil, compressed: number | nil, multicast: number | nil }, transmit: { bytes: number | nil, packets: number | nil, errs: number | nil, drop: number | nil, fifo: number | nil, colls: number | nil, carrier: number | nil, compressed: number | nil } } } | nil, string | nil)
mod.net.dev = function ()
	local f = io.open("/proc/net/dev")
	if not f then return nil, "could not open " .. "/proc/net/dev" end
	local ret = {}
	local line = f:read("*line"); line = f:read("*line")
	while true do
		line = f:read("*line")
		if not line then break end
		local name, r_bytes, r_packets, r_errs, r_drop, r_fifo, r_frame, r_compressed, r_multicast,
			t_bytes, t_packets, t_errs, t_drop, t_fifo, t_colls, t_carrier, t_compressed =
			match(line, "(%S+): +(%d+) +(%d+) +(%d+) +(%d+) +(%d+) +(%d+) +(%d+) +(%d+) +(%d+) +(%d+) +(%d+) +(%d+) +(%d+) +(%d+) +(%d+) +(%d+)")
		if name then ret[name] = {
			receive = {
				bytes = tonumber(r_bytes), packets = tonumber(r_packets), errs = tonumber(r_errs), drop = tonumber(r_drop), fifo = tonumber(r_fifo),
				frame = tonumber(r_frame), compressed = tonumber(r_compressed), multicast = tonumber(r_multicast),
			},
			transmit = {
				bytes = tonumber(t_bytes), packets = tonumber(t_packets), errs = tonumber(t_errs), drop = tonumber(t_drop), fifo = tonumber(t_fifo),
				colls = tonumber(t_colls), carrier = tonumber(t_carrier), compressed = tonumber(t_compressed),
			},
		} end
	end
	f:close()
	return ret
end

return mod
