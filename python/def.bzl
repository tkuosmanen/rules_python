def python_rules_dependencies():
    pass

def _python_toolchain_repository_impl(ctx):
    if (not ctx.attr.interpreter) == (not ctx.attr.interpreter_path):
        fail("one of interpreter and interpreter_path must be specified")

    if ctx.attr.interpreter:
        ctx.symlink(ctx.path(ctx.attr.interpreter), "bin/python")
    else:
        ctx.symlink(ctx.attr.interpreter_path, "bin/python")

    ctx.file("BUILD", """\
package(default_visibility = ["//visibility:public"])

load("@io_bazel_rules_python//:python/toolchain/toolchains.bzl", "define_toolchain")

define_toolchain(
    name = "toolchain",
    toolchain_name = "{name}",
    path = "@{name}//:bin/python",
    expose_site_packages = {expose_site_packages},
)
""".format(name=ctx.name, expose_site_packages=str(ctx.attr.expose_site_packages)))

_python_toolchain_repository = repository_rule(
    implementation = _python_toolchain_repository_impl,
    attrs = {
        "interpreter": attr.label(),
        "interpreter_path": attr.string(),
        "expose_site_packages": attr.bool(default=False),
    },
)

def python_toolchain_repository(name, interpreter=None, interpreter_path=None, expose_site_packages=False):
    _python_toolchain_repository(
        name = name,
        interpreter = interpreter,
        interpreter_path = interpreter_path,
        expose_site_packages = expose_site_packages,
    )
    native.register_toolchains(
        "@%s//:toolchain" % name,
    )
