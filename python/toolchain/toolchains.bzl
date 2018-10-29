def _python_toolchain_impl(ctx):
    pyargs = []
    if not ctx.attr.expose_site_packages:
        pyargs += ["-s", "-S"]
    return [
        platform_common.ToolchainInfo(
            interpreter = ctx.attr.interpreter,
            name = ctx.attr.toolchain_name,
            pyargs = pyargs,
        ),
    ]

_python_toolchain = rule(
    _python_toolchain_impl,
    attrs = {
        "interpreter": attr.label(allow_files = True, single_file = True, executable = True, cfg = 'host'),
        "expose_site_packages": attr.bool(default=False),
        "toolchain_name": attr.string(),
    }
)

def define_toolchain(name, toolchain_name, path, expose_site_packages=False, target_compatible_with=None):
    _python_toolchain(
        name = toolchain_name + "_toolchain",
        interpreter = path,
        toolchain_name = toolchain_name,
        expose_site_packages = expose_site_packages,
    )

    native.toolchain(
        name = name,
        toolchain_type = "@io_bazel_rules_python//python:toolchain",
        toolchain = ":%s_toolchain" % toolchain_name,
        target_compatible_with = target_compatible_with,
    )
