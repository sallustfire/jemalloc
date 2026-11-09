"Transition build and platform settings"

load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")

PLATFORM = select({
    "@platforms//os:android": "android",
    "@platforms//os:freebsd": "freebsd",
    "@platforms//os:linux": "linux",
    "@platforms//os:windows": "windows",
    "//settings/platform:darwin": "darwin",
    "//conditions:default": "unknown",
})

# The CPU class the platform defaults can read, alongside the platform: aarch64, x86_64 or any other.
CPU = select({
    "@platforms//cpu:aarch64": "aarch64",
    "@platforms//cpu:x86_64": "x86_64",
    "//conditions:default": "other",
})

# Assume typical defaults for target platforms. A "<platform>-<cpu>" key takes precedence over a "<platform>" key, and
# that over a "*-<cpu>" key.
_PLATFORM_DEFAULTS = {
    "//settings/flags:enable_zone_allocator": {"darwin": "yes", "default": "no"},
    # configure.ac's --with-jemalloc-prefix default: "je_" for the macho and pecoff ABIs, "" otherwise.
    "//settings/flags:jemalloc_prefix": {"darwin": "je_", "windows": "je_", "default": ""},
    "//settings/platform:glibc_overrides_support": {"linux": "yes", "default": "no"},
    "//settings/platform:lg_page": {"darwin": "14", "default": "12"},
    "//settings/platform:memalign_support": {"linux": "yes", "default": "no"},
    "//settings/platform:malloc_size_support": {"darwin": "yes", "default": "no"},
    "//settings/platform:valloc_support": {"darwin": "yes", "linux": "yes", "default": "no"},
}

_BOOL_SETTINGS = ["//settings:enable_jet", "//settings/flags:enable_experimental_smallocx", "//settings/flags:enable_fill"]

_SETTINGS = _BOOL_SETTINGS + ["//settings:with_test"] + list(_PLATFORM_DEFAULTS)

_SETTING_LABELS = [Label(setting) for setting in _SETTINGS]

_PREFIX_RESOLVED = "//settings/flags:jemalloc_prefix_resolved"

_CPREFIX = "//settings/flags:jemalloc_cprefix"

def _platform_constraints_transition_impl(settings, attr):
    # Only _SETTINGS are taken from settings. Any other key is either not an output of this transition or, like
    # jemalloc_prefix_resolved and jemalloc_cprefix, derived from jemalloc_prefix below, so its value would be dropped
    # without a word.
    for label in attr.settings:
        if label not in _SETTING_LABELS:
            fail("transition_default_constraints cannot take {} from settings; it takes only {}".format(label, ", ".join(_SETTINGS)))

    result = {}
    for setting in _SETTINGS:
        if Label(setting) in attr.settings:
            value = attr.settings[Label(setting)]
            if setting in _BOOL_SETTINGS:
                value = value == "True"
        else:
            value = settings[setting]
        if value == "__auto__" and setting in _PLATFORM_DEFAULTS:
            defaults = _PLATFORM_DEFAULTS[setting]
            value = defaults.get(
                "{}-{}".format(attr.platform, attr.cpu),
                defaults.get(attr.platform, defaults.get("*-" + attr.cpu, defaults["default"])),
            )
        result[setting] = value

    # configure.ac: AC_MSG_ERROR([--enable-zone-allocator is only supported on Darwin]). Without it, zone.c stops at
    # its own #error once compiled.
    if result["//settings/flags:enable_zone_allocator"] == "yes" and attr.platform != "darwin":
        fail("//settings/flags:enable_zone_allocator=yes is only supported on Darwin, as configure's " +
             "--enable-zone-allocator; the target platform is {}".format(attr.platform))

    result[_PREFIX_RESOLVED] = result["//settings/flags:jemalloc_prefix"]

    # Equivalent of JEMALLOC_CPREFIX=`echo ${JEMALLOC_PREFIX} | tr "a-z" "A-Z"`
    result[_CPREFIX] = result[_PREFIX_RESOLVED].upper()

    return result

platform_constraints_transition = transition(
    implementation = _platform_constraints_transition_impl,
    inputs = _SETTINGS + [_CPREFIX],
    outputs = _SETTINGS + [_PREFIX_RESOLVED, _CPREFIX],
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
        "src": attr.label(cfg = platform_constraints_transition),
        "cpu": attr.string(
            doc = "The CPU class the transition reads, alongside platform, to apply unset defaults",
            mandatory = True,
            values = [
                "aarch64",
                "other",
                "x86_64",
            ],
        ),
        "platform": attr.string(
            doc = "Hack to inject platform constraints into the transition to apply unset defaults",
            mandatory = True,
            values = [
                "android",
                "freebsd",
                "linux",
                "darwin",
                "windows",
                "unknown",
            ],
        ),
        "settings": attr.label_keyed_string_dict(
            doc = "Settings to transition to, over both their configured values and the platform defaults. Only the " +
                  "settings it resolves are accepted; jemalloc_prefix_resolved and jemalloc_cprefix are derived from " +
                  "jemalloc_prefix.",
            default = {},
        ),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
)
