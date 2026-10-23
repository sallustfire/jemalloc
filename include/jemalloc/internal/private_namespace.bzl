load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("@rules_cc//cc:find_cc_toolchain.bzl", "find_cc_toolchain", "use_cc_toolchain")

_CAT_TOOLCHAIN = "@rules_coreutils//coreutils/toolchain/cat:type"
_ECHO_TOOLCHAIN = "@rules_coreutils//coreutils/toolchain/echo:type"
_TR_TOOLCHAIN = "@rules_coreutils//coreutils/toolchain/tr:type"

def _private_namespace_impl(ctx):
    cc_toolchain = find_cc_toolchain(ctx)
    cat = ctx.toolchains[_CAT_TOOLCHAIN]
    echo = ctx.toolchains[_ECHO_TOOLCHAIN]
    tr = ctx.toolchains[_TR_TOOLCHAIN]
    coreutils_env = {"CAT": cat.executable.path, "ECHO": echo.executable.path, "TR": tr.executable.path}
    coreutils_tools = [cat.run, echo.run, tr.run]
    output = ctx.actions.declare_file(ctx.attr.out)

    # Extract private symbols
    args = ctx.actions.args()

    prefix = ctx.attr.prefix if ctx.attr.prefix else ctx.attr._prefix[BuildSettingInfo].value
    for sym in ctx.attr.public_symbols:
        args.add(prefix + sym)

    # Wrap symbols without prefix
    args.add_all(ctx.attr.wrap_symbols)

    # Write out awk script
    constraint = ctx.attr._constraint_macos[platform_common.ConstraintValueInfo]
    sym_prefix = "_" if ctx.target_platform_has_constraint(constraint) else ""
    output_awk = ctx.actions.declare_file("{name}.awk".format(name = ctx.attr.name))
    ctx.actions.run_shell(
        inputs = [],
        outputs = [output_awk],
        arguments = [args],
        command = "{script} \"{sym_prefix}\" $@ > {output}".format(
            script = ctx.file._private_symbols_sh.path,
            output = output_awk.path,
            sym_prefix = sym_prefix,
        ),
        env = coreutils_env,
        mnemonic = "PrivateSymbols",
        tools = [ctx.file._private_symbols_sh] + coreutils_tools,
    )

    inputs = [src for src in ctx.files.input if src.path.endswith(".a")]
    output_symbols = ctx.actions.declare_file("symbols{jet}.sym".format(jet = "_jet" if ctx.attr.enable_jet else ""))

    ctx.actions.run_shell(
        inputs = depset(inputs, transitive = [cc_toolchain.all_files]),
        outputs = [output_symbols],
        command = "{nm} -a {inputs} | {awk} -f {script} > {output}".format(
            nm = ctx.file._llvm_nm.path,
            inputs = " ".join([input.path for input in inputs]),
            awk = ctx.executable._gawk.path,
            script = output_awk.path,
            output = output_symbols.path,
        ),
        tools = [output_awk, ctx.file._llvm_nm, ctx.executable._gawk],
        mnemonic = "PrivateNamespaceNM",
    )

    ctx.actions.run_shell(
        inputs = [output_symbols],
        outputs = [output],
        command = "{script} {symbols} > {output}".format(
            script = ctx.file._private_namespace_sh.path,
            symbols = output_symbols.path,
            output = output.path,
        ),
        env = coreutils_env,
        mnemonic = "PrivateNamespace",
        tools = [ctx.file._private_namespace_sh] + coreutils_tools,
    )

    return [DefaultInfo(files = depset([output]))]

def _transition_impl(_settings, attr):
    return {
        # Only C sources are used for symbol extraction
        "//settings/flags:enable_cxx": False,
        "//settings:enable_no_private_namespace": True,
        "//settings:enable_jet": attr.enable_jet,
    }

transition_config_settings = transition(
    implementation = _transition_impl,
    inputs = [],
    outputs = ["//settings/flags:enable_cxx", "//settings:enable_no_private_namespace", "//settings:enable_jet"],
)

private_namespace = rule(
    doc = "Generate the private namespace header from compiled object files. This combines the private_symbols.awk " +
          "generation with the header generation to bridge the requriements between the exec and target platforms.",
    implementation = _private_namespace_impl,
    attrs = {
        "prefix": attr.string(doc = "Explicit prefix for public symbols, overrides value selected by build setting."),
        "public_symbols": attr.string_list(
            doc = "List of public API symbols",
            mandatory = True,
        ),
        "input": attr.label(
            doc = "Compiled object achive from which to extract the symbols. A transition is forced to compile with JEMALLOC_NO_PRIVATE_NAMESPACE",
            cfg = transition_config_settings,
        ),
        "enable_jet": attr.bool(default = False),
        "out": attr.string(
            doc = "Name of the generated file",
            mandatory = True,
        ),
        "wrap_symbols": attr.string_list(
            doc = "List of symbols to wrap without prefix",
            default = [],
        ),
        "_prefix": attr.label(default = "//settings/flags:jemalloc_prefix"),
        "_cc_toolchain": attr.label(default = Label("@rules_cc//cc:current_cc_toolchain")),
        "_llvm_nm": attr.label(default = "@llvm//tools:llvm-nm", allow_single_file = True, cfg = "exec"),
        "_gawk": attr.label(default = "@gawk//:gawk", executable = True, cfg = "exec"),
        "_constraint_macos": attr.label(default = "@platforms//os:macos", cfg = "target"),
        "_private_namespace_sh": attr.label(
            default = "//include/jemalloc/internal:private_namespace.sh",
            allow_single_file = True,
            cfg = "exec",
        ),
        "_private_symbols_sh": attr.label(
            default = "//include/jemalloc/internal:private_symbols.sh",
            allow_single_file = True,
            cfg = "exec",
        ),
    },
    toolchains = use_cc_toolchain(True) + [_CAT_TOOLCHAIN, _ECHO_TOOLCHAIN, _TR_TOOLCHAIN],
)
