#include <windows.h>
#include <stdio.h>
#include <string.h>

int main(int argc, char *argv[]) {
    char cmdline[32768];
    char exepath[MAX_PATH];
    char *lastslash;
    int offset;

    // Get directory of this exe
    GetModuleFileNameA(NULL, exepath, MAX_PATH);
    lastslash = strrchr(exepath, '\\');
    if (lastslash) *(lastslash + 1) = '\0';

    // Build command: real exe + original args + our extra flags
    offset = snprintf(cmdline, sizeof(cmdline), "\"%ssteamwebhelper_real.exe\"", exepath);
    if (offset < 0 || (size_t)offset >= sizeof(cmdline)) return 1;

    // Append all original arguments with bounds checking
    for (int i = 1; i < argc; i++) {
        int needed;
        if (strchr(argv[i], ' ')) {
            needed = snprintf(cmdline + offset, sizeof(cmdline) - offset,
                              " \"%s\"", argv[i]);
        } else {
            needed = snprintf(cmdline + offset, sizeof(cmdline) - offset,
                              " %s", argv[i]);
        }
        if (needed < 0 || (size_t)(offset + needed) >= sizeof(cmdline)) return 1;
        offset += needed;
    }

    // Append our Wine-compatibility flags
    {
        int needed = snprintf(cmdline + offset, sizeof(cmdline) - offset,
                              " --no-sandbox --in-process-gpu --disable-gpu --disable-gpu-compositing");
        if (needed < 0 || (size_t)(offset + needed) >= sizeof(cmdline)) return 1;
    }

    // Launch the real webhelper
    STARTUPINFOA si = { sizeof(si) };
    PROCESS_INFORMATION pi;

    if (!CreateProcessA(NULL, cmdline, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi)) {
        return 1;
    }

    // Wait for it to exit and return its exit code
    WaitForSingleObject(pi.hProcess, INFINITE);
    DWORD exitCode;
    GetExitCodeProcess(pi.hProcess, &exitCode);
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    return exitCode;
}
