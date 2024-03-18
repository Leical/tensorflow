"""Repository rule for hermetic CUDA autoconfiguration.

`hermetic_cuda_configure` depends on the following environment variables:

  * `TF_NEED_CUDA`: Whether to enable building with CUDA.
  * `TF_NVCC_CLANG`: Whether to use clang for C++ and NVCC for Cuda compilation.
  * `CLANG_CUDA_COMPILER_PATH`: The clang compiler path that will be used for
    both host and device code compilation.
  * `TF_SYSROOT`: The sysroot to use when compiling.
  * `TF_CUDA_VERSION`: The version of the CUDA toolkit (mandatory).
  * `TF_CUDA_COMPUTE_CAPABILITIES`: The CUDA compute capabilities. Default is
    `3.5,5.2`.
  * `PYTHON_BIN_PATH`: The python binary path
"""

load(
    "//third_party/remote_config:common.bzl",
    "get_cpu_value",
    "get_host_environ",
)
load(
    ":compiler_common_tools.bzl",
    "get_cxx_inc_directories",
    "to_list_of_strings",
)

def _auto_configure_fail(msg):
    """Output failure message when cuda configuration fails."""
    red = "\033[0;31m"
    no_color = "\033[0m"
    fail("\n%sCuda Configuration Error:%s %s\n" % (red, no_color, msg))

def _lib_name(base_name, cpu_value, version = None, static = False):
    """Constructs the platform-specific name of a library.

    Args:
    base_name: The name of the library, such as "cudart"
    cpu_value: The name of the host operating system.
    version: The version of the library.
    static: True the library is static or False if it is a shared object.

    Returns:
    The platform-specific name of the library.
    """
    version = "" if not version else "." + version
    if cpu_value in ("Linux"):
        if static:
            return "lib%s.a" % base_name
        return "lib%s.so%s" % (base_name, version)
    elif cpu_value == "Windows":
        return "%s.lib" % base_name
    elif cpu_value == "Darwin":
        if static:
            return "lib%s.a" % base_name
        return "lib%s%s.dylib" % (base_name, version)
    else:
        _auto_configure_fail("Invalid cpu_value: %s" % cpu_value)

def _verify_build_defines(params):
    """Verify all variables that crosstool/BUILD.tpl expects are substituted.

    Args:
      params: dict of variables that will be passed to the BUILD.tpl template.
    """
    missing = []
    for param in [
        "cxx_builtin_include_directories",
        "extra_no_canonical_prefixes_flags",
        "host_compiler_path",
        "host_compiler_prefix",
        "host_compiler_warnings",
        "linker_bin_path",
        "compiler_deps",
        "msvc_cl_path",
        "msvc_env_include",
        "msvc_env_lib",
        "msvc_env_path",
        "msvc_env_tmp",
        "msvc_lib_path",
        "msvc_link_path",
        "msvc_ml_path",
        "unfiltered_compile_flags",
        "win_compiler_deps",
    ]:
        if ("%{" + param + "}") not in params:
            missing.append(param)

    if missing:
        _auto_configure_fail(
            "BUILD.tpl template is missing these variables: " +
            str(missing) +
            ".\nWe only got: " +
            str(params) +
            ".",
        )

def get_cuda_version(repository_ctx):
    return get_host_environ(repository_ctx, _TF_CUDA_VERSION)

def enable_cuda(repository_ctx):
    """Returns whether to build with CUDA support."""
    return int(get_host_environ(repository_ctx, TF_NEED_CUDA, False))

def _flag_enabled(repository_ctx, flag_name):
    return get_host_environ(repository_ctx, flag_name) == "1"

def _use_nvcc_and_clang(repository_ctx):
    # Returns the flag if we need to use clang for C++ and NVCC for Cuda.
    return _flag_enabled(repository_ctx, _TF_NVCC_CLANG)

def _tf_sysroot(repository_ctx):
    return get_host_environ(repository_ctx, _TF_SYSROOT, "")

def _py_tmpl_dict(d):
    return {"%{cuda_config}": str(d)}

def _cudart_static_linkopt(cpu_value):
    """Returns additional platform-specific linkopts for cudart."""
    return "" if cpu_value == "Darwin" else "\"-lrt\","

def _compute_capabilities(repository_ctx):
    """Returns a list of strings representing cuda compute capabilities.

    Args:
      repository_ctx: the repo rule's context.

    Returns:
      list of cuda architectures to compile for. 'compute_xy' refers to
      both PTX and SASS, 'sm_xy' refers to SASS only.
    """
    capabilities = get_host_environ(
        repository_ctx,
        _TF_CUDA_COMPUTE_CAPABILITIES,
        "compute_35,compute_52",
    ).split(",")

    # Map old 'x.y' capabilities to 'compute_xy'.
    if len(capabilities) > 0 and all([len(x.split(".")) == 2 for x in capabilities]):
        # If all capabilities are in 'x.y' format, only include PTX for the
        # highest capability.
        cc_list = sorted([x.replace(".", "") for x in capabilities])
        capabilities = ["sm_%s" % x for x in cc_list[:-1]] + ["compute_%s" % cc_list[-1]]
    for i, capability in enumerate(capabilities):
        parts = capability.split(".")
        if len(parts) != 2:
            continue
        capabilities[i] = "compute_%s%s" % (parts[0], parts[1])

    # Make list unique
    capabilities = dict(zip(capabilities, capabilities)).keys()

    # Validate capabilities.
    for capability in capabilities:
        if not capability.startswith(("compute_", "sm_")):
            _auto_configure_fail("Invalid compute capability: %s" % capability)
        for prefix in ["compute_", "sm_"]:
            if not capability.startswith(prefix):
                continue
            if len(capability) == len(prefix) + 2 and capability[-2:].isdigit():
                continue
            if len(capability) == len(prefix) + 3 and capability.endswith("90a"):
                continue
            _auto_configure_fail("Invalid compute capability: %s" % capability)

    return capabilities

def _compute_cuda_extra_copts(compute_capabilities):
    copts = ["--no-cuda-include-ptx=all"]
    for capability in compute_capabilities:
        if capability.startswith("compute_"):
            capability = capability.replace("compute_", "sm_")
            copts.append("--cuda-include-ptx=%s" % capability)
        copts.append("--cuda-gpu-arch=%s" % capability)

    return str(copts)

def _get_cuda_config(repository_ctx):
    """Detects and returns information about the CUDA installation on the system.

      Args:
        repository_ctx: The repository context.

      Returns:
        A struct containing the following fields:
          cuda_version: The version of CUDA on the system.
          cudart_version: The CUDA runtime version on the system.
          cudnn_version: The version of cuDNN on the system.
          compute_capabilities: A list of the system's CUDA compute capabilities.
          cpu_value: The name of the host operating system.
      """

    return struct(
        cuda_version = get_cuda_version(repository_ctx),
        cupti_version = repository_ctx.read(repository_ctx.attr.cupti_version),
        cudart_version = repository_ctx.read(repository_ctx.attr.cudart_version),
        cublas_version = repository_ctx.read(repository_ctx.attr.cublas_version),
        cusolver_version = repository_ctx.read(repository_ctx.attr.cusolver_version),
        curand_version = repository_ctx.read(repository_ctx.attr.curand_version),
        cufft_version = repository_ctx.read(repository_ctx.attr.cufft_version),
        cusparse_version = repository_ctx.read(repository_ctx.attr.cusparse_version),
        cudnn_version = repository_ctx.read(repository_ctx.attr.cudnn_version),
        compute_capabilities = _compute_capabilities(repository_ctx),
        cpu_value = get_cpu_value(repository_ctx),
    )

_DUMMY_CROSSTOOL_BZL_FILE = """
def error_gpu_disabled():
  fail("ERROR: Building with --config=cuda but TensorFlow is not configured " +
       "to build with GPU support. Please re-run ./configure and enter 'Y' " +
       "at the prompt to build with GPU support.")

  native.genrule(
      name = "error_gen_crosstool",
      outs = ["CROSSTOOL"],
      cmd = "echo 'Should not be run.' && exit 1",
  )

  native.filegroup(
      name = "crosstool",
      srcs = [":CROSSTOOL"],
      output_licenses = ["unencumbered"],
  )
"""

_DUMMY_CROSSTOOL_BUILD_FILE = """
load("//crosstool:error_gpu_disabled.bzl", "error_gpu_disabled")

error_gpu_disabled()
"""

def _create_dummy_repository(repository_ctx):
    cpu_value = get_cpu_value(repository_ctx)

    # Set up BUILD file for cuda/.
    repository_ctx.template(
        "cuda/build_defs.bzl",
        repository_ctx.attr.build_defs_tpl,
        {
            "%{cuda_is_configured}": "False",
            "%{cuda_extra_copts}": "[]",
            "%{cuda_gpu_architectures}": "[]",
            "%{cuda_version}": "0.0",
        },
    )

    repository_ctx.template(
        "cuda/BUILD",
        repository_ctx.attr.dummy_cuda_build_tpl,
        {
            "%{cuda_driver_lib}": _lib_name("cuda", cpu_value),
            "%{cudart_static_lib}": _lib_name(
                "cudart_static",
                cpu_value,
                static = True,
            ),
            "%{cudart_static_linkopt}": _cudart_static_linkopt(cpu_value),
            "%{cudart_lib}": _lib_name("cudart", cpu_value),
            "%{cublas_lib}": _lib_name("cublas", cpu_value),
            "%{cublasLt_lib}": _lib_name("cublasLt", cpu_value),
            "%{cusolver_lib}": _lib_name("cusolver", cpu_value),
            "%{cudnn_lib}": _lib_name("cudnn", cpu_value),
            "%{cufft_lib}": _lib_name("cufft", cpu_value),
            "%{curand_lib}": _lib_name("curand", cpu_value),
            "%{cupti_lib}": _lib_name("cupti", cpu_value),
            "%{cusparse_lib}": _lib_name("cusparse", cpu_value),
            "%{cub_actual}": ":cuda_headers",
            "%{copy_rules}": """
filegroup(name="cuda-include")
filegroup(name="cublas-include")
filegroup(name="cusolver-include")
filegroup(name="cufft-include")
filegroup(name="cusparse-include")
filegroup(name="curand-include")
filegroup(name="cudnn-include")
""",
        },
    )

    # Create dummy files for the CUDA toolkit since they are still required by
    # tensorflow/tsl/platform/default/build_config:cuda.
    repository_ctx.file("cuda/cuda/include/cuda.h")
    repository_ctx.file("cuda/cuda/include/cublas.h")
    repository_ctx.file("cuda/cuda/include/cudnn.h")
    repository_ctx.file("cuda/cuda/extras/CUPTI/include/cupti.h")
    repository_ctx.file("cuda/cuda/nvml/include/nvml.h")
    repository_ctx.file("cuda/cuda/lib/%s" % _lib_name("cuda", cpu_value))
    repository_ctx.file("cuda/cuda/lib/%s" % _lib_name("cudart", cpu_value))
    repository_ctx.file(
        "cuda/cuda/lib/%s" % _lib_name("cudart_static", cpu_value),
    )
    repository_ctx.file("cuda/cuda/lib/%s" % _lib_name("cublas", cpu_value))
    repository_ctx.file("cuda/cuda/lib/%s" % _lib_name("cublasLt", cpu_value))
    repository_ctx.file("cuda/cuda/lib/%s" % _lib_name("cusolver", cpu_value))
    repository_ctx.file("cuda/cuda/lib/%s" % _lib_name("cudnn", cpu_value))
    repository_ctx.file("cuda/cuda/lib/%s" % _lib_name("curand", cpu_value))
    repository_ctx.file("cuda/cuda/lib/%s" % _lib_name("cufft", cpu_value))
    repository_ctx.file("cuda/cuda/lib/%s" % _lib_name("cupti", cpu_value))
    repository_ctx.file("cuda/cuda/lib/%s" % _lib_name("cusparse", cpu_value))

    # Set up cuda_config.h, which is used by
    # tensorflow/compiler/xla/stream_executor/dso_loader.cc.
    repository_ctx.template(
        "cuda/cuda/cuda_config.h",
        repository_ctx.attr.cuda_config_tpl,
        {
            "%{cuda_version}": "",
            "%{cudart_version}": "",
            "%{cupti_version}": "",
            "%{cublas_version}": "",
            "%{cusolver_version}": "",
            "%{curand_version}": "",
            "%{cufft_version}": "",
            "%{cusparse_version}": "",
            "%{cudnn_version}": "",
            "%{cuda_toolkit_path}": "",
            "%{cuda_compute_capabilities}": "",
        },
    )

    # Set up cuda_config.py, which is used by gen_build_info to provide
    # static build environment info to the API
    repository_ctx.template(
        "cuda/cuda/cuda_config.py",
        repository_ctx.attr.cuda_config_py_tpl,
        _py_tmpl_dict({}),
    )

    # If cuda_configure is not configured to build with GPU support, and the user
    # attempts to build with --config=cuda, add a dummy build rule to intercept
    # this and fail with an actionable error message.
    repository_ctx.file(
        "crosstool/error_gpu_disabled.bzl",
        _DUMMY_CROSSTOOL_BZL_FILE,
    )
    repository_ctx.file("crosstool/BUILD", _DUMMY_CROSSTOOL_BUILD_FILE)

def _create_local_cuda_repository(repository_ctx):
    """Creates the repository containing files set up to build with CUDA."""
    cuda_config = _get_cuda_config(repository_ctx)

    # Set up BUILD file for cuda/
    repository_ctx.template(
        "cuda/build_defs.bzl",
        repository_ctx.attr.build_defs_tpl,
        {
            "%{cuda_is_configured}": "True",
            "%{cuda_extra_copts}": _compute_cuda_extra_copts(
                cuda_config.compute_capabilities,
            ),
            "%{cuda_gpu_architectures}": str(cuda_config.compute_capabilities),
            "%{cuda_version}": cuda_config.cuda_version,
        },
    )

    repository_ctx.template(
        "cuda/BUILD",
        repository_ctx.attr.cuda_build_tpl,
        {
            "%{cudart_static_linkopt}": _cudart_static_linkopt(cuda_config.cpu_value),
            "%{cub_actual}": ":cuda_headers",
            "%{cccl_repo_name}": repository_ctx.attr.cccl_version.repo_name,
            "%{cublas_repo_name}": repository_ctx.attr.cublas_version.repo_name,
            "%{cudart_repo_name}": repository_ctx.attr.cudart_version.repo_name,
            "%{cudnn_repo_name}": repository_ctx.attr.cudnn_version.repo_name,
            "%{cufft_repo_name}": repository_ctx.attr.cufft_version.repo_name,
            "%{cupti_repo_name}": repository_ctx.attr.cupti_version.repo_name,
            "%{curand_repo_name}": repository_ctx.attr.curand_version.repo_name,
            "%{cusolver_repo_name}": repository_ctx.attr.cusolver_version.repo_name,
            "%{cusparse_repo_name}": repository_ctx.attr.cusparse_version.repo_name,
            "%{nvcc_repo_name}": repository_ctx.attr.nvcc_binary.repo_name,
            "%{nvjitlink_repo_name}": repository_ctx.attr.nvjitlink_version.repo_name,
            "%{nvml_repo_name}": repository_ctx.attr.nvml_version.repo_name,
            "%{nvtx_repo_name}": repository_ctx.attr.nvtx_version.repo_name,
            "%{nvprune_repo_name}": repository_ctx.attr.nvprune_version.repo_name,
        },
    )

    is_nvcc_and_clang = _use_nvcc_and_clang(repository_ctx)
    tf_sysroot = _tf_sysroot(repository_ctx)

    # Set up crosstool/
    cc = get_host_environ(repository_ctx, _CLANG_CUDA_COMPILER_PATH)
    host_compiler_includes = get_cxx_inc_directories(
        repository_ctx,
        cc,
        tf_sysroot,
    )

    cuda_defines = {}

    # CUDA is not supported in Windows.
    # This ensures the CROSSTOOL file parser is happy.
    cuda_defines.update({
        "%{msvc_env_tmp}": "msvc_not_used",
        "%{msvc_env_path}": "msvc_not_used",
        "%{msvc_env_include}": "msvc_not_used",
        "%{msvc_env_lib}": "msvc_not_used",
        "%{msvc_cl_path}": "msvc_not_used",
        "%{msvc_ml_path}": "msvc_not_used",
        "%{msvc_link_path}": "msvc_not_used",
        "%{msvc_lib_path}": "msvc_not_used",
        "%{win_compiler_deps}": ":empty",
    })

    cuda_defines["%{builtin_sysroot}"] = tf_sysroot
    cuda_defines["%{cuda_toolkit_path}"] = repository_ctx.attr.nvcc_binary.workspace_root
    cuda_defines["%{compiler}"] = "clang"
    cuda_defines["%{host_compiler_prefix}"] = "/usr/bin"
    cuda_defines["%{linker_bin_path}"] = ""
    cuda_defines["%{extra_no_canonical_prefixes_flags}"] = ""
    cuda_defines["%{unfiltered_compile_flags}"] = ""
    cuda_defines["%{cxx_builtin_include_directories}"] = to_list_of_strings(host_compiler_includes)
    cuda_defines["%{cuda_nvcc_files}"] = "if_cuda([\"@{nvcc_archive}//:bin\", \"@{nvcc_archive}//:nvvm\"])".format(nvcc_archive = repository_ctx.attr.nvcc_binary.repo_name)

    if not is_nvcc_and_clang:
        cuda_defines["%{host_compiler_path}"] = str(cc)
        cuda_defines["%{host_compiler_warnings}"] = """
        # Some parts of the codebase set -Werror and hit this warning, so
        # switch it off for now.
        "-Wno-invalid-partial-specialization"
    """
        cuda_defines["%{compiler_deps}"] = ":cuda_nvcc_files"
        repository_ctx.file(
            "crosstool/clang/bin/crosstool_wrapper_driver_is_not_gcc",
            "",
        )
    else:
        cuda_defines["%{host_compiler_path}"] = "clang/bin/crosstool_wrapper_driver_is_not_gcc"
        cuda_defines["%{host_compiler_warnings}"] = ""

        nvcc_relative_path = "%s/%s" % (repository_ctx.attr.nvcc_binary.workspace_root, repository_ctx.attr.nvcc_binary.name)
        cuda_defines["%{compiler_deps}"] = ":crosstool_wrapper_driver_is_not_gcc"

        wrapper_defines = {
            "%{cpu_compiler}": str(cc),
            "%{cuda_version}": cuda_config.cuda_version,
            "%{nvcc_path}": nvcc_relative_path,
            "%{host_compiler_path}": str(cc),
            "%{use_clang_compiler}": "True",
        }
        repository_ctx.template(
            "crosstool/clang/bin/crosstool_wrapper_driver_is_not_gcc",
            repository_ctx.attr.crosstool_wrapper_driver_is_not_gcc_tpl,
            wrapper_defines,
        )

    _verify_build_defines(cuda_defines)

    # Only expand template variables in the BUILD file
    repository_ctx.template(
        "crosstool/BUILD",
        repository_ctx.attr.crosstool_build_tpl,
        cuda_defines,
    )

    # No templating of cc_toolchain_config - use attributes and templatize the
    # BUILD file.
    repository_ctx.template(
        "crosstool/cc_toolchain_config.bzl",
        repository_ctx.attr.cc_toolchain_config_tpl,
        {},
    )

    # Set up cuda_config.h, which is used by
    # tensorflow/compiler/xla/stream_executor/dso_loader.cc.
    repository_ctx.template(
        "cuda/cuda/cuda_config.h",
        repository_ctx.attr.cuda_config_tpl,
        {
            "%{cuda_version}": cuda_config.cuda_version,
            "%{cudart_version}": cuda_config.cudart_version,
            "%{cupti_version}": cuda_config.cupti_version,
            "%{cublas_version}": cuda_config.cublas_version,
            "%{cusolver_version}": cuda_config.cusolver_version,
            "%{curand_version}": cuda_config.curand_version,
            "%{cufft_version}": cuda_config.cufft_version,
            "%{cusparse_version}": cuda_config.cusparse_version,
            "%{cudnn_version}": cuda_config.cudnn_version,
            "%{cuda_toolkit_path}": "",
            "%{cuda_compute_capabilities}": ", ".join([
                cc.split("_")[1]
                for cc in cuda_config.compute_capabilities
            ]),
        },
    )

    # Set up cuda_config.py, which is used by gen_build_info to provide
    # static build environment info to the API
    repository_ctx.template(
        "cuda/cuda/cuda_config.py",
        repository_ctx.attr.cuda_config_py_tpl,
        _py_tmpl_dict({
            "cuda_version": cuda_config.cuda_version,
            "cudnn_version": cuda_config.cudnn_version,
            "cuda_compute_capabilities": cuda_config.compute_capabilities,
            "cpu_compiler": str(cc),
        }),
    )

def _cuda_autoconf_impl(repository_ctx):
    """Implementation of the cuda_autoconf repository rule."""
    build_file = repository_ctx.attr.local_config_cuda_build_file

    if not enable_cuda(repository_ctx):
        _create_dummy_repository(repository_ctx)
    else:
        _create_local_cuda_repository(repository_ctx)

    repository_ctx.symlink(build_file, "BUILD")

_CLANG_CUDA_COMPILER_PATH = "CLANG_CUDA_COMPILER_PATH"
_PYTHON_BIN_PATH = "PYTHON_BIN_PATH"
_TF_CUDA_COMPUTE_CAPABILITIES = "TF_CUDA_COMPUTE_CAPABILITIES"
_TF_CUDA_VERSION = "TF_CUDA_VERSION"
TF_NEED_CUDA = "TF_NEED_CUDA"
_TF_NVCC_CLANG = "TF_NVCC_CLANG"
_TF_SYSROOT = "TF_SYSROOT"

_ENVIRONS = [
    _CLANG_CUDA_COMPILER_PATH,
    TF_NEED_CUDA,
    _TF_NVCC_CLANG,
    _TF_CUDA_VERSION,
    _TF_CUDA_COMPUTE_CAPABILITIES,
    _TF_SYSROOT,
    _PYTHON_BIN_PATH,
    "TMP",
    "TMPDIR",
]

hermetic_cuda_configure = repository_rule(
    implementation = _cuda_autoconf_impl,
    environ = _ENVIRONS,
    attrs = {
        "environ": attr.string_dict(),
        "cccl_version": attr.label(default = Label("@cuda_cccl//:version.txt")),
        "cublas_version": attr.label(default = Label("@cuda_cublas//:version.txt")),
        "cudart_version": attr.label(default = Label("@cuda_cudart//:version.txt")),
        "cudnn_version": attr.label(default = Label("@cuda_cudnn//:version.txt")),
        "cufft_version": attr.label(default = Label("@cuda_cufft//:version.txt")),
        "cupti_version": attr.label(default = Label("@cuda_cupti//:version.txt")),
        "curand_version": attr.label(default = Label("@cuda_curand//:version.txt")),
        "cusolver_version": attr.label(default = Label("@cuda_cusolver//:version.txt")),
        "cusparse_version": attr.label(default = Label("@cuda_cusparse//:version.txt")),
        "nvcc_binary": attr.label(default = Label("@cuda_nvcc//:bin/nvcc")),
        "nvjitlink_version": attr.label(default = Label("@cuda_nvjitlink//:version.txt")),
        "nvml_version": attr.label(default = Label("@cuda_nvml//:version.txt")),
        "nvprune_version": attr.label(default = Label("@cuda_nvprune//:version.txt")),
        "nvtx_version": attr.label(default = Label("@cuda_nvtx//:version.txt")),
        "local_config_cuda_build_file": attr.label(default = Label("//third_party/gpus:local_config_cuda.BUILD")),
        "build_defs_tpl": attr.label(default = Label("//third_party/gpus/cuda:build_defs.bzl.tpl")),
        "cuda_build_tpl": attr.label(default = Label("//third_party/gpus/cuda:BUILD.hermetic.tpl")),
        "dummy_cuda_build_tpl": attr.label(default = Label("//third_party/gpus/cuda:BUILD.tpl")),
        "cuda_config_tpl": attr.label(default = Label("//third_party/gpus/cuda:cuda_config.h.tpl")),
        "cuda_config_py_tpl": attr.label(default = Label("//third_party/gpus/cuda:cuda_config.py.tpl")),
        "crosstool_wrapper_driver_is_not_gcc_tpl": attr.label(default = Label("//third_party/gpus/crosstool:clang/bin/crosstool_wrapper_driver_is_not_gcc.tpl")),
        "crosstool_build_tpl": attr.label(default = Label("//third_party/gpus/crosstool:BUILD.tpl")),
        "cc_toolchain_config_tpl": attr.label(default = Label("//third_party/gpus/crosstool:cc_toolchain_config.bzl.tpl")),
    },
)
"""Detects and configures the hermetic CUDA toolchain.

Add the following to your WORKSPACE FILE:

```python
hermetic cuda_configure(name = "local_config_cuda")
```

Args:
  name: A unique name for this workspace rule.
"""
