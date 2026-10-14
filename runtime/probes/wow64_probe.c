#include <windows.h>
#include <stdio.h>
int main(void) {
    BOOL wow = FALSE;
    IsWow64Process(GetCurrentProcess(), &wow);
    printf("{\"bits\": %d, \"wow64\": %s, \"pointer\": %d}\n", (int)(sizeof(void *) * 8), wow ? "true" : "false", (int)sizeof(void *));
    return 0;
}
