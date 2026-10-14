/* Riftway runtime smoke test: a D3D11 device, HLSL shaders, one draw, readback.
 *
 * Exercises the runtime's whole graphics path (DXMT's d3d11/dxgi, shader
 * translation to Metal, the GPU) without a window. Prints one JSON line:
 *   {"adapter": "...", "feature_level": "11_0", "inside": "cc6633ff", "outside": "000000ff", "ok": true}
 *
 * Build: x86_64-w64-mingw32-clang -O2 d3d11_probe.c -ld3d11 -ldxgi -ld3dcompiler -o d3d11_probe.exe
 */
#define COBJMACROS
#define INITGUID
#include <windows.h>
#include <d3d11.h>
#include <dxgi.h>
#include <d3dcompiler.h>
#include <stdio.h>
#include <string.h>

static const char shader[] =
    "float4 vs(uint id : SV_VertexID) : SV_Position {\n"
    "    float2 p = float2((id << 1) & 2, id & 2);\n"          /* (0,0) (2,0) (0,2) become    */
    "    return float4(p * float2(1, -1) + float2(-1, 1), 0, 1);\n" /* the target's top-left half  */
    "}\n"
    "float4 ps(float4 pos : SV_Position) : SV_Target {\n"
    "    return float4(0.8, 0.4, 0.2, 1.0);\n"
    "}\n";

static int fail(const char *step, HRESULT hr) {
    printf("{\"ok\": false, \"step\": \"%s\", \"hresult\": \"0x%08lx\"}\n", step, (unsigned long)hr);
    return 1;
}

static ID3DBlob *compile(const char *entry, const char *target) {
    ID3DBlob *code = NULL, *errors = NULL;
    HRESULT hr = D3DCompile(shader, sizeof(shader) - 1, "probe", NULL, NULL, entry, target, 0, 0, &code, &errors);
    if (FAILED(hr)) {
        if (errors) fprintf(stderr, "%s\n", (const char *)ID3D10Blob_GetBufferPointer(errors));
        return NULL;
    }
    return code;
}

int main(void) {
    const UINT size = 64;
    ID3D11Device *device = NULL;
    ID3D11DeviceContext *context = NULL;
    D3D_FEATURE_LEVEL level = 0;
    HRESULT hr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0, D3D11_SDK_VERSION,
                                   &device, &level, &context);
    if (FAILED(hr)) return fail("D3D11CreateDevice", hr);

    char adapter[256] = "unknown";
    IDXGIDevice *dxgi = NULL;
    if (SUCCEEDED(ID3D11Device_QueryInterface(device, &IID_IDXGIDevice, (void **)&dxgi))) {
        IDXGIAdapter *a = NULL;
        DXGI_ADAPTER_DESC desc;
        if (SUCCEEDED(IDXGIDevice_GetAdapter(dxgi, &a)) && SUCCEEDED(IDXGIAdapter_GetDesc(a, &desc)))
            WideCharToMultiByte(CP_UTF8, 0, desc.Description, -1, adapter, sizeof(adapter), NULL, NULL);
        if (a) IDXGIAdapter_Release(a);
        IDXGIDevice_Release(dxgi);
    }

    D3D11_TEXTURE2D_DESC td = {size, size, 1, 1, DXGI_FORMAT_R8G8B8A8_UNORM, {1, 0}, D3D11_USAGE_DEFAULT,
                               D3D11_BIND_RENDER_TARGET, 0, 0};
    ID3D11Texture2D *target = NULL, *staging = NULL;
    if (FAILED(hr = ID3D11Device_CreateTexture2D(device, &td, NULL, &target))) return fail("CreateTexture2D", hr);
    td.Usage = D3D11_USAGE_STAGING; td.BindFlags = 0; td.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    if (FAILED(hr = ID3D11Device_CreateTexture2D(device, &td, NULL, &staging))) return fail("CreateTexture2D staging", hr);
    ID3D11RenderTargetView *rtv = NULL;
    if (FAILED(hr = ID3D11Device_CreateRenderTargetView(device, (ID3D11Resource *)target, NULL, &rtv))) return fail("CreateRenderTargetView", hr);

    ID3DBlob *vsCode = compile("vs", "vs_5_0"), *psCode = compile("ps", "ps_5_0");
    if (!vsCode || !psCode) return fail("D3DCompile", E_FAIL);
    ID3D11VertexShader *vs = NULL;
    ID3D11PixelShader *ps = NULL;
    if (FAILED(hr = ID3D11Device_CreateVertexShader(device, ID3D10Blob_GetBufferPointer(vsCode), ID3D10Blob_GetBufferSize(vsCode), NULL, &vs)))
        return fail("CreateVertexShader", hr);
    if (FAILED(hr = ID3D11Device_CreatePixelShader(device, ID3D10Blob_GetBufferPointer(psCode), ID3D10Blob_GetBufferSize(psCode), NULL, &ps)))
        return fail("CreatePixelShader", hr);

    const float black[4] = {0, 0, 0, 1};
    D3D11_VIEWPORT viewport = {0, 0, (float)size, (float)size, 0, 1};
    ID3D11DeviceContext_ClearRenderTargetView(context, rtv, black);
    ID3D11DeviceContext_OMSetRenderTargets(context, 1, &rtv, NULL);
    ID3D11DeviceContext_RSSetViewports(context, 1, &viewport);
    ID3D11DeviceContext_IASetPrimitiveTopology(context, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    ID3D11DeviceContext_VSSetShader(context, vs, NULL, 0);
    ID3D11DeviceContext_PSSetShader(context, ps, NULL, 0);
    ID3D11DeviceContext_Draw(context, 3, 0);
    ID3D11DeviceContext_CopyResource(context, (ID3D11Resource *)staging, (ID3D11Resource *)target);

    D3D11_MAPPED_SUBRESOURCE mapped;
    if (FAILED(hr = ID3D11DeviceContext_Map(context, (ID3D11Resource *)staging, 0, D3D11_MAP_READ, 0, &mapped)))
        return fail("Map", hr);
    const unsigned char *row = mapped.pData;
    /* (8, 8) is inside the triangle; (56, 56) is outside, still black. */
    const unsigned char *in = row + 8 * mapped.RowPitch + 8 * 4;
    const unsigned char *out = row + 56 * mapped.RowPitch + 56 * 4;
    unsigned inside = (unsigned)in[0] << 24 | (unsigned)in[1] << 16 | (unsigned)in[2] << 8 | in[3];
    unsigned outside = (unsigned)out[0] << 24 | (unsigned)out[1] << 16 | (unsigned)out[2] << 8 | out[3];
    ID3D11DeviceContext_Unmap(context, (ID3D11Resource *)staging, 0);

    /* 0.8, 0.4, 0.2 in UNORM8 rounds to cc 66 33. */
    int ok = inside == 0xcc6633ffu && outside == 0x000000ffu;
    printf("{\"adapter\": \"%s\", \"feature_level\": \"%d_%d\", \"inside\": \"%08x\", \"outside\": \"%08x\", \"ok\": %s}\n",
           adapter, (level >> 12) & 0xf, (level >> 8) & 0xf, inside, outside, ok ? "true" : "false");
    return ok ? 0 : 2;
}
