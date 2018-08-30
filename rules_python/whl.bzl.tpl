load("@io_bazel_rules_python//python:whl.bzl", "download_or_build_wheel", "extract_wheels")

_additional_buildtime_deps = {%{additional_buildtime_deps}
}
_additional_runtime_deps = {%{additional_runtime_deps}
}
_remove_runtime_deps = {%{remove_runtime_deps}
}

def _global_wheel(all_libs, key):
  return "@%s_wheel//:%s" % (all_libs[key]["name"], all_libs[key]["wheel_name"])

def _wheel(all_libs, key):
  return "@%s_wheel//:%s" % (all_libs[key]["name"], all_libs[key]["wheel_name"])

def _extracted_wheel(all_libs, key):
  return "@%s//:%s" % (all_libs[key]["name"], all_libs[key]["wheel_name"])

def whl_library(key, all_libs, name, wheel_name, version=None, urls=None, whl=None, transitive_runtime_deps=[], runtime_deps=[], extras=[], python=None):
    repository = "%{repo}"
    dirty_repo_name = "%s_dirty" % name
    wheel_repo_name = "%s_wheel" % name
    requirement = None if urls != None else "%s==%s" % (key, version)

    buildtime_deps = _additional_buildtime_deps.get(key, [])
    additional_runtime_deps = _additional_runtime_deps.get(key, [])
    remove_runtime_deps = _remove_runtime_deps.get(key, [])

    if name not in native.existing_rules():
        if whl:
            extract_wheels(
                name = name,
                wheels = [whl],
                additional_runtime_deps = additional_runtime_deps,
                remove_runtime_deps = remove_runtime_deps,
                repository = repository,
                extras = extras,
                python = python,
            )
        else:
            download_or_build_wheel(
                name = wheel_repo_name,
                requirement = requirement,
                urls = urls,
                wheel_name = wheel_name,
                buildtime_deps = [_extracted_wheel(all_libs, d) for d in buildtime_deps],
                pip_args = [%{pip_args}],
                python = python,
            )
            extract_wheels(
                name = name,
                wheels = ["@%s//:%s" % (wheel_repo_name, wheel_name)],
                additional_runtime_deps = additional_runtime_deps,
                remove_runtime_deps = remove_runtime_deps,
                repository = repository,
                extras = extras,
                python = python,
            )

    if dirty_repo_name not in native.existing_rules():
        # Make sure the current package's wheel is the first element in the "wheels" list,
        # since piptool will generate the BUILD file based on that.  The remaining wheels
        # on the list should be all transitive runtime dependencies (unless explicitly
        # dropped at pip_import rule level).
        dep_keys = {d.split("[")[0]: None for d in transitive_runtime_deps if d not in remove_runtime_deps}
        if whl:
            wheels = ["@%s//:%s" % (repository, all_libs[key]["wheel_name"])] + \
                     ["@%s//:%s" % (repository, all_libs[key]["wheel_name"]) for key in dep_keys]
        else:
            wheels = [_wheel(all_libs, key)] + \
                     [_wheel(all_libs, d) for d in dep_keys]
        extract_wheels(
            name = dirty_repo_name,
            wheels = wheels,
            additional_runtime_deps = additional_runtime_deps,
            remove_runtime_deps = remove_runtime_deps,
            repository = repository,
            extras = extras,
            python = python,
        )
