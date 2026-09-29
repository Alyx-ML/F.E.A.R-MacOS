//part of static recompiler -- do not edit

/**
 *
 *  Copyright (C) 2019-2026 Roman Pauer
 *
 *  Permission is hereby granted, free of charge, to any person obtaining a copy of
 *  this software and associated documentation files (the "Software"), to deal in
 *  the Software without restriction, including without limitation the rights to
 *  use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
 *  of the Software, and to permit persons to whom the Software is furnished to do
 *  so, subject to the following conditions:
 *
 *  The above copyright notice and this permission notice shall be included in all
 *  copies or substantial portions of the Software.
 *
 *  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 *  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 *  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 *  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 *  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 *  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 *  SOFTWARE.
 *
 */

#include "llasm_cpu.h"
#include <stdlib.h>
#include <limits.h>

/* Reject division faults before changing registers. Guest #DE delivery is
   unfinished; abort is the runtime's existing unsupported-exception policy. */
static uint64_t divide_unsigned(uint64_t value, uint64_t divisor, uint64_t maximum)
{
    if (!divisor) abort();
    uint64_t quotient = value / divisor;
    if (quotient > maximum) abort();
    return quotient;
}

static int64_t divide_signed(int64_t value, int64_t divisor, int64_t minimum, int64_t maximum)
{
    if (!divisor || (value == INT64_MIN && divisor == -1)) abort();
    int64_t quotient = value / divisor;
    if (quotient < minimum || quotient > maximum) abort();
    return quotient;
}

EXTERNC void CCALL x86_div_64_64(CPU, uint32_t *div)
{
    uint64_t value = div[0] | ((uint64_t)div[1] << 32);
    uint64_t divisor = div[2] | ((uint64_t)div[3] << 32);
    uint64_t result = divide_unsigned(value, divisor, UINT64_MAX);
    eax = (uint32_t)result;
    edx = (uint32_t)(result >> 32);
}

EXTERNC void CCALL x86_div_64(CPU, uint32_t divisor)
{
    uint64_t value = ((uint64_t)edx << 32) | eax;
    uint32_t quotient = (uint32_t)divide_unsigned(value, divisor, UINT32_MAX);
    edx = (uint32_t)(value % divisor);
    eax = quotient;
}

EXTERNC void CCALL x86_div_32(CPU, uint32_t divisor)
{
    uint32_t value = (edx << 16) | (eax & 0xffff);
    divisor &= 0xffff;
    uint32_t quotient = (uint32_t)divide_unsigned(value, divisor, UINT16_MAX);
    eax = (eax & 0xffff0000) | quotient;
    edx = (edx & 0xffff0000) | (value % divisor);
}

EXTERNC void CCALL x86_div_16(CPU, uint32_t divisor)
{
    uint32_t value = eax & 0xffff;
    divisor &= 0xff;
    uint32_t quotient = (uint32_t)divide_unsigned(value, divisor, UINT8_MAX);
    eax = (eax & 0xffff0000) | quotient | ((value % divisor) << 8);
}

EXTERNC void CCALL x86_idiv_64_64(CPU, uint32_t *div)
{
    int64_t value = (int64_t)(div[0] | ((uint64_t)div[1] << 32));
    int64_t divisor = (int64_t)(div[2] | ((uint64_t)div[3] << 32));
    uint64_t result = (uint64_t)divide_signed(value, divisor, INT64_MIN, INT64_MAX);
    eax = (uint32_t)result;
    edx = (uint32_t)(result >> 32);
}

EXTERNC void CCALL x86_idiv_64(CPU, int32_t divisor)
{
    int64_t value = (int64_t)(((uint64_t)edx << 32) | eax);
    int32_t quotient = (int32_t)divide_signed(value, divisor, INT32_MIN, INT32_MAX);
    edx = (uint32_t)(value % divisor);
    eax = (uint32_t)quotient;
}

EXTERNC void CCALL x86_idiv_32(CPU, int32_t divisor)
{
    int64_t value = (int32_t)((edx << 16) | (eax & 0xffff));
    divisor = (int16_t)divisor;
    uint32_t quotient = (uint32_t)divide_signed(value, divisor, INT16_MIN, INT16_MAX);
    eax = (eax & 0xffff0000) | (quotient & 0xffff);
    edx = (edx & 0xffff0000) | ((uint32_t)(value % divisor) & 0xffff);
}

EXTERNC void CCALL x86_idiv_16(CPU, int32_t divisor)
{
    int32_t value = (int16_t)eax;
    divisor = (int8_t)divisor;
    uint32_t quotient = (uint32_t)divide_signed(value, divisor, INT8_MIN, INT8_MAX);
    eax = (eax & 0xffff0000) | (quotient & 0xff) | (((uint32_t)(value % divisor) & 0xff) << 8);
}

#ifdef TC_DIVIDE_SELF_CHECK
#include <assert.h>
#include <signal.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <unistd.h>
int main(void)
{
    _cpu registers = {0};
    _cpu *cpu = &registers;
    eax = 7;
    x86_div_64(cpu, 3);
    assert(eax == 2 && edx == 1);
    eax = (uint32_t)-7;
    edx = UINT32_MAX;
    x86_idiv_64(cpu, 3);
    assert(eax == (uint32_t)-2 && edx == UINT32_MAX);
    eax = 0xabcdfff9;
    edx = 0x1234ffff;
    x86_idiv_32(cpu, 3);
    assert(eax == 0xabcdfffe && edx == 0x1234ffff);
    eax = 0x1234fff9;
    x86_idiv_16(cpu, 3);
    assert(eax == 0x1234fffe);
    /* Fault cases run only when this optional check is explicitly invoked. */
    for (unsigned fault = 0; fault < 3; ++fault) {
        pid_t child = fork();
        assert(child >= 0);
        if (!child) {
            struct rlimit limit = {0, 0};
            setrlimit(RLIMIT_CORE, &limit);
            if (fault == 0) divide_unsigned(1, 0, UINT32_MAX);
            if (fault == 1) divide_unsigned(UINT64_C(1) << 32, 1, UINT32_MAX);
            if (fault == 2) divide_signed(INT64_MIN, -1, INT64_MIN, INT64_MAX);
            _exit(0);
        }
        int status;
        assert(waitpid(child, &status, 0) == child);
        assert(WIFSIGNALED(status) && WTERMSIG(status) == SIGABRT);
    }
    return 0;
}
#endif
