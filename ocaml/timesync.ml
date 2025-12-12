(*
 * timesync.ml - Minimal SNTP client (RFC 5905 subset)
 *
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2025 tsupplis
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 *
 * Query server, print offset/delay in ms. Set system time if run as root and
 * offset is > 500ms.
 *
 * Build:
 *   ocamlopt -o timesync unix.cmxa timesync.ml
 *
 * Usage:
 *   ./timesync                    # query pool.ntp.org
 *   ./timesync -t 1500 -r 2 -s -v time.google.com
 *)

open Printf

(* Constants *)
let default_ntp_port = 123
let ntp_packet_size = 48
let ntp_unix_epoch_diff = 2208988800L
let default_server = "pool.ntp.org"
let default_timeout_ms = 2000
let default_retries = 3

(* Configuration record *)
type config = {
  server: string;
  timeout_ms: int;
  retries: int;
  verbose: bool;
  test_only: bool;
  use_syslog: bool;
}

(* Convert Unix time to milliseconds *)
let time_to_ms t =
  let sec = int_of_float t in
  let usec = int_of_float ((t -. float_of_int sec) *. 1_000_000.0) in
  Int64.(add (mul (of_int sec) 1000L) (of_int (usec / 1000)))

(* Get current time in milliseconds *)
let get_time_ms () =
  time_to_ms (Unix.gettimeofday ())

(* Log function with timestamp *)
let stderr_log fmt =
  ksprintf (fun s ->
    let t = Unix.localtime (Unix.time ()) in
    fprintf stderr "%04d-%02d-%02d %02d:%02d:%02d %s\n%!"
      (t.Unix.tm_year + 1900) (t.Unix.tm_mon + 1) t.Unix.tm_mday
      t.Unix.tm_hour t.Unix.tm_min t.Unix.tm_sec s
  ) fmt

(* Syslog wrapper *)
let syslog_log priority msg =
  try
    let cmd = sprintf "logger -t ntp_client -p user.%s '%s'" priority msg in
    ignore (Sys.command cmd)
  with _ -> ()

(* Build NTP request packet *)
let build_ntp_request () =
  let buf = Bytes.make ntp_packet_size '\000' in
  Bytes.set buf 0 '\x23';  (* LI=0, VN=4, Mode=3 *)
  buf

(* Read 32-bit big-endian integer from bytes *)
let read_be32 buf offset =
  let b0 = Int64.of_int (Char.code (Bytes.get buf offset)) in
  let b1 = Int64.of_int (Char.code (Bytes.get buf (offset + 1))) in
  let b2 = Int64.of_int (Char.code (Bytes.get buf (offset + 2))) in
  let b3 = Int64.of_int (Char.code (Bytes.get buf (offset + 3))) in
  Int64.(logor (logor (logor (shift_left b0 24) (shift_left b1 16))
                       (shift_left b2 8)) b3)

(* Convert NTP timestamp to Unix milliseconds *)
let ntp_ts_to_unix_ms buf offset =
  let sec = read_be32 buf offset in
  let frac = read_be32 buf (offset + 4) in
  if Int64.compare sec ntp_unix_epoch_diff < 0 then
    None
  else
    let usec = Int64.(div (mul frac 1_000_000L) (shift_left 1L 32)) in
    let unix_sec = Int64.sub sec ntp_unix_epoch_diff in
    Some Int64.(add (mul unix_sec 1000L) (div usec 1000L))

(* Format time in ISO format *)
let format_time ms =
  let sec = Int64.(to_float (div ms 1000L)) in
  let msec = Int64.(to_int (rem ms 1000L)) in
  let t = Unix.localtime sec in
  sprintf "%04d-%02d-%02dT%02d:%02d:%02d+0000.%03d"
    (t.Unix.tm_year + 1900) (t.Unix.tm_mon + 1) t.Unix.tm_mday
    t.Unix.tm_hour t.Unix.tm_min t.Unix.tm_sec msec

(* Perform NTP query *)
let do_ntp_query config =
  try
    (* Resolve server address *)
    let host_entry = Unix.gethostbyname config.server in
    if Array.length host_entry.Unix.h_addr_list = 0 then
      Error "No addresses found for server"
    else
      let addr = host_entry.Unix.h_addr_list.(0) in
      let sockaddr = Unix.ADDR_INET (addr, default_ntp_port) in
      
      (* Create UDP socket *)
      let sock = Unix.socket Unix.PF_INET Unix.SOCK_DGRAM 0 in
      
      (* Set receive timeout *)
      let timeout_sec = float_of_int config.timeout_ms /. 1000.0 in
      Unix.setsockopt_float sock Unix.SO_RCVTIMEO timeout_sec;
      
      (* Send NTP request *)
      let packet = build_ntp_request () in
      let local_before = get_time_ms () in
      let sent = Unix.sendto sock packet 0 ntp_packet_size [] sockaddr in
      
      if sent <> ntp_packet_size then begin
        Unix.close sock;
        Error "Failed to send complete NTP request"
      end else
        try
          (* Receive response *)
          let buf = Bytes.create ntp_packet_size in
          let (recv_len, recv_addr) = Unix.recvfrom sock buf 0 ntp_packet_size [] in
          let local_after = get_time_ms () in
          Unix.close sock;
          
          if recv_len < ntp_packet_size then
            Error "Received short NTP response"
          else
            (* Validate response *)
            let mode = Char.code (Bytes.get buf 0) land 0x07 in
            if mode <> 4 then
              Error (sprintf "Invalid mode in NTP response: %d" mode)
            else
              let stratum = Char.code (Bytes.get buf 1) in
              if stratum = 0 then
                Error "Invalid stratum in NTP response"
              else
                let version = (Char.code (Bytes.get buf 0) lsr 3) land 0x07 in
                if version < 1 || version > 4 then
                  Error (sprintf "Invalid version in NTP response: %d" version)
                else
                  (* Extract transmit timestamp *)
                  match ntp_ts_to_unix_ms buf 40 with
                  | None -> Error "Invalid transmit timestamp"
                  | Some remote_ms ->
                      let server_addr = match recv_addr with
                        | Unix.ADDR_INET (addr, _) -> Unix.string_of_inet_addr addr
                        | _ -> "unknown"
                      in
                      Ok (local_before, remote_ms, local_after, server_addr)
        with
        | Unix.Unix_error (Unix.EAGAIN, _, _) | Unix.Unix_error (Unix.EWOULDBLOCK, _, _) ->
            Unix.close sock;
            Error "Timeout waiting for NTP response"
        | e ->
            Unix.close sock;
            Error (sprintf "Exception during receive: %s" (Printexc.to_string e))
  with
  | Not_found -> Error (sprintf "Cannot resolve hostname: %s" config.server)
  | e -> Error (sprintf "Exception during query: %s" (Printexc.to_string e))

(* Set system time using external C function *)
external set_time_of_day : float -> int -> int = "caml_set_time_of_day"

let set_system_time new_time_ms =
  try
    let sec = Int64.(to_float (div new_time_ms 1000L)) in
    let usec = Int64.(to_int (mul (rem new_time_ms 1000L) 1000L)) in
    let rc = set_time_of_day sec usec in
    if rc = 0 then Ok () else Error "Failed to set system time"
  with e ->
    Error (sprintf "Exception setting time: %s" (Printexc.to_string e))

(* Main logic *)
let run config =
  if config.verbose then begin
    stderr_log "DEBUG Using server: %s" config.server;
    stderr_log "DEBUG Timeout: %d ms, Retries: %d, Syslog: %s"
      config.timeout_ms config.retries
      (if config.use_syslog then "on" else "off")
  end;
  
  (* Attempt NTP query with retries *)
  let rec attempt_query n =
    if n >= config.retries then
      Error (sprintf "Failed to contact NTP server %s after %d attempts"
               config.server config.retries)
    else begin
      if config.verbose then
        stderr_log "DEBUG Attempt (%d) at NTP query on %s ..." (n + 1) config.server;
      
      match do_ntp_query config with
      | Ok result -> Ok result
      | Error _ when n + 1 < config.retries ->
          Unix.sleepf 0.2;
          attempt_query (n + 1)
      | Error msg -> Error msg
    end
  in
  
  match attempt_query 0 with
  | Error msg ->
      stderr_log "ERROR %s" msg;
      if config.use_syslog then
        syslog_log "err" msg;
      2
  | Ok (local_before_ms, remote_ms, local_after_ms, server_addr) ->
      (* Calculate offset and roundtrip *)
      let avg_local_ms = Int64.(div (add local_before_ms local_after_ms) 2L) in
      let offset_ms = Int64.sub remote_ms avg_local_ms in
      let roundtrip_ms = Int64.sub local_after_ms local_before_ms in
      
      if config.verbose then begin
        stderr_log "DEBUG Server: %s (%s)" config.server server_addr;
        stderr_log "DEBUG Local time: %s" (format_time local_after_ms);
        stderr_log "DEBUG Remote time: %s" (format_time remote_ms);
        stderr_log "DEBUG Local before(ms): %Ld" local_before_ms;
        stderr_log "DEBUG Local after(ms): %Ld" local_after_ms;
        stderr_log "DEBUG Estimated roundtrip(ms): %Ld" roundtrip_ms;
        stderr_log "DEBUG Estimated offset remote - local(ms): %Ld" offset_ms;
        
        if config.use_syslog then
          syslog_log "info"
            (sprintf "NTP server=%s addr=%s offset_ms=%Ld rtt_ms=%Ld"
               config.server server_addr offset_ms roundtrip_ms)
      end;
      
      (* Validate roundtrip *)
      if Int64.compare roundtrip_ms 0L < 0 || Int64.compare roundtrip_ms 10000L > 0 then begin
        stderr_log "ERROR Invalid roundtrip time: %Ld ms" roundtrip_ms;
        if config.use_syslog then
          syslog_log "err" (sprintf "Invalid roundtrip time: %Ld ms" roundtrip_ms);
        1
      end else
        (* Check if offset is small *)
        let abs_offset = Int64.abs offset_ms in
        if Int64.compare abs_offset 0L > 0 && Int64.compare abs_offset 500L < 0 then begin
          if config.verbose then begin
            stderr_log "INFO Delta < 500ms, not setting system time.";
            if config.use_syslog then
              syslog_log "info" "Delta < 500ms, not setting system time"
          end;
          0
        end else
          (* Validate remote time year *)
          let remote_sec = Int64.(to_float (div remote_ms 1000L)) in
          let remote_tm = Unix.localtime remote_sec in
          let remote_year = remote_tm.Unix.tm_year + 1900 in
          
          if remote_year < 2025 || remote_year > 2200 then begin
            stderr_log "ERROR Remote year is out of valid range (2025-2200): %d" remote_year;
            if config.use_syslog then
              syslog_log "err" (sprintf "Remote year out of range: %d" remote_year);
            1
          end else if config.test_only then
            0
          else if Unix.getuid () <> 0 then begin
            stderr_log "WARNING Not root, not setting system time.";
            if config.use_syslog then
              syslog_log "warning" "Not root, not setting system time";
            0
          end else
            (* Set system time *)
            let half_rtt = Int64.div roundtrip_ms 2L in
            let new_time_ms = Int64.add remote_ms half_rtt in
            
            match set_system_time new_time_ms with
            | Ok () ->
                stderr_log "INFO System time set (%s)" (format_time new_time_ms);
                if config.use_syslog then
                  syslog_log "info" (sprintf "System time set (%s)" (format_time new_time_ms));
                0
            | Error msg ->
                stderr_log "ERROR %s" msg;
                if config.use_syslog then
                  syslog_log "err" msg;
                10

(* Command-line argument parsing *)
let () =
  let config = ref {
    server = default_server;
    timeout_ms = default_timeout_ms;
    retries = default_retries;
    verbose = false;
    test_only = false;
    use_syslog = false;
  } in
  
  let print_usage () =
    fprintf stderr "Usage: timesync [-t timeout_ms] [-r retries] [-n] [-v] [-s] [-h] [ntp server]\n";
    fprintf stderr "  server       NTP server to query (default: pool.ntp.org)\n";
    fprintf stderr "  -t timeout   Timeout in ms (default: 2000)\n";
    fprintf stderr "  -r retries   Number of retries (default: 3)\n";
    fprintf stderr "  -n           Test mode (no system time adjustment)\n";
    fprintf stderr "  -v           Verbose output\n";
    fprintf stderr "  -s           Enable syslog logging\n";
    fprintf stderr "  -h           Show this help message\n";
    exit 0
  in
  
  let rec parse_args = function
    | [] -> []
    | "-h" :: _ -> print_usage ()
    | "-t" :: value :: rest ->
        (try
          config := { !config with timeout_ms = max 1 (min 6000 (int_of_string value)) }
        with _ -> ());
        parse_args rest
    | "-r" :: value :: rest ->
        (try
          config := { !config with retries = max 1 (min 10 (int_of_string value)) }
        with _ -> ());
        parse_args rest
    | arg :: rest when String.length arg > 1 && arg.[0] = '-' && arg.[1] <> '-' ->
        (* Handle combined flags like -nv *)
        let has_h = ref false in
        for i = 1 to String.length arg - 1 do
          match arg.[i] with
          | 'h' -> has_h := true
          | 'n' -> config := { !config with test_only = true }
          | 'v' -> config := { !config with verbose = true }
          | 's' -> config := { !config with use_syslog = true }
          | _ -> ()
        done;
        if !has_h then print_usage ();
        parse_args rest
    | arg :: rest -> arg :: parse_args rest
  in
  
  let argv = Array.to_list Sys.argv in
  let positional = parse_args (List.tl argv) in
  
  (* Get server from positional argument *)
  (match positional with
  | server :: _ -> config := { !config with server }
  | [] -> ());
  
  (* Disable syslog in test mode *)
  if !config.test_only then
    config := { !config with use_syslog = false };
  
  exit (run !config)
