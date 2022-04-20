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
        if address == 0x1f then
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

do
    local fd = filesystem.open("/boot.bin")

    if not fd then
        error("boot.bin not found")
    end

    for i = 0, (filesystem.size("/boot.bin") / 2) - 1 do
        memory[0x40 + i] = string.unpack(">H", filesystem.read(fd, 2))
    end
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
        end
    end
end

while true do
    local word = memory[0x40 + memory[0x1c]]
    local opcode = word & 0x1f
    local b = (word >> 5) & 0x1f
    local a = (word >> 10) & 0x3f

    memory[0x1c] = memory[0x1c] + 1

    if opcode == 0x00 then
        if b == 0x00 then
            error("Reserved special opcode")
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
        memory[b] = (memory[b] + memory[a]) % 0x10000
    else
        error(string.format("Unknown opcode %x at %x", opcode, memory[0x1c] - 1))
    end

    computer.pullSignal(0) -- Comment this out to unlimit the speed
end
