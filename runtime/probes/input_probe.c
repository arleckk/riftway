/* Riftway input probe: which game controllers a Windows game sees in a bottle.
 *
 * Lists DirectInput 8 game controllers (names), then watches the four XInput
 * slots for `seconds` (default 10) and prints each change of buttons, so a
 * person can press buttons and check the mapping. Output: one line per event.
 *
 *   input_probe.exe [seconds]
 */
#define DIRECTINPUT_VERSION 0x0800
#define COBJMACROS
#include <windows.h>
#include <dinput.h>
#include <xinput.h>
#include <stdio.h>
#include <stdlib.h>

static BOOL CALLBACK device(LPCDIDEVICEINSTANCEA instance, void *context)
{
    (void)context;
    printf("dinput: %s (product %s)\n", instance->tszInstanceName, instance->tszProductName);
    fflush(stdout);
    return DIENUM_CONTINUE;
}

static const char *button_names[16] = {
    "DPAD_UP", "DPAD_DOWN", "DPAD_LEFT", "DPAD_RIGHT", "START", "BACK", "LEFT_THUMB", "RIGHT_THUMB",
    "LEFT_SHOULDER", "RIGHT_SHOULDER", "?", "?", "A", "B", "X", "Y",
};

int main(int argc, char **argv)
{
    int seconds = argc > 1 ? atoi(argv[1]) : 10;
    IDirectInput8A *dinput = NULL;
    if (SUCCEEDED(DirectInput8Create(GetModuleHandleA(NULL), DIRECTINPUT_VERSION, &IID_IDirectInput8A, (void **)&dinput, NULL)))
    {
        IDirectInput8_EnumDevices(dinput, DI8DEVCLASS_GAMECTRL, device, NULL, DIEDFL_ATTACHEDONLY);
        IDirectInput8_Release(dinput);
    }

    XINPUT_STATE last[4] = {0};
    BOOL connected[4] = {0};
    DWORD start = GetTickCount(), end = start + seconds * 1000, next_scan = 0;
    while (GetTickCount() < end)
    {
        /* Controllers appear a moment after the bus starts, and come and go. */
        if (GetTickCount() >= next_scan)
        {
            for (int slot = 0; slot < 4; slot++)
            {
                XINPUT_CAPABILITIES caps;
                BOOL now = XInputGetCapabilities(slot, 0, &caps) == ERROR_SUCCESS;
                if (now != connected[slot])
                    printf("xinput: slot %d %s after %lu ms (type %u subtype %u)\n", slot, now ? "connected" : "disconnected",
                           GetTickCount() - start, now ? caps.Type : 0, now ? caps.SubType : 0);
                connected[slot] = now;
            }
            fflush(stdout);
            next_scan = GetTickCount() + 1000;
        }
        for (int slot = 0; slot < 4; slot++)
        {
            XINPUT_STATE state;
            if (!connected[slot] || XInputGetState(slot, &state) != ERROR_SUCCESS) continue;
            WORD changed = state.Gamepad.wButtons ^ last[slot].Gamepad.wButtons;
            for (int bit = 0; bit < 16; bit++)
                if (changed & (1 << bit))
                    printf("xinput: slot %d %s %s\n", slot, button_names[bit], (state.Gamepad.wButtons & (1 << bit)) ? "down" : "up");
            if ((state.Gamepad.bLeftTrigger > 128) != (last[slot].Gamepad.bLeftTrigger > 128))
                printf("xinput: slot %d LT %s\n", slot, state.Gamepad.bLeftTrigger > 128 ? "down" : "up");
            if ((state.Gamepad.bRightTrigger > 128) != (last[slot].Gamepad.bRightTrigger > 128))
                printf("xinput: slot %d RT %s\n", slot, state.Gamepad.bRightTrigger > 128 ? "down" : "up");
            if (abs(state.Gamepad.sThumbLX) > 20000 && abs(last[slot].Gamepad.sThumbLX) <= 20000)
                printf("xinput: slot %d left stick %s\n", slot, state.Gamepad.sThumbLX > 0 ? "right" : "left");
            last[slot] = state;
            fflush(stdout);
        }
        Sleep(10);
    }
    printf("done\n");
    return 0;
}
