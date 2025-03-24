load("//clang_tidy:clang_tidy.bzl", "clang_tidy_excludes_rule")

filegroup(
    name = "clang_tidy_config_default",
    srcs = [
        ".clang-tidy",
        # '//example:clang_tidy_config', # add package specific configs if needed
    ],
)

label_flag(
    name = "clang_tidy_config",
    build_setting_default = ":clang_tidy_config_default",
    visibility = ["//visibility:public"],
)

filegroup(
    name = "clang_tidy_executable_default",
    srcs = [],  # empty list: system clang-tidy
)

label_flag(
    name = "clang_tidy_executable",
    build_setting_default = ":clang_tidy_executable_default",
    visibility = ["//visibility:public"],
)

filegroup(
    name = "clang_tidy_additional_deps_default",
    srcs = [],
)

label_flag(
    name = "clang_tidy_additional_deps",
    build_setting_default = ":clang_tidy_additional_deps_default",
    visibility = ["//visibility:public"],
)

label_flag(
    name = "clang_tidy_plugin_deps",
    build_setting_default = ":clang_tidy_additional_deps_default",
    visibility = ["//visibility:public"],
)

clang_tidy_excludes_rule(
    name="clang_tidy_excludes_rule",
    build_setting_default = "",
)
