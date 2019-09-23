load("//python:python_grpc_compile.bzl", "python_grpc_compile")

load(
    "@com_bluecore_rules_pyz//rules_python_zip:rules_python_zip.bzl",
    "pyz_library",
)

def python_grpc_library(**kwargs):
    # Compile protos
    name_pb = kwargs.get("name") + "_pb"
    python_grpc_compile(
        name = name_pb,
        **{k: v for (k, v) in kwargs.items() if k in ("deps", "verbose")} # Forward args
    )

    # Pick deps based on python version
    if "python_version" not in kwargs or kwargs["python_version"] == "PY3":
        grpc_deps = GRPC_PYTHON3_DEPS
    elif kwargs["python_version"] == "PY2":
        grpc_deps = GRPC_PYTHON2_DEPS
    else:
        fail("The 'python_version' attribute to python_grpc_library must be one of ['PY2', 'PY3']")


    # Create python library
    pyz_library(
        name = kwargs.get("name"),
        srcs = [name_pb],
        deps = [
            "@com_google_protobuf//:protobuf_python",
        ] + grpc_deps,
        # imports = [name_pb],
        visibility = kwargs.get("visibility"),
    )

GRPC_PYTHON2_DEPS = [
    "@rules_proto_grpc_py2_deps//grpcio"
]

GRPC_PYTHON3_DEPS = [
    "@rules_proto_grpc_py3_deps//grpcio"
]
