local filesystem = component.proxy(computer.getBootAddress())
local gpu = component.proxy(component.list("gpu")())

local memory = setmetatable({}, {
    __newindex = function(self, address, value)
        if type(value) == "number" then
            if address >= 0x20 and address <= 0x3f then
                return -- Fail silently
            else
                rawset(self, address, value)
            end
        else
            error("bad memory value")
        end
    end,
    __index = function(self, address)
        if address >= 0x08 and address <= 0x0f then
            local ind_addr = rawget(self, address - 0x08)
            return rawget(self, ind_addr)
        elseif address == 0x1e then
            local addr = rawget(self, 0x40 + rawget(self, 0x1c))
            rawset(self, 0x1c, rawget(self, 0x1c) + 1)
            return rawget(self, addr)
        elseif address == 0x1f then
            local value = rawget(self, 0x40 + rawget(self, 0x1c))
            rawset(self, 0x1c, rawget(self, 0x1c) + 1)
            return value
        elseif address >= 0x20 and address <= 0x3f then
            return address - 0x21
        else
            return rawget(self, address) or 0
        end
    end
})

---@class DeviceInterface
---@field id integer
---@field version integer
---@field manufacturer integer
---@field interrupt function
---@field update function

---@type DeviceInterface[]
local devices = {}

---@type table<string, fun(address: string): DeviceInterface>
local drivers = {}

function drivers.drive(addr)
    local proxy = component.proxy(addr)

    return {
        interrupt = function()
            if memory[0x00] == 2 then
                local data = proxy.readSector(memory[0x03] + 1)
                local addr = 0x40 + memory[0x04]
                for i = 1, #data do
                    memory[addr + i - 1] = data:byte(i)
                end
            elseif memory[0x00] == 3 then
                local data = ""
                local addr = 0x40 + memory[0x04]
                for i = 0, 512 do
                    local char = utf8.char(memory[addr + i])
                    data = data .. char
                end
                proxy.writeSector(memory[0x03] + 1, data)
            end
        end
    }
end

function drivers.keyboard(addr)
    return {
        interrupt = function()
            if memory[0x00] == 1 then
                local signal, signal_addr, char = computer.pullSignal(0)

                if signal == "key_down" and signal_addr == addr then
                    memory[0x02] = char
                else
                    memory[0x02] = 0x00
                end
            end
        end
    }
end

function drivers.gpu(addr)
    local proxy = component.proxy(addr)

    local vram_addr = 0

    proxy.setResolution(32, 12)

    return {
        interrupt = function()
            if memory[0x00] == 0 then
                vram_addr = 0x40 + memory[0x01]
            end
        end,
        update = function()
            if vram_addr > 0 then
                for y = 1, 12 do
                    local line = ""
                    for x = 1, 32 do
                        local cell = memory[vram_addr + (y - 1) * 32 + x - 1] or 0
                        local char = cell & 0x7f
                        line = line .. string.char(char)
                    end
                    gpu.set(1, y, line)
                end
            end
        end,
    }
end

for c_addr, c_type in component.list() do
    if drivers[c_type] then
        table.insert(devices, drivers[c_type](c_addr))
    end
end

do
    local fd = filesystem.open("/boot.bin")

    if not fd then
        error("boot.bin not found")
    end

    local loadtext = "Loading boot.bin..."
    gpu.set(1,1, loadtext)
    for i = 0, (filesystem.size("/boot.bin") / 2) - 1 do
        memory[0x40 + i] = string.unpack(">H", filesystem.read(fd, 2))
    end
    gpu.set(1,1, string.rep(" ", #loadtext))
end

local function debug(fmt, ...)
    local width, _ = gpu.getResolution()
    gpu.fill(1, 1, width, 1, " ")
    gpu.set(1, 1, string.format(fmt, ...))
end

local putchar
do
    local width, height = gpu.getResolution()
    local x, y = 1, 1

    function putchar(c)
        if c == "\n" then
            x, y = 1, y + 1
        else
            gpu.set(x, y, c)
            x = x + 1
        end

        if x > width then
            x = 1
            y = y + 1
        end
        if y > height then
            y = height
            gpu.copy(1, 1, width, height, 0, -1)
            gpu.fill(1, height, width, 1, " ")
        end
    end
end

local skip = false
while true do
    local word = memory[0x40 + memory[0x1c]]
    local opcode = word & 0x1f
    local b = (word >> 5) & 0x1f
    local a = (word >> 10) & 0x3f

    memory[0x1c] = memory[0x1c] + 1

    if skip then
        skip = false

        -- Read A and B in case they refer to next word
        local d_a = memory[a]
        local d_b = memory[b]
    elseif opcode == 0x00 then
        if b == 0x00 then
            error(string.format("Reserved special opcode %x at %x", opcode, memory[0x1c] - 1))
        elseif b == 0x10 then
            memory[a] = #devices
        elseif b == 0x12 then
            if devices[memory[a] + 1] then
                devices[memory[a] + 1].interrupt()
            end
        elseif b == 0x13 then
            local str_addr = 0x40 + memory[a]
            while memory[str_addr] ~= 0 do
                putchar(string.char(memory[str_addr]))
                str_addr = str_addr + 1
            end
        elseif b == 0x14 then
            local str = tostring(memory[a])
            for i = 1, #str do
                putchar(str:sub(i, i))
            end
        else
            error(string.format("Unknown special opcode %x at %x", b, memory[0x1c] - 1))
        end
    elseif opcode == 0x01 then
        memory[b] = memory[a]
    elseif opcode == 0x02 then
        local result = (memory[b] + memory[a])
        memory[b] = result & 0xffff
        if result > 0xffff then
            memory[0x1d] = 0x0001
        end
    elseif opcode == 0x03 then
        local result = (memory[b] - memory[a])
        memory[b] = result & 0xffff
        if result < 0 then
            memory[0x1d] = 0xffff
        end
    elseif opcode == 0x14 then
        if not (memory[b] > memory[a]) then
            skip = true
        end
    else
        error(string.format("Unknown opcode %x at %x", opcode, memory[0x1c] - 1))
    end

    for i, interface in ipairs(devices) do
        if interface.update then
            interface.update()
        end
    end

    computer.pullSignal(0) -- Comment this out to unlimit the speed
end
