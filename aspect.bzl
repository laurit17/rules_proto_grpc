load("//:plugin.bzl", "ProtoPluginInfo")
load(
    "//:common.bzl",
    "ProtoCompileInfo",
    "copy_file",
    "get_int_attr",
    "get_output_filename",
    "descriptor_proto_path",
)


ProtoLibraryAspectNodeInfo = provider(
    fields = {
        "output_files": "The files generated by this aspect and its transitive dependencies, as a dict indexed by the root directory",
        "output_dirs": "The directories generated by this aspect and its transitive dependencies, as a string list",
    },
)


proto_compile_attrs = {
    "verbose": attr.int(
        doc = "The verbosity level. Supported values and results are 1: *show command*, 2: *show command and sandbox after running protoc*, 3: *show command and sandbox before and after running protoc*, 4. *show env, command, expected outputs and sandbox before and after running protoc*",
    ),
    "verbose_string": attr.string(
        doc = "String version of the verbose string, used for aspect",
        default = "0",
    ),
    "prefix_path": attr.string(
        doc = "Path to prefix to the generated files in the output directory",
    ),
}


proto_compile_aspect_attrs = {
    "verbose_string": attr.string(
        doc = "String version of the verbose string, used for aspect",
        values = ["", "None", "0", "1", "2", "3", "4"],
        default = "0",
    ),
}


def proto_compile_impl(ctx):
    # Aggregate output files created by the aspect as it has walked the deps
    output_files = [dep[ProtoLibraryAspectNodeInfo].output_files for dep in ctx.attr.deps]
    output_dirs = [d for dirs in [dep[ProtoLibraryAspectNodeInfo].output_dirs for dep in ctx.attr.deps] for d in dirs]

    # Build output tree by aggregating files created by aspect
    # TODO: remove this and update library rules to consume the existing outputs
    copied_output_files = []
    prefix_path = ctx.attr.prefix_path

    for output_files_dict in output_files:
        for root, files in output_files_dict.items():
            for file in files:
                # Strip root from file path
                path = file.path
                if path.startswith(root):
                    path = path[len(root):]
                if path.startswith("/"):
                    path = path[1:]

                # Prepend prefix path if given
                if prefix_path:
                    path = prefix_path + '/' + path

                # Copy file to output
                copied_output_files.append(copy_file(
                    ctx, file,
                    "{}/{}".format(ctx.label.name, path)
                ))

    # Merge output directories created by aspect
    copied_output_dirs = []
    if output_dirs:
        # Declare shared output directory
        dir_name = ctx.label.name
        if prefix_path:
            dir_name = prefix_path + '/' + dir_name
        new_dir = ctx.actions.declare_directory(dir_name)
        copied_output_dirs.append(new_dir)

        # Copy directories to shared output directory in one action
        ctx.actions.run_shell(
            mnemonic = "CopyDirs",
            inputs = output_dirs,
            outputs = [new_dir],
            command = "cp -r {} '{}'".format(
                ' '.join(["'" + d.path + "'/*" for d in output_dirs]),
                new_dir.path
            ),
            progress_message = 'copying directories to {}'.format(new_dir.path),
        )

    # Create default and proto compile providers
    return [
        ProtoCompileInfo(
            label = ctx.label,
            outputs = copied_output_files + copied_output_dirs,
            files = copied_output_files + copied_output_dirs,
        ),
        DefaultInfo(
            files = depset(copied_output_files + copied_output_dirs),
            data_runfiles = ctx.runfiles(files=copied_output_files + copied_output_dirs),
        )
    ]


def proto_compile_aspect_impl(target, ctx):
    ###
    ### Part 1: setup variables used in scope
    ###

    # <int> verbose level
    # verbose = ctx.attr.verbose
    verbose = get_int_attr(ctx.attr, "verbose_string")

    # <struct> The resolved protoc toolchain
    protoc_toolchain_info = ctx.toolchains["@build_stack_rules_proto//protobuf:toolchain_type"]

    # <Target> The resolved protoc compiler from the protoc toolchain
    protoc = protoc_toolchain_info.protoc_executable

    # <ProtoInfo> The ProtoInfo of the current node
    proto_info = target[ProtoInfo]

    # <string> The directory where the outputs will be generated, relative to
    # the package. This contains the aspect _prefix attr to disambiguate
    # different aspects that may share the same plugins and would otherwise try
    # to touch the same file. The same is true for the verbose_string attr.
    rel_outdir = '{}/{}_verb{}'.format(ctx.label.name, ctx.attr._prefix, verbose)

    # <string> The full path to the directory where the outputs will be generated
    full_outdir = ctx.bin_dir.path + '/'
    if ctx.label.workspace_root:
        full_outdir += ctx.label.workspace_root + '/'
    if ctx.label.package:
        full_outdir += ctx.label.package + '/'
    full_outdir += rel_outdir

    # <list<PluginInfo>> A list of PluginInfo providers for the requested
    # plugins
    plugins = [plugin[ProtoPluginInfo] for plugin in ctx.attr._plugins]

    # <list<File>> The list of generated artifacts like 'foo_pb2.py' that we
    # expect to be produced.
    output_files = []

    # <list<File>> The list of generated artifacts directories that we
    # expect to be produced.
    output_dirs = []


    ###
    ### Part 2: iterate over plugins
    ###

    # Each plugin is isolated to its own execution of protoc, as plugins may
    # have differing exclusions that cannot be expressed in a single protoc
    # execution for all plugins

    for plugin in plugins:

        ###
        ### Part 2.1: fetch plugin tool and runfiles
        ###

        # <list<File>> Files required for running the plugins
        plugin_runfiles = []

        # <list<opaque>> Plugin input manifests
        plugin_input_manifests = None

        # Add plugin executable if not a built-in plugin
        plugin_tool = None
        if plugin.tool_executable:
            plugin_tool = plugin.tool_executable

        # Add plugin runfiles if plugin has a tool
        if plugin.tool:
            plugin_runfiles, plugin_input_manifests = ctx.resolve_tools(tools = [plugin.tool])
            plugin_runfiles = plugin_runfiles.to_list()

        # Add extra plugin data files
        plugin_runfiles += plugin.data

        # Check plugin outputs
        if plugin.output_directory and (plugin.out or plugin.outputs):
            fail('Proto plugin {} cannot use output_directory in conjunction with outputs or out'.format(plugin.name))


        ###
        ### Part 2.2: gather proto files and filter by exclusions
        ###

        # <list<File>> The filtered set of .proto files to compile
        protos = []

        for proto in proto_info.direct_sources:
            # Check for exclusion
            if any([
                proto.dirname.endswith(exclusion) or proto.path.endswith(exclusion)
                for exclusion in plugin.exclusions
            ]):
                continue

            # Proto not excluded
            protos.append(proto)

        # Skip plugin if all proto files have now been excluded
        if len(protos) == 0:
            if verbose > 2:
                print('Skipping plugin "{}" for "{}" as all proto files have been excluded'.format(plugin.name, ctx.label))
            continue


        ###
        ### Part 2.3: declare per-proto generated outputs from plugin
        ###

        # <list<File>> The list of generated artifacts like 'foo_pb2.py' that we
        # expect to be produced by this plugin only
        plugin_outputs = []

        for proto in protos:
            for pattern in plugin.outputs:
                plugin_outputs.append(ctx.actions.declare_file('{}/{}'.format(
                    rel_outdir,
                    get_output_filename(proto, pattern, proto_info)
                )))

        # Append current plugin outputs to global outputs before looking at
        # per-plugin outputs; these are manually added globally as there may
        # be srcjar outputs.
        output_files.extend(plugin_outputs)


        ###
        ### Part 2.4: declare per-plugin artifacts
        ###

        # Some protoc plugins generate a set of output files (like python) while
        # others generate a single 'archive' file that contains the individual
        # outputs (like java). Jar outputs are gathered as a special case as we need to
        # post-process them to have a 'srcjar' extension (java_library rules don't
        # accept source jars with a 'jar' extension)

        out_file = None
        if plugin.out:
            # Define out file
            out_file = ctx.actions.declare_file('{}/{}'.format(
                rel_outdir,
                plugin.out.replace("{name}", ctx.label.name)
            ))
            plugin_outputs.append(out_file)

            if not out_file.path.endswith(".jar"):
                # Add output direct to global outputs
                output_files.append(out_file)
            else:
                # Create .srcjar from .jar for global outputs
                output_files.append(copy_file(
                    ctx, out_file,
                    "{}.srcjar".format(out_file.basename.rpartition('.')[0]),
                    sibling=out_file
                ))


        ###
        ### Part 2.5: declare plugin output directory
        ###

        # Some plugins outputs a structure that cannot be predicted from the
        # input file paths alone. For these plugins, we simply declare the
        # directory.

        if plugin.output_directory:
            out_file = ctx.actions.declare_directory(rel_outdir)
            plugin_outputs.append(out_file)
            output_dirs.append(out_file)


        ###
        ### Part 2.6: build command
        ###

        # <Args> argument list for protoc execution
        args = ctx.actions.args()

        # Add proto paths
        #for proto_path in proto_info.transitive_proto_path.to_list():
        #    args.add("--proto_path={}".format(proto_path))

        # Add descriptors
        pathsep = ctx.configuration.host_path_separator
        args.add("--descriptor_set_in={}".format(pathsep.join(
            [f.path for f in proto_info.transitive_descriptor_sets.to_list()],
        )))

        # Add plugin if not built-in
        if plugin_tool:
            args.add("--plugin=protoc-gen-{}={}".format(plugin.name, plugin_tool.path))

        # Add plugin out arg
        out_arg = out_file.path if out_file else full_outdir
        if plugin.options:
            out_arg = "{}:{}".format(",".join(
                [option.replace("{name}", ctx.label.name) for option in plugin.options]
            ), out_arg)
        args.add("--{}_out={}".format(plugin.name, out_arg))

        # Add source proto files as descriptor paths
        for proto in protos:
            args.add(descriptor_proto_path(proto, proto_info))


        ###
        ### Part 2.7: run command
        ###

        mnemonic = "ProtoCompile"
        command = ("mkdir -p '{}' && ".format(full_outdir)) + protoc.path + " $@" # $@ is replaced with args list
        inputs = proto_info.transitive_descriptor_sets.to_list() + plugin_runfiles # Proto files are not inputs, as they come via the descriptor sets
        tools = [protoc] + ([plugin_tool] if plugin_tool else [])

        # Amend command with debug options
        if verbose > 0:
            print("{}:".format(mnemonic), protoc.path, args)

        if verbose > 1:
            command += " && echo '\n##### SANDBOX AFTER RUNNING PROTOC' && find . -type f "

        if verbose > 2:
            command = "echo '\n##### SANDBOX BEFORE RUNNING PROTOC' && find . -type l && " + command

        if verbose > 3:
            command = "env && " + command
            for f in inputs:
                print("INPUT:", f.path)
            for f in protos:
                print("TARGET PROTO:", f.path)
            for f in tools:
                print("TOOL:", f.path)
            for f in plugin_outputs:
                print("EXPECTED OUTPUT:", f.path)

        # Run protoc
        ctx.actions.run_shell(
            mnemonic = mnemonic,
            command = command,
            arguments = [args],
            inputs = inputs,
            tools = tools,
            outputs = plugin_outputs,
            input_manifests = plugin_input_manifests if plugin_input_manifests else [],
            progress_message = "Compiling protoc outputs for {} plugin".format(plugin.name),
        )


    ###
    ### Step 3: generate providers
    ###

    # Gather transitive info
    transitive_infos = [dep[ProtoLibraryAspectNodeInfo] for dep in ctx.rule.attr.deps]
    output_files_dict = {}
    if output_files:
        output_files_dict[full_outdir] = output_files

    for transitive_info in transitive_infos:
        for root, files in transitive_info.output_files.items():
            if root not in output_files_dict:
                output_files_dict[root] = []
            output_files_dict[root].extend(files)

        output_dirs += transitive_info.output_dirs

    return [
        ProtoLibraryAspectNodeInfo(
            output_files = output_files_dict,
            output_dirs = output_dirs,
        )
    ]
