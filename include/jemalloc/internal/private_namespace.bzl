"""Rules that generate private_namespace.h from the library's symbols."""

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("@rules_cc//cc:find_cc_toolchain.bzl", "find_cc_toolchain", "use_cc_toolchain")

def _private_namespace_impl(ctx):
    cc_toolchain = find_cc_toolchain(ctx)
    prefix = ctx.attr.prefix if ctx.attr.prefix else ctx.attr._prefix[BuildSettingInfo].value
    public = [prefix + symbol for symbol in ctx.attr.public_symbols]

    output = ctx.actions.declare_file(ctx.attr.out)
    nm_stderr = ctx.actions.declare_file(ctx.label.name + ".nm.stderr")
    sym_prefix = ctx.attr.sym_prefix
    listing_source = "`{}`".format(cc_toolchain.nm_executable)
    unfound_reason = "it read no symbol table (for example from LTO bitcode it cannot parse)"
    archives = [file for file in ctx.files.input if file.path.endswith(".a")]
    if not archives:
        fail("{} provides no static archive (.a) to list, got {}".format(ctx.attr.input[0].label, ctx.files.input))
    listing = ctx.actions.declare_file(ctx.label.name + ".nm")
    ctx.actions.run(
        executable = ctx.executable._generator,
        arguments = ["nm", cc_toolchain.nm_executable, listing.path, nm_stderr.path] + [archive.path for archive in archives],
        inputs = depset(archives, transitive = [cc_toolchain.all_files]),
        outputs = [listing, nm_stderr],
        mnemonic = "PrivateNamespaceNM",
    )

    args = ctx.actions.args()
    args.add_all(["header", output.path, listing, nm_stderr, sym_prefix, listing_source, unfound_reason])
    args.add_all(public, format_each = "--public=%s")
    args.add_all(ctx.attr.wrap_symbols, format_each = "--wrap=%s")
    ctx.actions.run(
        executable = ctx.executable._generator,
        arguments = [args],
        inputs = [listing, nm_stderr],
        outputs = [output],
        mnemonic = "PrivateNamespace",
    )

    export_syms = ctx.actions.declare_file(ctx.label.name + ".export_syms")
    ctx.actions.write(output = export_syms, content = "".join([symbol + "\n" for symbol in public + ctx.attr.wrap_symbols]))

    return [
        DefaultInfo(files = depset([output])),
        OutputGroupInfo(upstream_inputs = depset([listing, export_syms])),
    ]

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
    doc = "Generate the private namespace header from the `nm -a` listing of `input`, as upstream's private_symbols.awk " +
          "and private_namespace.sh do. Output group `upstream_inputs` holds that listing and configure's export_syms.",
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
        "sym_prefix": attr.string(
            doc = "configure's SYM_PREFIX: \"_\" for Mach-O targets.",
            mandatory = True,
            values = ["", "_"],
        ),
        "wrap_symbols": attr.string_list(
            doc = "List of symbols to wrap without prefix",
            default = [],
        ),
        "_prefix": attr.label(default = "//settings/flags:jemalloc_prefix_resolved"),
        "_cc_toolchain": attr.label(default = Label("@rules_cc//cc:current_cc_toolchain")),
        "_generator": attr.label(
            default = Label("//tools/generators:private_namespace_gen"),
            cfg = "exec",
            executable = True,
        ),
    },
    toolchains = use_cc_toolchain(True),
)
