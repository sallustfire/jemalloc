"Version string utilities."

# Upstream's VERSION file (`git describe --long --abbrev=40`), which configure reads. A constant because Starlark cannot
# read a source file while BUILD files load.
UPSTREAM_VERSION = "5.3.0-0-g54eaed1d8b56b1aa528be3bdd1877e59c56fa90c"

def parse_version(version):
    """Parses upstream's VERSION string into configure's version components.

    Args:
        version: upstream's VERSION string, `<major>.<minor>.<bugfix>-<nrev>-g<gid>`.

    Returns:
        struct: full (the VERSION string), major, minor, bugfix, nrev and gid.
    """
    release, nrev, gid = version.split("-", 2)
    major, minor, bugfix = release.split(".")

    return struct(
        full = version,
        major = major,
        minor = minor,
        bugfix = bugfix,
        nrev = nrev,
        gid = gid.removeprefix("g"),
    )
