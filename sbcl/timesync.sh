#!/usr/bin/env sbcl --script
;;;; timesync.lisp - Simple SNTP client in Common Lisp
;;;;
;;;; Copyright (c) 2025 Thierry Supplis
;;;;
;;;; Permission is hereby granted, free of charge, to any person obtaining a copy
;;;; of this software and associated documentation files (the "Software"), to deal
;;;; in the Software without restriction, including without limitation the rights
;;;; to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
;;;; copies of the Software, and to permit persons to whom the Software is
;;;; furnished to do so, subject to the following conditions:
;;;;
;;;; The above copyright notice and this permission notice shall be included in all
;;;; copies or substantial portions of the Software.
;;;;
;;;; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
;;;; IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
;;;; FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
;;;; AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
;;;; LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
;;;; OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
;;;; SOFTWARE.

(require :sb-bsd-sockets)

(defconstant +ntp-port+ 123)
(defconstant +ntp-packet-size+ 48)
(defconstant +ntp-unix-epoch+ 2208988800)
(defconstant +default-timeout-ms+ 2000)
(defconstant +default-retries+ 3)
(defconstant +default-server+ "pool.ntp.org")

(defstruct config
  (server +default-server+ :type string)
  (timeout-ms +default-timeout-ms+ :type fixnum)
  (retries +default-retries+ :type fixnum)
  (verbose nil :type boolean)
  (test-only nil :type boolean)
  (use-syslog nil :type boolean))

(defun show-usage ()
  (format t "Usage: timesync [-t timeout_ms] [-r retries] [-n] [-v] [-s] [-h] [ntp server]~%")
  (format t "  server       NTP server to query (default: pool.ntp.org)~%")
  (format t "  -t timeout   Timeout in ms (default: 2000)~%")
  (format t "  -r retries   Number of retries (default: 3)~%")
  (format t "  -n           Test mode (no system time adjustment)~%")
  (format t "  -v           Verbose output~%")
  (format t "  -s           Enable syslog logging~%")
  (format t "  -h           Show this help message~%"))

(defun log-stderr (format-string &rest args)
  (let* ((time (multiple-value-bind (sec min hour day month year)
                   (get-decoded-time)
                 (format nil "~4,'0D-~2,'0D-~2,'0D ~2,'0D:~2,'0D:~2,'0D"
                         year month day hour min sec))))
    (apply #'format *error-output* (concatenate 'string time " " format-string "~%") args)
    (force-output *error-output*)))

(defun clamp (val min-val max-val)
  (max min-val (min max-val val)))

(defun parse-flags (flags config)
  (loop for char across flags
        do (case char
             (#\h (show-usage) (sb-ext:exit :code 0))
             (#\n (setf (config-test-only config) t))
             (#\v (setf (config-verbose config) t))
             (#\s (setf (config-use-syslog config) t))))
  config)

(defun parse-args (args)
  (let ((config (make-config)))
    (loop while args
          for arg = (pop args)
          do (cond
               ((string= arg "-h")
                (show-usage)
                (sb-ext:exit :code 0))
               ((string= arg "-t")
                (let ((timeout (parse-integer (pop args) :junk-allowed t)))
                  (when timeout
                    (setf (config-timeout-ms config)
                          (clamp timeout 1 6000)))))
               ((string= arg "-r")
                (let ((retries (parse-integer (pop args) :junk-allowed t)))
                  (when retries
                    (setf (config-retries config)
                          (clamp retries 1 10)))))
               ((and (> (length arg) 1)
                     (char= (char arg 0) #\-)
                     (not (char= (char arg 1) #\-)))
                ;; Combined flags like -nv
                (parse-flags (subseq arg 1) config))
               ((not (char= (char arg 0) #\-))
                (setf (config-server config) arg))))
    config))

(defun get-time-ms ()
  (multiple-value-bind (sec usec) (sb-ext:get-time-of-day)
    (+ (* sec 1000) (truncate usec 1000))))

(defun build-ntp-request ()
  (let ((packet (make-array +ntp-packet-size+ :element-type '(unsigned-byte 8) :initial-element 0)))
    (setf (aref packet 0) #x1b)
    packet))

(defun ntp-to-unix-ms (sec-bytes frac-bytes)
  (let ((ntp-sec (+ (ash (aref sec-bytes 0) 24)
                    (ash (aref sec-bytes 1) 16)
                    (ash (aref sec-bytes 2) 8)
                    (aref sec-bytes 3)))
        (ntp-frac (+ (ash (aref frac-bytes 0) 24)
                     (ash (aref frac-bytes 1) 16)
                     (ash (aref frac-bytes 2) 8)
                     (aref frac-bytes 3))))
    (if (< ntp-sec +ntp-unix-epoch+)
        (values nil "Invalid NTP timestamp")
        (let* ((unix-sec (- ntp-sec +ntp-unix-epoch+))
               (unix-ms (truncate (* ntp-frac 1000) #x100000000)))
          (values (+ (* unix-sec 1000) unix-ms) nil)))))

(defun handle-response (response local-before local-after)
  (when (< (length response) +ntp-packet-size+)
    (return-from handle-response (values nil "Short packet")))
  
  (let ((mode (logand (aref response 0) #x07)))
    (when (/= mode 4)
      (return-from handle-response (values nil "Invalid mode"))))
  
  (multiple-value-bind (remote-ms error)
      (ntp-to-unix-ms (subseq response 40 44) (subseq response 44 48))
    (if error
        (values nil error)
        (values (list :local-before local-before
                      :local-after local-after
                      :remote-ms remote-ms)
                nil))))

(defun query-ntp-server (hostname config)
  (handler-case
      (let* ((socket (make-instance 'sb-bsd-sockets:inet-socket
                                    :type :datagram
                                    :protocol :udp))
             (host-ent (sb-bsd-sockets:get-host-by-name hostname))
             (address (first (sb-bsd-sockets:host-ent-addresses host-ent)))
             (packet (build-ntp-request))
             (local-before (get-time-ms))
             (response (make-array +ntp-packet-size+ :element-type '(unsigned-byte 8))))
        
        (unwind-protect
             (progn
               ;; Send request
               (sb-bsd-sockets:socket-send socket packet +ntp-packet-size+
                                          :address (list address +ntp-port+))
               
               ;; Receive response with timeout handling via handler-timeout
               (handler-case
                   (sb-ext:with-timeout (/ (config-timeout-ms config) 1000.0)
                     (multiple-value-bind (buf len addr port)
                         (sb-bsd-sockets:socket-receive socket response +ntp-packet-size+)
                       (declare (ignore addr port))
                       (let ((local-after (get-time-ms)))
                         (if (>= len +ntp-packet-size+)
                             (handle-response buf local-before local-after)
                             (values nil "Timeout")))))
                 (sb-ext:timeout ()
                   (values nil "Timeout"))))
          (sb-bsd-sockets:socket-close socket)))
    (sb-bsd-sockets:socket-error ()
      (values nil "Socket error"))
    (sb-bsd-sockets:host-not-found-error ()
      (values nil (format nil "Cannot resolve hostname: ~A" hostname)))
    (error (e)
      (values nil (format nil "Error: ~A" e)))))

(defun handle-ntp-result (result config ip-str)
  (let* ((local-before (getf result :local-before))
         (local-after (getf result :local-after))
         (remote-ms (getf result :remote-ms))
         (avg-local (truncate (+ local-before local-after) 2))
         (offset (- remote-ms avg-local))
         (rtt (- local-after local-before)))
    
    (when (config-verbose config)
      (log-stderr "DEBUG Server: ~A (~A)" (config-server config) ip-str)
      (log-stderr "DEBUG Local before(ms): ~D" local-before)
      (log-stderr "DEBUG Local after(ms): ~D" local-after)
      (log-stderr "DEBUG Remote time(ms): ~D" remote-ms)
      (log-stderr "DEBUG Estimated roundtrip(ms): ~D" rtt)
      (log-stderr "DEBUG Estimated offset remote - local(ms): ~D" offset))
    
    (cond
      ((or (< rtt 0) (> rtt 10000))
       (log-stderr "ERROR Invalid roundtrip time: ~D ms" rtt)
       1)
      ((and (> (abs offset) 0) (< (abs offset) 500))
       (when (config-verbose config)
         (log-stderr "INFO Delta < 500ms, not setting system time."))
       0)
      (t
       (validate-and-set-time remote-ms offset config)))))

(defun validate-and-set-time (remote-ms offset config)
  (let* ((remote-sec (truncate remote-ms 1000))
         (unix-epoch-sec 2208988800) ; Seconds between 1900 and 1970
         (remote-year (+ 1970 (truncate (- remote-sec unix-epoch-sec) (* 365 24 3600)))))
    
    (cond
      ((or (< remote-year 2025) (> remote-year 2200))
       (log-stderr "ERROR Remote year is out of valid range (2025-2200): ~D" remote-year)
       1)
      ((config-test-only config)
       (when (config-verbose config)
         (log-stderr "INFO Test mode: would adjust system time by ~D ms" offset))
       0)
      (t
       (log-stderr "ERROR Time setting not implemented in SBCL (use C extension)")
       10))))

(defun do-ntp-attempt (config attempt)
  (when (config-verbose config)
    (log-stderr "DEBUG Attempt (~D) at NTP query on ~A ..." attempt (config-server config)))
  
  (multiple-value-bind (result error)
      (query-ntp-server (config-server config) config)
    (cond
      (error
       (cond
         ((string= error "Timeout")
          (if (< attempt (config-retries config))
              (progn
                (sleep 0.2)
                (do-ntp-attempt config (1+ attempt)))
              (progn
                (log-stderr "ERROR Timeout waiting for NTP response")
                2)))
         (t
          (log-stderr "ERROR ~A" error)
          2)))
      (t
       (handler-case
           (let* ((hostname (config-server config))
                  (host-ent (sb-bsd-sockets:get-host-by-name hostname))
                  (address (first (sb-bsd-sockets:host-ent-addresses host-ent)))
                  (ip-str (format nil "~{~D~^.~}" (coerce address 'list))))
             (handle-ntp-result result config ip-str))
         (error ()
           (handle-ntp-result result config (config-server config))))))))

(defun do-ntp-query (config)
  (do-ntp-attempt config 1))

(defun main (args)
  (let* ((config (parse-args args)))
    
    ;; Disable syslog in test mode
    (when (config-test-only config)
      (setf (config-use-syslog config) nil))
    
    (when (config-verbose config)
      (log-stderr "DEBUG Using server: ~A" (config-server config))
      (log-stderr "DEBUG Timeout: ~D ms, Retries: ~D, Syslog: ~A"
                  (config-timeout-ms config)
                  (config-retries config)
                  (if (config-use-syslog config) "on" "off")))
    
    (let ((exit-code (do-ntp-query config)))
      (sb-ext:exit :code exit-code))))

;; Wrapper for compiled binary mode
(defun timesync-main ()
  (main (rest sb-ext:*posix-argv*)))

;; Entry point for script mode
(when (member "--script" sb-ext:*posix-argv* :test #'string=)
  (main sb-ext:*posix-argv*))
