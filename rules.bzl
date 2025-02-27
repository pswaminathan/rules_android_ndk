# Copyright 2022 The Bazel Authors. All rights reserved.
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

"""A repository rule for integrating the Android NDK."""

load("versions.bzl", "versions")

def _android_ndk_repository_impl(ctx):
    """Install the Android NDK files.

    Args:
        ctx: An implementation context.

    Returns:
        A final dict of configuration attributes and values.
    """
    download_ndk = ctx.attr.download_ndk_version != None
    ndk_path = ""
    if not download_ndk:
        ndk_path = ctx.attr.path or ctx.getenv("ANDROID_NDK_HOME", None)
        if not ndk_path:
            fail("Either download_ndk_version must be set or a local NDK must " +
                 "be specified by path attribute or ANDROID_NDK_HOME environment")

    os_name = ctx.os.name
    if os_name.startswith("windows"):
        os_name = "windows"

    if download_ndk:
        print("\n\033[1;33mWARNING:\033[0m by setting download_ndk_version, you are agreeing " +
              "to the NDK terms and conditions. You can view these at " +
              "https://developer.android.com/studio/terms")
        version = ctx.attr.download_ndk_version
        cfg = versions[version][os_name]
        ctx.download_and_extract(
            url = cfg["url"],
            integrity = cfg["integrity"],
            stripPrefix = cfg["prefix"],  # n.b. renamed to strip_prefix in 8.x, but this remains for compatibility
        )

    if ndk_path.startswith("$WORKSPACE_ROOT"):
        ndk_path = str(ctx.workspace_root) + ndk_path.removeprefix("$WORKSPACE_ROOT")

    is_windows = False
    executable_extension = ""
    if os_name == "linux":
        clang_directory = "toolchains/llvm/prebuilt/linux-x86_64"
    elif os_name == "mac os x":
        # Note: darwin-x86_64 does indeed contain fat binaries with arm64 slices, too.
        clang_directory = "toolchains/llvm/prebuilt/darwin-x86_64"
    elif os_name == "windows":
        clang_directory = "toolchains/llvm/prebuilt/windows-x86_64"
        is_windows = True
        executable_extension = ".exe"
    else:
        fail("Unsupported operating system: " + ctx.os.name)

    sysroot_directory = "%s/sysroot" % clang_directory

    if not download_ndk:
        _create_symlinks(ctx, ndk_path, clang_directory, sysroot_directory)

    api_level = ctx.attr.api_level or 31

    result = ctx.execute([clang_directory + "/bin/clang", "--print-resource-dir"])
    if result.return_code != 0:
        fail("Failed to execute clang: %s" % result.stderr)
    stdout = result.stdout.strip()
    if is_windows:
        stdout = stdout.replace("\\", "/")
    clang_resource_directory = stdout.split(clang_directory)[1].strip("/")

    # Use a label relative to the workspace from which this repository rule came
    # to get the workspace name.
    repository_name = ctx.attr._build.workspace_name

    ctx.template(
        "BUILD.bazel",
        ctx.attr._template_ndk_root,
        {
            "{clang_directory}": clang_directory,
        },
        executable = False,
    )

    ctx.template(
        "target_systems.bzl",
        ctx.attr._template_target_systems,
        {
        },
        executable = False,
    )

    ctx.template(
        "%s/BUILD.bazel" % clang_directory,
        ctx.attr._template_ndk_clang,
        {
            "{repository_name}": repository_name,
            "{api_level}": str(api_level),
            "{clang_resource_directory}": clang_resource_directory,
            "{sysroot_directory}": sysroot_directory,
            "{executable_extension}": executable_extension,
        },
        executable = False,
    )

    ctx.template(
        "%s/BUILD.bazel" % sysroot_directory,
        ctx.attr._template_ndk_sysroot,
        {
            "{api_level}": str(api_level),
        },
        executable = False,
    )

# Manually create a partial symlink tree of the NDK to avoid creating BUILD
# files in the real NDK directory, when using a system-installed NDK.
def _create_symlinks(ctx, ndk_path, clang_directory, sysroot_directory):
    # Path needs to end in "/" for replace() below to work
    if not ndk_path.endswith("/"):
        ndk_path = ndk_path + "/"

    for p in ctx.path(ndk_path + clang_directory).readdir():
        repo_relative_path = str(p).replace(ndk_path, "")

        # Skip sysroot directory, since it gets its own BUILD file
        if repo_relative_path != sysroot_directory:
            ctx.symlink(p, repo_relative_path)

    for p in ctx.path(ndk_path + sysroot_directory).readdir():
        repo_relative_path = str(p).replace(ndk_path, "")
        ctx.symlink(p, repo_relative_path)

    ctx.symlink(ndk_path + "sources", "sources")

    # TODO(#32): Remove this hack
    ctx.symlink(ndk_path + "sources", "ndk/sources")

android_ndk_repository = repository_rule(
    attrs = {
        "path": attr.string(),
        "api_level": attr.int(),
        "download_ndk_version": attr.string(),
        "_build": attr.label(default = ":BUILD", allow_single_file = True),
        "_template_ndk_root": attr.label(default = ":BUILD.ndk_root.tpl", allow_single_file = True),
        "_template_target_systems": attr.label(default = ":target_systems.bzl.tpl", allow_single_file = True),
        "_template_ndk_clang": attr.label(default = ":BUILD.ndk_clang.tpl", allow_single_file = True),
        "_template_ndk_sysroot": attr.label(default = ":BUILD.ndk_sysroot.tpl", allow_single_file = True),
    },
    local = True,
    implementation = _android_ndk_repository_impl,
)
