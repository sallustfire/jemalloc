"Reproduce the public_symbols.txt generation from configure.ac"

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")

def _public_symbols_impl(ctx):
    output = ctx.actions.declare_file(ctx.attr.out)
    prefix = ctx.attr._prefix[BuildSettingInfo].value

    # configure.ac splits entries with `echo ${mangling_map} |tr ',' ' '` and writes each as $1:$2 of
    # `echo ${nm} |tr ':' ' ' |awk`, so whitespace also separates entries, empty fields are skipped, and an entry whose
    # name is not a public symbol is still written.
    content = ""
    symbols = list(ctx.attr.symbols)
    words = ctx.attr.mangling_map.replace(",", " ").replace("\t", " ").replace("\n", " ").split(" ")
    for word in [w for w in words if w]:
        fields = [f for f in word.split(":") if f] + ["", ""]
        content += "{}:{}\n".format(fields[0], fields[1])
        symbols = [sym for sym in symbols if sym != fields[0]]
    for sym in symbols:
        content += "{}:{}{}\n".format(sym, prefix, sym)

    ctx.actions.write(
        output = output,
        content = content,
    )

    return DefaultInfo(files = depset([output]))

public_symbols = rule(
    implementation = _public_symbols_impl,
    attrs = {
        "symbols": attr.string_list(
            doc = "List of all public symbols",
            allow_empty = False,
            mandatory = True,
        ),
        "mangling_map": attr.string(
            doc = "The equivalent of --with-mangling=<key_1>:<value_1>,<key_2>:<value_2>,...",
        ),
        "out": attr.string(
            doc = "Name of the generated file",
            mandatory = True,
        ),
        "_prefix": attr.label(default = "//settings/flags:jemalloc_prefix"),
    },
)
