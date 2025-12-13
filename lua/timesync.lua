#!/usr/bin/env lua
--[[
  timesync.lua - Minimal SNTP client (RFC 5905 subset)

  SPDX-License-Identifier: MIT
  Copyright (c) 2025 tsupplis

  Permission is hereby granted, free of charge, to any person obtaining a copy
  of this software and associated documentation files (the "Software"), to deal
  in the Software without restriction, including without limitation the rights
  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
  copies of the Software, and to permit persons to whom the Software is
  furnished to do so, subject to the following conditions:

  The above copyright notice and this permission notice shall be included in all
  copies or substantial portions of the Software.

  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
  SOFTWARE.

  Query server, print offset/delay in ms. Set system time if run as root and
  offset is > 500ms.

  Usage:
    ./timesync.lua                    # query pool.ntp.org
    ./timesync.lua -t 1500 -r 2 -v time.google.com

  Notes:
  - Requires LuaSocket library for UDP networking
  - Works on Linux/macOS/BSD systems
]]

local socket = require("socket")
local posix = pcall(require, "posix")

-- Constants
local NTP_PACKET_SIZE = 48
local NTP_UNIX_EPOCH_DIFF = 2208988800
local NTP_PORT = 123
local DEFAULT_SERVER = "pool.ntp.org"
local DEFAULT_TIMEOUT_MS = 2000
local DEFAULT_RETRIES = 3

-- Configuration
local config = {
    server = DEFAULT_SERVER,
    timeout_ms = DEFAULT_TIMEOUT_MS,
    retries = DEFAULT_RETRIES,
    test_mode = false,
    verbose = false,
    use_syslog = false
}

-- Logging functions
local function log_message(level, message)
    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    if config.verbose then
        io.stderr:write(string.format("%s [%s] %s\n", timestamp, level, message))
    end
    if config.use_syslog and posix then
        -- Basic syslog output (simplified)
        os.execute(string.format("logger -t timesync '%s: %s'", level, message))
    end
end

local function log_info(message)
    log_message("INFO", message)
end

local function log_error(message)
    log_message("ERROR", message)
end

local function log_warning(message)
    log_message("WARNING", message)
end

-- Convert NTP timestamp to Unix milliseconds
local function ntp_to_unix_ms(buf, offset)
    local sec = (buf:byte(offset) * 16777216) + (buf:byte(offset+1) * 65536) + 
                (buf:byte(offset+2) * 256) + buf:byte(offset+3)
    local frac = (buf:byte(offset+4) * 16777216) + (buf:byte(offset+5) * 65536) + 
                 (buf:byte(offset+6) * 256) + buf:byte(offset+7)
    
    if sec < NTP_UNIX_EPOCH_DIFF then
        return nil
    end
    
    local unix_sec = sec - NTP_UNIX_EPOCH_DIFF
    local usec = math.floor((frac * 1000000) / 4294967296)
    return (unix_sec * 1000) + math.floor(usec / 1000)
end

-- Create NTP request packet
local function create_ntp_request()
    local packet = {}
    -- LI=0, VN=3, Mode=3 (client)
    packet[1] = string.char(0x1b)
    -- Rest zeros
    for i = 2, NTP_PACKET_SIZE do
        packet[i] = string.char(0)
    end
    return table.concat(packet)
end

-- Perform NTP query
local function query_ntp_server()
    local udp = socket.udp()
    if not udp then
        log_error("Failed to create UDP socket")
        return nil, "socket creation failed"
    end
    
    udp:settimeout(config.timeout_ms / 1000.0)
    
    -- Resolve server
    local ip, err = socket.dns.toip(config.server)
    if not ip then
        log_error(string.format("Cannot resolve hostname: %s", config.server))
        udp:close()
        return nil, "DNS resolution failed"
    end
    
    log_info(string.format("Resolved %s to %s", config.server, ip))
    
    local request = create_ntp_request()
    local t1_ms = math.floor(socket.gettime() * 1000)
    
    -- Send request
    local ok, err = udp:sendto(request, ip, NTP_PORT)
    if not ok then
        log_error(string.format("Failed to send NTP request: %s", err or "unknown error"))
        udp:close()
        return nil, "send failed"
    end
    
    log_info(string.format("Sent NTP request to %s:%d", ip, NTP_PORT))
    
    -- Receive response
    local response, err = udp:receive(NTP_PACKET_SIZE)
    local t4_ms = math.floor(socket.gettime() * 1000)
    
    udp:close()
    
    if not response then
        log_error(string.format("Failed to receive NTP response: %s", err or "timeout"))
        return nil, "receive failed"
    end
    
    if #response < NTP_PACKET_SIZE then
        log_error(string.format("Received incomplete packet: %d bytes", #response))
        return nil, "incomplete packet"
    end
    
    log_info(string.format("Received %d bytes from server", #response))
    
    -- Parse timestamps
    local t2_ms = ntp_to_unix_ms(response, 33)  -- Receive timestamp
    local t3_ms = ntp_to_unix_ms(response, 41)  -- Transmit timestamp
    
    if not t2_ms or not t3_ms then
        log_error("Invalid NTP timestamps in response")
        return nil, "invalid timestamps"
    end
    
    -- Calculate offset and RTT
    local offset_ms = math.floor(((t2_ms - t1_ms) + (t3_ms - t4_ms)) / 2)
    local rtt_ms = (t4_ms - t1_ms) - (t3_ms - t2_ms)
    
    log_info(string.format("RTT=%d ms, Offset=%d ms", rtt_ms, offset_ms))
    
    return {
        offset_ms = offset_ms,
        rtt_ms = rtt_ms,
        remote_time_ms = t3_ms
    }
end

-- Check if running as root
local function is_root()
    -- Try to use posix library if available
    if posix and type(posix.geteuid) == "function" then
        return posix.geteuid() == 0
    end
    
    -- Fallback: check using id command
    local handle = io.popen("id -u")
    if handle then
        local result = handle:read("*a")
        handle:close()
        return tonumber(result) == 0
    end
    
    return false
end

-- Set system time
local function set_system_time(remote_ms, offset_ms)
    if not is_root() then
        log_warning("Not root, not setting system time.")
        return false, 10
    end
    
    local new_time_sec = math.floor((remote_ms + offset_ms) / 1000)
    local new_time_usec = ((remote_ms + offset_ms) % 1000) * 1000
    
    -- Format for date command: YYYYMMDDhhmm.ss
    local date_str = os.date("!%Y%m%d%H%M.%S", new_time_sec)
    local cmd = string.format("date -u %s > /dev/null 2>&1", date_str)
    
    log_info(string.format("Setting system time to %s", date_str))
    
    local result = os.execute(cmd)
    if result == 0 or result == true then
        log_info("System time updated successfully")
        return true, 0
    else
        log_error("Failed to set system time")
        return false, 10
    end
end

-- Validate and set time if needed
local function validate_and_set_time(result)
    if not result then
        return 1
    end
    
    local offset_ms = result.offset_ms
    local remote_ms = result.remote_time_ms
    
    -- Check if time is reasonable (between 2000 and 2100)
    local year_2000_ms = 946684800000
    local year_2100_ms = 4102444800000
    
    if remote_ms < year_2000_ms or remote_ms > year_2100_ms then
        log_error(string.format("Remote time out of range: %d", remote_ms))
        return 1
    end
    
    -- Check offset threshold
    if math.abs(offset_ms) < 500 then
        log_info(string.format("Delta < 500ms, not setting system time."))
        return 0
    end
    
    if config.test_mode then
        log_info(string.format("TEST MODE: Would set time with offset %d ms", offset_ms))
        return 0
    end
    
    local ok, exit_code = set_system_time(remote_ms, offset_ms)
    return exit_code
end

-- Main query function with retries
local function query_with_retries()
    for attempt = 1, config.retries do
        if attempt > 1 then
            log_info(string.format("Retry attempt %d/%d", attempt, config.retries))
        end
        
        local result, err = query_ntp_server()
        if result then
            return result
        end
        
        if attempt < config.retries then
            socket.sleep(0.5)
        end
    end
    
    log_error(string.format("Failed after %d attempts", config.retries))
    return nil
end

-- Parse command line arguments
local function parse_args(args)
    local i = 1
    while i <= #args do
        local arg = args[i]
        
        if arg == "-h" or arg == "--help" then
            print([[
Usage: timesync.lua [options] [ntp-server]

Options:
  -t timeout    Timeout in milliseconds (default: 2000, max: 6000)
  -r retries    Number of retries (default: 3, max: 10)
  -n            Run in test mode (does not actually set the system time)
  -v            Enable verbose logging
  -s            Enable syslog logging
  -h            Display this help message

Positional Arguments:
  ntp-server    The NTP server to synchronize with (default: pool.ntp.org)

Examples:
  timesync.lua
  timesync.lua -n -v
  timesync.lua -t 1500 -r 2 time.google.com
  timesync.lua -nv 192.168.1.1
]])
            os.exit(0)
        elseif arg == "-t" then
            i = i + 1
            if i <= #args then
                local timeout = tonumber(args[i])
                if timeout and timeout > 0 and timeout <= 6000 then
                    config.timeout_ms = timeout
                else
                    io.stderr:write("Error: Invalid timeout value\n")
                    os.exit(1)
                end
            end
        elseif arg == "-r" then
            i = i + 1
            if i <= #args then
                local retries = tonumber(args[i])
                if retries and retries > 0 and retries <= 10 then
                    config.retries = retries
                else
                    io.stderr:write("Error: Invalid retries value\n")
                    os.exit(1)
                end
            end
        elseif arg == "-n" then
            config.test_mode = true
        elseif arg == "-v" then
            config.verbose = true
        elseif arg == "-s" then
            config.use_syslog = true
        elseif arg:match("^%-[nvs]+$") then
            -- Combined flags like -nv, -nvs, etc.
            if arg:match("n") then config.test_mode = true end
            if arg:match("v") then config.verbose = true end
            if arg:match("s") then config.use_syslog = true end
        elseif not arg:match("^%-") then
            config.server = arg
        else
            io.stderr:write(string.format("Error: Unknown option: %s\n", arg))
            os.exit(1)
        end
        
        i = i + 1
    end
end

-- Main function
local function main(args)
    parse_args(args)
    
    log_info(string.format("Starting timesync for server: %s", config.server))
    log_info(string.format("Timeout: %d ms, Retries: %d", config.timeout_ms, config.retries))
    
    local result = query_with_retries()
    if not result then
        return 2
    end
    
    -- Always print RTT and offset (even without -v)
    io.stderr:write(string.format("RTT=%d ms, Offset=%d ms\n", result.rtt_ms, result.offset_ms))
    
    return validate_and_set_time(result)
end

-- Entry point
if arg then
    local exit_code = main(arg)
    os.exit(exit_code)
end
