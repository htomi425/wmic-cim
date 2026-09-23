/* x64 console stub. Forwards the raw command tail to wmic.ps1.
   zig cc -target x86_64-windows-gnu -O2 -s -o wmic.exe wmic-stub.c
*/
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

static void say(const wchar_t *msg) {
    HANDLE err = GetStdHandle(STD_ERROR_HANDLE);
    DWORD mode = 0;
    DWORD n = 0;
    if (err != INVALID_HANDLE_VALUE && GetConsoleMode(err, &mode)) {
        WriteConsoleW(err, msg, lstrlenW(msg), &n, NULL);
        return;
    }
    /* Pipe / redirect: UTF-8, so the Japanese prefix still survives. */
    int bytes = WideCharToMultiByte(CP_UTF8, 0, msg, -1, NULL, 0, NULL, NULL);
    if (bytes <= 1) return;
    char *buf = (char *)HeapAlloc(GetProcessHeap(), 0, (SIZE_T)bytes);
    if (!buf) return;
    WideCharToMultiByte(CP_UTF8, 0, msg, -1, buf, bytes, NULL, NULL);
    if (err != INVALID_HANDLE_VALUE)
        WriteFile(err, buf, (DWORD)(bytes - 1), &n, NULL);
    HeapFree(GetProcessHeap(), 0, buf);
}

static wchar_t *skip_arg0(wchar_t *s) {
    while (*s == L' ' || *s == L'\t') s++;
    if (*s == L'"') {
        s++;
        while (*s) {
            if (*s == L'"') {
                s++;
                if (*s == L'"') { s++; continue; }
                break;
            }
            s++;
        }
    } else {
        while (*s && *s != L' ' && *s != L'\t') s++;
    }
    while (*s == L' ' || *s == L'\t') s++;
    return s;
}

static int append(wchar_t *dst, int cap, int pos, const wchar_t *src) {
    while (*src) {
        if (pos >= cap - 1) return -1;
        dst[pos++] = *src++;
    }
    dst[pos] = 0;
    return pos;
}

static BOOL launch(const wchar_t *exe, wchar_t *cmdline) {
    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    DWORD code = 1;
    ZeroMemory(&si, sizeof(si));
    si.cb = sizeof(si);
    ZeroMemory(&pi, sizeof(pi));
    if (!CreateProcessW(exe, cmdline, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi))
        return FALSE;
    WaitForSingleObject(pi.hProcess, INFINITE);
    GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    ExitProcess(code);
    return TRUE;
}

int main(void) {
    wchar_t mod[32768];
    wchar_t ps1[32768];
    wchar_t pwsh[32768];
    wchar_t powershell[32768];
    wchar_t cmdline[32768];
    const wchar_t *cands[2];
    int nc = 0;
    int i;
    DWORD n;
    wchar_t *slash;
    wchar_t *tail;

    n = GetModuleFileNameW(NULL, mod, 32768);
    if (n == 0 || n >= 32767) return 1;
    slash = wcsrchr(mod, L'\\');
    if (!slash) return 1;
    *slash = 0;
    if (append(ps1, 32768, 0, mod) < 0) return 1;
    if (append(ps1, 32768, lstrlenW(ps1), L"\\wmic.ps1") < 0) return 1;

    tail = skip_arg0(GetCommandLineW());
    pwsh[0] = 0;
    powershell[0] = 0;
    if (SearchPathW(NULL, L"pwsh.exe", NULL, 32768, pwsh, NULL) > 0)
        cands[nc++] = pwsh;
    if (SearchPathW(NULL, L"powershell.exe", NULL, 32768, powershell, NULL) > 0) {
        cands[nc++] = powershell;
    } else {
        wchar_t root[MAX_PATH];
        DWORD rn = GetEnvironmentVariableW(L"SystemRoot", root, MAX_PATH);
        if (rn == 0 || rn >= MAX_PATH) lstrcpyW(root, L"C:\\Windows");
        powershell[0] = 0;
        if (append(powershell, 32768, 0, root) >= 0 &&
            append(powershell, 32768, lstrlenW(powershell),
                   L"\\System32\\WindowsPowerShell\\v1.0\\powershell.exe") >= 0 &&
            GetFileAttributesW(powershell) != INVALID_FILE_ATTRIBUTES) {
            cands[nc++] = powershell;
        }
    }
    if (nc == 0) {
        say(L"エラー: pwsh も powershell も見つかりません。\n");
        return 1;
    }

    for (i = 0; i < nc; i++) {
        int pos = 0;
        cmdline[0] = 0;
        pos = append(cmdline, 32768, pos, L"\"");
        if (pos < 0) break;
        pos = append(cmdline, 32768, pos, cands[i]);
        if (pos < 0) break;
        pos = append(cmdline, 32768, pos, L"\" -NoProfile -ExecutionPolicy Bypass -File \"");
        if (pos < 0) break;
        pos = append(cmdline, 32768, pos, ps1);
        if (pos < 0) break;
        pos = append(cmdline, 32768, pos, L"\"");
        if (pos < 0) break;
        if (tail && tail[0]) {
            pos = append(cmdline, 32768, pos, L" ");
            if (pos < 0) break;
            pos = append(cmdline, 32768, pos, tail);
            if (pos < 0) break;
        }
        if (launch(cands[i], cmdline))
            return 0;
    }
    say(L"エラー: PowerShell を起動できません。\n");
    return 1;
}
