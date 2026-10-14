/* Riftway probe: plays a video the way Unreal Engine 4's WmfMedia plugin does.
 *
 *   movie_probe.exe reader  NV12|RGB32 C:\path\movie.mp4   source reader, video only
 *   movie_probe.exe session NV12|RGB32 C:\path\movie.mp4   media session: source -> sample grabber
 *   movie_probe.exe d3d11   NV12|RGB32 C:\path\movie.mp4   source reader decoding into D3D11 textures
 *   movie_probe.exe mft     NV12       C:\path\movie.h264  H.264 decoder by CLSID, given a D3D11 device,
 *                                                           fed a raw Annex-B stream (Electra's path)
 *
 * The session mode is WmfMedia's path (a topology from the source's video stream to a
 * sample grabber sink that asks for an uncompressed subtype, Media Foundation inserting
 * the decoder and any converter). The d3d11 mode is Unreal Engine 5's Electra path: the
 * decoder gets the game's D3D11 device through a DXGI device manager and writes its
 * frames to textures (the mft mode asks the decoder directly, as Electra does, and prints
 * its answer). Prints one JSON line with what reached the sink.
 *
 * Build: x86_64-w64-mingw32-clang -O2 -municode movie_probe.c -lmfplat -lmf -lmfreadwrite -lmfuuid -ld3d11 -ldxguid -lole32 -o movie_probe.exe
 */
#define COBJMACROS
#define INITGUID
#include <windows.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <mferror.h>
#include <d3d11.h>
#include <stdio.h>
#include <string.h>

static int fail(const char *step, HRESULT hr) {
    printf("{\"ok\": false, \"step\": \"%s\", \"hresult\": \"0x%08lx\"}\n", step, (unsigned long)hr);
    fflush(stdout);
    return 1;
}

/* The sample grabber's callback: counts samples and bytes. */
typedef struct {
    IMFSampleGrabberSinkCallback iface;
    LONG refs;
    volatile LONG samples;
    volatile LONG64 bytes;
} grabber;

static grabber *impl(IMFSampleGrabberSinkCallback *iface) { return (grabber *)iface; }

static HRESULT WINAPI g_QueryInterface(IMFSampleGrabberSinkCallback *iface, REFIID riid, void **out) {
    if (IsEqualGUID(riid, &IID_IUnknown) || IsEqualGUID(riid, &IID_IMFClockStateSink)
        || IsEqualGUID(riid, &IID_IMFSampleGrabberSinkCallback)) {
        *out = iface;
        IMFSampleGrabberSinkCallback_AddRef(iface);
        return S_OK;
    }
    *out = NULL;
    return E_NOINTERFACE;
}
static ULONG WINAPI g_AddRef(IMFSampleGrabberSinkCallback *iface) { return InterlockedIncrement(&impl(iface)->refs); }
static ULONG WINAPI g_Release(IMFSampleGrabberSinkCallback *iface) { return InterlockedDecrement(&impl(iface)->refs); }
static HRESULT WINAPI g_OnClockStart(IMFSampleGrabberSinkCallback *i, MFTIME t, LONGLONG o) { return S_OK; }
static HRESULT WINAPI g_OnClockStop(IMFSampleGrabberSinkCallback *i, MFTIME t) { return S_OK; }
static HRESULT WINAPI g_OnClockPause(IMFSampleGrabberSinkCallback *i, MFTIME t) { return S_OK; }
static HRESULT WINAPI g_OnClockRestart(IMFSampleGrabberSinkCallback *i, MFTIME t) { return S_OK; }
static HRESULT WINAPI g_OnClockSetRate(IMFSampleGrabberSinkCallback *i, MFTIME t, float r) { return S_OK; }
static HRESULT WINAPI g_OnSetPresentationClock(IMFSampleGrabberSinkCallback *i, IMFPresentationClock *c) { return S_OK; }
static HRESULT WINAPI g_OnProcessSample(IMFSampleGrabberSinkCallback *iface, REFGUID major, DWORD flags,
                                        LONGLONG time, LONGLONG duration, const BYTE *buffer, DWORD size) {
    InterlockedIncrement(&impl(iface)->samples);
    InterlockedAdd64(&impl(iface)->bytes, size);
    return S_OK;
}
static HRESULT WINAPI g_OnShutdown(IMFSampleGrabberSinkCallback *iface) { return S_OK; }

static IMFSampleGrabberSinkCallbackVtbl grabber_vtbl = {
    g_QueryInterface, g_AddRef, g_Release, g_OnClockStart, g_OnClockStop, g_OnClockPause,
    g_OnClockRestart, g_OnClockSetRate, g_OnSetPresentationClock, g_OnProcessSample, g_OnShutdown,
};

/* A D3D11 device (the runtime's DXMT) in a DXGI device manager, as a game hands it over. */
static HRESULT make_manager(IMFDXGIDeviceManager **manager, UINT *nv12) {
    ID3D11Device *device = NULL;
    D3D_FEATURE_LEVEL level;
    HRESULT hr;
    if (FAILED(hr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, D3D11_CREATE_DEVICE_VIDEO_SUPPORT,
                                      NULL, 0, D3D11_SDK_VERSION, &device, &level, NULL))
        && FAILED(hr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0, D3D11_SDK_VERSION,
                                         &device, &level, NULL)))
        return hr;
    *nv12 = 0;
    ID3D11Device_CheckFormatSupport(device, DXGI_FORMAT_NV12, nv12);
    ID3D10Multithread *multithread = NULL;
    if (SUCCEEDED(ID3D11Device_QueryInterface(device, &IID_ID3D10Multithread, (void **)&multithread))) {
        ID3D10Multithread_SetMultithreadProtected(multithread, TRUE);
        ID3D10Multithread_Release(multithread);
    }
    UINT token;
    if (FAILED(hr = MFCreateDXGIDeviceManager(&token, manager))) return hr;
    return IMFDXGIDeviceManager_ResetDevice(*manager, (IUnknown *)device, token);
}

/* CLSID_MSH264DecoderMFT, the decoder Electra creates directly (msmpeg2vdec). */
static const GUID clsid_h264_decoder = {0x62ce7e72, 0x4c71, 0x4d20, {0xb1, 0x5d, 0x45, 0x28, 0x31, 0xa8, 0x7d, 0x9d}};

/* Sets the decoder's output to NV12 from the types it offers. */
static HRESULT set_nv12_output(IMFTransform *transform) {
    HRESULT hr;
    IMFMediaType *type = NULL;
    for (DWORD i = 0; SUCCEEDED(hr = IMFTransform_GetOutputAvailableType(transform, 0, i, &type)); i++) {
        GUID subtype;
        IMFMediaType_GetGUID(type, &MF_MT_SUBTYPE, &subtype);
        if (IsEqualGUID(&subtype, &MFVideoFormat_NV12)) {
            hr = IMFTransform_SetOutputType(transform, 0, type, 0);
            IMFMediaType_Release(type);
            return hr;
        }
        IMFMediaType_Release(type);
    }
    return hr;
}

/* Decodes a raw Annex-B H.264 file with an H.264 decoder whose D3D manager was offered. */
static int mft_raw(IMFTransform *transform, const WCHAR *path, UINT32 aware, HRESULT set, UINT nv12) {
    HRESULT hr;
    IMFMediaType *input = NULL;
    MFCreateMediaType(&input);
    IMFMediaType_SetGUID(input, &MF_MT_MAJOR_TYPE, &MFMediaType_Video);
    IMFMediaType_SetGUID(input, &MF_MT_SUBTYPE, &MFVideoFormat_H264);
    IMFMediaType_SetUINT64(input, &MF_MT_FRAME_SIZE, ((UINT64)1920 << 32) | 1080);
    if (FAILED(hr = IMFTransform_SetInputType(transform, 0, input, 0))) return fail("SetInputType", hr);
    if (FAILED(hr = set_nv12_output(transform))) return fail("SetOutputType", hr);
    IMFTransform_ProcessMessage(transform, MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
    IMFTransform_ProcessMessage(transform, MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);

    HANDLE file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, 0, NULL);
    if (file == INVALID_HANDLE_VALUE) return fail("CreateFile", HRESULT_FROM_WIN32(GetLastError()));
    MFT_OUTPUT_STREAM_INFO info = {0};
    IMFTransform_GetOutputStreamInfo(transform, 0, &info);
    BOOL provides = !!(info.dwFlags & MFT_OUTPUT_STREAM_PROVIDES_SAMPLES);
    int frames = 0, inputs = 0, changes = 0;
    HRESULT output_failed = S_OK;
    BYTE chunk[65536];
    DWORD got = 0;
    while (frames < 30 && ReadFile(file, chunk, sizeof(chunk), &got, NULL) && got) {
        IMFMediaBuffer *buffer = NULL;
        IMFSample *sample = NULL;
        BYTE *data;
        MFCreateMemoryBuffer(got, &buffer);
        IMFMediaBuffer_Lock(buffer, &data, NULL, NULL);
        memcpy(data, chunk, got);
        IMFMediaBuffer_Unlock(buffer);
        IMFMediaBuffer_SetCurrentLength(buffer, got);
        MFCreateSample(&sample);
        IMFSample_AddBuffer(sample, buffer);
        IMFSample_SetSampleTime(sample, (LONGLONG)inputs * 333333);
        IMFMediaBuffer_Release(buffer);
        while ((hr = IMFTransform_ProcessInput(transform, 0, sample, 0)) == MF_E_NOTACCEPTING) {
            MFT_OUTPUT_DATA_BUFFER out = {0};
            DWORD status = 0;
            if (!provides) {
                IMFMediaBuffer *b = NULL;
                MFCreateSample(&out.pSample);
                MFCreateMemoryBuffer(info.cbSize, &b);
                IMFSample_AddBuffer(out.pSample, b);
                IMFMediaBuffer_Release(b);
            }
            HRESULT o = IMFTransform_ProcessOutput(transform, 0, 1, &out, &status);
            if (o == MF_E_TRANSFORM_STREAM_CHANGE) { changes++; set_nv12_output(transform); IMFTransform_GetOutputStreamInfo(transform, 0, &info); }
            else if (SUCCEEDED(o)) frames++;
            else if (o != MF_E_TRANSFORM_NEED_MORE_INPUT) { output_failed = o; }
            if (out.pSample) IMFSample_Release(out.pSample);
            if (out.pEvents) IMFCollection_Release(out.pEvents);
            if (FAILED(output_failed)) break;
        }
        IMFSample_Release(sample);
        inputs++;
        if (FAILED(hr) || FAILED(output_failed)) break;
        for (;;) {
            MFT_OUTPUT_DATA_BUFFER out = {0};
            DWORD status = 0;
            if (!provides) {
                IMFMediaBuffer *b = NULL;
                MFCreateSample(&out.pSample);
                MFCreateMemoryBuffer(info.cbSize, &b);
                IMFSample_AddBuffer(out.pSample, b);
                IMFMediaBuffer_Release(b);
            }
            HRESULT o = IMFTransform_ProcessOutput(transform, 0, 1, &out, &status);
            if (out.pSample) IMFSample_Release(out.pSample);
            if (out.pEvents) IMFCollection_Release(out.pEvents);
            if (o == MF_E_TRANSFORM_STREAM_CHANGE) { changes++; set_nv12_output(transform); IMFTransform_GetOutputStreamInfo(transform, 0, &info); continue; }
            if (SUCCEEDED(o)) { frames++; continue; }
            if (o != MF_E_TRANSFORM_NEED_MORE_INPUT) output_failed = o;
            break;
        }
        if (FAILED(output_failed)) break;
    }
    CloseHandle(file);
    printf("{\"mode\": \"mft\", \"d3d11_aware\": %u, \"set_d3d_manager\": \"0x%08lx\", \"inputs\": %d, \"stream_changes\": %d, "
           "\"frames\": %d, \"input_failed\": \"0x%08lx\", \"output_failed\": \"0x%08lx\", \"nv12_support\": \"0x%x\", \"ok\": %s}\n",
           aware, (unsigned long)set, inputs, changes, frames, (unsigned long)(FAILED(hr) ? hr : S_OK),
           (unsigned long)output_failed, nv12, frames > 0 ? "true" : "false");
    fflush(stdout);
    return frames > 0 ? 0 : 2;
}

/* The decoder as Electra drives it: created by CLSID, offered the game's device, then fed
 * a raw Annex-B H.264 stream by hand (ffmpeg -i movie.mp4 -c:v copy -bsf:v h264_mp4toannexb
 * -f h264 movie.h264; the samples of an MP4 are length-prefixed, which Electra converts). */
static int mft_mode(const WCHAR *path) {
    IMFDXGIDeviceManager *manager = NULL;
    UINT nv12 = 0;
    HRESULT hr;
    size_t length = wcslen(path);
    if (length <= 5 || _wcsicmp(path + length - 5, L".h264")) return fail("mft takes a raw .h264 file", E_INVALIDARG);
    if (FAILED(hr = make_manager(&manager, &nv12))) return fail("device manager", hr);
    IMFTransform *transform = NULL;
    if (FAILED(hr = CoCreateInstance(&clsid_h264_decoder, NULL, CLSCTX_INPROC_SERVER, &IID_IMFTransform, (void **)&transform)))
        return fail("CoCreateInstance", hr);
    IMFAttributes *attributes = NULL;
    UINT32 aware = 0;
    if (SUCCEEDED(IMFTransform_GetAttributes(transform, &attributes)))
        IMFAttributes_GetUINT32(attributes, &MF_SA_D3D11_AWARE, &aware);
    HRESULT set = aware ? IMFTransform_ProcessMessage(transform, MFT_MESSAGE_SET_D3D_MANAGER, (ULONG_PTR)manager) : E_NOTIMPL;
    return mft_raw(transform, path, aware, set, nv12);
}

static int reader_mode(const WCHAR *url, const GUID *subtype, BOOL d3d11) {
    IMFAttributes *attributes = NULL;
    MFCreateAttributes(&attributes, 3);
    UINT nv12 = 0;
    HRESULT hr;
    if (d3d11) {
        IMFDXGIDeviceManager *manager = NULL;
        if (FAILED(hr = make_manager(&manager, &nv12))) return fail("device manager", hr);
        IMFAttributes_SetUnknown(attributes, &MF_SOURCE_READER_D3D_MANAGER, (IUnknown *)manager);
        IMFAttributes_SetUINT32(attributes, &MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, TRUE);
    } else {
        IMFAttributes_SetUINT32(attributes, &MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING, TRUE);
    }
    IMFSourceReader *reader = NULL;
    hr = MFCreateSourceReaderFromURL(url, attributes, &reader);
    if (FAILED(hr)) return fail("MFCreateSourceReaderFromURL", hr);
    IMFMediaType *type = NULL;
    MFCreateMediaType(&type);
    IMFMediaType_SetGUID(type, &MF_MT_MAJOR_TYPE, &MFMediaType_Video);
    IMFMediaType_SetGUID(type, &MF_MT_SUBTYPE, subtype);
    if (FAILED(hr = IMFSourceReader_SetCurrentMediaType(reader, MF_SOURCE_READER_FIRST_VIDEO_STREAM, NULL, type)))
        return fail("SetCurrentMediaType", hr);
    int frames = 0, textures = 0;
    LONGLONG bytes = 0;
    for (int i = 0; i < 30; i++) {
        DWORD index, flags = 0;
        LONGLONG time;
        IMFSample *sample = NULL;
        if (FAILED(hr = IMFSourceReader_ReadSample(reader, MF_SOURCE_READER_FIRST_VIDEO_STREAM, 0, &index, &flags, &time, &sample)))
            return fail("ReadSample", hr);
        if (flags & MF_SOURCE_READERF_ENDOFSTREAM) break;
        if (!sample) continue;
        DWORD length = 0;
        IMFSample_GetTotalLength(sample, &length);
        IMFMediaBuffer *buffer = NULL;
        IMFDXGIBuffer *dxgi = NULL;
        if (SUCCEEDED(IMFSample_GetBufferByIndex(sample, 0, &buffer))) {
            if (SUCCEEDED(IMFMediaBuffer_QueryInterface(buffer, &IID_IMFDXGIBuffer, (void **)&dxgi))) {
                textures++;
                IMFDXGIBuffer_Release(dxgi);
            }
            IMFMediaBuffer_Release(buffer);
        }
        bytes += length;
        IMFSample_Release(sample);
        frames++;
    }
    printf("{\"mode\": \"%s\", \"frames\": %d, \"textures\": %d, \"bytes\": %lld, \"nv12_support\": \"0x%x\", \"ok\": %s}\n",
           d3d11 ? "d3d11" : "reader", frames, textures, bytes, nv12, frames > 0 ? "true" : "false");
    fflush(stdout);
    return frames > 0 ? 0 : 2;
}

static int session_mode(const WCHAR *url, const GUID *subtype) {
    HRESULT hr;
    IMFSourceResolver *resolver = NULL;
    IUnknown *object = NULL;
    IMFMediaSource *source = NULL;
    MF_OBJECT_TYPE kind;
    if (FAILED(hr = MFCreateSourceResolver(&resolver))) return fail("MFCreateSourceResolver", hr);
    if (FAILED(hr = IMFSourceResolver_CreateObjectFromURL(resolver, url, MF_RESOLUTION_MEDIASOURCE, NULL, &kind, &object)))
        return fail("CreateObjectFromURL", hr);
    IUnknown_QueryInterface(object, &IID_IMFMediaSource, (void **)&source);

    IMFPresentationDescriptor *pd = NULL;
    if (FAILED(hr = IMFMediaSource_CreatePresentationDescriptor(source, &pd))) return fail("CreatePresentationDescriptor", hr);
    DWORD count = 0;
    IMFPresentationDescriptor_GetStreamDescriptorCount(pd, &count);

    IMFTopology *topology = NULL;
    MFCreateTopology(&topology);
    grabber callback = {{&grabber_vtbl}, 1, 0, 0};
    int video_streams = 0;
    for (DWORD i = 0; i < count; i++) {
        BOOL selected;
        IMFStreamDescriptor *sd = NULL;
        IMFPresentationDescriptor_GetStreamDescriptorByIndex(pd, i, &selected, &sd);
        IMFMediaTypeHandler *handler = NULL;
        IMFStreamDescriptor_GetMediaTypeHandler(sd, &handler);
        GUID major;
        IMFMediaTypeHandler_GetMajorType(handler, &major);
        IMFMediaTypeHandler_Release(handler);
        if (!IsEqualGUID(&major, &MFMediaType_Video)) {
            IMFPresentationDescriptor_DeselectStream(pd, i);
            IMFStreamDescriptor_Release(sd);
            continue;
        }
        IMFPresentationDescriptor_SelectStream(pd, i);
        video_streams++;

        IMFTopologyNode *src = NULL, *out = NULL;
        MFCreateTopologyNode(MF_TOPOLOGY_SOURCESTREAM_NODE, &src);
        IMFTopologyNode_SetUnknown(src, &MF_TOPONODE_SOURCE, (IUnknown *)source);
        IMFTopologyNode_SetUnknown(src, &MF_TOPONODE_PRESENTATION_DESCRIPTOR, (IUnknown *)pd);
        IMFTopologyNode_SetUnknown(src, &MF_TOPONODE_STREAM_DESCRIPTOR, (IUnknown *)sd);
        IMFTopology_AddNode(topology, src);

        IMFMediaType *type = NULL;
        MFCreateMediaType(&type);
        IMFMediaType_SetGUID(type, &MF_MT_MAJOR_TYPE, &MFMediaType_Video);
        IMFMediaType_SetGUID(type, &MF_MT_SUBTYPE, subtype);
        IMFActivate *sink = NULL;
        if (FAILED(hr = MFCreateSampleGrabberSinkActivate(type, &callback.iface, &sink)))
            return fail("MFCreateSampleGrabberSinkActivate", hr);
        MFCreateTopologyNode(MF_TOPOLOGY_OUTPUT_NODE, &out);
        IMFTopologyNode_SetObject(out, (IUnknown *)sink);
        IMFTopology_AddNode(topology, out);
        IMFTopologyNode_ConnectOutput(src, 0, out, 0);
        IMFStreamDescriptor_Release(sd);
    }
    if (!video_streams) return fail("no video stream", E_FAIL);

    IMFMediaSession *session = NULL;
    if (FAILED(hr = MFCreateMediaSession(NULL, &session))) return fail("MFCreateMediaSession", hr);
    if (FAILED(hr = IMFMediaSession_SetTopology(session, 0, topology))) return fail("SetTopology", hr);

    /* Events until the topology is ready, then start and let it play. */
    static const GUID no_format; /* GUID_NULL: the default time format */
    PROPVARIANT start;
    PropVariantInit(&start);
    BOOL started = FALSE;
    HRESULT status_failed = S_OK;
    MediaEventType failed_event = 0;
    DWORD deadline = GetTickCount() + 8000;
    while (GetTickCount() < deadline) {
        IMFMediaEvent *event = NULL;
        hr = IMFMediaSession_GetEvent(session, MF_EVENT_FLAG_NO_WAIT, &event);
        if (hr == MF_E_NO_EVENTS_AVAILABLE) { Sleep(20); continue; }
        if (FAILED(hr)) return fail("GetEvent", hr);
        MediaEventType type;
        HRESULT status;
        IMFMediaEvent_GetType(event, &type);
        IMFMediaEvent_GetStatus(event, &status);
        IMFMediaEvent_Release(event);
        if (FAILED(status) && !failed_event) { failed_event = type; status_failed = status; }
        if (type == MESessionTopologyStatus && !started && SUCCEEDED(status)) {
            if (FAILED(hr = IMFMediaSession_Start(session, &no_format, &start))) return fail("Start", hr);
            started = TRUE;
        }
        if (type == MESessionEnded) break;
    }
    LONG samples = callback.samples;
    LONG64 bytes = callback.bytes;
    IMFMediaSession_Close(session);
    Sleep(200);
    IMFMediaSession_Shutdown(session);
    IMFMediaSource_Shutdown(source);
    printf("{\"mode\": \"session\", \"started\": %s, \"samples\": %ld, \"bytes\": %lld, \"failed_event\": %lu, "
           "\"failed_status\": \"0x%08lx\", \"ok\": %s}\n",
           started ? "true" : "false", samples, bytes, (unsigned long)failed_event, (unsigned long)status_failed,
           samples > 0 ? "true" : "false");
    fflush(stdout);
    return samples > 0 ? 0 : 2;
}

int wmain(int argc, wchar_t **argv) {
    if (argc < 4) return fail("usage", E_INVALIDARG);
    const GUID *subtype = !wcscmp(argv[2], L"RGB32") ? &MFVideoFormat_RGB32 : &MFVideoFormat_NV12;
    HRESULT hr = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    if (FAILED(hr)) return fail("CoInitializeEx", hr);
    if (FAILED(hr = MFStartup(MF_VERSION, 0))) return fail("MFStartup", hr);
    int result = !wcscmp(argv[1], L"mft") ? mft_mode(argv[3])
                 : !wcscmp(argv[1], L"session") ? session_mode(argv[3], subtype)
                 : reader_mode(argv[3], subtype, !wcscmp(argv[1], L"d3d11"));
    MFShutdown();
    return result;
}
