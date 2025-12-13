#!/usr/bin/env ruby
# frozen_string_literal: true

=begin
  timesync.rb - Minimal SNTP client (RFC 5905 subset)

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
    ./timesync.rb                    # query pool.ntp.org
    ./timesync.rb -t 1500 -r 2 -v time.google.com

  Notes:
  - Uses Ruby standard library (socket, etc.)
  - Works on Linux/macOS/BSD systems
=end

require 'socket'
require 'optparse'
require 'time'
require 'syslog/logger'

# Constants
NTP_PACKET_SIZE = 48
NTP_UNIX_EPOCH_DIFF = 2_208_988_800
NTP_PORT = 123
DEFAULT_SERVER = 'pool.ntp.org'
DEFAULT_TIMEOUT_MS = 2000
DEFAULT_RETRIES = 3

# Configuration class
class Config
  attr_accessor :server, :timeout_ms, :retries, :test_mode, :verbose, :use_syslog

  def initialize
    @server = DEFAULT_SERVER
    @timeout_ms = DEFAULT_TIMEOUT_MS
    @retries = DEFAULT_RETRIES
    @test_mode = false
    @verbose = false
    @use_syslog = false
  end
end

# Logger class
class Logger
  def initialize(config)
    @config = config
    @syslog = Syslog::Logger.new('timesync') if config.use_syslog
  end

  def log(level, message)
    timestamp = Time.now.strftime('%Y-%m-%d %H:%M:%S')
    $stderr.puts "#{timestamp} [#{level}] #{message}" if @config.verbose
    @syslog&.send(level.downcase.to_sym, message) if @config.use_syslog
  end

  def info(message)
    log('INFO', message)
  end

  def error(message)
    log('ERROR', message)
  end

  def warning(message)
    log('WARNING', message)
  end
end

# NTP Client class
class NTPClient
  def initialize(config, logger)
    @config = config
    @logger = logger
  end

  def create_ntp_request
    # LI=0, VN=3, Mode=3 (client)
    packet = [0x1b].pack('C')
    packet += "\x00" * (NTP_PACKET_SIZE - 1)
    packet
  end

  def ntp_to_unix_ms(data, offset)
    sec = data[offset, 4].unpack1('N')
    frac = data[offset + 4, 4].unpack1('N')

    return nil if sec < NTP_UNIX_EPOCH_DIFF

    unix_sec = sec - NTP_UNIX_EPOCH_DIFF
    usec = (frac * 1_000_000) >> 32
    (unix_sec * 1000) + (usec / 1000)
  end

  def query_server
    # Resolve hostname
    begin
      addrinfo = Socket.getaddrinfo(@config.server, nil, Socket::AF_UNSPEC, Socket::SOCK_DGRAM)
      ip = addrinfo[0][3]
      @logger.info("Resolved #{@config.server} to #{ip}")
    rescue SocketError => e
      @logger.error("Cannot resolve hostname: #{@config.server}")
      return nil
    end

    # Create UDP socket
    socket = UDPSocket.new
    socket.connect(ip, NTP_PORT)

    # Set timeout
    timeout_sec = @config.timeout_ms / 1000.0
    socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_RCVTIMEO, [timeout_sec.to_i, (timeout_sec % 1 * 1_000_000).to_i].pack('l_2'))
    socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_SNDTIMEO, [timeout_sec.to_i, (timeout_sec % 1 * 1_000_000).to_i].pack('l_2'))

    begin
      # Send request
      request = create_ntp_request
      t1_ms = (Time.now.to_f * 1000).to_i

      socket.send(request, 0)
      @logger.info("Sent NTP request to #{ip}:#{NTP_PORT}")

      # Receive response
      response, _ = socket.recvfrom(NTP_PACKET_SIZE)
      t4_ms = (Time.now.to_f * 1000).to_i

      if response.length < NTP_PACKET_SIZE
        @logger.error("Received incomplete packet: #{response.length} bytes")
        return nil
      end

      @logger.info("Received #{response.length} bytes from server")

      # Parse timestamps
      t2_ms = ntp_to_unix_ms(response, 32)  # Receive timestamp
      t3_ms = ntp_to_unix_ms(response, 40)  # Transmit timestamp

      unless t2_ms && t3_ms
        @logger.error('Invalid NTP timestamps in response')
        return nil
      end

      # Calculate offset and RTT
      offset_ms = ((t2_ms - t1_ms) + (t3_ms - t4_ms)) / 2
      rtt_ms = (t4_ms - t1_ms) - (t3_ms - t2_ms)

      @logger.info("RTT=#{rtt_ms} ms, Offset=#{offset_ms} ms")

      {
        offset_ms: offset_ms,
        rtt_ms: rtt_ms,
        remote_time_ms: t3_ms
      }
    rescue Errno::ETIMEDOUT, Errno::EAGAIN, IOError => e
      @logger.error("Failed to receive NTP response: #{e.message}")
      nil
    ensure
      socket.close if socket
    end
  end

  def query_with_retries
    @config.retries.times do |attempt|
      @logger.info("Retry attempt #{attempt + 1}/#{@config.retries}") if attempt > 0

      result = query_server
      return result if result

      sleep(0.5) if attempt < @config.retries - 1
    end

    @logger.error("Failed after #{@config.retries} attempts")
    nil
  end
end

# Time setter class
class TimeSetter
  def initialize(config, logger)
    @config = config
    @logger = logger
  end

  def root?
    Process.uid.zero?
  end

  def set_system_time(remote_ms, offset_ms)
    unless root?
      @logger.warning('Not root, not setting system time.')
      return [false, 10]
    end

    new_time_sec = (remote_ms + offset_ms) / 1000
    new_time_usec = ((remote_ms + offset_ms) % 1000) * 1000

    # Try settimeofday via fiddle (FFI)
    begin
      require 'fiddle'
      require 'fiddle/import'

      module LibC
        extend Fiddle::Importer
        dlload Fiddle::Handle::DEFAULT

        Timeval = struct([
          'long tv_sec',
          'long tv_usec'
        ])

        extern 'int settimeofday(void*, void*)'
      end

      tv = LibC::Timeval.malloc
      tv.tv_sec = new_time_sec
      tv.tv_usec = new_time_usec

      result = LibC.settimeofday(tv, nil)

      if result.zero?
        @logger.info('System time updated successfully')
        return [true, 0]
      else
        @logger.error("Failed to set system time: errno #{result}")
        return [false, 10]
      end
    rescue LoadError, StandardError => e
      # Fallback to date command
      @logger.warning("settimeofday via FFI failed (#{e.message}), trying date command")

      time = Time.at(new_time_sec).utc
      date_str = time.strftime('%Y%m%d%H%M.%S')
      cmd = "date -u #{date_str} > /dev/null 2>&1"

      @logger.info("Setting system time to #{date_str}")

      if system(cmd)
        @logger.info('System time updated successfully')
        return [true, 0]
      else
        @logger.error('Failed to set system time')
        return [false, 10]
      end
    end
  end

  def validate_and_set_time(result)
    return 1 unless result

    offset_ms = result[:offset_ms]
    remote_ms = result[:remote_time_ms]

    # Check if time is reasonable (between 2000 and 2100)
    year_2000_ms = 946_684_800_000
    year_2100_ms = 4_102_444_800_000

    if remote_ms < year_2000_ms || remote_ms > year_2100_ms
      @logger.error("Remote time out of range: #{remote_ms}")
      return 1
    end

    # Check offset threshold
    if offset_ms.abs < 500
      @logger.info('Delta < 500ms, not setting system time.')
      return 0
    end

    if @config.test_mode
      @logger.info("TEST MODE: Would set time with offset #{offset_ms} ms")
      return 0
    end

    _, exit_code = set_system_time(remote_ms, offset_ms)
    exit_code
  end
end

# Main application class
class TimeSync
  def initialize
    @config = Config.new
    parse_args
    @logger = Logger.new(@config)
    @client = NTPClient.new(@config, @logger)
    @setter = TimeSetter.new(@config, @logger)
  end

  def parse_args
    parser = OptionParser.new do |opts|
      opts.banner = 'Usage: timesync.rb [options] [ntp-server]'

      opts.on('-t TIMEOUT', '--timeout TIMEOUT', Integer, 'Timeout in milliseconds (default: 2000, max: 6000)') do |t|
        if t > 0 && t <= 6000
          @config.timeout_ms = t
        else
          $stderr.puts 'Error: Invalid timeout value'
          exit(1)
        end
      end

      opts.on('-r RETRIES', '--retries RETRIES', Integer, 'Number of retries (default: 3, max: 10)') do |r|
        if r > 0 && r <= 10
          @config.retries = r
        else
          $stderr.puts 'Error: Invalid retries value'
          exit(1)
        end
      end

      opts.on('-n', '--test-mode', 'Run in test mode (does not actually set the system time)') do
        @config.test_mode = true
      end

      opts.on('-v', '--verbose', 'Enable verbose logging') do
        @config.verbose = true
      end

      opts.on('-s', '--syslog', 'Enable syslog logging') do
        @config.use_syslog = true
      end

      opts.on('-h', '--help', 'Display this help message') do
        puts opts
        puts "\nPositional Arguments:"
        puts "  ntp-server    The NTP server to synchronize with (default: pool.ntp.org)"
        puts "\nExamples:"
        puts "  timesync.rb"
        puts "  timesync.rb -n -v"
        puts "  timesync.rb -t 1500 -r 2 time.google.com"
        puts "  timesync.rb -nv 192.168.1.1"
        exit(0)
      end
    end

    begin
      parser.parse!
      @config.server = ARGV[0] if ARGV[0] && !ARGV[0].start_with?('-')
    rescue OptionParser::InvalidOption => e
      $stderr.puts "Error: #{e.message}"
      exit(1)
    end
  end

  def run
    @logger.info("Starting timesync for server: #{@config.server}")
    @logger.info("Timeout: #{@config.timeout_ms} ms, Retries: #{@config.retries}")

    result = @client.query_with_retries
    return 2 unless result

    # Always print RTT and offset (even without -v)
    $stderr.puts "RTT=#{result[:rtt_ms]} ms, Offset=#{result[:offset_ms]} ms"

    @setter.validate_and_set_time(result)
  end
end

# Entry point
if __FILE__ == $PROGRAM_NAME
  app = TimeSync.new
  exit_code = app.run
  exit(exit_code)
end
