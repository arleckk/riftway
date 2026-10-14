/* Riftway probe: plays a video the way Unreal Engine 4's WmfMedia plugin does.
 *
 *   movie_probe.exe reader  NV12|RGB32 C:\path\movie.mp4   source reader, video only
 *   movie_probe.exe session NV12|RGB32 C:\path\movie.mp4   media session: source -> sample grabber
 *   movie_probe.exe d3d11   NV12|RGB32 C:\path\movie.mp4   source reader decoding into D3D11 textures
 *   movie_probe.exe mft     NV12       -                    H.264 decoder given a D3D11 device
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

static int mft_mode(void) {
    IMFDXGIDeviceManager *manager = NULL;
    UINT nv12 = 0;
    HRESULT hr;
    if (FAILED(hr = make_manager(&manager, &nv12))) return fail("device manager", hr);
    MFT_REGISTER_TYPE_INFO input = {MFMediaType_Video, MFVideoFormat_H264};
    IMFActivate **activates = NULL;
    UINT32 count = 0;
    if (FAILED(hr = MFTEnumEx(MFT_CATEGORY_VIDEO_DECODER, MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_SORTANDFILTER,
                              &input, NULL, &activates, &count)) || !count)
        return fail("MFTEnumEx", hr);
    IMFTransform *transform = NULL;
    if (FAILED(hr = IMFActivate_ActivateObject(activates[0], &IID_IMFTransform, (void **)&transform)))
        return fail("ActivateObject", hr);
    IMFAttributes *attributes = NULL;
    UINT32 aware = 0;
    if (SUCCEEDED(IMFTransform_GetAttributes(transform, &attributes)))
        IMFAttributes_GetUINT32(attributes, &MF_SA_D3D11_AWARE, &aware);
    hr = IMFTransform_ProcessMessage(transform, MFT_MESSAGE_SET_D3D_MANAGER, (ULONG_PTR)manager);
    printf("{\"mode\": \"mft\", \"d3d11_aware\": %u, \"set_d3d_manager\": \"0x%08lx\", \"nv12_support\": \"0x%x\", "
           "\"ok\": %s}\n", aware, (unsigned long)hr, nv12, SUCCEEDED(hr) == !!(nv12 & D3D11_FORMAT_SUPPORT_TEXTURE2D) ? "true" : "false");
    fflush(stdout);
    return 0;
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
    int result = !wcscmp(argv[1], L"mft") ? mft_mode()
                 : !wcscmp(argv[1], L"session") ? session_mode(argv[3], subtype)
                 : reader_mode(argv[3], subtype, !wcscmp(argv[1], L"d3d11"));
    MFShutdown();
    return result;
}
