#include <windows.h>
#include <stdio.h>
#include <string.h>

int main(int argc, char *argv[]) {
    char cmdline[32768];
    char exepath[MAX_PATH];
    char *lastslash;
    
    // Get directory of this exe
    GetModuleFileNameA(NULL, exepath, MAX_PATH);
    lastslash = strrchr(exepath, '\\');
    if (lastslash) *(lastslash + 1) = '\0';
    
    // Build command: real exe + original args + our extra flags
    snprintf(cmdline, sizeof(cmdline), "\"%ssteamwebhelper_real.exe\"", exepath);
    
    // Append all original arguments
    for (int i = 1; i < argc; i++) {
        strcat(cmdline, " ");
        // Quote args that contain spaces
        if (strchr(argv[i], ' ')) {
            strcat(cmdline, "\"");
            strcat(cmdline, argv[i]);
            strcat(cmdline, "\"");
        } else {
            strcat(cmdline, argv[i]);
        }
    }
    
    // Append our Wine-compatibility flags
    strcat(cmdline, " --no-sandbox --in-process-gpu --disable-gpu --disable-gpu-compositing");
    
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
