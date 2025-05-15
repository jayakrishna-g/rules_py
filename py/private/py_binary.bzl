"""Implementation for the py_binary and py_test rules."""

load("@aspect_bazel_lib//lib:expand_make_vars.bzl", "expand_locations", "expand_variables")
load("@aspect_bazel_lib//lib:paths.bzl", "BASH_RLOCATION_FUNCTION", "to_rlocation_path")
load("@rules_python//python:defs.bzl", "PyInfo")
load("//py/private:py_library.bzl", _py_library = "py_library_utils")
load("//py/private:py_semantics.bzl", _py_semantics = "semantics")
load("//py/private/toolchain:types.bzl", "PY_TOOLCHAIN", "VENV_TOOLCHAIN")

def _dict_to_exports(env):
    return [
        "export %s=\"%s\"" % (k, v)
        for (k, v) in env.items()
    ]

def _py_binary_rule_impl(ctx):
    venv_toolchain = ctx.toolchains[VENV_TOOLCHAIN]
    py_toolchain = _py_semantics.resolve_toolchain(ctx)

    # Check for duplicate virtual dependency names. Those that map to the same resolution target would have been merged by the depset for us.
    virtual_resolution = _py_library.resolve_virtuals(ctx)

    # extra_libs are for runfiles and LD_LIBRARY_PATH, not for PYTHONPATH.
    # So, we don't add their PyInfo.imports to the .pth file here.
    imports_depset = _py_library.make_imports_depset(
        ctx,
        extra_imports_depsets = virtual_resolution.imports, # Only includes imports from deps and virtual_resolution
    )

    pth_lines = ctx.actions.args()
    pth_lines.use_param_file("%s", use_always = True)
    pth_lines.set_param_file_format("multiline")

    # The venv is created at the root in the runfiles tree, in 'VENV_NAME', the full path is "${RUNFILES_DIR}/${VENV_NAME}",
    # but depending on if we are running as the top level binary or a tool, then $RUNFILES_DIR may be absolute or relative.
    # Paths in the .pth are relative to the site-packages folder where they reside.
    # All "import" paths from `py_library` start with the workspace name, so we need to go back up the tree for
    # each segment from site-packages in the venv to the root of the runfiles tree.
    # Five .. will get us back to the root of the venv:
    # {name}.runfiles/.{name}.venv/lib/python{version}/site-packages/first_party.pth
    # If the target is defined with a slash, it adds to the level of nesting
    target_depth = len(ctx.label.name.split("/")) - 1
    escape = "/".join(([".."] * (4 + target_depth)))

    # A few imports rely on being able to reference the root of the runfiles tree as a Python module,
    # the common case here being the @rules_python//python/runfiles target that adds the runfiles helper,
    # which ends up in bazel_tools/tools/python/runfiles/runfiles.py, but there are no imports attrs that hint we
    # should be adding the root to the PYTHONPATH
    # Maybe in the future we can opt out of this?
    pth_lines.add(escape)

    pth_lines.add_all(imports_depset, format_each = "{}/%s".format(escape))

    site_packages_pth_file = ctx.actions.declare_file("{}.venv.pth".format(ctx.attr.name))
    ctx.actions.write(
        output = site_packages_pth_file,
        content = pth_lines,
    )

    default_env = {
        "BAZEL_TARGET": str(ctx.label).lstrip("@"),
        "BAZEL_WORKSPACE": ctx.workspace_name,
        "BAZEL_TARGET_NAME": ctx.attr.name,
    }

    passed_env = dict(ctx.attr.env)
    for k, v in passed_env.items():
        passed_env[k] = expand_variables(
            ctx,
            expand_locations(ctx, v, ctx.attr.data),
            attribute_name = "env",
        )

    # Get the custom script content directly from the attribute if provided
    custom_script_hook_content_from_attr = ""
    if hasattr(ctx.attr, "custom_run_script_hook_content") and ctx.attr.custom_run_script_hook_content:
        custom_script_hook_content_from_attr = ctx.attr.custom_run_script_hook_content

    # --- Auto LD_LIBRARY_PATH setup for extra_libs --- START ---
    auto_ld_library_path_setup_cmds = []
    if hasattr(ctx.attr, "extra_libs") and ctx.attr.extra_libs:
        auto_ld_library_path_setup_cmds.append("echo \"INFO: Processing extra_libs for LD_LIBRARY_PATH...\"")
        auto_ld_library_path_setup_cmds.append("TEMP_LD_PATHS_COLLECTED=()"); # Use a bash array

        for i, lib_target in enumerate(ctx.attr.extra_libs):
            # Use the short_path of the label as the argument to rlocation
            # This is generally what rlocation expects for targets.
            rloc_arg = lib_target.label.name # Using name to get a more unique identifier for var names
            if ctx.label.workspace_root: # Non-empty for external repos usually
                 # For targets in external repos, short_path is often more direct for rlocation
                 # For targets in the main repo, label.name might be like //pkg:name
                 # We rely on rlocation being smart enough; short_path is usually safest for files.
                 # However, rlocation might need workspace_name/path for files from external repos.
                 # Let's assume short_path of the File object is the most reliable.
                 # Since lib_target is a Target, not a File, we use its label. This is a common convention.
                 # The actual `rlocation` argument needs to map to what's in the MANIFEST.
                 # For a target @foo//bar:baz, rlocation often takes "foo/bar/baz" or similar.
                 # We will pass the direct label string to rlocation, e.g. "@repo//pkg:name"
                 # or "//pkg:name". The BASH_RLOCATION_FN sourced should handle this.
                pass # rloc_arg is already set to label.name

            # A unique variable name for the resolved path of each lib
            # Sanitize label name for shell variable
            sanitized_label_name = "EXTRA_LIB_" + str(lib_target.label).replace("/", "_").replace(":", "_").replace("@", "").replace("~", "_").replace("-", "_").upper()

            # Using .format() for idx and rloc_arg makes it clearer.
            # Each command is a separate string for clarity and correctness.
            auto_ld_library_path_setup_cmds.append(
                "CANDIDATE_PATH_{idx}=\"$(rlocation \\\"{rloc_arg}\\\")\"".format(
                    idx = sanitized_label_name,
                    rloc_arg = str(lib_target.label)
                )
            )
            auto_ld_library_path_setup_cmds.append("LIB_DIR_TO_ADD_{idx}=\"\";".format(idx = sanitized_label_name))
            auto_ld_library_path_setup_cmds.append("if [ -n \"${{CANDIDATE_PATH_{idx}:-}}\" ]; then".format(idx = sanitized_label_name))
            auto_ld_library_path_setup_cmds.append("  if [ -d \"${{CANDIDATE_PATH_{idx}}}\" ]; then".format(idx = sanitized_label_name))
            auto_ld_library_path_setup_cmds.append("    LIB_DIR_TO_ADD_{idx}=\"${{CANDIDATE_PATH_{idx}}}\";".format(idx = sanitized_label_name))
            auto_ld_library_path_setup_cmds.append("  elif [ -f \"${{CANDIDATE_PATH_{idx}}}\" ]; then".format(idx = sanitized_label_name))
            auto_ld_library_path_setup_cmds.append(
                "    LIB_DIR_TO_ADD_{idx}=\"$(dirname \\\"${{CANDIDATE_PATH_{idx}}}\\\")\"".format(idx = sanitized_label_name)
            )
            auto_ld_library_path_setup_cmds.append("  fi;".format(idx = sanitized_label_name))
            auto_ld_library_path_setup_cmds.append("fi;".format(idx = sanitized_label_name))
            auto_ld_library_path_setup_cmds.append("if [ -n \"${{LIB_DIR_TO_ADD_{idx}:-}}\" ]; then".format(idx = sanitized_label_name))
            auto_ld_library_path_setup_cmds.append("  SHOULD_ADD=true") # No .format here, direct shell command
            auto_ld_library_path_setup_cmds.append("  for existing_path in \"${TEMP_LD_PATHS_COLLECTED[@]}\"; do")
            auto_ld_library_path_setup_cmds.append(
                "    if [[ \"${{existing_path}}\" == \"${{LIB_DIR_TO_ADD_{idx}}}\" ]]; then".format(idx = sanitized_label_name)
            )
            auto_ld_library_path_setup_cmds.append("      SHOULD_ADD=false; break;")
            auto_ld_library_path_setup_cmds.append("    fi")
            auto_ld_library_path_setup_cmds.append("  done")
            auto_ld_library_path_setup_cmds.append("  if $SHOULD_ADD; then TEMP_LD_PATHS_COLLECTED+=(\"${{LIB_DIR_TO_ADD_{idx}}}\"); fi".format(idx = sanitized_label_name))
            auto_ld_library_path_setup_cmds.append("fi;")

        auto_ld_library_path_setup_cmds.extend([
            "FINAL_AUTO_LD_LIBRARY_PATH=\"\"",
            "for path_component in \"${TEMP_LD_PATHS_COLLECTED[@]}\"; do",
            "  if [ -z \"${FINAL_AUTO_LD_LIBRARY_PATH}\" ]; then",
            "    FINAL_AUTO_LD_LIBRARY_PATH=\"${path_component}\";",
            "  else",
            "    FINAL_AUTO_LD_LIBRARY_PATH=\"${path_component}:${FINAL_AUTO_LD_LIBRARY_PATH}\";", # Prepend to ensure priority
            "  fi;",
            "done;",
            "if [ -n \"${FINAL_AUTO_LD_LIBRARY_PATH}\" ]; then",
            "  if [ -n \"${LD_LIBRARY_PATH:-}\" ]; then", # Check if LD_LIBRARY_PATH is already set and not empty
            "    export LD_LIBRARY_PATH=\"${FINAL_AUTO_LD_LIBRARY_PATH}:${LD_LIBRARY_PATH}\";",
            "  else",
            "    export LD_LIBRARY_PATH=\"${FINAL_AUTO_LD_LIBRARY_PATH}\";",
            "  fi;",
            "  echo \"INFO: Automatically prepended to LD_LIBRARY_PATH from extra_libs: ${FINAL_AUTO_LD_LIBRARY_PATH}\"", # Log the components added
            "  echo \"INFO: Full LD_LIBRARY_PATH: ${LD_LIBRARY_PATH}\"",
            "fi;",
            "unset TEMP_LD_PATHS_COLLECTED FINAL_AUTO_LD_LIBRARY_PATH;", # Clean up temp variables
        ])
    # --- Auto LD_LIBRARY_PATH setup for extra_libs --- END ---

    executable_launcher = ctx.actions.declare_file(ctx.attr.name)
    ctx.actions.expand_template(
        template = ctx.file._run_tmpl,
        output = executable_launcher,
        substitutions = {
            "{{BASH_RLOCATION_FN}}": BASH_RLOCATION_FUNCTION,
            "{{INTERPRETER_FLAGS}}": " ".join(py_toolchain.flags + ctx.attr.interpreter_options),
            "{{VENV_TOOL}}": to_rlocation_path(ctx, venv_toolchain.bin),
            "{{ARG_COLLISION_STRATEGY}}": ctx.attr.package_collisions,
            "{{ARG_PYTHON}}": to_rlocation_path(ctx, py_toolchain.python) if py_toolchain.runfiles_interpreter else py_toolchain.python.path,
            "{{ARG_VENV_NAME}}": ".{}.venv".format(ctx.attr.name),
            "{{ARG_PTH_FILE}}": to_rlocation_path(ctx, site_packages_pth_file),
            "{{ENTRYPOINT}}": to_rlocation_path(ctx, ctx.file.main),
            "{{PYTHON_ENV}}": "\n".join(_dict_to_exports(default_env)).strip(),
            "{{AUTO_LD_LIBRARY_PATH_SETUP}}": "\n".join(auto_ld_library_path_setup_cmds).strip(),
            "{{CUSTOM_SCRIPT_HOOK_PRE_EXEC}}": custom_script_hook_content_from_attr,
            "{{EXEC_PYTHON_BIN}}": "python{}".format(
                py_toolchain.interpreter_version_info.major,
            ),
            "{{RUNFILES_INTERPRETER}}": str(py_toolchain.runfiles_interpreter).lower(),
        },
        is_executable = True,
    )

    srcs_depset = _py_library.make_srcs_depset(ctx)

    # No need to add the hook script to runfiles as its content is passed as a string attribute.
    # Based on user's last diff, extra_runfiles will just be site_packages_pth_file.
    # If runfiles_extra_runfiles_list was defined before, it's simplified now.
    current_extra_runfiles_list = [site_packages_pth_file]

    # Collect DefaultInfo.default_runfiles from extra_libs
    extra_runfiles_depsets_from_extra_libs = []
    if hasattr(ctx.attr, "extra_libs"):
        for lib in ctx.attr.extra_libs:
            if DefaultInfo in lib:
                extra_runfiles_depsets_from_extra_libs.append(lib[DefaultInfo].default_runfiles)

    runfiles = _py_library.make_merged_runfiles(
        ctx,
        extra_depsets = [
            py_toolchain.files,
            srcs_depset,
        ] + virtual_resolution.srcs + virtual_resolution.runfiles,
        extra_runfiles = current_extra_runfiles_list, # Should be [site_packages_pth_file]
        extra_runfiles_depsets = [
            ctx.attr._runfiles_lib[DefaultInfo].default_runfiles,
            venv_toolchain.default_info.default_runfiles,
        ] + extra_runfiles_depsets_from_extra_libs,
    )

    instrumented_files_info = _py_library.make_instrumented_files_info(
        ctx,
        extra_source_attributes = ["main"],
    )

    return [
        DefaultInfo(
            files = depset([
                executable_launcher,
                ctx.file.main,
                site_packages_pth_file,
            ]),
            executable = executable_launcher,
            runfiles = runfiles,
        ),
        PyInfo(
            imports = imports_depset,
            transitive_sources = srcs_depset,
            has_py2_only_sources = False,
            has_py3_only_sources = True,
            uses_shared_libraries = False,
        ),
        instrumented_files_info,
        RunEnvironmentInfo(
            environment = passed_env,
            inherited_environment = getattr(ctx.attr, "env_inherit", []),
        ),
    ]

_attrs = dict({
    "env": attr.string_dict(
        doc = "Environment variables to set when running the binary.",
        default = {},
    ),
    "main": attr.label(
        doc = "Script to execute with the Python interpreter.",
        allow_single_file = True,
        mandatory = True,
    ),
    "python_version": attr.string(
        doc = """Whether to build this target and its transitive deps for a specific python version.""",
    ),
    "package_collisions": attr.string(
        doc = """The action that should be taken when a symlink collision is encountered when creating the venv.
A collision can occur when multiple packages providing the same file are installed into the venv. The possible values are:

* "error": When conflicting symlinks are found, an error is reported and venv creation halts.
* "warning": When conflicting symlinks are found, an warning is reported, however venv creation continues.
* "ignore": When conflicting symlinks are found, no message is reported and venv creation continues.
        """,
        default = "error",
        values = ["error", "warning", "ignore"],
    ),
    "interpreter_options": attr.string_list(
        doc = "Additional options to pass to the Python interpreter in addition to -B and -I passed by rules_py",
        default = [],
    ),
    "_run_tmpl": attr.label(
        allow_single_file = True,
        default = "//py/private:run.tmpl.sh",
    ),
    "_runfiles_lib": attr.label(
        default = "@bazel_tools//tools/bash/runfiles",
    ),
    # NB: this is read by _resolve_toolchain in py_semantics.
    "_interpreter_version_flag": attr.label(
        default = "//py:interpreter_version",
    ),
    # Required for py_version attribute
    "_allowlist_function_transition": attr.label(
        default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
    ),
    # Changed from a file label to a string attribute
    "custom_run_script_hook_content": attr.string(
        doc = "Shell script content to be injected into the run script before execution.",
        default = "",
    ),
    # Renamed from _implicit_sibling_data_targets and repurposed
    "extra_libs": attr.label_list(
        doc = "Additional library targets whose runfiles and Python imports should be available to this target, without being direct dependencies.",
        allow_empty = True,
    ),
})

_attrs.update(**_py_library.attrs)

_test_attrs = dict({
    "env_inherit": attr.string_list(
        doc = "Specifies additional environment variables to inherit from the external environment when the test is executed by bazel test.",
        default = [],
    ),
    # Magic attribute to make coverage --combined_report flag work.
    # There's no docs about this.
    # See https://github.com/bazelbuild/bazel/blob/fde4b67009d377a3543a3dc8481147307bd37d36/tools/test/collect_coverage.sh#L186-L194
    # NB: rules_python ALSO includes this attribute on the py_binary rule, but we think that's a mistake.
    # see https://github.com/aspect-build/rules_py/pull/520#pullrequestreview-2579076197
    "_lcov_merger": attr.label(
        default = configuration_field(fragment = "coverage", name = "output_generator"),
        executable = True,
        cfg = "exec",
    ),
})

def _python_version_transition_impl(_, attr):
    if not attr.python_version:
        return {}
    return {"@rules_python//python/config_settings:python_version": str(attr.python_version)}

_python_version_transition = transition(
    implementation = _python_version_transition_impl,
    inputs = [],
    outputs = ["@rules_python//python/config_settings:python_version"],
)

py_base = struct(
    implementation = _py_binary_rule_impl,
    attrs = _attrs,
    test_attrs = _test_attrs,
    toolchains = [
        PY_TOOLCHAIN,
        VENV_TOOLCHAIN,
    ],
    cfg = _python_version_transition,
)

py_binary = rule(
    doc = "Run a Python program under Bazel. Most users should use the [py_binary macro](#py_binary) instead of loading this directly.",
    implementation = py_base.implementation,
    attrs = py_base.attrs,
    toolchains = py_base.toolchains,
    executable = True,
    cfg = py_base.cfg,
)

py_test = rule(
    doc = "Run a Python program under Bazel. Most users should use the [py_test macro](#py_test) instead of loading this directly.",
    implementation = py_base.implementation,
    attrs = py_base.attrs | py_base.test_attrs,
    toolchains = py_base.toolchains,
    test = True,
    cfg = py_base.cfg,
)
