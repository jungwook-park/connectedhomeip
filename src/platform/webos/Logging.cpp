/*
 *
 *    Copyright (c) 2021-2025 Project CHIP Authors
 *    All rights reserved.
 *
 *    Licensed under the Apache License, Version 2.0 (the "License");
 *    you may not use this file except in compliance with the License.
 *    You may obtain a copy of the License at
 *
 *        http://www.apache.org/licenses/LICENSE-2.0
 *
 *    Unless required by applicable law or agreed to in writing, software
 *    distributed under the License is distributed on an "AS IS" BASIS,
 *    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *    See the License for the specific language governing permissions and
 *    limitations under the License.
 */

/**
 *    @file
 *          Platform-specific implementation of KVS for webOS.
 */
#include <platform/logging/LogV.h>

#include <lib/core/CHIPConfig.h>
#include <lib/support/logging/Constants.h>

#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <sys/syscall.h>
#include <sys/time.h>
#include <unistd.h>

#include <PmLogLib.h>

namespace chip {
namespace DeviceLayer {

/**
 * Called whenever a log message is emitted by chip or LwIP.
 *
 * This function is intended be overridden by the application to, e.g.,
 * schedule output of queued log entries.
 */
void __attribute__((weak)) OnLogOutput() {}

} // namespace DeviceLayer

namespace Logging {
namespace Platform {

namespace {

// PmLog context for CHIP/Matter stack logs (viewable via `pmlog`/journald under this context name). Fetched lazily on first use.
PmLogContext GetChipPmLogContext()
{
    static PmLogContext sContext = nullptr;
    if (sContext == nullptr)
    {
        PmLogGetContext("thinqlocal", &sContext);
    }
    return sContext;
}

// File sink for CHIP/Matter stack logs, so they can be inspected with plain
// tail/cat/grep without depending on the PmLog/journald configuration of the
// target. The path is overridable via the MATTER_LOG_FILE environment variable
// (default: /tmp/unifiedmatter.log). Set MATTER_LOG_FILE="" to disable the file.
FILE * GetChipLogFile()
{
    static bool sInitialized = false;
    static FILE * sFile      = nullptr;
    if (!sInitialized)
    {
        sInitialized      = true;
        const char * path = getenv("MATTER_LOG_FILE");
        if (path == nullptr)
        {
            path = "/tmp/thinqlocal.log";
        }
        if (path[0] != '\0')
        {
            sFile = fopen(path, "a");
        }
    }
    return sFile;
}

const char * CategoryLabel(uint8_t category)
{
    switch (category)
    {
    case kLogCategory_Error:
        return "ERROR";
    case kLogCategory_Progress:
        return "INFO";
    case kLogCategory_Detail:
    default:
        return "DEBUG";
    }
}

} // namespace

/**
 * CHIP log output functions.
 *
 * Routed to PmLog so the Matter stack logs land in the webOS logging system
 * instead of stdout. The message is pre-formatted with vsnprintf so that any
 * '%' in the payload is not re-interpreted by PmLog's own formatter.
 */
void LogV(const char * module, uint8_t category, const char * msg, va_list v)
{
    char buffer[CHIP_CONFIG_LOG_MESSAGE_MAX_SIZE];
    vsnprintf(buffer, sizeof(buffer), msg, v);

    PmLogContext ctx = GetChipPmLogContext();
    switch (category)
    {
    case kLogCategory_Error:
        PmLogError(ctx, "CHIP", 0, "[%s] %s", module, buffer);
        break;
    case kLogCategory_Progress:
        PmLogInfo(ctx, "CHIP", 0, "[%s] %s", module, buffer);
        break;
    case kLogCategory_Detail:
    default:
        PmLogDebug(ctx, "[%s] %s", module, buffer);
        break;
    }

    // Also emit to a log file and to stdout. CHIP logging can be invoked from
    // multiple threads, so serialize the formatting/writes with a mutex.
    {
        static std::mutex sMutex;
        std::lock_guard<std::mutex> lock(sMutex);

        struct timeval tv;
        gettimeofday(&tv, nullptr);
        long long sec = static_cast<long long>(tv.tv_sec);
        long ms       = static_cast<long>(tv.tv_usec / 1000);
        long pid      = static_cast<long>(syscall(SYS_getpid));
        long tid      = static_cast<long>(syscall(SYS_gettid));

        FILE * logFile = GetChipLogFile();
        if (logFile != nullptr)
        {
            fprintf(logFile, "[%lld.%03ld] [%ld:%ld] [%s] [%s] %s\n", sec, ms, pid, tid, CategoryLabel(category), module,
                    buffer);
            fflush(logFile);
        }

        // Keep console output for interactive test runs.
        fprintf(stdout, "[%lld.%03ld] [%ld:%ld] [%s] %s\n", sec, ms, pid, tid, module, buffer);
        fflush(stdout);
    }

    // Let the application know that a log message has been emitted.
    DeviceLayer::OnLogOutput();
}

} // namespace Platform
} // namespace Logging
} // namespace chip
