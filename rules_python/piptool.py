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
"""The piptool module imports pip requirements into Bazel rules."""

import argparse
import atexit
import json
import os
import pkgutil
import pkg_resources
import re
import shutil
import sys
import tempfile
import zipfile

# Note: We carefully import the following modules in a particular
# order, since these modules modify the import path and machinery.
import pkg_resources


def extract_packages(package_names):
    """Extract zipfile contents to disk and add to import path"""

    # Set a safe extraction dir
    extraction_tmpdir = tempfile.mkdtemp()
    atexit.register(lambda: shutil.rmtree(
        extraction_tmpdir, ignore_errors=True))
    pkg_resources.set_extraction_path(extraction_tmpdir)

    # Extract each package to disk
    dirs_to_add = []
    for package_name in package_names:
        req = pkg_resources.Requirement.parse(package_name)
        extraction_dir = pkg_resources.resource_filename(req, '')
        dirs_to_add.append(extraction_dir)

    # Add extracted directories to import path ahead of their zip file
    # counterparts.
    sys.path[0:0] = dirs_to_add
    existing_pythonpath = os.environ.get('PYTHONPATH')
    if existing_pythonpath:
        dirs_to_add.extend(existing_pythonpath.split(':'))
    os.environ['PYTHONPATH'] = ':'.join(dirs_to_add)


# Wheel, pip, and setuptools are much happier running from actual
# files on disk, rather than entries in a zipfile.  Extract zipfile
# contents, add those contents to the path, then import them.
extract_packages(['pip', 'setuptools', 'wheel'])

# Defeat pip's attempt to mangle sys.path
saved_sys_path = sys.path
sys.path = sys.path[:]
import pip
sys.path = saved_sys_path

import setuptools
import wheel


def pip_main(argv):
    # Extract the certificates from the PAR following the example of get-pip.py
    # https://github.com/pypa/get-pip/blob/430ba37776ae2ad89/template.py#L164-L168
    cert_path = os.path.join(tempfile.mkdtemp(), "cacert.pem")
    with open(cert_path, "wb") as cert:
      cert.write(pkgutil.get_data("pip._vendor.requests", "cacert.pem"))
    argv = ["--disable-pip-version-check", "--cert", cert_path] + argv
    return pip.main(argv)

from rules_python.whl import Wheel, unpack


def determine_possible_extras(whls):
  """Determines the list of possible "extras" for each .whl

  The possibility of an extra is determined by looking at its
  additional requirements, and determinine whether they are
  satisfied by the complete list of available wheels.

  Args:
    whls: a list of Wheel objects

  Returns:
    a dict that is keyed by the Wheel objects in whls, and whose
    values are lists of possible extras.
  """
  whl_map = {
    whl.distribution(): whl
    for whl in whls
  }

  # TODO(mattmoor): Consider memoizing if this recursion ever becomes
  # expensive enough to warrant it.
  def is_possible(distro, extra):
    distro = distro.replace("-", "_")
    # If we don't have the .whl at all, then this isn't possible.
    if distro not in whl_map:
      return False
    whl = whl_map[distro]
    # If we have the .whl, and we don't need anything extra then
    # we can satisfy this dependency.
    if not extra:
      return True
    # If we do need something extra, then check the extra's
    # dependencies to make sure they are fully satisfied.
    for extra_dep in whl.dependencies(extra=extra):
      req = pkg_resources.Requirement.parse(extra_dep)
      # Check that the dep and any extras are all possible.
      if not is_possible(req.project_name, None):
        return False
      for e in req.extras:
        if not is_possible(req.project_name, e):
          return False
    # If all of the dependencies of the extra are satisfiable then
    # it is possible to construct this dependency.
    return True

  return {
    whl: [
      extra
      for extra in whl.extras()
      if is_possible(whl.distribution(), extra)
    ]
    for whl in whls
  }

def resolve(args):
  cache_dir = os.path.join(args.directory or ".", "cache")
  os.makedirs(cache_dir)
  pip_args = ["wheel"]
  pip_args += ["--cache-dir", cache_dir]
  if args.directory:
    pip_args += ["-w", args.directory]
  if args.input:
    pip_args += ["-r", args.input]
  if args.constraint:
    pip_args += ["-c", args.constraint]
  if len(args.args) > 0 and args.args[0] == '--':
    pip_args += args.args[1:]
  else:
    pip_args += args.args
  # https://github.com/pypa/pip/blob/9.0.1/pip/__init__.py#L209
  if pip_main(pip_args):
    sys.exit(1)

  # Enumerate the .whl files we downloaded.
  def list_whls(dir):
    for root, _, filenames in os.walk(dir + "/"):
      for fname in filenames:
        if fname.endswith('.whl'):
          yield Wheel(os.path.join(root, fname))

  def wheels_from_dir(dir):
    whls = list(list_whls(dir))
    whls.sort(key=lambda x: x.distribution().lower())
    return whls

  whls = wheels_from_dir(args.directory)
  possible_extras = determine_possible_extras(whls)

  def parse_fix(filename):
      with open(filename, 'r') as f:
          lines = f.readlines()
          for line in lines:
              items = line.strip().split(' ')
              main_ref = items[0]
              others = items[1:]
              for w in whls:
                  if w.distribution().lower() == main_ref.replace('-', '_').lower():
                      yield w, others
                      break

  if args.buildtime_fix:
    for w, deps in parse_fix(args.buildtime_fix):
      w.add_extra_buildtime_deps(deps)
  if args.runtime_fix:
    for w, deps in parse_fix(args.runtime_fix):
      w.add_extra_runtime_deps(deps)

  if not args.output:
    return

  #fixed_versions = ["{}=={}".format(wheel.distribution(), wheel.version()) for wheel in whls]
  #fix_file = os.path.join(args.directory, "requirements-pip-fixed.txt")
  #with open(fix_file, "w") as f:
  #  f.write('\n'.join(fixed_versions))

  #print("\n\nANALYZING DEPENDENCIES\n\n")


  def quote(string):
    return '"{}"'.format(string)

  # If we are generating whl_library rules that are intended to be fully
  # deterministic and we lock the transient dependency versions, then we
  # don't want to share repositories across different pip_import repositories.
  scope = args.name if args.output_format == 'download' else None

  whl_map = {
    whl.distribution(): whl
    for whl in whls
  }

  def whl_library(wheel):
    attrs = {"name": quote(wheel.repository_name(scope))}
    if args.output_format == 'download':
      attrs["requirement"] = '"{}=={}"'.format(wheel.distribution(), wheel.version())
      attrs["whl_name"] = quote(wheel.basename())
    else:
      attrs["whl"] = '"@{}//:{}"'.format(args.name, wheel.basename())
    extras = ', '.join([quote(extra) for extra in possible_extras.get(wheel, [])])
    if extras != '':
      attrs["extras"] = '[{}]'.format(extras)
    # Hopefully these are not needed and we can use requirements-fix.txt ONLY
    # for ensuring build-time deps!
    extra_deps = ', '.join([quote(extra) for extra in wheel.get_extra_runtime_deps()])
    if extra_deps != '':
      attrs["extra_deps"] = '[{}]'.format(extra_deps)
    build_deps = ', '.join(['"@{}//:pkg"'.format(whl_map[dep].repository_name(scope)) for dep in wheel.get_extra_buildtime_deps()])
    if build_deps != '':
      attrs["whl_build_deps"] = '[{}]'.format(build_deps)
    # Indentation here matters.  whl_library must be within the scope
    # of the function below.  We also avoid reimporting an existing WHL.
    return """
  whl_library(
    {},
  )""".format(",\n    ".join(["{} = {}".format(k, v) for k, v in attrs.items()]))

  whl_targets = ',\n  '.join([
    ',\n  '.join([
      '"{dist}": "@{repo}//:pkg",\n  "{dist}:dirty": "@{repo}_dirty//:pkg"'.format(
          dist=whl.distribution().lower(), repo=whl.repository_name(scope))
    ] + [
      # For every extra that is possible from this requirements.txt
      '"{dist}[{extra_lower}]": "@{repo}//:{extra}",\n  "{dist}:dirty[{extra_lower}]": "@{repo}_dirty//:{extra}"'.format(
        dist=whl.distribution().lower(), repo=whl.repository_name(scope), extra=extra, extra_lower=extra.lower())
      for extra in possible_extras.get(whl, [])
    ])
    for whl in whls
  ])

  with open(args.output, 'w') as f:
    f.write("""\
# Install pip requirements.
#
# Generated from {input}

load("@{name}//python:whl.bzl", "whl_library")

def pip_install():
{whl_libraries}

_requirements = {{
  {mappings}
}}

all_requirements = _requirements.values()

def requirement(name):
  name_key = name.replace("-", "_").lower()
  if name_key not in _requirements:
    fail("Could not find pip-provided dependency: '%s'" % name)
  return _requirements[name_key]
""".format(input=args.input, name=args.name,
           whl_libraries='\n'.join(map(whl_library, whls)) if whls else "pass",
           mappings=whl_targets))


global_parser = argparse.ArgumentParser(
    description='Import Python dependencies into Bazel.')
subparsers = global_parser.add_subparsers()

# piptool resolve
parser = subparsers.add_parser('resolve', help='Resolve wheels from requirements.txt')
parser.set_defaults(func=resolve)

parser.add_argument('--name', action='store',
                    help=('The namespace of the import.'))

parser.add_argument('--input', action='store',
                    help=('The requirements.txt file to import.'))

parser.add_argument('--input-fix', action='store',
                    help=('The requirements-fix.txt file to import.'))

parser.add_argument('--runtime-fix', action='store',
                    help=('Additional runtime dependencies.'))

parser.add_argument('--buildtime-fix', action='store',
                    help=('Additional buildtime dependencies.'))

parser.add_argument('--constraint', action='store',
                    help=('An optional constraints file to pass to "pip wheel" command.'))

parser.add_argument('--output', action='store',
                    help=('The requirements.bzl file to export.'))

parser.add_argument('--output-format', choices=['refer', 'download'], default='refer',
                    help=('How whl_library rules should obtain the wheel.'))

parser.add_argument('--directory', action='store',
                    help=('The directory into which to put .whl files.'))

parser.add_argument('args', nargs=argparse.REMAINDER,
                    help=('Extra arguments to send to pip.'))

# piptool unpack
parser = subparsers.add_parser('unpack', help='Unpack a WHL file as a py_library')
parser.set_defaults(func=unpack)

parser.add_argument('--whl', action='store',
                    help=('The .whl file we are expanding.'))

parser.add_argument('--requirements', action='store',
                    help='The pip_import from which to draw dependencies.')

parser.add_argument('--add-dependency', action='append',
                    help='Specify additional dependencies beyond the ones specified in the wheel.')

parser.add_argument('--directory', action='store', default='.',
                    help='The directory into which to expand things.')

parser.add_argument('--extras', action='append',
                    help='The set of extras for which to generate library targets.')

parser.add_argument('--dirty', action='store_true',
                    help='TODO')

def main():
  args = global_parser.parse_args()
  args.func(args)

if __name__ == '__main__':
  main()
