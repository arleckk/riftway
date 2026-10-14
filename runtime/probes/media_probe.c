/* Riftway runtime smoke test: Media Foundation decodes an MP4 (H.264 + AAC).
 *
 * Exercises the path games take for their videos: mfplat's source reader,
 * winegstreamer's demuxer and decoders, and GStreamer's applemedia plugin
 * (VideoToolbox, AudioToolbox) behind them. The clip is a solid colour
 * (0xCC6633) with a tone; prints one JSON line:
 *   {"video_frames": 10, "width": 320, "height": 240, "pixel": "cc6633", "audio_bytes": 35280, "ok": true}
 *
 * Build: x86_64-w64-mingw32-clang -O2 media_probe.c -lmfplat -lmfreadwrite -lmfuuid -lole32 -o media_probe.exe
 * Run:   media_probe.exe C:\probes\clip.mp4
 */
#define COBJMACROS
#define INITGUID
#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <mferror.h>
#include <stdio.h>
#include <stdlib.h>

static int fail(const char *step, HRESULT hr) {
    printf("{\"ok\": false, \"step\": \"%s\", \"hresult\": \"0x%08lx\"}\n", step, (unsigned long)hr);
    return 1;
}

static HRESULT set_output(IMFSourceReader *reader, DWORD stream, const GUID *major, const GUID *subtype) {
    IMFMediaType *type = NULL;
    HRESULT hr = MFCreateMediaType(&type);
    if (FAILED(hr)) return hr;
    IMFMediaType_SetGUID(type, &MF_MT_MAJOR_TYPE, major);
    IMFMediaType_SetGUID(type, &MF_MT_SUBTYPE, subtype);
    hr = IMFSourceReader_SetCurrentMediaType(reader, stream, NULL, type);
    IMFMediaType_Release(type);
    return hr;
}

static int close_to(int a, int b) { return abs(a - b) <= 6; }

int wmain(int argc, wchar_t **argv) {
    if (argc < 2) return fail("usage", E_INVALIDARG);
    HRESULT hr = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    if (FAILED(hr)) return fail("CoInitializeEx", hr);
    if (FAILED(hr = MFStartup(MF_VERSION, 0))) return fail("MFStartup", hr);

    IMFAttributes *attributes = NULL;
    MFCreateAttributes(&attributes, 1);
    IMFAttributes_SetUINT32(attributes, &MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING, TRUE);
    IMFSourceReader *reader = NULL;
    if (FAILED(hr = MFCreateSourceReaderFromURL(argv[1], attributes, &reader)))
        return fail("MFCreateSourceReaderFromURL", hr);

    const DWORD video = MF_SOURCE_READER_FIRST_VIDEO_STREAM, audio = MF_SOURCE_READER_FIRST_AUDIO_STREAM;
    if (FAILED(hr = set_output(reader, video, &MFMediaType_Video, &MFVideoFormat_RGB32)))
        return fail("SetCurrentMediaType video RGB32", hr);
    if (FAILED(hr = set_output(reader, audio, &MFMediaType_Audio, &MFAudioFormat_PCM)))
        return fail("SetCurrentMediaType audio PCM", hr);

    UINT32 width = 0, height = 0;
    IMFMediaType *current = NULL;
    if (SUCCEEDED(IMFSourceReader_GetCurrentMediaType(reader, video, &current))) {
        UINT64 size = 0;
        IMFMediaType_GetUINT64(current, &MF_MT_FRAME_SIZE, &size);
        width = (UINT32)(size >> 32);
        height = (UINT32)size;
        IMFMediaType_Release(current);
    }

    int frames = 0;
    unsigned pixel = 0;
    for (int i = 0; i < 10; i++) {
        DWORD index, flags = 0;
        LONGLONG time;
        IMFSample *sample = NULL;
        if (FAILED(hr = IMFSourceReader_ReadSample(reader, video, 0, &index, &flags, &time, &sample)))
            return fail("ReadSample video", hr);
        if (flags & MF_SOURCE_READERF_ENDOFSTREAM) break;
        if (!sample) continue;
        IMFMediaBuffer *buffer = NULL;
        if (SUCCEEDED(IMFSample_ConvertToContiguousBuffer(sample, &buffer))) {
            BYTE *data;
            DWORD length;
            if (SUCCEEDED(IMFMediaBuffer_Lock(buffer, &data, NULL, &length)) && width && height) {
                /* RGB32 is BGRX; sample the centre. */
                const BYTE *p = data + ((height / 2) * width + width / 2) * 4;
                if ((DWORD)(p - data) + 4 <= length) pixel = (unsigned)p[2] << 16 | (unsigned)p[1] << 8 | p[0];
                IMFMediaBuffer_Unlock(buffer);
            }
            IMFMediaBuffer_Release(buffer);
        }
        IMFSample_Release(sample);
        frames++;
    }

    DWORD audio_bytes = 0;
    for (int i = 0; i < 20; i++) {
        DWORD index, flags = 0;
        LONGLONG time;
        IMFSample *sample = NULL;
        if (FAILED(hr = IMFSourceReader_ReadSample(reader, audio, 0, &index, &flags, &time, &sample)))
            return fail("ReadSample audio", hr);
        if (flags & MF_SOURCE_READERF_ENDOFSTREAM) break;
        if (!sample) continue;
        DWORD length = 0;
        IMFSample_GetTotalLength(sample, &length);
        audio_bytes += length;
        IMFSample_Release(sample);
    }

    int ok = frames > 0 && close_to((pixel >> 16) & 0xff, 0xcc) && close_to((pixel >> 8) & 0xff, 0x66)
             && close_to(pixel & 0xff, 0x33) && audio_bytes > 0;
    printf("{\"video_frames\": %d, \"width\": %u, \"height\": %u, \"pixel\": \"%06x\", \"audio_bytes\": %lu, \"ok\": %s}\n",
           frames, width, height, pixel, (unsigned long)audio_bytes, ok ? "true" : "false");
    fflush(stdout); /* shutting GStreamer down can end the process before the CRT flushes */
    IMFSourceReader_Release(reader);
    MFShutdown();
    return ok ? 0 : 2;
}
