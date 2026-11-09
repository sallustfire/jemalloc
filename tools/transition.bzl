"Transition build and platform settings"

load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")

PLATFORM = select({
    "@platforms//os:freebsd": "freebsd",
    "@platforms//os:linux": "linux",
    "@platforms//os:windows": "windows",
    "//settings/platform:darwin": "darwin",
    "//conditions:default": "unknown",
})

# Assume typical defaults for target platforms
_PLATFORM_DEFAULTS = {
    "//settings/flags:enable_zone_allocator": {"darwin": "yes", "default": "no"},
    "//settings/platform:glibc_overrides_support": {"linux": "yes", "default": "no"},
    "//settings/platform:lg_page": {"darwin": "14", "default": "12"},
    "//settings/platform:memalign_support": {"linux": "yes", "default": "no"},
    "//settings/platform:malloc_size_support": {"darwin": "yes", "default": "no"},
    "//settings/platform:usable_size_const": {"linux": "", "default": "const"},
    "//settings/platform:valloc_support": {"darwin": "yes", "linux": "yes", "default": "no"},
}

_BOOL_SETTINGS = ["//settings:enable_jet", "//settings/flags:enable_experimental_smallocx", "//settings/flags:enable_fill"]

_SETTINGS = _BOOL_SETTINGS + ["//settings:with_test", "//settings/flags:jemalloc_prefix"] + list(_PLATFORM_DEFAULTS)

_CPREFIX = "//settings/flags:jemalloc_cprefix"

def _platform_constraints_transition_impl(settings, attr):
    result = {}
    for setting in _SETTINGS:
        if Label(setting) in attr.settings:
            value = attr.settings[Label(setting)]
            if setting in _BOOL_SETTINGS:
                value = value == "True"
        else:
            value = settings[setting]
        if value == "__auto__" and setting in _PLATFORM_DEFAULTS:
            value = _PLATFORM_DEFAULTS[setting].get(attr.platform, _PLATFORM_DEFAULTS[setting]["default"])
        result[setting] = value

    # Equivalent of JEMALLOC_CPREFIX=`echo ${JEMALLOC_PREFIX} | tr "a-z" "A-Z"`
    result[_CPREFIX] = result["//settings/flags:jemalloc_prefix"].upper()

    return result

_platform_constraints_transition = transition(
    implementation = _platform_constraints_transition_impl,
    inputs = _SETTINGS + [_CPREFIX],
    outputs = _SETTINGS + [_CPREFIX],
)

def _transition_default_constraints_impl(ctx):
    target = ctx.attr.src[0]
    providers = [DefaultInfo, CcInfo, InstrumentedFilesInfo, OutputGroupInfo]

    return [target[provider] for provider in providers if provider in target]

transition_default_constraints = rule(
    doc = "Configure detects target platform constraints. The target platform should declare these, but " +
          "intelligent defaults can be set for the majority of cases.",
    implementation = _transition_default_constraints_impl,
    attrs = {
        "src": attr.label(cfg = _platform_constraints_transition),
        "platform": attr.string(
            doc = "Hack to inject platform constraints into the transition to apply unset defaults",
            mandatory = True,
            values = [
                "freebsd",
                "linux",
                "darwin",
                "windows",
                "unknown",
            ],
        ),
        "settings": attr.label_keyed_string_dict(
            doc = "Settings to transition to, over both their configured values and the platform defaults",
            default = {},
        ),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
)
