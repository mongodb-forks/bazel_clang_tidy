load("@bazel_tools//tools/build_defs/cc:action_names.bzl", "ACTION_NAMES")
load("@bazel_tools//tools/cpp:toolchain_utils.bzl", "find_cpp_toolchain")

ExcludesInfo = provider(
    fields = {"string": "comma separated path of excluded extensions"},
)

clang_tidy_excludes_rule = rule(
    implementation = lambda ctx: ExcludesInfo(string = ctx.build_setting_value),
    build_setting = config.string(flag = True),
)

def _run_tidy(
        ctx,
        wrapper,
        exe,
        additional_deps,
        plugin_deps,
        config,
        flags,
        compilation_context,
        infile,
        discriminator):
    inputs = depset(
        direct = (
            [infile, config] +
            additional_deps.files.to_list() +
            plugin_deps.files.to_list() +
            ([exe.files_to_run.executable] if exe.files_to_run.executable else [])
        ),
        transitive = [compilation_context.headers],
    )

    args = ctx.actions.args()

    # specify the output file - twice
    outfile = ctx.actions.declare_file(
        "bazel_clang_tidy_" + infile.path + "." + discriminator + ".clang-tidy.yaml",
    )
    status = ctx.actions.declare_file(
        "bazel_clang_tidy_" + infile.path + "." + discriminator + ".clang-tidy.status",
    )
    status_done = ctx.actions.declare_file(
        "bazel_clang_tidy_" + infile.path + "." + discriminator + ".clang-tidy.status_done",
    )
    logfile = ctx.actions.declare_file(
        "bazel_clang_tidy_" + infile.path + "." + discriminator + ".clang-tidy.log",
    )

    # this is consumed by the wrapper script
    if len(exe.files.to_list()) == 0:
        args.add("clang-tidy")
    else:
        args.add(exe.files_to_run.executable)

    args.add(outfile.path)  # this is consumed by the wrapper script

    args.add(config.path)

    args.add(status.path)   

    args.add(logfile.path)

    args.add("--export-fixes", outfile.path)

    # Note: We assume that plugin_deps, if given, has only one file in it
    if len(plugin_deps.files.to_list()) > 0:
        args.add("--load=" + plugin_deps.files.to_list()[0].path)

    # add source to check
    args.add(infile.path)

    # start args passed to the compiler
    args.add("--")

    # add includes
    for i in compilation_context.framework_includes.to_list():
        args.add("-F" + i)

    for i in compilation_context.includes.to_list():
        args.add("-I" + i)

    args.add_all(compilation_context.quote_includes.to_list(), before_each = "-iquote")

    args.add_all(compilation_context.system_includes.to_list(), before_each = "-isystem")

    # add args specified by the toolchain, on the command line and rule copts
    args.add_all(flags)

    # add defines
    for define in compilation_context.defines.to_list():
        args.add("-D" + define)

    for define in compilation_context.local_defines.to_list():
        args.add("-D" + define)

    outputs = [outfile, status, logfile]
    ctx.actions.run(
        inputs = inputs,
        outputs = [outfile, status, logfile],
        executable = wrapper,
        arguments = [args],
        mnemonic = "ClangTidy",
        use_default_shell_env = True,
        progress_message = "Run clang-tidy on {}".format(infile.short_path),
    )
    ctx.actions.run(
        inputs = [status, logfile],
        outputs = [status_done],
        executable = ctx.attr._clang_tidy_status.files_to_run,
        arguments = [status.path, logfile.path, status_done.path],
        mnemonic = "ClangTidyStatus",
        use_default_shell_env = True,
        progress_message = "Check clang-tidy results for {}".format(infile.short_path),
    )
    return outputs + [status_done]

def _rule_sources(ctx):
    def check_valid_file_type(src):
        """
        Returns True if the file type matches one of the permitted srcs file types for C and C++ header/source files.
        """
        permitted_file_types = [
            ".c", ".cc", ".cpp", ".cxx", ".c++", ".C",
            # We only analyze cc files (headers are effectively analyzed by being #include-d)
            # ".h", ".hh", ".hpp", ".hxx", ".inc", ".inl", ".H",
        ]
        for file_type in permitted_file_types:
            if src.basename.endswith(file_type):
                for ending in ctx.attr._clang_tidy_excludes[ExcludesInfo].string.split(","):
                    if src.basename.endswith(ending):
                        return False
                return True
        return False

    srcs = []
    if hasattr(ctx.rule.attr, "srcs"):
        for src_depset in ctx.rule.attr.srcs:
            for src_file in src_depset.files.to_list():
                if check_valid_file_type(src_file): 
                    srcs.append(src_file)

    # Filter sources down to only those that are Mongo-specific.
    # Although we also apply a filter mechanism in the clang-tidy config itself, this filter mechanism
    # ensures we don't run clang-tidy at *all* on #include-d headers. Without this filter, Bazel
    # runs clang-tidy individual on each 3P header, which massively increases execution time.
    # For a long-term fix, see https://github.com/erenon/bazel_clang_tidy/issues/64
    return [src for src in srcs if 'src/mongo/' in src.path]

def _toolchain_flags(ctx, action_name = ACTION_NAMES.cpp_compile):
    cc_toolchain = find_cpp_toolchain(ctx)
    feature_configuration = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
    )
    compile_variables = cc_common.create_compile_variables(
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        user_compile_flags = ctx.fragments.cpp.cxxopts + ctx.fragments.cpp.copts,
    )
    flags = cc_common.get_memory_inefficient_command_line(
        feature_configuration = feature_configuration,
        action_name = action_name,
        variables = compile_variables,
    )
    return flags

def _safe_flags(flags):
    # Some flags might be used by GCC, but not understood by Clang.
    # Remove them here, to allow users to run clang-tidy, without having
    # a clang toolchain configured (that would produce a good command line with --compiler clang)
    unsupported_flags = [
        "-fno-canonical-system-headers",
        "-fstack-usage",
    ]

    return [flag for flag in flags if flag not in unsupported_flags]

def _expand_flags(ctx, flags):
    return [ctx.expand_make_variables("clang_tidy_expand_flags", flag, ctx.var) for flag in flags]

def _clang_tidy_aspect_impl(target, ctx):
    # if not a C/C++ target, we are not interested
    if not CcInfo in target:
        return []

    # Ignore external targets
    if target.label.workspace_root.startswith("external"):
        return []

    # Targets with specific tags will not be formatted
    ignore_tags = [
        "noclangtidy",
        "no-clang-tidy",
    ]

    for tag in ignore_tags:
        if tag in ctx.rule.attr.tags:
            return []

    wrapper = ctx.attr._clang_tidy_wrapper.files_to_run
    exe = ctx.attr._clang_tidy_executable
    additional_deps = ctx.attr._clang_tidy_additional_deps
    plugin_deps = ctx.attr._clang_tidy_plugin_deps
    config = ctx.attr._clang_tidy_config.files.to_list()[0]
    compilation_context = target[CcInfo].compilation_context

    rule_flags = ctx.rule.attr.copts if hasattr(ctx.rule.attr, "copts") else []
    c_flags = _expand_flags(ctx, _safe_flags(_toolchain_flags(ctx, ACTION_NAMES.c_compile) + rule_flags) + ["-xc"])
    cxx_flags = _expand_flags(ctx, _safe_flags(_toolchain_flags(ctx, ACTION_NAMES.cpp_compile) + rule_flags) + ["-xc++"])

    srcs = _rule_sources(ctx)

    outputs = []
    for src in srcs:
        outputs.extend(_run_tidy(
            ctx,
            wrapper,
            exe,
            additional_deps,
            plugin_deps,
            config,
            c_flags if src.extension == "c" else cxx_flags,
            compilation_context,
            src,
            target.label.name,
        ))

    return [
        OutputGroupInfo(report = depset(direct = outputs)),
    ]

clang_tidy_aspect = aspect(
    implementation = _clang_tidy_aspect_impl,
    fragments = ["cpp"],
    attrs = {
        "_cc_toolchain": attr.label(default = Label("@bazel_tools//tools/cpp:current_cc_toolchain")),
        "_clang_tidy_wrapper": attr.label(default = Label("//clang_tidy:clang_tidy")),
        "_clang_tidy_status": attr.label(default = Label("//clang_tidy:status")),
        "_clang_tidy_executable": attr.label(default = Label("//:clang_tidy_executable")),
        "_clang_tidy_additional_deps": attr.label(default = Label("//:clang_tidy_additional_deps")),
        "_clang_tidy_plugin_deps": attr.label(default = Label("//:clang_tidy_plugin_deps")),
        "_clang_tidy_config": attr.label(default = Label("//:clang_tidy_config")),
        "_clang_tidy_excludes": attr.label(default = Label("//:clang_tidy_excludes")),
    },
    toolchains = ["@bazel_tools//tools/cpp:toolchain_type"],
)
