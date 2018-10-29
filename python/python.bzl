# Copyright 2017 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

ImportsProvider = provider(
    fields = {
        "imports": "collected imports (dict)",  # todo depset?
    },
)

def _get_initfiles(existing_runfiles, files_depset, empty_init_py):
    files_map = {f.short_path: None for f in files_depset.to_list()}
    symlinks = {}
    for f in files_map:
        parts = f.rsplit(".", 1)
        if parts[-1] not in ["py", "pyc", "so"]:
            continue

        # Given foo/bar/baz.py,
        # we split to [foo, bar, baz.py]
        # and ensure existence of [foo/__init__.py, foo/bar/__init__.py]
        parts = f.split("/")
        for i in range(1, len(parts)):
            dirname = "/".join(parts[0:i])
            if dirname + "/__init__.py" not in files_map and \
                    dirname + "/__init__.pyc" not in files_map and \
                    dirname + "/__init__.py" not in existing_runfiles.empty_filenames:
                symlinks[dirname + "/__init__.py"] = empty_init_py
    return symlinks

def _py_binary_impl(ctx):
    srcs = ctx.attr.srcs
    data = ctx.attr.data

    # If empty is not provided, try to find among the source files
    main = None
    if not ctx.attr.main:
        for f in srcs:
            f = f.files.to_list()[0]
            if f.basename == ctx.attr.name + ".py":
                main = f
                break
        if not main:
            fail('Argument "main" not provided and couldn\'t infer from the source files provided')
    else:
        main = ctx.attr.main.files.to_list()[0]

    # Get the interpreter path from the toolchain
    toolchain = ctx.toolchains["@io_bazel_rules_python//python:toolchain"]
    interpreter = toolchain.interpreter.files.to_list()[0]

    # Collect imports from all transitive deps, to construct PYTHONPATH.
    imports = {}
    for d in ctx.attr.deps:
        imports.update(d[ImportsProvider].imports)
    pythonpath = ":".join(["$EXECROOT/%s" % p for p in imports])

    # Collect all runfiles from dependent targets.
    transitive_runfiles = ctx.runfiles(collect_default = True)
    transitive_files = depset(
        transitive = [d.files for d in ctx.attr.srcs] + [d.files for d in ctx.attr.data] + [transitive_runfiles.files],
    )

    # Generate missing __init__.py files, if needed.
    symlinks = {}
    if ctx.attr.legacy_create_init:
        symlinks.update(_get_initfiles(transitive_runfiles, transitive_files, ctx.file._empty_init_py))

    runfiles = ctx.runfiles(
        symlinks = symlinks,
        files = [interpreter],
        transitive_files = transitive_files,
    )

    # Create the action that runs the command
    cmd = """#!/bin/bash
set -eo pipefail

function guess_runfiles() {{
    if [ -d ${{BASH_SOURCE[0]}}.runfiles ]; then
        # Runfiles are adjacent to the current script.
        echo "$( cd ${{BASH_SOURCE[0]}}.runfiles && pwd )"
    else
        # The current script is within some other script's runfiles.
        mydir="$( cd "$( dirname "${{BASH_SOURCE[0]}}" )" && pwd )"
        echo $mydir | sed -e 's|\(.*\.runfiles\)/.*|\\1|'
    fi
}}
RUNFILES="${{RUNFILES_DIR:-$(guess_runfiles)}}"
EXECROOT="$RUNFILES/{workspace_name}"
export PYTHONPATH="$EXECROOT:{pythonpath}"

$EXECROOT/{python} {pyargs} $EXECROOT/{main} "$@"
""".format(
        workspace_name = ctx.workspace_name,
        python = interpreter.path,
        pythonpath = pythonpath,
        main = main.short_path,
        pyargs = " ".join(toolchain.pyargs),
    )
    executable = ctx.actions.declare_file("%s/%s/%s" % (ctx.attr.name, toolchain.name, ctx.attr.name))
    ctx.actions.write(executable, cmd, is_executable = True)

    return struct(
        py = struct(transitive_sources = runfiles.files),
        providers = [DefaultInfo(runfiles = runfiles, executable = executable)],
    )

def _imports_aspect_impl(target, ctx):
    imports = {}
    if hasattr(ctx.rule.attr, "imports") and ctx.rule.attr.imports:
        for imp in ctx.rule.attr.imports:
            path = "/".join([x for x in [target.label.workspace_root, target.label.package, imp] if x])
            imports[path] = None
    for dep in ctx.rule.attr.deps:
        imports.update(dep[ImportsProvider].imports)
    return [ImportsProvider(imports = imports)]

imports_aspect = aspect(
    implementation = _imports_aspect_impl,
    attr_aspects = ["deps"],
    attrs = {
    },
)

py_binary = rule(
    implementation = _py_binary_impl,
    attrs = {
        "main": attr.label(allow_files = True),
        "deps": attr.label_list(
            providers = [],  # TODO
            aspects = [imports_aspect],  # TODO?
        ),
        "srcs": attr.label_list(
            allow_files = [".py"],
            mandatory = True,
            allow_empty = False,
        ),
        "data": attr.label_list(
            allow_files = True,
            cfg = "data",
        ),
        "legacy_create_init": attr.bool(
            default = True,
        ),
        "_empty_init_py": attr.label(
            allow_files = True,
            single_file = True,
            default = "@io_bazel_rules_python//python:__init__.py",
        ),
    },
    executable = True,
    toolchains = ["@io_bazel_rules_python//python:toolchain"],
)

py_test = rule(
    implementation = _py_binary_impl,
    attrs = {
        "main": attr.label(allow_files = True),
        "deps": attr.label_list(
            providers = [],  # TODO
            aspects = [imports_aspect],  # TODO?
        ),
        "srcs": attr.label_list(
            allow_files = [".py"],
            mandatory = True,
            allow_empty = False,
        ),
        "data": attr.label_list(
            allow_files = True,
            cfg = "data",
        ),
        "legacy_create_init": attr.bool(
            default = True,
        ),
        "_empty_init_py": attr.label(
            allow_files = True,
            single_file = True,
            default = "@io_bazel_rules_python//python:__init__.py",
        ),
    },
    test = True,
    toolchains = ["@io_bazel_rules_python//python:toolchain"],
)

def py_library(*args, **kwargs):
    """See the Bazel core py_library documentation.

    [available here](
    https://docs.bazel.build/versions/master/be/python.html#py_library).
    """
    native.py_library(*args, **kwargs)
