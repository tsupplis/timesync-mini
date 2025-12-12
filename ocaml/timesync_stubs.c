/*
 * Copyright (c) 2025 Thierry Gayet
 * Licensed under the MIT License. See LICENSE file for details.
 */

#include <sys/time.h>
#include <time.h>
#include <caml/mlvalues.h>
#include <caml/alloc.h>

CAMLprim value caml_set_time_of_day(value sec_val, value usec_val) {
    struct timeval tv;
    tv.tv_sec = (time_t)Double_val(sec_val);
    tv.tv_usec = (suseconds_t)Long_val(usec_val);
    
    int rc = settimeofday(&tv, NULL);
    return Val_long(rc);
}
