#!/usr/bin/env sbcl --script

(format t "Hello from script~%")
(format t "Args: ~S~%" (rest sb-ext:*posix-argv*))
(sb-ext:exit :code 0)
