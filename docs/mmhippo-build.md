# Building llama.cpp (mmhippo fork)

## Requirements

- **Visual Studio 2022 Build Tools** (CUDA 13.x does NOT support VS 2026)
- **CUDA Toolkit** (13.x with sm_120a for Blackwell GPUs)
- **CMake** (>= 3.14)
- **Ninja**
- **Node.js** (for UI assets)

## Setup

Open a VS 2022 Developer Command Prompt:

```
"C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvarsall.bat" x64
```

## Configure

```powershell
cmake -B build -G Ninja -DGGML_CUDA=ON -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER=cl -DCMAKE_CXX_COMPILER=cl
```

### CMake options

| Option | Default | Description |
|--------|---------|-------------|
| `GGML_CUDA` | OFF | Enable CUDA backend |
| `GGML_VULKAN` | OFF | Enable Vulkan backend |
| `GGML_METAL` | OFF | Enable Metal (macOS) |
| `CMAKE_BUILD_TYPE` | Release | Debug, Release, RelWithDebInfo |

## Build

```powershell
cmake --build build --config Release -j
```

## Output

Binaries land in `build\bin\`:
- `llama-server.exe` - HTTP server
- `llama-cli.exe` - interactive CLI
- `llama-bench.exe` - benchmarking
- `llama-quantize.exe` - model quantization
- `ggml-cuda.dll` - CUDA backend

## Troubleshooting

**CUDA error: unsupported Visual Studio version**
- CUDA 13.x only supports VS 2019-2022. Use VS 2022 Build Tools, not VS 2026.

**Ninja can't find cl.exe**
- You're not in a VS developer prompt. Run `vcvarsall.bat` first.

**cudafe++ ACCESS_VIOLATION**
- Same root cause as unsupported VS version. Use VS 2022.
