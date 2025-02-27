"""# Public API for Jest rules
"""

load("@aspect_bazel_lib//lib:write_source_files.bzl", _write_source_files = "write_source_files")
load("@aspect_bazel_lib//lib:utils.bzl", "to_label")
load("@aspect_rules_js//js:defs.bzl", _js_run_binary = "js_run_binary")
load("@aspect_rules_js//js:libs.bzl", "js_binary_lib")
load("//jest/private:jest_test.bzl", "lib")

_jest_test = rule(
    attrs = lib.attrs,
    implementation = lib.implementation,
    test = True,
    toolchains = js_binary_lib.toolchains,
)

# binary rule used for snapshot updates
_jest_binary = rule(
    attrs = lib.attrs,
    implementation = lib.implementation,
    executable = True,
    toolchains = js_binary_lib.toolchains,
)

REFERENCE_SNAPSHOT_SUFFIX = "-out"
REFERENCE_SNAPSHOT_DIRECTORY = "out"

REFERENCE_BUILD_TARGET_SUFFIX = "_ref_snapshots"
UPDATE_SNAPSHOTS_TARGET_SUFFIX = "_update_snapshots"

def _jest_from_repository(jest_rule, jest_repository, **kwargs):
    jest_rule(
        enable_runfiles = select({
            "@aspect_rules_js//js/private:enable_runfiles": True,
            "//conditions:default": False,
        }),
        entry_point = "@{}//:jest_entrypoint".format(jest_repository),
        bazel_sequencer = "@{}//:bazel_sequencer".format(jest_repository),
        bazel_snapshot_reporter = "@{}//:bazel_snapshot_reporter".format(jest_repository),
        bazel_snapshot_resolver = "@{}//:bazel_snapshot_resolver".format(jest_repository),
        data = kwargs.pop("data", []) + [
            "@{}//:node_modules/@jest/test-sequencer".format(jest_repository),
            "@{}//:node_modules/jest-cli".format(jest_repository),
            "@{}//:node_modules/jest-junit".format(jest_repository),
            "@{}//:node_modules/jest-snapshot".format(jest_repository),
        ],
        jest_repository = jest_repository,
        testonly = True,
        **kwargs
    )

def jest_test(
        name,
        config = None,
        data = [],
        snapshots = None,
        run_in_band = True,
        colors = True,
        auto_configure_reporters = True,
        auto_configure_test_sequencer = True,
        snapshots_ext = ".snap",
        quiet_snapshot_updates = False,
        jest_repository = "jest",
        **kwargs):
    """jest_test rule

    Supports Bazel sharding. See https://docs.bazel.build/versions/main/test-encyclopedia.html#test-sharding.

    Supports updating snapshots with `bazel run {name}_update_snapshots` if `snapshots` are specified.

    Args:
        name: A unique name for this target.

        config: "Optional Jest config file. See https://jestjs.io/docs/configuration.

            Supported config file types are ".js", ".cjs", ".mjs", ".json" which come from https://jestjs.io/docs/configuration
            minus TypeScript since we this rule extends from the configuration. TypeScript jest configs should be transpiled
            before being passed to jest_test with [rules_ts](https://github.com/aspect-build/rules_ts).

        data: Runtime dependencies of the Jest test.

            This should include all test files, configuration files & files under test.

        snapshots: If True, a `{name}_update_snapshots` binary target is generated that will update the snapshots
            directory when `bazel run`. This is the equivalent to running `jest -u` or `jest --updateSnapshot` outside of Bazel.

            The `__snapshots__` directory must not contain any files except for snapshots. There must also be no
            BUILD files in the `__snapshots__` directory. If the name of the snapshot directory is not the default
            `__snapshots__` because of a custom snapshot resolver, you can specify a custom directory name by setting
            `snapshots` to the custom directory name instead of True.

            If snapshots are not configured to output to a directory that contains only snapshots, you may alternately
            set `snapshots` to a list of snapshot files expected to be generated by this `jest_test` target.
            These must be source files and all snapshots that are generated must be explicitly listed. You may use a
            `glob` such as `glob(["**/*.snap"])` to generate this list, in which case all snapshots must already be on
            disk so they are discovered by `glob`.

        run_in_band: When True, the `--runInBand` argument is passed to the Jest CLI so that all tests are run serially
            in the current process, rather than creating a worker pool of child processes that run tests. See
            https://jestjs.io/docs/cli#--runinband for more info.

            This is the desired default behavior under Bazel since Bazel expect each test process to use up one CPU core.
            To parallelize a single jest_test across many cores, use `shard_count` instead which is supported by `jest_test`.
            See https://docs.bazel.build/versions/main/test-encyclopedia.html#test-sharding.

        colors: When True, the `--colors` argument is passed to the Jest CLI. See https://jestjs.io/docs/cli#--colors.

        auto_configure_reporters: Let jest_test configure reporters for Bazel test and xml test logs.

            The `default` reporter is used for the standard test log and `jest-junit` is used for the xml log.
            These reporters are appended to the list of reporters from the user Jest `config` only if they are
            not already set.

            The `JEST_JUNIT_OUTPUT_FILE` environment variable is always set to where Bazel expects a test runner
            to write its xml test log so that if `jest-junit` is configured in the user Jest `config` it will output
            the junit xml file where Bazel expects by default.

        auto_configure_test_sequencer: Let jest_test configure a custom test sequencer for Bazel test that support Bazel sharding.

            Any custom testSequencer value in a user Jest `config` will be overridden.

            See https://jestjs.io/docs/configuration#testsequencer-string for more information on Jest testSequencer config option.

        snapshots_ext: The expected extensions for snapshot files. Defaults to `.snap`, the Jest default.

        quiet_snapshot_updates: When True, snapshot update stdout & stderr is hidden when the snapshot update is successful.

            On a snapshot update failure, its stdout & stderr will always be shown.

        jest_repository: Name of the repository created with jest_repositories().

        **kwargs: All other args from `js_test`. See https://github.com/aspect-build/rules_js/blob/main/docs/js_binary.md#js_test
    """
    tags = kwargs.pop("tags", [])

    snapshot_files = []
    if snapshots == True:
        snapshots = "__snapshots__"  # default jest snapshots directory
    if type(snapshots) == "string":
        snapshot_files = native.glob(["{}/**".format(snapshots)])
    elif type(snapshots) == "list":
        snapshot_files = snapshots
    elif snapshots != None:
        fail("snapshots expected to be a boolean, string or list")

    # This is the primary {name} jest_test test target
    _jest_from_repository(
        jest_rule = _jest_test,
        jest_repository = jest_repository,
        name = name,
        config = config,
        data = data + snapshot_files,
        run_in_band = run_in_band,
        colors = colors,
        auto_configure_reporters = auto_configure_reporters,
        auto_configure_test_sequencer = auto_configure_test_sequencer,
        tags = tags,
        **kwargs
    )

    if snapshots:
        gen_snapshots_bin = "{}_ref_snapshots_bin".format(name)
        update_snapshots = None
        update_directory = None
        if type(snapshots) == "string":
            update_snapshots = "directory"
            update_directory = snapshots
        elif type(snapshots) == "list":
            update_snapshots = "files"

        # This is the generated reference snapshot generator binary target that is used as the
        # `tool` in the `js_run_binary` target below to output the reference snapshots.
        _jest_from_repository(
            jest_rule = _jest_binary,
            jest_repository = jest_repository,
            name = gen_snapshots_bin,
            config = config,
            run_in_band = run_in_band,
            colors = colors,
            auto_configure_reporters = auto_configure_reporters,
            auto_configure_test_sequencer = auto_configure_test_sequencer,
            update_snapshots = update_snapshots,
            # Tagged manual so it is not built unless the {name}_update_snapshot target is run
            tags = tags + ["manual"],
            **kwargs
        )

        _jest_update_snapshots(
            name = name,
            config = config,
            data = data,
            tags = tags,
            update_directory = update_directory,
            snapshot_files = snapshot_files,
            gen_snapshots_bin = gen_snapshots_bin,
            snapshots_ext = snapshots_ext,
            quiet_snapshot_updates = quiet_snapshot_updates,
        )

def _jest_update_snapshots(
        name,
        config,
        data,
        tags,
        update_directory,
        snapshot_files,
        gen_snapshots_bin,
        snapshots_ext,
        quiet_snapshot_updates):
    for snapshot in snapshot_files:
        snapshot_label = to_label(snapshot)
        if snapshot_label.package != native.package_name():
            msg = "Expected jest_test '{target}' snapshots to be in test target package '{jest_test_package}' but got '{snapshot_label}' in package '{snapshot_package}'".format(
                jest_test_package = native.package_name(),
                snapshot_label = snapshot_label,
                snapshot_package = snapshot_label.package,
                target = to_label(name),
            )
            fail(msg)
        if not snapshot_label.name.endswith(snapshots_ext):
            msg = "Expected jest_test '{target}' snapshots to be labels to source files ending with extension '{snapshots_ext}' but got '{snapshot}'".format(
                snapshot = snapshot,
                snapshots_ext = snapshots_ext,
                target = to_label(name),
            )

    update_snapshots_files = {}
    if update_directory:
        # This js_run_binary outputs the reference snapshots directory used by the
        # write_source_files updater target below. Reference snapshots have a
        # REFERENCE_SNAPSHOT_SUFFIX suffix so the write_source_files is able to specify both the
        # source file snapshots and the reference snapshots by label.
        ref_snapshots_target = "{}{}".format(name, REFERENCE_BUILD_TARGET_SUFFIX)
        _js_run_binary(
            name = ref_snapshots_target,
            srcs = data + ([config] if config else []),
            out_dirs = ["{}/{}".format(update_directory, REFERENCE_SNAPSHOT_DIRECTORY)],
            tool = gen_snapshots_bin,
            silent_on_success = quiet_snapshot_updates,
            testonly = True,
            # Tagged manual so it is not built unless the {name}_update_snapshot target is run
            tags = tags + ["manual"],
        )
        update_snapshots_files[update_directory] = ref_snapshots_target
    else:
        snapshot_outs = []
        for snapshot in snapshot_files:
            snapshot_out = "{}{}".format(snapshot, REFERENCE_SNAPSHOT_SUFFIX)
            snapshot_outs.append(snapshot_out)
            update_snapshots_files[snapshot] = snapshot_out

        # This js_run_binary outputs the reference snapshots files used by the write_source_files
        # updater target below. Reference snapshots have a REFERENCE_SNAPSHOT_SUFFIX suffix so the
        # write_source_files is able to specify both the source file snapshots and the reference
        # snapshots by label.
        _js_run_binary(
            name = "{}{}".format(name, REFERENCE_BUILD_TARGET_SUFFIX),
            srcs = data + ([config] if config else []),
            outs = snapshot_outs,
            tool = gen_snapshots_bin,
            silent_on_success = quiet_snapshot_updates,
            testonly = True,
            # Tagged manual so it is not built unless the {name}_update_snapshot target is run
            tags = tags + ["manual"],
        )

    # The snapshot update binary target: {name}_update_snapshots
    _write_source_files(
        name = "{}{}".format(name, UPDATE_SNAPSHOTS_TARGET_SUFFIX),
        files = update_snapshots_files,
        # Jest will already fail if the snapshot is out-of-date so just use write_source_files
        # for the update script
        diff_test = False,
        testonly = True,
        # Tagged manual so it is not built unless run
        tags = tags + ["manual"],
        # Always public visibility so that it can be used downstream in an aggregate write_source_files target
        visibility = ["//visibility:public"],
    )
