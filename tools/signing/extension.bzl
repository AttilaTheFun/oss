"""The builder's own signing values, from the environment, not the repo.

`@oss_signing//:signing.bzl` defines TEAM_ID: the Apple team to sign
OS Monitor's iPhone builds with, from OSS_TEAM_ID, or a placeholder. Set it
in a `.bazelrc.user` at the repository's root (it is not checked in):

    common --repo_env=OSS_TEAM_ID=<your team id>

Simulator and Mac builds need nothing; an iPhone build needs the team's
Xcode-managed wildcard profile ("iOS Team Provisioning Profile: *").
"""

def _signing_impl(rctx):
    team = rctx.getenv("OSS_TEAM_ID", "YOUR_TEAM_ID") or "YOUR_TEAM_ID"
    rctx.file("BUILD.bazel", 'exports_files(["signing.bzl"])\n')
    rctx.file("signing.bzl", 'TEAM_ID = "%s"\n' % team)

_signing = repository_rule(implementation = _signing_impl)

def _extension_impl(_mctx):
    _signing(name = "oss_signing")

signing = module_extension(implementation = _extension_impl)
