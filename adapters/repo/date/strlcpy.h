#ifndef RUBY_ZIG_DATE_STRLCPY_H
#define RUBY_ZIG_DATE_STRLCPY_H

#include <stddef.h>
#include <string.h>

static inline size_t
ruby_zig_date_strlcpy(char *destination, const char *source, size_t size)
{
    const size_t length = strlen(source);

    if (size > 0) {
        const size_t copied = length < size ? length : size - 1;
        memcpy(destination, source, copied);
        destination[copied] = '\0';
    }
    return length;
}

#define strlcpy ruby_zig_date_strlcpy

#endif
