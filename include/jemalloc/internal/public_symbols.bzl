"Reproduce the public_symbols.txt generation from configure.ac and the headers generated from it"

load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")

PublicSymbolsInfo = provider(
    doc = "The contents of public_symbols.txt.",
    fields = ["txt"],
)

def _public_symbols_impl(ctx):
    output = ctx.actions.declare_file(ctx.attr.out)
    prefix = ctx.attr._prefix[BuildSettingInfo].value

    # configure.ac splits entries with `echo ${mangling_map} |tr ',' ' '` and writes each as $1:$2 of
    # `echo ${nm} |tr ':' ' ' |awk`, so whitespace also separates entries, empty fields are skipped, and an entry whose
    # name is not a public symbol is still written.
    content = ""
    symbols = list(ctx.attr.symbols)
    words = ctx.attr.mangling_map.replace(",", " ").replace("\t", " ").replace("\n", " ").split(" ")
    for word in [word for word in words if word]:
        fields = [field for field in word.split(":") if field] + ["", ""]
        content += "{}:{}\n".format(fields[0], fields[1])
        symbols = [symbol for symbol in symbols if symbol != fields[0]]
    for symbol in symbols:
        content += "{}:{}{}\n".format(symbol, prefix, symbol)

    ctx.actions.write(
        output = output,
        content = content,
    )

    return [DefaultInfo(files = depset([output])), PublicSymbolsInfo(txt = content)]

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
        "_prefix": attr.label(default = "//settings/flags:jemalloc_prefix_resolved"),
    },
)

_MANGLE_HEAD = """\
/*
 * By default application code must explicitly refer to mangled symbol names,
 * so that it is possible to use jemalloc in conjunction with another allocator
 * in the same application.  Define JEMALLOC_MANGLE in order to cause automatic
 * name mangling that matches the API prefixing that happened as a result of
 * --with-mangling and/or --with-jemalloc-prefix configuration settings.
 */
#ifdef JEMALLOC_MANGLE
#  ifndef JEMALLOC_NO_DEMANGLE
#    define JEMALLOC_NO_DEMANGLE
#  endif
"""

_MANGLE_MIDDLE = """\
#endif

/*
 * The {}* macros can be used as stable alternative names for the
 * public jemalloc API if JEMALLOC_NO_DEMANGLE is defined.  This is primarily
 * meant for use in jemalloc itself, but it can be used by application code to
 * provide isolation from the name mangling specified via --with-mangling
 * and/or --with-jemalloc-prefix.
 */
#ifndef JEMALLOC_NO_DEMANGLE
"""

_RENAME_HEAD = """\
/*
 * Name mangling for public symbols is controlled by --with-mangling and
 * --with-jemalloc-prefix.  With default settings the je_ prefix is stripped by
 * these macro definitions.
 */
#ifndef JEMALLOC_NO_RENAME
"""

def _mangle(symbols, prefix):
    return (
        _MANGLE_HEAD +
        "".join(["#  define {} {}{}\n".format(name, prefix, name) for name, _ in symbols]) +
        _MANGLE_MIDDLE.format(prefix) +
        "".join(["#  undef {}{}\n".format(prefix, name) for name, _ in symbols]) +
        "#endif\n"
    )

def _rename(symbols, _symbol_prefix):
    return _RENAME_HEAD + "".join(["#  define je_{} {}\n".format(name, mangled) for name, mangled in symbols]) + "#endif\n"

def _namespace(symbols, _symbol_prefix):
    return "".join(["#define je_{} JEMALLOC_N({})\n".format(name, name) for name, _ in symbols])

def _unnamespace(symbols, _symbol_prefix):
    return "".join(["#undef je_{}\n".format(name) for name, _ in symbols])

_SCRIPTS = {
    "jemalloc_mangle.sh": _mangle,
    "jemalloc_rename.sh": _rename,
    "public_namespace.sh": _namespace,
    "public_unnamespace.sh": _unnamespace,
}

def _name_and_mangled(word):
    # $1 and $2 of `echo ${nm} |tr ':' ' ' |awk ...`
    fields = [field for field in word.split(":") if field] + ["", ""]
    return fields[0], fields[1]

def _public_symbols_header_impl(ctx):
    # for nm in `cat public_symbols.txt`
    words = ctx.attr.public_symbols[PublicSymbolsInfo].txt.replace("\t", " ").replace("\n", " ").split(" ")
    output = ctx.actions.declare_file(ctx.attr.out)
    ctx.actions.write(
        output = output,
        content = _SCRIPTS[ctx.attr.script]([_name_and_mangled(word) for word in words if word], ctx.attr.symbol_prefix),
    )
    return [DefaultInfo(files = depset([output]))]

public_symbols_header = rule(
    doc = "Writes what the upstream `script` prints when given `public_symbols`.",
    implementation = _public_symbols_header_impl,
    attrs = {
        "out": attr.string(mandatory = True),
        "public_symbols": attr.label(mandatory = True, providers = [PublicSymbolsInfo]),
        "script": attr.string(mandatory = True, values = _SCRIPTS.keys()),
        "symbol_prefix": attr.string(doc = "The second argument of jemalloc_mangle.sh."),
    },
)
